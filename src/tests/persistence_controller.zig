const std = @import("std");
const application = @import("application");
const protocol = @import("persistence_test_protocol");

const PersistenceController = @This();
const ForkFn = *const fn () anyerror!std.posix.pid_t;
const WaitPidFn = *const fn (std.posix.pid_t) anyerror!?u32;
const SyncFn = *const fn (?*anyopaque, std.Io.File) std.Io.File.SyncError!void;

const BackendAdapter = struct {
    original_fork: ForkFn,
    original_io: std.Io,
    vtable: std.Io.VTable,

    fn init(fork_fn: ForkFn, base_io: std.Io, sync_fn: SyncFn) BackendAdapter {
        var vtable = base_io.vtable.*;
        vtable.fileSync = sync_fn;
        return .{ .original_fork = fork_fn, .original_io = base_io, .vtable = vtable };
    }

    fn adaptedIo(self: *const BackendAdapter) std.Io {
        return .{ .userdata = self.original_io.userdata, .vtable = &self.vtable };
    }
};

// Existing fork and wait interfaces have no context argument. One controlled
// Server uses this pointer from setup until the shared application returns.
var active_controller: ?*PersistenceController = null;

environ: std.process.Environ,
configured: bool = false,
event_fd: ?std.posix.fd_t = null,
release_fd: ?std.posix.fd_t = null,
server_pid: std.posix.pid_t = 0,
backend: protocol.Backend = .kgc,
gate_stage: protocol.Stage = .synced,
next_operation: std.atomic.Value(u32) = .init(0),
selected_pid: std.atomic.Value(std.posix.pid_t) = .init(0),
kgc: ?BackendAdapter = null,
aof: ?BackendAdapter = null,
original_wait_pid: ?WaitPidFn = null,
// These fields change only in a fork child's copied memory.
child_backend: ?protocol.Backend = null,
child_pid: std.posix.pid_t = 0,
child_synced: bool = false,

// Initialization is inert so version and health modes never parse controls.
pub fn init(environ: std.process.Environ) PersistenceController {
    return .{ .environ = environ };
}

pub fn options(self: *PersistenceController) application.Options {
    return .{
        .lifecycle_hooks = .{
            .context = self,
            .on_persistence_draining = draining,
        },
        .configure_server = .{ .context = self, .configure = configure },
    };
}

// Keep this context and its vtables at a stable address through Server cleanup.
// TODO: here we are overriding private fields, refactor this
fn configure(context: *anyopaque, server: *application.Server) anyerror!void {
    const self: *PersistenceController = @ptrCast(@alignCast(context));
    if (self.configured or active_controller != null) return error.TestControlAlreadyConfigured;
    self.configured = true;
    if (!try self.loadSettings()) return;

    self.kgc = BackendAdapter.init(server._kgc._fork, server._kgc._io, syncKgc);
    if (server._aof) |*aof| {
        self.aof = BackendAdapter.init(aof._fork, aof._io, syncAof);
    }
    self.original_wait_pid = server._persistence_state._process.wait_pid;
    active_controller = self;

    server._kgc._fork = forkKgc;
    server._kgc._io = self.kgc.?.adaptedIo();
    if (self.aof) |*adapter| {
        server._aof.?._fork = forkAof;
        server._aof.?._io = adapter.adaptedIo();
    }
    server._persistence_state._process.wait_pid = waitPid;
}

fn loadSettings(self: *PersistenceController) !bool {
    const setting = std.process.Environ.getPosix(self.environ, "KGCACHE_TEST_CONTROL") orelse return false;
    var fields = std.mem.tokenizeScalar(u8, setting, ' ');
    const event_fd = try std.fmt.parseInt(std.posix.fd_t, fields.next() orelse return error.InvalidTestControl, 10);
    const release_fd = try std.fmt.parseInt(std.posix.fd_t, fields.next() orelse return error.InvalidTestControl, 10);
    const backend = std.meta.stringToEnum(protocol.Backend, fields.next() orelse return error.InvalidTestControl) orelse return error.InvalidTestControl;
    const gate_stage = std.meta.stringToEnum(protocol.Stage, fields.next() orelse return error.InvalidTestControl) orelse return error.InvalidTestControl;
    if (gate_stage != .before_write and gate_stage != .synced) return error.InvalidTestControl;
    if (fields.next() != null or event_fd < 3 or release_fd < 3) return error.InvalidTestControl;

    self.event_fd = event_fd;
    self.release_fd = release_fd;
    self.backend = backend;
    self.gate_stage = gate_stage;
    self.server_pid = std.c.getpid();
    return true;
}

