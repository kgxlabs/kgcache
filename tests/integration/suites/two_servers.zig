const std = @import("std");
const support = @import("server_process");
const resp_client = @import("../harness/resp_client.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable_path: []const u8, artifact_dir: ?[]const u8) !void {
    std.log.info("integration: two servers baseline started", .{});
    const first = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer first.destroy();
    errdefer first.failed = true;

    const second = try support.ServerProcess.create(io, allocator, executable_path, .{ .artifact_dir = artifact_dir });
    defer second.destroy();
    errdefer second.failed = true;

    if (first.address.?.getPort() == second.address.?.getPort()) return error.SharedPort;
    if (std.mem.eql(u8, first.data_dir, second.data_dir)) return error.SharedDataDirectory;

    const first_client = try first.address.?.connect(io, .{ .mode = .stream });
    defer first_client.close(io);
    const second_client = try second.address.?.connect(io, .{ .mode = .stream });
    defer second_client.close(io);

    try resp_client.sendAndExpect(io, first, first_client.socket.handle, "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", "+OK\r\n");
    try resp_client.sendAndExpect(io, second, second_client.socket.handle, "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", "$-1\r\n");

    try first.stop();
    try resp_client.sendAndExpect(io, second, second_client.socket.handle, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
    try second.stop();
    std.log.info("integration: two servers baseline passed", .{});
}
