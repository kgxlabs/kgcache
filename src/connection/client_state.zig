const protocol = @import("../protocol.zig");
const ConnectionContext = @import("context.zig");
const ClientState = @This();

db_index: u32 = 0,
resp: protocol.Resp = protocol.Resp2.resp(),
connection_context: ?*const ConnectionContext = null,

pub fn init() ClientState {
    return .{};
}

pub fn initWithConnection(context: *const ConnectionContext) ClientState {
    return .{ .connection_context = context };
}

test "client state starts in RESP2 and keeps protocol selection per client" {
    const std = @import("std");
    const testing = std.testing;
    var first = ClientState.init();
    const second = ClientState.init();
    try testing.expectEqual(protocol.Resp.Version.resp2, first.resp.version());
    try testing.expectEqual(protocol.Resp.Version.resp2, second.resp.version());

    first.resp = protocol.Resp3.resp();
    try testing.expectEqual(protocol.Resp.Version.resp3, first.resp.version());
    try testing.expectEqual(protocol.Resp.Version.resp2, second.resp.version());
    var buffer: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try first.resp.writeReply(&writer, .{ .null_value = .bulk_string });
    try writer.flush();
    try testing.expectEqualStrings("_\r\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);
    try second.resp.writeReply(&writer, .{ .null_value = .bulk_string });
    try writer.flush();
    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}
