const std = @import("std");
const store = @import("../store.zig");
const Commander = @import("interface.zig");
const Request = @import("request.zig");
const Schema = @import("schema.zig");
const time = @import("../time.zig");

const Set = @This();

allocator: std.mem.Allocator,
arguments: []const []const u8,

pub fn commander(self: *Set) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, io: std.Io, data_store: *store.Store, client_state: *Commander.ClientState) anyerror!Commander.Result {
    const self: *Set = @ptrCast(@alignCast(ptr));

    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const req = try bind(self.arguments, now_ms);

    const result = try data_store.set(req, client_state.db_index);

    if (result.value) |value| {
        return try Commander.Result.owned(value);
    }

    const requested_prev_value = req.response != null and req.response.?.get;
    if (requested_prev_value or result.outcome == .not_applied) {
        return Commander.Result.borrowed(.{ .null_value = .bulk_string });
    }

    return Commander.Result.borrowed(.{ .simple_string = "OK" });
}

fn bind(argv: []const []const u8, now_ms: time.UnixMs) anyerror!Request.SetRequest {
    var pos: usize = 0;
    var req: Request.SetRequest = .{
        .key = "",
        .value = "",
        .condition = null,
        .expires_at = null,
        .response = null,
        .keepttl = false,
    };

    req.key = argv[pos];
    pos += 1;

    req.value = argv[pos];
    pos += 1;

    while (pos < argv.len) {
        // Look up
        const keyword = argv[pos];
        const definition = Schema.Set.Options.get(keyword) orelse return Commander.Error.Syntax;

        // Validate , Consume and Apply
        // NOTE: For `SET` command all the possible option groups are non-repeatable
        const consumed = switch (definition.group) {
            .condition => blk: {
                if (req.condition != null)
                    return Commander.Error.Syntax;

                break :blk try applyOption(&req, definition, argv[pos..], now_ms);
            },
            .expiration => blk: {
                if (req.expires_at != null or req.keepttl)
                    return Commander.Error.Syntax;

                break :blk try applyOption(&req, definition, argv[pos..], now_ms);
            },
            .response => blk: {
                if (req.response != null)
                    return Commander.Error.Syntax;

                break :blk try applyOption(&req, definition, argv[pos..], now_ms);
            },
        };

        pos += consumed;
    }

    if (req.expires_at != null and req.keepttl) {
        return Commander.Error.Syntax;
    }

    return req;
}

fn applyOption(
    req: *Request.SetRequest,
    definition: *const Schema.Interface.OptionDefinition,
    args: []const []const u8,
    now_ms: time.UnixMs,
) anyerror!usize {
    return Schema.Set.apply(req, definition, args, now_ms) catch return error.UnsupportedOption;
}

fn deinit(ptr: *anyopaque) void {
    const self: *Set = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
