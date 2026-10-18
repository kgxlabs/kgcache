const std = @import("std");
const protocol = @import("test_control_protocol.zig");
const enabled = @import("build_options").persistence_test_controls;

var event_fd: ?std.posix.fd_t = null;
var release_fd: ?std.posix.fd_t = null;
var server_pid: i32 = 0;
var next_operation: std.atomic.Value(u32) = .init(0);
var selected_pid: std.atomic.Value(i32) = .init(0);

// Only the integration binary reads this setting. Normal builds omit controls.
pub fn init(environ: std.process.Environ) !void {
    if (!enabled) return;
    const setting = std.process.Environ.getPosix(environ, "KGCACHE_TEST_CONTROL") orelse return;
    var fields = std.mem.tokenizeScalar(u8, setting, ' ');
    event_fd = try std.fmt.parseInt(i32, fields.next() orelse return error.InvalidTestControl, 10);
    release_fd = try std.fmt.parseInt(i32, fields.next() orelse return error.InvalidTestControl, 10);
    if (fields.next() != null or event_fd.? < 3 or release_fd.? < 3) return error.InvalidTestControl;
    server_pid = std.c.getpid();
}

pub fn deinit() void {
    if (!enabled) return;
    if (event_fd) |fd| _ = std.c.close(fd);
    if (release_fd) |fd| _ = std.c.close(fd);
}

pub fn claim() bool {
    if (!enabled) return false;
    return event_fd != null and next_operation.fetchAdd(1, .monotonic) == 0;
}

pub fn track(selected: bool, pid: i32) void {
    if (!enabled) return;
    if (selected) selected_pid.store(pid, .release);
}

pub fn childSynced(selected: bool) void {
    if (!enabled) return;
    if (!selected) return;
    if (!emit(.synced, std.c.getpid(), 0)) std.c._exit(90);
    var fds = [_]std.posix.pollfd{.{ .fd = release_fd.?, .events = std.posix.POLL.IN, .revents = 0 }};
    // A lost harness must not leave a child blocked forever.
    if (std.c.poll(&fds, fds.len, 15_000) != 1) std.c._exit(91);
    var command: [1]u8 = undefined;
    if (std.c.read(release_fd.?, &command, 1) != 1 or command[0] != 'r') std.c._exit(92);
}

pub fn draining() void {
    if (!enabled) return;
    const pid = selected_pid.load(.acquire);
    if (pid != 0) _ = emit(.draining, pid, 0);
}

pub fn reaped(pid: i32, status: u32) void {
    if (!enabled) return;
    if (selected_pid.cmpxchgStrong(pid, 0, .acq_rel, .acquire) == null) _ = emit(.reaped, pid, status);
}

fn emit(stage: protocol.Stage, pid: i32, status: u32) bool {
    const fd = event_fd orelse return false;
    const event: protocol.Event = .{
        .server_pid = server_pid,
        .child_pid = pid,
        .operation = 1,
        .status = status,
        .backend = .kgc,
        .stage = stage,
    };
    while (true) {
        const n = std.c.write(fd, std.mem.asBytes(&event).ptr, @sizeOf(protocol.Event));
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return n == @sizeOf(protocol.Event);
    }
}