// The application finishes Server cleanup before releasing these dependencies.
pub fn deinit(self: *PersistenceController) void {
    if (active_controller == self) active_controller = null;
    if (self.event_fd) |fd| _ = std.c.close(fd);
    if (self.release_fd) |fd| _ = std.c.close(fd);
    self.event_fd = null;
    self.release_fd = null;
}

fn claim(self: *PersistenceController, candidate: protocol.Backend) bool {
    return self.event_fd != null and candidate == self.backend and
        self.next_operation.fetchAdd(1, .monotonic) == 0;
}

fn forkKgc() anyerror!std.posix.pid_t {
    const self = active_controller.?;
    return self.forkBackend(.kgc, self.kgc.?.original_fork);
}

fn forkAof() anyerror!std.posix.pid_t {
    const self = active_controller.?;
    return self.forkBackend(.aof, self.aof.?.original_fork);
}

fn forkBackend(self: *PersistenceController, candidate: protocol.Backend, original: ForkFn) !std.posix.pid_t {
    const selected = self.claim(candidate);
    const pid = try original();
    if (pid == 0) {
        self.child_backend = if (selected) candidate else null;
        self.child_pid = if (selected) std.c.getpid() else 0;
        self.child_synced = false;
        if (selected and self.gate_stage == .before_write) {
            // No descriptor opens occur before the backend repeats these closes.
            // Close now so a blocked gate does not keep stdout open.
            _ = std.c.close(std.posix.STDIN_FILENO);
            _ = std.c.close(std.posix.STDOUT_FILENO);
            if (self.waitAtGate(.before_write) == 'f') std.c._exit(1);
        }
        return 0;
    }
    if (selected) self.selected_pid.store(pid, .release);
    return pid;
}

fn syncKgc(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    const self = active_controller.?;
    try self.kgc.?.original_io.vtable.fileSync(userdata, file);
    self.childSynced(.kgc);
}

fn syncAof(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
    const self = active_controller.?;
    try self.aof.?.original_io.vtable.fileSync(userdata, file);
    self.childSynced(.aof);
}

fn childSynced(self: *PersistenceController, candidate: protocol.Backend) void {
    if (self.child_backend != candidate or self.child_pid != std.c.getpid()) return;
    if (self.gate_stage != .synced or self.child_synced) return;
    self.child_synced = true;
    if (self.waitAtGate(.synced) != 'r') std.c._exit(92);
}

fn draining(context: *anyopaque) void {
    const self: *PersistenceController = @ptrCast(@alignCast(context));
    const pid = self.selected_pid.load(.acquire);
    if (pid != 0) _ = self.emit(.draining, pid, 0);
}

fn waitPid(pid: std.posix.pid_t) anyerror!?u32 {
    const self = active_controller.?;
    const status = try self.original_wait_pid.?(pid);
    if (status) |bits| {
        if (self.selected_pid.cmpxchgStrong(pid, 0, .acq_rel, .acquire) == null) {
            _ = self.emit(.reaped, pid, bits);
        }
    }
    return status;
}

fn waitAtGate(self: *PersistenceController, stage: protocol.Stage) u8 {
    if (!self.emit(stage, std.c.getpid(), 0)) std.c._exit(90);
    var fds = [_]std.posix.pollfd{.{ .fd = self.release_fd.?, .events = std.posix.POLL.IN, .revents = 0 }};
    // A lost harness must not leave a child blocked forever.
    if (std.c.poll(&fds, fds.len, 15_000) != 1) std.c._exit(91);
    var command: [1]u8 = undefined;
    if (std.c.read(self.release_fd.?, &command, 1) != 1) std.c._exit(92);
    if (command[0] != 'r' and command[0] != 'f') std.c._exit(92);
    return command[0];
}

fn emit(self: *PersistenceController, stage: protocol.Stage, pid: std.posix.pid_t, status: u32) bool {
    const fd = self.event_fd orelse return false;
    const event: protocol.Event = .{
        .server_pid = self.server_pid,
        .child_pid = pid,
        .operation = 1,
        .status = status,
        .backend = self.backend,
        .stage = stage,
    };
    while (true) {
        const n = std.c.write(fd, std.mem.asBytes(&event).ptr, @sizeOf(protocol.Event));
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return n == @sizeOf(protocol.Event);
    }
}
