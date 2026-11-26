const std = @import("std");
const ConnectionContext = @import("context.zig");
const ClientWorker = @import("worker.zig");
const ClientRegistry = @import("client_registry.zig");
const WorkerSelector = @import("worker_selector.zig");
const CapacityCalculator = @import("capacity.zig");
const Admission = @import("admission.zig");
const ServerBudget = @import("server_budget.zig");
const Lock = @import("../lock.zig");
const socket_metadata = @import("socket_metadata.zig");
const logging = @import("../logger.zig");
const store = @import("../store.zig");
const TestNetwork = @import("test_network.zig");

const ConnectionManager = @This();

pub const SpawnWorkerFn = ClientWorker.SpawnWorkerFn;
pub const LocalEndpointFn = ClientWorker.LocalEndpointFn;

pub const CapacitySettings = struct {
    calculator: CapacityCalculator.Config,
    worker_limits: Admission.Limits,
    server_limits: ServerBudget.Limits,
    scheduling: ClientWorker.Scheduling,

    // Reject if there are any invalid settings
    pub fn validate(self: CapacitySettings, connection_buffer_size: usize) !void {
        try self.calculator.validate();
        try self.worker_limits.validate();
        try self.server_limits.validate();
        try self.scheduling.validate();
        try self.validateRelationships(connection_buffer_size);
    }

    fn validateRelationships(self: CapacitySettings, connection_buffer_size: usize) error{InvalidCapacitySettings}!void {
        _ = .{ self, connection_buffer_size };
        @panic("ConnectionManager.CapacitySettings.validateRelationships is not implemented");
    }
};

pub const Options = struct {
    local_endpoint: LocalEndpointFn = socket_metadata.localEndpoint,
    spawn_worker: ?SpawnWorkerFn = null,
    capacity_settings: ?CapacitySettings = null,
};

pub const InitParams = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: logging.Logger,
    data_store: *store.Store,
    connection_buffer_size: usize,
};

pub const InitConfig = union(enum) {
    default: InitParams,
    with_runtime_config: struct {
        params: InitParams,
        options: Options,
    },
};

pub const AdmissionOutcome = union(enum) {
    accepted,
    refused: RefusalReason,
};
pub const RefusalReason = enum {
    budget_exhausted,
    no_worker_capacity,
};

const PrepareError = error{
    ManagerStopping,
    NoWorkerCapacity,
    CapacityNotConfigured,
    BudgetExhausted,
    ConnectionIdExhausted,
};

_io: std.Io,
_allocator: std.mem.Allocator,
_logger: logging.Logger,
_store: *store.Store,
// Activated once at start, at this manager's stable address.
_budget: ?ServerBudget = null,
_capacity_settings: ?CapacitySettings,
_lock: Lock,
_registry: ClientRegistry,
_workers: std.ArrayList(*ClientWorker) = .empty,
_worker_selector: WorkerSelector.LinearScan,
_registry_released: bool = false,
_next_connection_id: ClientWorker.SessionId = 1,
_connection_buffer_size: usize,
_stopping: std.atomic.Value(bool) = .init(false),
_spawn_worker: ?SpawnWorkerFn,
_local_endpoint: LocalEndpointFn,

pub fn init(config: InitConfig) ConnectionManager {
    const params, const options = switch (config) {
        .default => |params| .{ params, Options{} },
        .with_runtime_config => |custom| .{ custom.params, custom.options },
    };
    return .{
        ._io = params.io,
        ._allocator = params.allocator,
        ._logger = params.logger,
        ._store = params.data_store,
        ._capacity_settings = options.capacity_settings,
        ._connection_buffer_size = params.connection_buffer_size,
        ._lock = Lock.init(params.io),
        ._registry = ClientRegistry.init(params.io, params.allocator),
        ._worker_selector = WorkerSelector.LinearScan.init(params.io, params.allocator),
        ._spawn_worker = options.spawn_worker,
        ._local_endpoint = options.local_endpoint,
    };
}

