const std = @import("std");

const ReadyPipe = @This();

io: std.Io,
file: ?std.Io.File,

pub fn init(io: std.Io, fd: ?std.posix.fd_t) ReadyPipe {
    return .{
        .io = io,
        .file = if (fd) |handle| .{
            .handle = handle,
            .flags = .{ .nonblocking = false },
        } else null,
    };
}

pub fn close(self: *ReadyPipe) void {
    const file = self.file orelse return;
    self.file = null;
    file.close(self.io);
}

pub fn notify(context: *anyopaque, address: std.Io.net.IpAddress) anyerror!void {
    const self: *ReadyPipe = @ptrCast(@alignCast(context));
    const file = self.file orelse return;
    defer self.close();

    const ip4 = address.ip4;
    var buffer: [64]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buffer,
        "READY {d}.{d}.{d}.{d} {d}\n",
        .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3], ip4.port },
    ) catch unreachable;
    try std.Io.File.writeStreamingAll(file, self.io, line);
}

test "ready pipe reports the bound address" {
    const testing = std.testing;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[0]);

    var ready_pipe = ReadyPipe.init(testing.io, fds[1]);
    defer ready_pipe.close();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 4321);
    try ReadyPipe.notify(&ready_pipe, address);

    try testing.expect(ready_pipe.file == null);
    var buffer: [64]u8 = undefined;
    const count = std.c.read(fds[0], &buffer, buffer.len);
    try testing.expect(count > 0);
    try testing.expectEqualStrings("READY 127.0.0.1 4321\n", buffer[0..@intCast(count)]);
}
