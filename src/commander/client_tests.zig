const std = @import("std");
const commander = @import("../commander.zig");
const connection = @import("../connection.zig");
const protocol = @import("../protocol.zig");
const MockStore = @import("../store/mock_store.zig");
const testing = std.testing;

const Provider = struct {
    report: connection.ConnectionReport,
    peer_endpoint: std.Io.net.IpAddress = .{ .ip4 = .loopback(40000) },
    local_endpoint: std.Io.net.IpAddress = .{ .ip4 = .loopback(6379) },
    registered_at: std.Io.Timestamp = .fromNanoseconds(10_500_000_000),
    sampled_at: std.Io.Timestamp = .fromNanoseconds(130_999_999_999),
    command: [3]u8 = "get".*,
    library_name: [9]u8 = "my-client".*,
    library_version: [5]u8 = "1.2.3".*,
    calls: usize = 0,

    fn init() Provider {
        return .{ .report = connection.ConnectionReport.init(testing.io, .fromNanoseconds(10_500_000_000)) };
    }

    fn context(self: *Provider) connection.ConnectionContext {
        self.report._values = .{
            .last_activity = .fromNanoseconds(127_800_000_000),
            .db_index = 7,
            .resp = .resp3,
            .last_command = &self.command,
            .lib_name = &self.library_name,
            .lib_ver = &self.library_version,
            .total_net_in = 500,
            .total_net_out = 400,
            .total_cmds = 8,
        };
        return .{ .id = 42, .reports = .{ .ptr = self, .vtable = &vtable } };
    }

    const vtable: connection.ReportAccess.VTable = .{ .snapshot_current = snapshotCurrent };

    fn snapshotCurrent(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator) connection.ReportAccess.Error!connection.ReportAccess.Snapshot {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{
            .id = 42,
            .peer_endpoint = self.peer_endpoint,
            .local_endpoint = self.local_endpoint,
            .descriptor = 7,
            .registered_at = self.registered_at,
            .sampled_at = self.sampled_at,
            .report = try self.report.snapshot(allocator),
        };
    }
};

const expected_row = "id=42 addr=127.0.0.1:40000 laddr=127.0.0.1:6379 fd=7 age=120 idle=3 db=7 cmd=get resp=3 " ++
    "lib-name=my-client lib-ver=1.2.3 tot-net-in=500 tot-net-out=400 tot-cmds=8 " ++
    "name= sub=0 psub=0 ssub=0 watch=0 multi=-1 multi-mem=0 redir=-1\n";

test "CLIENT binds only INFO with exact arity before allocation" {
    const cases = [_]struct { arguments: []const []const u8, err: anyerror }{
        .{ .arguments = &.{}, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "INFO", "extra" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "iNfO", "", "extra" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{""}, .err = error.UnsupportedOption },
        .{ .arguments = &.{"UNKNOWN"}, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "UNKNOWN", "extra" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{"lIsT"}, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "LIST", "ID", "42" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{"SETINFO"}, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "setinfo", "LIB-NAME", "client" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "SETNAME", "name" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{"ID"}, .err = error.UnsupportedOption },
        .{ .arguments = &.{"INFO\x00"}, .err = error.UnsupportedOption },
    };
    for (cases) |case| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(case.err, commander.init(failing.allocator(), .{ .name = "cLiEnT", .arguments = case.arguments }));
        try testing.expectEqual(0, failing.alloc_index);
    }
}

