const std = @import("std");
const time = @import("../time.zig");
const store = @import("../store.zig");
const logging = @import("../logger.zig");
const ClientSession = @import("session.zig");
const ClientRegistry = @import("client_registry.zig");
const Poller = @import("poller.zig");
const CapacityCalculator = @import("capacity.zig");
const Admission = @import("admission.zig");
const ReadyQueue = @import("ready_queue.zig");
const ServerBudget = @import("server_budget.zig");

const ClientWorker = @This();

pub const PendingSession = Admission.PendingSession;
pub const SessionId = ClientSession.SessionId;
pub const WorkerId = u16;
// Errors preserve caller ownership. InvalidRegistrationState is not a refusal.
pub const RegisterError = Admission.EnqueueError;
pub const DeinitError = error{ WorkerNotJoined, WorkerSessionsNotDrained };
pub const LocalEndpointFn = *const fn (std.Io, std.Io.net.Socket.Handle) anyerror!std.Io.net.IpAddress;
pub const SpawnWorkerFn = *const fn (*ClientWorker) std.Thread.SpawnError!std.Thread;

pub const Scheduling = struct {
    setup_attempts_per_pass: usize,
    ready_turns_per_pass: usize,
    session_turn: ClientSession.TurnBudget,

    pub fn validate(self: Scheduling) error{InvalidSchedulingBudget}!void {
        _ = self;
        @panic("ClientWorker.Scheduling.validate is not implemented");
    }
};

pub const InitConfig = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    logger: logging.Logger,
    store: *store.Store,
    registry: *ClientRegistry,
    buffer_size: usize,
    worker_id: WorkerId,
    capacity: CapacityCalculator.Config,
    admission: Admission.Limits,
    scheduling: Scheduling,
    local_endpoint: LocalEndpointFn,
    spawn_worker: ?SpawnWorkerFn = null,
};

const OwnedConnection = union(enum) {
    pending: *?PendingSession,
    session: *ClientSession,
};

const OwnedResources = struct {
    stream: std.Io.net.Stream,
    server_reservation: ServerBudget.Reservation,
    worker_buffer_charge: usize,
};

_io: std.Io,
_allocator: std.mem.Allocator,
_logger: logging.Logger,
_store: *store.Store,
_registry: *ClientRegistry,
_worker_id: WorkerId,
_capacity: CapacityCalculator,
_admission: Admission,
_ready: ReadyQueue = .{},
_sessions: std.AutoHashMap(SessionId, *ClientSession),
_poller: Poller.Interface,
// Worker methods manage the handle. The manager owns the worker's lifetime.
_thread: ?std.Thread = null,
_spawn_worker: SpawnWorkerFn,
_started: std.Io.Event = .unset,
_buffer_size: usize,
_scheduling: Scheduling,
_local_endpoint: LocalEndpointFn,
_event_buffer: Poller.Interface.EventBuffer = undefined,

pub fn init(config: InitConfig) !ClientWorker {
    try config.scheduling.validate();
    const capacity = try CapacityCalculator.init(config.io, config.capacity, std.Io.Clock.awake.now(config.io));
    var admission = try Admission.init(config.io, config.allocator, config.admission);
    errdefer admission.deinit();
    const poller = try Poller.init();

    return .{
        ._io = config.io,
        ._allocator = config.allocator,
        ._logger = config.logger,
        ._store = config.store,
        ._registry = config.registry,
        ._worker_id = config.worker_id,
        ._capacity = capacity,
        ._admission = admission,
        ._sessions = .init(config.allocator),
        ._poller = poller,
        ._buffer_size = config.buffer_size,
        ._scheduling = config.scheduling,
        ._local_endpoint = config.local_endpoint,
        ._spawn_worker = config.spawn_worker orelse spawnWorkerThread,
    };
}

