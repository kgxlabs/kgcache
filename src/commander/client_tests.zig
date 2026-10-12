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
    label_calls: usize = 0,
    live_ids: []const u64 = &.{},

    fn init() Provider {
        return .{ .report = connection.ConnectionReport.init(testing.io, testing.allocator, .fromNanoseconds(10_500_000_000)) };
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
        return .{ .id = 42, .ptr = self, .vtable = &vtable };
    }

    const vtable: connection.ConnectionContext.VTable = .{
        .snapshot_current = snapshotCurrent,
        .snapshot_live = snapshotLive,
        .record_read = recordRead,
        .record_write = recordWrite,
        .record_dispatch = recordDispatch,
        .record_db_and_proto = recordDbAndProto,
        .set_library_info = setLibraryInfo,
    };

    fn recordRead(ptr: *anyopaque, count: u64, at: std.Io.Timestamp) void {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        self.report.recordRead(count, at);
    }

    fn recordWrite(ptr: *anyopaque, count: u64, at: std.Io.Timestamp) void {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        self.report.recordWrite(count, at);
    }

    fn recordDispatch(ptr: *anyopaque, name: []const u8) void {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        self.report.recordDispatch(name);
    }

    fn recordDbAndProto(ptr: *anyopaque, db_index: u32, resp: protocol.Resp.Version) void {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        self.report.recordDbAndProto(db_index, resp);
    }

    fn setLibraryInfo(ptr: *anyopaque, attribute: connection.ConnectionReport.LibraryAttribute, value: []const u8) connection.ConnectionContext.Error!void {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        self.label_calls += 1;
        return self.report.setLibraryInfo(attribute, value);
    }

    fn snapshotCurrent(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator) connection.ConnectionContext.Error!connection.ConnectionContext.Snapshot {
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

    fn snapshotLive(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) connection.ConnectionContext.Error!connection.ConnectionContext.LiveSnapshots {
        const self: *Provider = @ptrCast(@alignCast(ptr));
        const items = try allocator.alloc(connection.ConnectionContext.Snapshot, self.live_ids.len);
        var count: usize = 0;
        errdefer {
            for (items[0..count]) |*snapshot| snapshot.deinit();
            allocator.free(items);
        }
        for (self.live_ids, 0..) |id, index| {
            items[index] = try snapshotCurrent(ptr, io, allocator);
            items[index].id = id;
            count += 1;
        }
        return .{ .items = items, .allocator = allocator };
    }
};

const expected_row = "id=42 addr=127.0.0.1:40000 laddr=127.0.0.1:6379 fd=7 age=120 idle=3 db=7 cmd=get resp=3 " ++
    "lib-name=my-client lib-ver=1.2.3 tot-net-in=500 tot-net-out=400 tot-cmds=8 " ++
    "name= sub=0 psub=0 ssub=0 watch=0 multi=-1 multi-mem=0 redir=-1\n";

test "CLIENT resolves supported subcommands and exact arity before allocation" {
    const cases = [_]struct { arguments: []const []const u8, err: anyerror }{
        .{ .arguments = &.{}, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "INFO", "extra" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "iNfO", "", "extra" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{""}, .err = error.UnsupportedOption },
        .{ .arguments = &.{"UNKNOWN"}, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "UNKNOWN", "extra" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "lIsT", "extra" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "LIST", "ID", "42" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "LIST", "TYPE", "NORMAL" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{"SETINFO"}, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "setinfo", "LIB-NAME" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "setinfo", "LIB-NAME", "client", "extra" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "setinfo", "unknown" }, .err = error.WrongNumberArguments },
        .{ .arguments = &.{ "SETNAME", "name" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{ "TRACKING", "ON" }, .err = error.UnsupportedOption },
        .{ .arguments = &.{"ID"}, .err = error.UnsupportedOption },
        .{ .arguments = &.{"INFO\x00"}, .err = error.UnsupportedOption },
    };
    for (cases) |case| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(case.err, commander.init(failing.allocator(), .{ .name = "cLiEnT", .arguments = case.arguments }));
        try testing.expectEqual(0, failing.alloc_index);
    }
}

