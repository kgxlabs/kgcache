const std = @import("std");
const resp = @import("resp.zig");
const commander = @import("commands/commander.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // You can use print statements as follows for debugging, they'll be visible when running tests.
    try std.Io.File.writeStreamingAll(std.Io.File.stderr(), io, "Logs from your program will appear here!\n");

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 6379);

    var server = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);

    try listen(io, &server);
}

fn listen(io: std.Io, server: *std.Io.net.Server) !void {
    while (true) {
        const connection = try server.accept(io);
        const handle = try std.Thread.spawn(.{}, handleConnection, .{ io, connection });
        handle.detach();
    }
}

fn handleConnection(io: std.Io, connection: std.Io.net.Stream) !void {
    defer connection.close(io);

    while (true) {
        // TODO: use buffered writer
        var connection_writer = connection.writer(io, &.{});
        var buf: [1024]u8 = undefined;
        var data = [_][]u8{&buf};

        // TODO: We are directly doing syscall to OS which is expensive. Refactor this to use buffered reader
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch break;
        if (bytes_read == 0) break;

        var gpa: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa.deinit();

        const allocator = gpa.allocator();

        var parser = resp.parser(buf[0..bytes_read]);
        // TODO: Write error resposne for the parser
        const commands = try parser.parse(allocator);
        defer parser.deinit(allocator, commands);

        // TODO: Write error response for the commander
        // TODO: Refactor to more idiomatic Zig
        const c = try commander.init(commands);
        // TODO: Write error response
        const result = try c.execute();
        const serializer = resp.serializer();
        const serialized_result = try serializer.serialize(allocator, result);
        defer serializer.deinit(allocator, serialized_result);

        // Write serialized string

        try connection_writer.interface.writeAll(serialized_result);
    }
}
