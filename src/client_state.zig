const protocol = @import("protocol.zig");
const ClientState = @This();

db_index: u32 = 0,
resp: protocol.Resp = protocol.Resp2.resp(),

pub fn init() ClientState {
    return .{};
}

test "client state starts in RESP2 and keeps protocol selection per client" {
    const testing = @import("std").testing;
    var first = ClientState.init();
    const second = ClientState.init();
    const default: ClientState = .{};
    try testing.expectEqual(protocol.Resp.Version.resp2, first.resp.version());
    try testing.expectEqual(protocol.Resp.Version.resp2, default.resp.version());

    first.resp = protocol.Resp3.resp();
    try testing.expectEqual(protocol.Resp.Version.resp3, first.resp.version());
    try testing.expectEqual(protocol.Resp.Version.resp2, second.resp.version());
}