// Registration and destruction are serialized by the server lifecycle.
pub fn deinit(self: *ConnectionManager) !void {
    if (self.isClosed()) return;
    self._stopping.store(true, .release);
    var first_error: ?anyerror = null;
    self.destroyWorkersFrom(0) catch |err| {
        // Remaining workers still borrow the registry, budget, and store.
        if (self._workers.items.len != 0) return err;
        first_error = err;
    };
    self._workers.deinit(self._allocator);
    self._workers = .empty;
    self._worker_selector.selector().deinit();
    self._registry.deinit();
    self._registry_released = true;
    self._budget = null;
    if (first_error) |err| return err;
}

// Closed means every worker and manager-owned cleanup resource was released.
pub fn isClosed(self: *const ConnectionManager) bool {
    return self._registry_released;
}

pub fn start(self: *ConnectionManager, thread_count: u16) !void {
    const previous_worker_count = self._workers.items.len;
    if (thread_count == 0 or thread_count > WorkerSelector.Interface.max_workers - previous_worker_count) {
        return error.InvalidWorkerCount;
    }

    if (self._stopping.load(.acquire)) return error.ManagerStopping;

    const settings = self._capacity_settings orelse return error.CapacityNotConfigured;
    try settings.validate(self._connection_buffer_size);

    if (self._budget == null) self._budget = ServerBudget.init(self._io, settings.server_limits);
    const selector = self._worker_selector.selector();
    try self._workers.ensureUnusedCapacity(self._allocator, thread_count);

    errdefer {
        self.destroyWorkersFrom(previous_worker_count) catch |err| {
            if (self._workers.items.len > previous_worker_count) self._stopping.store(true, .release);
            self._logger.err("connection manager: failed to roll back worker startup", err, @errorReturnTrace());
        };
    }

    for (0..thread_count) |_| {
        const worker_id: WorkerSelector.Interface.WorkerId = @intCast(self._workers.items.len);
        const worker = try self.createWorker(worker_id, settings);
        // Keep ownership visible even when registration, startup, or cleanup fails.
        self._workers.appendAssumeCapacity(worker);

        try selector.addWorker(.{
            .id = worker_id,
            .ptr = worker,
            .assess_capacity = readCapacityAssessment,
        });
        try worker.start();
    }
}

// Consumes the stream on every return. Expected refusal is a normal outcome.
pub fn register(self: *ConnectionManager, stream: std.Io.net.Stream) !AdmissionOutcome {
    // Manger keeps the ownership of pending session to be able to retry on different workers
    var pending: ?ClientWorker.PendingSession = self.preparePending(stream) catch |err| switch (err) {
        error.ManagerStopping, error.NoWorkerCapacity => return .{ .refused = .no_worker_capacity },
        error.BudgetExhausted => return .{ .refused = .budget_exhausted },
        else => return err,
    };

    var selection = self._worker_selector.selector().selection(std.Io.Clock.awake.now(self._io)) catch |err| {
        self.closeUnassigned(&pending);
        return err;
    };
    while (selection.next()) |worker_id| {
        const worker = self._workers.items[worker_id];
        worker.register(&pending) catch |err| {
            if (pending == null) return error.InvalidRegistrationState;
            if (err == error.InvalidRegistrationState) {
                self.closeUnassigned(&pending);
                return err;
            }
            continue;
        };

        if (pending != null) return error.InvalidRegistrationState;
        return .accepted;
    }

    self.closeUnassigned(&pending);
    return .{ .refused = .no_worker_capacity };
}

// Owns the stream until a complete pending connection can be returned.
fn preparePending(self: *ConnectionManager, stream: std.Io.net.Stream) PrepareError!ClientWorker.PendingSession {
    errdefer stream.close(self._io);

    if (self._stopping.load(.acquire)) return error.ManagerStopping;

    const budget = if (self._budget) |*active| active else return error.NoWorkerCapacity;
    const settings = self._capacity_settings orelse return error.CapacityNotConfigured;
    var reservation = budget.reserveNewSession(settings.worker_limits.initial_buffer_bytes) orelse {
        return error.BudgetExhausted;
    };
    errdefer reservation.release();

    return .{
        .id = try self.nextConnectionId(),
        .stream = stream,
        .enqueued_at_ns = .zero,
        .server_reservation = reservation,
        .worker_buffer_charge = 0,
    };
}