// The thread must be joined and sessions drained before releasing resources.
// Rejection leaves all resources owned by this worker.
pub fn deinit(self: *ClientWorker) DeinitError!void {
    if (self._thread != null) return error.WorkerNotJoined;

    if (self._sessions.count() != 0) return error.WorkerSessionsNotDrained;

    self._sessions.deinit();
    self._poller.deinit();
    self._admission.deinit();
}

pub fn start(self: *ClientWorker) !void {
    if (self._thread != null or self._admission.lifecycle() != .not_started) {
        return error.InvalidWorkerState;
    }
    self._thread = try self._spawn_worker(self);

    errdefer {
        self.requestStop() catch |err| {
            self._logger.err("worker: failed to stop after startup failure", err, @errorReturnTrace());
        };
        self.join();
    }

    try self.awaitRunning();
}

fn awaitRunning(self: *ClientWorker) !void {
    try self._started.wait(self._io);
    if (self._admission.lifecycle() != .running) return error.WorkerStartupFailed;
}

pub fn join(self: *ClientWorker) void {
    if (self._thread) |thread| {
        thread.join();
        self._thread = null;
    }
}

pub fn id(self: *const ClientWorker) WorkerId {
    return self._worker_id;
}

// Thread-safe assessment. Also used by the final registration recheck.
pub fn assessCapacity(self: *ClientWorker, now_ns: std.Io.Timestamp) CapacityCalculator.Assessment {
    const view = self._admission.snapshot();
    return self._capacity.evaluate(view, now_ns);
}

// Errors keep caller ownership. Success consumes pending before waking.
pub fn register(self: *ClientWorker, pending: *?PendingSession) RegisterError!void {
    if (pending.* == null) return error.InvalidRegistrationState;
    switch (self.assessCapacity(std.Io.Clock.awake.now(self._io))) {
        .refused => |err| return err,
        .allowed => {},
    }
    try self._admission.enqueue(pending, std.Io.Clock.awake.now(self._io));
    self._poller.wake() catch |err| {
        self.reportFatalWorkerFailure(err, @errorReturnTrace());
    };
}

pub fn closeAdmission(self: *ClientWorker) void {
    self._admission.requestStop();
}

pub fn requestStop(self: *ClientWorker) !void {
    self._admission.requestStop();
    if (self._thread == null) return;

    self._poller.wake() catch |err| {
        self.interruptFailedWait();
        return err;
    };
}

fn spawnWorkerThread(self: *ClientWorker) std.Thread.SpawnError!std.Thread {
    return std.Thread.spawn(.{}, threadMain, .{self});
}

// Entry for default and injected spawners. Report failures at the worker boundary.
pub fn threadMain(self: *ClientWorker) void {
    self.run() catch |err| self.reportFatalWorkerFailure(err, @errorReturnTrace());
}

pub fn run(self: *ClientWorker) !void {
    defer self._started.set(self._io);
    defer self.finishRun();
    errdefer self._admission.markFailed();

    if (!self._admission.markRunning()) return;
    self._started.set(self._io);

    while (self._admission.lifecycle() == .running) {
        const now_ns = std.Io.Clock.awake.now(self._io);
        self._capacity.schedulerBoundary(now_ns);
        self._capacity.updateRecovery(now_ns);

        const timeout_ms = self.nextPollTimeout(now_ns);
        if (timeout_ms == null or timeout_ms.? > 0) {
            self._capacity.setPhase(.waiting, std.Io.Clock.awake.now(self._io));
        }

        const wait_result = self._poller.wait(&self._event_buffer, timeout_ms);
        const resumed_at_ns = std.Io.Clock.awake.now(self._io);
        self._capacity.setPhase(.processing, resumed_at_ns);
        self._capacity.schedulerBoundary(resumed_at_ns);
        const events = try wait_result;

        self.recordReadyEvents(events, resumed_at_ns);
        if (self._admission.lifecycle() != .running) break;
        self.processPendingWithinBudget();
        self.processReadyWithinBudget();
    }
}

