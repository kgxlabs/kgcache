const std = @import("std");

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
        const thread = try std.Thread.spawn(.{}, handle_connection, .{ io, connection });
        thread.detach();
    }
}

fn handle_connection(io: std.Io, connection: std.Io.net.Stream) !void {
    defer connection.close(io);
    while (true) {
        var buf: [1024]u8 = undefined;
        var data = [_][]u8{&buf};
        const bytes_read = io.vtable.netRead(io.userdata, connection.socket.handle, &data) catch break;
        if (bytes_read == 0) return;

        var connection_writer = connection.writer(io, &.{});
        try connection_writer.interface.writeAll("+PONG\r\n");
    }
}
