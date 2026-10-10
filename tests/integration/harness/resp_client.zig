const std = @import("std");
const support = @import("server_process");

pub fn sendAndExpect(io: std.Io, server: *support.ServerProcess, fd: std.posix.fd_t, request: []const u8, expected: []const u8) !void {
    var sent: usize = 0;
    while (sent < request.len) {
        const count = try io.vtable.netWrite(io.userdata, fd, request[sent..], &.{""}, 0);
        if (count == 0) return error.ShortRequestWrite;
        sent += count;
    }

    var reply: [4096]u8 = undefined;
    std.debug.assert(expected.len <= reply.len);
    try server.readExact(fd, reply[0..expected.len]);
    if (!std.mem.eql(u8, reply[0..expected.len], expected)) {
        std.log.err("integration: expected reply {s}, got {s}", .{ expected, reply[0..expected.len] });
        return error.UnexpectedReply;
    }
}
