const std = @import("std");
const connection = @import("../connection.zig");
const store = @import("../store.zig");
const Commander = @import("interface.zig");

const Client = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,
subcommand: enum { info, setinfo },

pub fn init(allocator: std.mem.Allocator, arguments: []const []const u8) Commander.Error!Commander {
    if (arguments.len == 0) return error.WrongNumberArguments;

    const subcommand: @FieldType(Client, "subcommand") = if (std.ascii.eqlIgnoreCase(arguments[0], "info"))
        .info
    else if (std.ascii.eqlIgnoreCase(arguments[0], "setinfo"))
        .setinfo
    else
        return error.UnsupportedOption;

    const arity: usize = switch (subcommand) {
        .info => 1,
        .setinfo => 3,
    };

    if (arguments.len != arity) return error.WrongNumberArguments;

    const self = try allocator.create(Client);
    self.* = .{ .allocator = allocator, .arguments = arguments, .subcommand = subcommand };

    return .{ .ptr = self, .vtable = &vtable, .canonical_name = switch (subcommand) {
        .info => "client|info",
        .setinfo => "client|setinfo",
    } };
}

const vtable: Commander.VTable = .{ .execute = execute, .deinit = deinit };

fn execute(ptr: *anyopaque, io: std.Io, _: *store.Store, state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *Client = @ptrCast(@alignCast(ptr));

    // using simple if else because we only have two subcommands `info` and `setinfo`
    // TODO: Refactor this with proper Subcommand design. tracked here: https://github.com/kgxlabs/kgcache/issues/182
    if (self.subcommand == .setinfo) {
        const attribute: connection.ConnectionReport.LibraryAttribute = if (std.ascii.eqlIgnoreCase(self.arguments[1], "lib-name"))
            .lib_name
        else if (std.ascii.eqlIgnoreCase(self.arguments[1], "lib-ver"))
            .lib_ver
        else
            return error.UnsupportedOption;

        const value = self.arguments[2];
        for (value) |byte| {
            if (byte < '!' or byte > '~') return error.Syntax;
        }

        const context = state.connection_context orelse return error.MissingConnectionContext;

        try context.setLibraryInfo(attribute, value);

        return Commander.Result.borrowed(.{ .simple_string = "OK" });
    }

    const context = state.connection_context orelse return error.MissingConnectionContext;

    const arena = try self.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(self.allocator);
    errdefer {
        arena.deinit();
        self.allocator.destroy(arena);
    }

    var snapshot = try context.snapshotCurrent(io, arena.allocator());
    defer snapshot.deinit();

    const text = try formatReport(arena.allocator(), snapshot);
    return Commander.Result.inArena(.{ .verbatim = text }, arena);
}

fn formatReport(allocator: std.mem.Allocator, snapshot: connection.ConnectionContext.Snapshot) std.mem.Allocator.Error![]u8 {
    const values = snapshot.report.values;
    return std.fmt.allocPrint(
        allocator,
        "id={d} addr={f} laddr={f} fd={d} age={d} idle={d} db={d} cmd={s} resp={d} " ++
            "lib-name={s} lib-ver={s} tot-net-in={d} tot-net-out={d} tot-cmds={d} " ++
            "name= sub=0 psub=0 ssub=0 watch=0 multi=-1 multi-mem=0 redir=-1\n",
        .{
            snapshot.id,
            snapshot.peer_endpoint,
            snapshot.local_endpoint,
            snapshot.descriptor,
            secondsSince(snapshot.registered_at, snapshot.sampled_at),
            secondsSince(values.last_activity, snapshot.sampled_at),
            values.db_index,
            values.last_command,
            @intFromEnum(values.resp),
            values.lib_name,
            values.lib_ver,
            values.total_net_in,
            values.total_net_out,
            values.total_cmds,
        },
    );
}

fn secondsSince(since: std.Io.Timestamp, sampled_at: std.Io.Timestamp) i128 {
    const nanoseconds = @as(i128, sampled_at.nanoseconds) - since.nanoseconds;
    return @divTrunc(@max(nanoseconds, 0), std.time.ns_per_s);
}

fn deinit(ptr: *anyopaque) void {
    const self: *Client = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
