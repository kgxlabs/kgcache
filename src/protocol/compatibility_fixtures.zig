pub const Fixture = struct {
    request: []const u8,
    reply: []const u8,
    reply_resp3: ?[]const u8 = null,
    canonical_name: []const u8 = "",

    pub fn replyFor(self: Fixture, version: u8) []const u8 {
        return if (version == 3) self.reply_resp3 orelse self.reply else self.reply;
    }
};

pub const count: Fixture = .{
    .request = @embedFile("fixtures/command-count.request.resp"),
    .reply = @embedFile("fixtures/command-count.reply.resp"),
    .canonical_name = "command|count",
};

pub const list: Fixture = .{
    .request = @embedFile("fixtures/command-list.request.resp"),
    .reply = @embedFile("fixtures/command-list.reply.resp"),
    .canonical_name = "command|list",
};

pub const commands = [_]Fixture{
    .{ .request = @embedFile("fixtures/ping.request.resp"), .reply = @embedFile("fixtures/ping.reply.resp") },
    .{ .request = @embedFile("fixtures/echo-binary.request.resp"), .reply = @embedFile("fixtures/echo-binary.reply.resp") },
    .{ .request = @embedFile("fixtures/get-missing.request.resp"), .reply = @embedFile("fixtures/get-missing.reply.resp"), .reply_resp3 = "_\r\n" },
    .{ .request = @embedFile("fixtures/set-get-missing.request.resp"), .reply = @embedFile("fixtures/set-get-missing.reply.resp"), .reply_resp3 = "_\r\n" },
    count,
    list,
    .{ .request = @embedFile("fixtures/command-info-get.request.resp"), .reply = @embedFile("fixtures/command-info-get.reply.resp") },
    .{ .request = @embedFile("fixtures/command-info-unknown.request.resp"), .reply = @embedFile("fixtures/command-info-unknown.reply.resp"), .reply_resp3 = "*1\r\n_\r\n" },
    .{ .request = @embedFile("fixtures/command-getkeys.request.resp"), .reply = @embedFile("fixtures/command-getkeys.reply.resp") },
};

pub const metadata = [_]Fixture{
    .{ .request = @embedFile("fixtures/command-all.request.resp"), .reply = @embedFile("fixtures/command-all.reply.resp"), .canonical_name = "command" },
    .{ .request = @embedFile("fixtures/command-info-all.request.resp"), .reply = @embedFile("fixtures/command-all.reply.resp"), .canonical_name = "command|info" },
    .{ .request = @embedFile("fixtures/command-info-command.request.resp"), .reply = @embedFile("fixtures/command-info-command.reply.resp"), .canonical_name = "command|info" },
    .{ .request = @embedFile("fixtures/command-info-client.request.resp"), .reply = @embedFile("fixtures/command-info-client.reply.resp"), .canonical_name = "command|info" },
    .{ .request = @embedFile("fixtures/command-info-children.request.resp"), .reply = @embedFile("fixtures/command-info-children.reply.resp"), .canonical_name = "command|info" },
};