fn nextPollTimeout(self: *ClientWorker, now_ns: std.Io.Timestamp) ?time.DurationMs {
    if (self._admission.snapshot().queued != 0 or !self._ready.isEmpty()) return 0;
    return timeoutUntil(self._capacity.nextUpdateAt(now_ns), now_ns);
}

// Round positive durations up to milliseconds and clamp to DurationMs range.
fn timeoutUntil(next_check_ns: ?std.Io.Timestamp, now_ns: std.Io.Timestamp) ?time.DurationMs {
    _ = .{ next_check_ns, now_ns };
    @panic("ClientWorker.timeoutUntil is not implemented");
}

fn processPendingWithinBudget(self: *ClientWorker) void {
    for (0..self._scheduling.setup_attempts_per_pass) |_| {
        if (self._admission.lifecycle() != .running) break;
        var pending: ?PendingSession = self._admission.takeForSetup() orelse break;
        const started_at_ns = std.Io.Clock.awake.now(self._io);
        self._capacity.schedulerBoundary(started_at_ns);
        const result = self.setupSession(&pending);
        const finished_at_ns = std.Io.Clock.awake.now(self._io);
        const elapsed_ns = started_at_ns.durationTo(finished_at_ns);
        self._admission.finishSetup();
        self._capacity.setupFinished(elapsed_ns, finished_at_ns);

        _ = result catch |err| {
            self.closeOwned(.{ .pending = &pending });
            self._logger.err("connection: session setup failed", err, @errorReturnTrace());
            continue;
        };
    }
}

// Success publishes the live lookup/poller/registry before consuming pending.
// Failure rolls back partial setup and leaves stream and charges in pending.
fn setupSession(self: *ClientWorker, pending: *?PendingSession) anyerror!*ClientSession {
    const entry = pending.* orelse return error.InvalidSessionSetupState;
    const session = try self.createSession(entry);
    pending.* = null;
    return session;
}

// Success transfers entry's stream and charges into the published session.
// Failure rolls back partial setup and leaves entry's resources with the caller.
fn createSession(self: *ClientWorker, entry: PendingSession) anyerror!*ClientSession {
    _ = .{ self, entry };
    @panic("ClientWorker.createSession is not implemented");
}

fn recordReadyEvents(self: *ClientWorker, events: []const Poller.Interface.Event, now_ns: std.Io.Timestamp) void {
    for (events) |event| {
        switch (event) {
            .worker_notified => {},
            .socket_ready => |ready| {
                const session = self._sessions.get(ready.token) orelse continue;
                self._ready.push(session, .{
                    .readable = ready.readable,
                    .writable = ready.writable,
                    .read_closed = ready.read_closed,
                    .has_error = ready.has_error,
                }, now_ns);
            },
        }
    }
    self.publishReadyHead(null, now_ns);
}

fn processReadyWithinBudget(self: *ClientWorker) void {
    for (0..self._scheduling.ready_turns_per_pass) |_| {
        if (self._admission.lifecycle() != .running) break;
        const turn = self._ready.pop() orelse break;
        const now_ns = std.Io.Clock.awake.now(self._io);
        const served_wait_ns = turn.ready_since_ns.durationTo(now_ns);
        self.publishReadyHead(served_wait_ns, now_ns);
        self._capacity.schedulerBoundary(now_ns);
        const outcome = turn.session.serviceTurn(turn.signals, self._scheduling.session_turn) catch |err| {
            self.closeOwned(.{ .session = turn.session });
            self._logger.err("connection: session turn failed", err, @errorReturnTrace());
            continue;
        };
        switch (outcome) {
            .runnable => |signals| self.scheduleContinuation(turn.session, signals),
            .waiting => |interests| self._poller.modify(turn.session.stream(), .{
                .read = interests.read,
                .write = interests.write,
            }) catch |err| {
                self.closeOwned(.{ .session = turn.session });
                self._logger.err("connection: failed to update socket interests", err, @errorReturnTrace());
            },
            .closed => self.closeOwned(.{ .session = turn.session }),
        }
    }
}