test "CLIENT binds separate child factories and vtables with one handler allocation" {
    const registry = @import("registry.zig");
    const Factory = @import("definition.zig").Factory;
    const cases = [_]struct { arguments: []const []const u8, name: []const u8, factory: Factory }{
        .{ .arguments = &.{"iNfO"}, .name = "client|info", .factory = @import("client/client_info.zig").init },
        .{ .arguments = &.{ "sEtInFo", "LIB-NAME", "value" }, .name = "client|setinfo", .factory = @import("client/client_setinfo.zig").init },
        .{ .arguments = &.{"lIsT"}, .name = "client|list", .factory = @import("client/client_list.zig").init },
    };
    var vtables: [cases.len]*const commander.Commander.VTable = undefined;
    for (cases, 0..) |case, index| {
        const definition = registry.findMetadata(case.name).?;
        try testing.expect(definition.factory.? == case.factory);

        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(error.OutOfMemory, commander.init(failing.allocator(), .{ .name = "CLIENT", .arguments = case.arguments }));

        var single = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
        {
            const command = try commander.init(single.allocator(), .{ .name = "cLiEnT", .arguments = case.arguments });
            defer command.deinit();
            try testing.expectEqual(@as(usize, 1), single.allocations);
            try testing.expect(command.canonical_name.ptr == definition.name.ptr);
            vtables[index] = command.vtable;
        }
        try testing.expectEqual(single.allocations, single.deallocations);
        for (vtables[0..index]) |previous| try testing.expect(previous != vtables[index]);
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

test "SETINFO retains exact printable bytes and clears each label independently" {
    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |resp| {
        var provider = Provider.init();
        defer provider.report.deinit();
        const context: connection.ConnectionContext = .{ .id = 42, .ptr = &provider, .vtable = &Provider.vtable };
        var state = connection.ClientState.initWithConnection(&context);
        state.resp = resp;
        var unused_store: @import("../store.zig").Store = undefined;
        var value: [94]u8 = undefined;
        for (&value, 0..) |*byte, index| byte.* = @intCast('!' + index);
        const expected = value;
        const command = try commander.init(testing.allocator, .{ .name = "cLiEnT", .arguments = &.{ "sEtInFo", "lIb-NaMe", &value } });
        try testing.expectEqualStrings("client|setinfo", command.canonical_name);
        var result = command.execute(testing.io, &unused_store, &state) catch |err| {
            command.deinit();
            return err;
        };
        command.deinit();
        defer result.deinit();
        try testing.expectEqualStrings("OK", result.value.simple_string);
        @memset(&value, 'x');
        const version = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{ "SETINFO", "LiB-vEr", "AbC!~" } });
        defer version.deinit();
        var version_result = try version.execute(testing.io, &unused_store, &state);
        defer version_result.deinit();
        var snapshot = try context.snapshotCurrent(testing.io, testing.allocator);
        defer snapshot.deinit();
        try testing.expectEqualStrings(&expected, snapshot.report.values.lib_name);
        try testing.expectEqualStrings("AbC!~", snapshot.report.values.lib_ver);
        const clear = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{ "SETINFO", "LIB-NAME", "" } });
        defer clear.deinit();
        var clear_result = try clear.execute(testing.io, &unused_store, &state);
        defer clear_result.deinit();
        try testing.expectEqualStrings("", provider.report._values.lib_name);
        try testing.expectEqualStrings("AbC!~", provider.report._values.lib_ver);
        try testing.expectEqualStrings(&expected, snapshot.report.values.lib_name);
        try testing.expectEqual(resp, state.resp);
    }
}

test "SETINFO validates attributes and every invalid byte in its recognized handler" {
    var provider = Provider.init();
    defer provider.report.deinit();
    try provider.report.setLibraryInfo(.lib_name, "OldName");
    try provider.report.setLibraryInfo(.lib_ver, "OldVersion");
    const context: connection.ConnectionContext = .{ .id = 42, .ptr = &provider, .vtable = &Provider.vtable };
    var state = connection.ClientState.initWithConnection(&context);
    var unused_store: @import("../store.zig").Store = undefined;
    for ([_][]const u8{ "", "UNKNOWN", "LIB-NAME\x00", "LIB-VER\xff" }) |attribute| {
        const command = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{ "SETINFO", attribute, "valid" } });
        defer command.deinit();
        try testing.expectEqualStrings("client|setinfo", command.canonical_name);
        try testing.expectError(error.UnsupportedOption, command.execute(testing.io, &unused_store, &state));
    }
    for (0..256) |number| {
        if (number >= '!' and number <= '~') continue;
        const bytes = [_]u8{@intCast(number)};
        for ([_][]const u8{ "LIB-NAME", "LIB-VER" }) |attribute| {
            const command = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{ "SETINFO", attribute, &bytes } });
            defer command.deinit();
            try testing.expectError(error.Syntax, command.execute(testing.io, &unused_store, &state));
        }
    }
    try testing.expectEqual(0, provider.label_calls);
    try testing.expectEqualStrings("OldName", provider.report._values.lib_name);
    try testing.expectEqualStrings("OldVersion", provider.report._values.lib_ver);
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