test "CLIENT INFO owns its snapshot text through output in both protocols" {
    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |selected| {
        var provider = Provider.init();
        const context = provider.context();
        var state = connection.ClientState.initWithConnection(&context);
        state.db_index = 2;
        state.resp = selected;
        var unused_store: @import("../store.zig").Store = undefined;
        const command = try commander.init(testing.allocator, .{ .name = "cLiEnT", .arguments = &.{"iNfO"} });
        var result = command.execute(testing.io, &unused_store, &state) catch |err| {
            command.deinit();
            return err;
        };
        command.deinit();
        defer result.deinit();

        @memset(&provider.command, 'x');
        @memset(&provider.library_name, 'x');
        @memset(&provider.library_version, 'x');
        try testing.expectEqual(1, provider.calls);
        try testing.expect(result.owned_arena != null);
        try testing.expect(result.value == .verbatim);
        try testing.expectEqualStrings(expected_row, result.value.verbatim);
        try testing.expectEqual(2, state.db_index);
        try testing.expectEqual(selected, state.resp);

        var small_buffer: [1]u8 = undefined;
        var failing_writer = std.Io.Writer.fixed(&small_buffer);
        try testing.expectError(error.WriteFailed, selected.writeReply(&failing_writer, result.value));
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try selected.writeReply(&writer, result.value);
        try writer.flush();
        var expected_buffer: [1024]u8 = undefined;
        const expected = if (selected.version() == .resp2)
            try std.fmt.bufPrint(&expected_buffer, "${d}\r\n{s}\r\n", .{ expected_row.len, expected_row })
        else
            try std.fmt.bufPrint(&expected_buffer, "={d}\r\ntxt:{s}\r\n", .{ expected_row.len + 4, expected_row });
        try testing.expectEqualStrings(expected, writer.buffered());
    }
}

test "CLIENT INFO releases owners and report locks on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, infoAllocation, .{});
}

fn infoAllocation(allocator: std.mem.Allocator) !void {
    var provider = Provider.init();
    const context = provider.context();
    var state = connection.ClientState.initWithConnection(&context);
    state.db_index = 2;
    state.resp = protocol.Resp3.resp();
    defer {
        testing.expectEqual(2, state.db_index) catch unreachable;
        testing.expectEqual(protocol.Resp3.resp(), state.resp) catch unreachable;
        var tx = provider.report._lock.tryBegin() orelse unreachable;
        tx.end();
    }
    var unused_store: @import("../store.zig").Store = undefined;
    const command = try commander.init(allocator, .{ .name = "CLIENT", .arguments = &.{"INFO"} });
    defer command.deinit();
    var result = try command.execute(testing.io, &unused_store, &state);
    defer result.deinit();
    try testing.expectEqualStrings(expected_row, result.value.verbatim);
}

test "CLIENT INFO requires connection snapshot access" {
    var mock = MockStore.init();
    var data_store = mock.store();
    const command = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{"INFO"} });
    defer command.deinit();
    var state = connection.ClientState.init();
    try testing.expectError(error.MissingConnectionContext, command.execute(testing.io, &data_store, &state));
    const context: connection.ConnectionContext = .{ .id = 42 };
    state = connection.ClientState.initWithConnection(&context);
    try testing.expectError(error.MissingReportAccess, command.execute(testing.io, &data_store, &state));
}

test "report formatting brackets IPv6 and clamps or truncates sampled durations" {
    var provider = Provider.init();
    const context = provider.context();
    provider.peer_endpoint = .{ .ip6 = .loopback(40000) };
    provider.local_endpoint = .{ .ip6 = .loopback(6379) };
    provider.registered_at = .fromNanoseconds(1_900_000_000);
    provider.sampled_at = .fromNanoseconds(2_100_000_000);
    provider.report._values.last_activity = .fromNanoseconds(2_200_000_000);
    var state = connection.ClientState.initWithConnection(&context);
    var unused_store: @import("../store.zig").Store = undefined;
    const command = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{"INFO"} });
    defer command.deinit();
    var result = try command.execute(testing.io, &unused_store, &state);
    defer result.deinit();
    try testing.expectEqualStrings(
        "id=42 addr=[::1]:40000 laddr=[::1]:6379 fd=7 age=0 idle=0 db=7 cmd=get resp=3 " ++
            "lib-name=my-client lib-ver=1.2.3 tot-net-in=500 tot-net-out=400 tot-cmds=8 " ++
            "name= sub=0 psub=0 ssub=0 watch=0 multi=-1 multi-mem=0 redir=-1\n",
        result.value.verbatim,
    );
    provider.sampled_at = .fromNanoseconds(1);
    var earlier = try command.execute(testing.io, &unused_store, &state);
    defer earlier.deinit();
    try testing.expectEqualStrings(result.value.verbatim, earlier.value.verbatim);
}