fn closeUnassigned(self: *ConnectionManager, pending: *?ClientWorker.PendingSession) void {
    var entry = pending.* orelse return;
    pending.* = null;
    entry.stream.close(self._io);
    entry.server_reservation.release();
}

fn createWorker(self: *ConnectionManager, worker_id: WorkerSelector.Interface.WorkerId, settings: CapacitySettings) !*ClientWorker {
    const worker = try self._allocator.create(ClientWorker);
    errdefer self._allocator.destroy(worker);

    worker.* = try ClientWorker.init(.{
        .io = self._io,
        .allocator = self._allocator,
        .logger = self._logger,
        .store = self._store,
        .registry = &self._registry,
        .buffer_size = self._connection_buffer_size,
        .worker_id = worker_id,
        .capacity = settings.calculator,
        .admission = settings.worker_limits,
        .scheduling = settings.scheduling,
        .local_endpoint = self._local_endpoint,
        .spawn_worker = self._spawn_worker,
    });

    return worker;
}

fn readCapacityAssessment(ptr: *anyopaque, now_ns: std.Io.Timestamp) CapacityCalculator.Assessment {
    const worker: *ClientWorker = @ptrCast(@alignCast(ptr));
    return worker.assessCapacity(now_ns);
}

// Stop and join the whole suffix before freeing any worker in it.
fn destroyWorkersFrom(self: *ConnectionManager, first_worker: usize) !void {
    const workers = self._workers.items[first_worker..];
    const selector = self._worker_selector.selector();
    var first_error: ?anyerror = null;
    for (workers) |worker| worker.closeAdmission();
    for (workers) |worker| selector.removeWorker(worker.id());
    for (workers) |worker| {
        worker.requestStop() catch |err| {
            if (first_error == null) first_error = err;
        };
    }
    for (workers) |worker| worker.join();
    try self.deinitJoinedWorkers(first_worker);
    if (first_error) |err| return err;
}

// A rejected cleanup leaves that worker and the remaining suffix in the pool.
fn deinitJoinedWorkers(self: *ConnectionManager, first_worker: usize) ClientWorker.DeinitError!void {
    while (self._workers.items.len > first_worker) {
        const worker = self._workers.items[self._workers.items.len - 1];
        try worker.deinit();
        _ = self._workers.pop();
        self._allocator.destroy(worker);
    }
}

fn nextConnectionId(self: *ConnectionManager) error{ConnectionIdExhausted}!ClientWorker.SessionId {
    if (self._next_connection_id > std.math.maxInt(i64)) return error.ConnectionIdExhausted;
    const current_id = self._next_connection_id;
    self._next_connection_id += 1;
    return current_id;
}

// CLIENT snapshot migration is separate from capacity admission wiring.
pub fn snapshotLive(_: *ConnectionManager, _: std.Io, _: std.mem.Allocator) ConnectionContext.Error!ConnectionContext.LiveSnapshots {
    @panic("ConnectionManager.snapshotLive is not implemented");
}

test "manager retains a worker when joined cleanup is rejected" {
    const testing = std.testing;
    const ClientSession = @import("session.zig");
    var manager: ConnectionManager = undefined;
    manager._allocator = testing.allocator;
    manager._workers = .empty;
    defer manager._workers.deinit(testing.allocator);

    const worker = try testing.allocator.create(ClientWorker);
    defer testing.allocator.destroy(worker);
    worker.* = undefined;
    worker._thread = null;
    worker._sessions = .init(testing.allocator);
    defer worker._sessions.deinit();
    var session: ClientSession = undefined;
    // The guard reads membership only. No session resource is accessed.
    try worker._sessions.put(1, &session);
    try manager._workers.append(testing.allocator, worker);

    try testing.expectError(error.WorkerSessionsNotDrained, manager.deinitJoinedWorkers(0));
    try testing.expectEqual(@as(usize, 1), manager._workers.items.len);
    try testing.expectEqual(worker, manager._workers.items[0]);
    try testing.expectEqual(@as(usize, 1), worker._sessions.count());
}