test "CLIENT LIST sorts complete owned rows and encodes empty and populated lists in both protocols" {
    for ([_]protocol.Resp{ protocol.Resp2.resp(), protocol.Resp3.resp() }) |resp| {
        for ([_][]const u64{ &.{}, &.{42}, &.{ 99, 42, 7 } }) |ids| {
            var provider = Provider.init();
            provider.live_ids = ids;
            const context = provider.context();
            var state = connection.ClientState.initWithConnection(&context);
            state.db_index = 2;
            state.resp = resp;
            var unused_store: @import("../store.zig").Store = undefined;
            const command = try commander.init(testing.allocator, .{ .name = "cLiEnT", .arguments = &.{"lIsT"} });
            try testing.expectEqualStrings("client|list", command.canonical_name);
            var result = command.execute(testing.io, &unused_store, &state) catch |err| {
                command.deinit();
                return err;
            };
            command.deinit();
            defer result.deinit();

            @memset(&provider.command, 'x');
            @memset(&provider.library_name, 'x');
            @memset(&provider.library_version, 'x');
            try testing.expectEqual(ids.len, provider.calls);
            try testing.expectEqual(2, state.db_index);
            try testing.expectEqual(resp, state.resp);
            try testing.expect(result.owned_arena != null);
            try testing.expect(result.value == .verbatim);

            var expected: std.Io.Writer.Allocating = .init(testing.allocator);
            defer expected.deinit();
            const sorted: []const u64 = switch (ids.len) {
                0 => &.{},
                1 => &.{42},
                else => &.{ 7, 42, 99 },
            };
            for (sorted) |id| {
                try expected.writer.print("id={d}{s}", .{ id, expected_row["id=42".len..] });
            }
            try testing.expectEqualStrings(expected.written(), result.value.verbatim);

            var small_buffer: [1]u8 = undefined;
            var failing_writer = std.Io.Writer.fixed(&small_buffer);
            try testing.expectError(error.WriteFailed, resp.writeReply(&failing_writer, result.value));
            var wire: std.Io.Writer.Allocating = .init(testing.allocator);
            defer wire.deinit();
            try resp.writeReply(&wire.writer, result.value);
            var expected_wire: std.Io.Writer.Allocating = .init(testing.allocator);
            defer expected_wire.deinit();
            if (resp.version() == .resp2) {
                try expected_wire.writer.print("${d}\r\n{s}\r\n", .{ expected.written().len, expected.written() });
            } else {
                try expected_wire.writer.print("={d}\r\ntxt:{s}\r\n", .{ expected.written().len + 4, expected.written() });
            }
            try testing.expectEqualStrings(expected_wire.written(), wire.written());
            var tx = provider.report._lock.tryBegin() orelse return error.ReportLockStillHeld;
            tx.end();
        }
    }
}

test "CLIENT LIST releases partial snapshots and reply owners on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, listAllocation, .{});
}

fn listAllocation(allocator: std.mem.Allocator) !void {
    var provider = Provider.init();
    provider.live_ids = &.{ 99, 42, 7 };
    const context = provider.context();
    var state = connection.ClientState.initWithConnection(&context);
    defer {
        var tx = provider.report._lock.tryBegin() orelse unreachable;
        tx.end();
    }
    var unused_store: @import("../store.zig").Store = undefined;
    const command = try commander.init(allocator, .{ .name = "CLIENT", .arguments = &.{"LIST"} });
    defer command.deinit();
    var result = try command.execute(testing.io, &unused_store, &state);
    defer result.deinit();
    try testing.expect(std.mem.startsWith(u8, result.value.verbatim, "id=7 "));
}

test "CLIENT LIST requires live snapshot access" {
    var unused_store: @import("../store.zig").Store = undefined;
    var state = connection.ClientState.init();
    const command = try commander.init(testing.allocator, .{ .name = "CLIENT", .arguments = &.{"LIST"} });
    defer command.deinit();
    try testing.expectError(error.MissingConnectionContext, command.execute(testing.io, &unused_store, &state));
}
