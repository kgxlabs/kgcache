const std = @import("std");
const resp = @import("../resp.zig");
const store = @import("../store.zig");
const object = @import("../object.zig");
const command_arguments = @import("arguments.zig");
const Commander = @import("interface.zig");
const Request = @import("request.zig");
const Schema = @import("schema.zig");
const time = @import("../time.zig");

const Set = @This();

allocator: std.mem.Allocator,
arguments: []resp.RESPValue,

pub fn commander(self: *Set) Commander {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Commander.VTable{
    .execute = execute,
    .deinit = deinit,
};

fn execute(ptr: *anyopaque, io: std.Io, data_store: *store.Store) Commander.Error!resp.RESPValue {
    const self: *Set = @ptrCast(@alignCast(ptr));

    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const req = try bind(self.arguments, now_ms);
    const maybe_object = data_store.set(io, req) catch |err| {
        return .{ .simple_error = store.errorToString(err) };
    };

    if (maybe_object == null) {
        return .{ .simple_string = "OK" };
    }

    return object.toRESP(maybe_object.?) catch Commander.Error.UnableToConvertObject;
}

const schema: Schema.Interface.SchemaDefinition = .{
    .required = 2,
    .options = &.{
        .{
            .keyword = "nx",
            .repeatable = false,
            .group = Schema.Interface.OptionGroup.condition,
            .arity = 0,
        },
    },
};

fn bind(argv: []resp.RESPValue, now_ms: time.UnixMs) Commander.Error!Request.SetRequest {
    var pos: usize = 0;
    var req: Request.SetRequest = .{
        .key = "",
        .value = "",
        .condition = null,
        .expires_at = null,
        .response = null,
        .keepttl = false,
    };

    if (argv.len < schema.required) {
        return Commander.Error.WrongNumberArguments;
    }

    req.key = try command_arguments.bulkString(argv[pos]);
    pos += 1;

    req.value = try command_arguments.bulkString(argv[pos]);
    pos += 1;

    while (pos < argv.len) {
        // Look up
        const keyword = try command_arguments.bulkString(argv[pos]);
        const definition = Schema.Set.Options.get(keyword) orelse return Commander.Error.Syntax;

        // Validate , Consume and Apply
        // NOTE: For `SET` command all the possible option groups are non-repeatable
        const consumed = switch (definition.group) {
            .condition => blk: {
                if (req.condition != null)
                    return Commander.Error.Syntax;

                break :blk Schema.Set.apply(&req, definition, argv[pos..], now_ms) catch return Commander.Error.UnsupportedOption;
            },
            .expiration => blk: {
                if (req.expires_at != null or req.keepttl)
                    return Commander.Error.Syntax;

                break :blk Schema.Set.apply(&req, definition, argv[pos..], now_ms) catch return Commander.Error.UnsupportedOption;
            },
            .response => blk: {
                if (req.response != null)
                    return Commander.Error.Syntax;

                break :blk Schema.Set.apply(&req, definition, argv[pos..], now_ms) catch return Commander.Error.UnsupportedOption;
            },
        };

        pos += consumed;
    }

    return req;
}

// NOTE: The caller must only provide arguments after "key" and "value"
fn assertValidOptions(_: []resp.RESPValue) Commander.Error!void {
    // option of the same group with repeatable `false` must never repeat

}

fn deinit(ptr: *anyopaque) void {
    const self: *Set = @ptrCast(@alignCast(ptr));
    self.allocator.destroy(self);
}