fn scheduleContinuation(self: *ClientWorker, session: *ClientSession, signals: ClientSession.ReadySignals) void {
    const now_ns = std.Io.Clock.awake.now(self._io);
    var next_signals = signals;
    next_signals.local_work = true;
    self._ready.push(session, next_signals, now_ns);
    self.publishReadyHead(null, now_ns);
}

fn publishReadyHead(self: *ClientWorker, served_wait_ns: ?std.Io.Duration, now_ns: std.Io.Timestamp) void {
    self._capacity.readyChanged(self._ready.oldestTimestamp(), served_wait_ns, now_ns);
}

fn finishRun(self: *ClientWorker) void {
    self._admission.requestStop();
    self.closeAllOwned();
    self._admission.markClosed();
}

fn closeAllOwned(self: *ClientWorker) void {
    while (self._admission.takeForClose()) |entry| {
        var pending: ?PendingSession = entry;
        self.closeOwned(.{ .pending = &pending });
    }
    while (self._sessions.count() != 0) {
        var iterator = self._sessions.valueIterator();
        const session = iterator.next().?.*;
        self.closeOwned(.{ .session = session });
    }
}

fn closeOwned(self: *ClientWorker, connection: OwnedConnection) void {
    var resources: OwnedResources = switch (connection) {
        .pending => |pending| blk: {
            const entry = pending.* orelse return;
            pending.* = null;
            break :blk .{
                .stream = entry.stream,
                .server_reservation = entry.server_reservation,
                .worker_buffer_charge = entry.worker_buffer_charge,
            };
        },
        .session => |session| blk: {
            self._ready.remove(session);
            self.publishReadyHead(null, std.Io.Clock.awake.now(self._io));
            break :blk self.detachSession(session);
        },
    };
    resources.stream.close(self._io);
    self._admission.releaseOwned(resources.worker_buffer_charge);
    resources.server_reservation.release();
}

// Invalidate lookup/poller/registry membership and free session-owned storage.
// Move stream and charges out before destroying the stable session allocation.
fn detachSession(self: *ClientWorker, session: *ClientSession) OwnedResources {
    _ = .{ self, session };
    @panic("ClientWorker.detachSession is not implemented");
}

fn reportFatalWorkerFailure(self: *ClientWorker, err: anyerror, trace: ?*std.builtin.StackTrace) void {
    self._admission.markFailed();
    self.publishFatalFailure(err, trace);
}

// Must signal server supervision and reliably unblock failed backend waits.
// The trace is borrowed only for this call. Never retain its pointer.
fn publishFatalFailure(self: *ClientWorker, err: anyerror, trace: ?*std.builtin.StackTrace) void {
    _ = .{ self, trace };
    _ = @errorName(err);
    @panic("ClientWorker.publishFatalFailure is not implemented");
}

fn interruptFailedWait(self: *ClientWorker) void {
    _ = self;
    @panic("ClientWorker.interruptFailedWait is not implemented");
}

test "deinit refuses an unjoined worker thread before accessing resources" {
    const FinishedThread = struct {
        fn run() void {}
    };

    // Only the thread is initialized. Rejection must not access other resources.
    var worker: ClientWorker = undefined;
    worker._thread = try std.Thread.spawn(.{}, FinishedThread.run, .{});
    defer worker.join();

    try std.testing.expectError(error.WorkerNotJoined, worker.deinit());
    try std.testing.expect(worker._thread != null);
}

test "deinit preserves undrained worker sessions" {
    var worker: ClientWorker = undefined;
    worker._thread = null;
    worker._sessions = .init(std.testing.allocator);
    defer worker._sessions.deinit();
    var session: ClientSession = undefined;
    try worker._sessions.put(1, &session);

    try std.testing.expectError(error.WorkerSessionsNotDrained, worker.deinit());
    try std.testing.expectEqual(@as(usize, 1), worker._sessions.count());
    try std.testing.expectEqual(&session, worker._sessions.get(1).?);
}