test "thread spawn failure consumes its ID and closes the stream once" {
    const testing = std.testing;
    const failSpawn = struct {
        fn spawn(worker: *ClientWorker) std.Thread.SpawnError!std.Thread {
            if (worker.context.id == 1) {
                worker.context.setLibraryInfo(.lib_name, "failed-worker") catch return error.SystemResources;
                worker.context.setLibraryInfo(.lib_ver, "V1") catch return error.SystemResources;
                return error.ThreadQuotaExceeded;
            }
            return std.Thread.spawn(.{}, ClientWorker.threadMain, .{worker});
        }
    }.spawn;

    var network = TestNetwork.init(testing.io, 1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(.{ .with_runtime_config = .{
        .params = .{
            .io = network.io(),
            .allocator = testing.allocator,
            .logger = logging.NoopLogger.logger(),
            .data_store = &data_store,
            .connection_buffer_size = 1024,
        },
        .options = .{ .spawn_worker = failSpawn, .local_endpoint = TestNetwork.localEndpoint },
    } });
    errdefer manager.deinit() catch {};

    try testing.expectError(error.ThreadQuotaExceeded, manager.start(TestNetwork.stream(1)));
    try testing.expectEqual(1, network.close_calls.load(.acquire));
    try testing.expectEqual(0, manager._workers.items.len);
    var unpublished = try manager.snapshotLive(manager._io, testing.allocator);
    defer unpublished.deinit();
    try testing.expectEqual(0, unpublished.items.len);

    try manager.start(TestNetwork.stream(2));
    network.all_reads_started.waitUncancelable(testing.io);
    try testing.expectEqual(@as(u64, 2), manager._workers.items[0].context.id);
    try manager.deinit();
    try testing.expectEqual(2, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "ID exhaustion rejects registration without wrapping or closing twice" {
    const testing = std.testing;
    var network = TestNetwork.init(testing.io, 1);
    var mock = store.MockStore.init();
    var data_store = mock.store();
    var manager = ConnectionManager.init(.{ .with_runtime_config = .{
        .params = .{
            .io = network.io(),
            .allocator = testing.allocator,
            .logger = logging.NoopLogger.logger(),
            .data_store = &data_store,
            .connection_buffer_size = 1024,
        },
        .options = .{ .local_endpoint = TestNetwork.localEndpoint },
    } });
    errdefer manager.deinit() catch {};
    manager._next_connection_id = std.math.maxInt(i64);

    try manager.start(TestNetwork.stream(1));
    network.all_reads_started.waitUncancelable(testing.io);
    const worker = manager._workers.items[0];
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)), worker.context.id);

    for (2..4) |handle| {
        try testing.expectError(error.ConnectionIdExhausted, manager.start(TestNetwork.stream(handle)));
    }
    try testing.expectEqual(@as(u64, std.math.maxInt(i64)) + 1, manager._next_connection_id);
    try testing.expectEqual(1, manager._workers.items.len);
    try testing.expect(manager._workers.items[0] == worker);
    try testing.expectEqual(2, network.close_calls.load(.acquire));

    try manager.deinit();
    try testing.expectEqual(3, network.close_calls.load(.acquire));
    try testing.expectEqual(1, network.shutdown_calls.load(.acquire));
}

test "worker and collection allocation failures close the consumed stream once" {
    const testing = std.testing;
    for (0..2) |fail_index| {
        var network = TestNetwork.init(testing.io, 0);
        var mock = store.MockStore.init();
        var data_store = mock.store();
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var manager = ConnectionManager.init(.{ .with_runtime_config = .{
            .params = .{
                .io = network.io(),
                .allocator = failing_allocator.allocator(),
                .logger = logging.NoopLogger.logger(),
                .data_store = &data_store,
                .connection_buffer_size = 1024,
            },
            .options = .{ .local_endpoint = TestNetwork.localEndpoint },
        } });
        errdefer manager.deinit() catch {};

        try testing.expectError(error.OutOfMemory, manager.start(TestNetwork.stream(1)));
        try testing.expectEqual(0, manager._workers.items.len);
        try testing.expectEqual(1, network.close_calls.load(.acquire));
        try manager.deinit();
        try testing.expectEqual(1, network.close_calls.load(.acquire));
    }
}
