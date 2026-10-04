//! Build Config from prepared directives: init, apply, finish once, then deinit.

const std = @import("std");
const Config = @import("../config.zig");
const directive_definition = @import("definition.zig");
const DirectiveDefinition = directive_definition.Definition;

const ConfigBuilder = @This();

/// Apply file directives first, then CLI overrides, before finishing the build.
pub const Layer = enum {
    file,
    cli,
};

const StateEntry = struct {
    definition: *const DirectiveDefinition,
    state: *anyopaque,
    applied_in_cli: bool = false,
};

const Status = enum {
    building,
    failed,
    finished,
};

allocator: std.mem.Allocator,
config: Config,
states: std.ArrayList(StateEntry) = .empty,
status: Status = .building,

/// Start with Config defaults without allocating. Always call deinit afterward.
pub fn init(allocator: std.mem.Allocator) ConfigBuilder {
    return .{
        .allocator = allocator,
        .config = Config.default(),
    };
}

/// Apply a prepared value, creating or reusing its definition's state (null if stateless).
/// A failure ends the build. Failed registration discards the new state immediately;
/// other owned state remains for deinit. The first CLI occurrence of an append
/// definition resets the file's collection; later CLI occurrences append in order.
pub fn apply(
    self: *ConfigBuilder,
    directive: directive_definition.PreparedDirective,
    layer: Layer,
) directive_definition.ApplyError!void {
    std.debug.assert(self.status == .building);
    errdefer self.status = .failed;

    const definition = directive.definition;

    var context: directive_definition.ApplyContext = .{
        .allocator = self.allocator,
        .config = &self.config,
    };

    if (definition.state_lifecycle) |lifecycle| {
        var state_entry: ?*StateEntry = null;
        for (self.states.items) |*entry| {
            if (entry.definition == definition) {
                state_entry = entry;
                context.state = entry.state;
                break;
            }
        }

        if (context.state == null) {
            context.state = try lifecycle.init(self.allocator);
            self.states.append(self.allocator, .{
                .definition = definition,
                .state = context.state.?,
            }) catch |err| {
                lifecycle.deinit(&context, .discard);
                return err;
            };
            state_entry = &self.states.items[self.states.items.len - 1];
        }

        if (layer == .cli and definition.repeat == .append and !state_entry.?.applied_in_cli) {
            definition.reset.?(&context);
            state_entry.?.applied_in_cli = true;
        }
    }

    try definition.apply(&context, directive.value);
}

/// Finalize active states once, keeping defaults for untouched fields.
/// State owns output until all finalizers succeed; deinit discards it after any failure.
/// Success transfers allocated output to the caller: free with this allocator or
/// release its arena. Strings stay borrowed. Call deinit after either result.
pub fn finish(self: *ConfigBuilder) directive_definition.BuildError!Config {
    std.debug.assert(self.status == .building);
    errdefer self.status = .failed;

    for (self.states.items) |entry| {
        var context: directive_definition.ApplyContext = .{
            .allocator = self.allocator,
            .config = &self.config,
            .state = entry.state,
        };
        try entry.definition.state_lifecycle.?.finalize(&context);
    }
    self.status = .finished;
    return self.config;
}

/// Free states and entry storage using discard before successful finish or
/// retain_config afterward. Borrowed input is never freed. Invalidates the builder.
pub fn deinit(self: *ConfigBuilder) void {
    const mode: directive_definition.CleanupMode = if (self.status == .finished) .retain_config else .discard;
    for (self.states.items) |entry| {
        var context: directive_definition.ApplyContext = .{
            .allocator = self.allocator,
            .config = &self.config,
            .state = entry.state,
        };
        entry.definition.state_lifecycle.?.deinit(&context, mode);
    }
    self.states.deinit(self.allocator);
    self.* = undefined;
}

test {
    std.testing.refAllDecls(@This());
    _ = @sizeOf(ConfigBuilder);
}

test "apply replaces stateless values without allocating" {
    const testing = std.testing;
    const registry = @import("registry.zig");
    var builder = init(testing.failing_allocator);
    defer builder.deinit();
    try testing.expectEqualDeep(Config.default(), builder.config);
    try testing.expectEqual(0, builder.states.items.len);

    const port = registry.find("port").?;
    try builder.apply(try registry.prepare(port, &.{"7000"}), .file);
    try builder.apply(try registry.prepare(port, &.{"7001"}), .file);
    var directory = "data files".*;
    try builder.apply(try registry.prepare(registry.find("dir").?, &.{&directory}), .file);
    try builder.apply(try registry.prepare(registry.find("appendonly").?, &.{"yes"}), .file);
    try builder.apply(try registry.prepare(registry.find("appendfsync").?, &.{"no"}), .file);

    var expected = Config.default();
    expected.port = 7001;
    expected.dir = &directory;
    expected.append_only = true;
    expected.append_fsync = .no;
    try testing.expectEqualDeep(expected, builder.config);
    try testing.expect(builder.config.dir.ptr == directory[0..].ptr);
    directory[0] = 'D';
    try testing.expectEqualStrings("Data files", builder.config.dir);
    try testing.expectEqual(0, builder.states.items.len);
    try testing.expectEqual(.building, builder.status);
}

test "stateless callbacks receive null state after a stateful directive" {
    const Probe = struct {
        fn apply(context: *directive_definition.ApplyContext, value: directive_definition.Value) directive_definition.ApplyError!void {
            std.debug.assert(context.state == null);
            std.debug.assert(context.allocator.ptr == std.testing.allocator.ptr);
            context.config.port = value.u16_value;
        }
    };
    const registry = @import("registry.zig");
    var builder = init(std.testing.allocator);
    defer builder.deinit();
    try builder.apply(try registry.prepare(registry.find("save").?, &.{ "60", "1" }), .file);
    var definition = registry.find("port").?.*;
    definition.apply = Probe.apply;
    try builder.apply(try registry.prepare(&definition, &.{"7000"}), .file);

    try std.testing.expectEqual(7000, builder.config.port);
    try std.testing.expectEqual(1, builder.states.items.len);
}

test "file application lazily creates and reuses save state in order" {
    const testing = std.testing;
    const registry = @import("registry.zig");
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var builder = init(failing.allocator());
    defer builder.deinit();
    const definition = registry.find("save").?;

    const first = try registry.prepare(definition, &.{ "900", "1" });
    try testing.expectEqual(0, builder.states.items.len);
    try testing.expectEqual(0, failing.alloc_index);
    try builder.apply(first, .file);
    try testing.expectEqual(1, builder.states.items.len);
    try testing.expect(builder.states.items[0].definition == definition);
    const state = builder.states.items[0].state;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = 0;

    try builder.apply(try registry.prepare(registry.find("port").?, &.{"7000"}), .file);
    try builder.apply(try registry.prepare(definition, &.{ "300", "10" }), .file);
    try builder.apply(try registry.prepare(definition, &.{ "60", "10000" }), .file);
    try testing.expectEqual(1, builder.states.items.len);
    try testing.expect(builder.states.items[0].state == state);
    try testing.expect(!builder.states.items[0].applied_in_cli);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(0, builder.config.save_rules.len);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    var context: directive_definition.ApplyContext = .{
        .allocator = builder.allocator,
        .config = &builder.config,
        .state = state,
    };
    try definition.state_lifecycle.?.finalize(&context);
    try testing.expectEqualDeep(&[_]Config.SaveRule{
        .{ .seconds = 900, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
        .{ .seconds = 60, .changes = 10000 },
    }, builder.config.save_rules);
    try testing.expectEqual(7000, builder.config.port);
}

test "apply keeps states separate by definition and builder" {
    const testing = std.testing;
    const registry = @import("registry.zig");
    const definition = registry.find("save").?;
    var other_definition = definition.*;
    other_definition.name = "other-save";
    var first = init(testing.allocator);
    defer first.deinit();
    var second = init(testing.allocator);
    defer second.deinit();

    try first.apply(try registry.prepare(definition, &.{ "60", "1" }), .file);
    try first.apply(try registry.prepare(&other_definition, &.{ "300", "10" }), .file);
    try second.apply(try registry.prepare(definition, &.{ "900", "100" }), .file);
    try testing.expectEqual(2, first.states.items.len);
    try testing.expectEqual(1, second.states.items.len);
    try testing.expect(first.states.items[0].definition == definition);
    try testing.expect(first.states.items[1].definition == &other_definition);
    try testing.expect(second.states.items[0].definition == definition);
    try testing.expect(first.states.items[0].state != first.states.items[1].state);
    try testing.expect(first.states.items[0].state != second.states.items[0].state);

    for (first.states.items, [_]Config.SaveRule{
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    }) |entry, rule| {
        var context: directive_definition.ApplyContext = .{
            .allocator = first.allocator,
            .config = &first.config,
            .state = entry.state,
        };
        try entry.definition.state_lifecycle.?.finalize(&context);
        try testing.expectEqualDeep(&[_]Config.SaveRule{rule}, first.config.save_rules);
    }
    var context: directive_definition.ApplyContext = .{
        .allocator = second.allocator,
        .config = &second.config,
        .state = second.states.items[0].state,
    };
    try definition.state_lifecycle.?.finalize(&context);
    try testing.expectEqualDeep(
        &[_]Config.SaveRule{.{ .seconds = 900, .changes = 100 }},
        second.config.save_rules,
    );
}

test "apply cleans up failed initialization, registration, and first save application" {
    const testing = std.testing;
    const registry = @import("registry.zig");
    const prepared = try registry.prepare(registry.find("save").?, &.{ "60", "1" });
    for (0..3) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        {
            var builder = init(failing.allocator());
            defer builder.deinit();
            try testing.expectError(error.OutOfMemory, builder.apply(prepared, .file));
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(.failed, builder.status);
            try testing.expectEqual(if (fail_index == 2) @as(usize, 1) else 0, builder.states.items.len);
            try testing.expectEqualDeep(Config.default(), builder.config);
            if (fail_index == 1) {
                try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            }
        }
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "stateless application failure leaves registered states owned for cleanup" {
    const Probe = struct {
        fn apply(context: *directive_definition.ApplyContext, _: directive_definition.Value) directive_definition.ApplyError!void {
            std.debug.assert(context.state == null);
            return error.OutOfMemory;
        }
    };
    const testing = std.testing;
    const registry = @import("registry.zig");
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    {
        var builder = init(failing.allocator());
        defer builder.deinit();
        try builder.apply(try registry.prepare(registry.find("save").?, &.{ "60", "1" }), .file);
        const state = builder.states.items[0].state;
        var definition = registry.find("port").?.*;
        definition.apply = Probe.apply;
        try testing.expectError(error.OutOfMemory, builder.apply(try registry.prepare(&definition, &.{"7000"}), .file));
        try testing.expectEqual(.failed, builder.status);
        try testing.expectEqual(1, builder.states.items.len);
        try testing.expect(builder.states.items[0].state == state);
        try testing.expectEqual(Config.default().port, builder.config.port);
        try testing.expect(failing.allocated_bytes > failing.freed_bytes);
    }
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "apply cleans up every allocation failure during state registration and accumulation" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator) !void {
            const registry = @import("registry.zig");
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            var builder = init(failing_resize.allocator());
            defer builder.deinit();
            var entries: [16]DirectiveDefinition = undefined;
            inline for (0..entries.len) |index| {
                entries[index] = registry.find("save").?.*;
                entries[index].name = std.fmt.comptimePrint("save-{d}", .{index});
            }
            for (&entries) |*definition| {
                try builder.apply(try registry.prepare(definition, &.{ "60", "1" }), .file);
            }
            for (0..64) |index| {
                try builder.apply(.{
                    .definition = &entries[0],
                    .value = .{ .save = .{ .rule = .{
                        .seconds = @intCast(index + 1),
                        .changes = @intCast(index + 1),
                    } } },
                }, .file);
            }
            try std.testing.expectEqual(entries.len, builder.states.items.len);
            try std.testing.expectEqual(.building, builder.status);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}

test "finish returns untouched defaults without allocating" {
    var builder = init(std.testing.failing_allocator);
    defer builder.deinit();
    const config = try builder.finish();
    try std.testing.expectEqualDeep(Config.default(), config);
    try std.testing.expectEqual(.finished, builder.status);
    try std.testing.expectEqual(0, builder.states.items.len);
}

test "finish preserves partial scalar configuration without adding constraints" {
    const testing = std.testing;
    const registry = @import("registry.zig");
    var directory = "data files".*;
    const config = blk: {
        var builder = init(testing.failing_allocator);
        defer builder.deinit();
        try builder.apply(try registry.prepare(registry.find("port").?, &.{"7000"}), .file);
        try builder.apply(try registry.prepare(registry.find("dir").?, &.{&directory}), .file);
        try builder.apply(try registry.prepare(registry.find("bind").?, &.{"not an address"}), .file);
        try builder.apply(try registry.prepare(registry.find("appendfilename").?, &.{"history/journal.aof"}), .file);
        break :blk try builder.finish();
    };
    var expected = Config.default();
    expected.port = 7000;
    expected.dir = &directory;
    expected.bind_address = "not an address";
    expected.append_filename = "history/journal.aof";
    try testing.expectEqualDeep(expected, config);
    try testing.expect(config.dir.ptr == directory[0..].ptr);
    directory[0] = 'D';
    try testing.expectEqualStrings("Data files", config.dir);
}

test "finish invokes active state callbacks and retains output after builder cleanup" {
    const Probe = struct {
        const State = struct { value: u16 = 0 };
        var init_calls: usize = 0;
        var finalize_calls: usize = 0;
        var deinit_calls: usize = 0;
        var cleanup_mode: ?directive_definition.CleanupMode = null;
        var saw_save_rules: bool = false;

        fn stateFrom(context: *directive_definition.ApplyContext) *State {
            return @ptrCast(@alignCast(context.state.?));
        }

        fn initState(allocator: std.mem.Allocator) directive_definition.ApplyError!*anyopaque {
            const state = try allocator.create(State);
            state.* = .{};
            init_calls += 1;
            return state;
        }

        fn apply(context: *directive_definition.ApplyContext, value: directive_definition.Value) directive_definition.ApplyError!void {
            stateFrom(context).value = value.u16_value;
        }

        fn finalize(context: *directive_definition.ApplyContext) directive_definition.BuildError!void {
            finalize_calls += 1;
            saw_save_rules = context.config.save_rules.len == 2;
            context.config.connection_buffer_size = stateFrom(context).value;
        }

        fn deinitState(context: *directive_definition.ApplyContext, mode: directive_definition.CleanupMode) void {
            deinit_calls += 1;
            cleanup_mode = mode;
            context.allocator.destroy(stateFrom(context));
            context.state = null;
        }
    };
    Probe.init_calls = 0;
    Probe.finalize_calls = 0;
    Probe.deinit_calls = 0;
    Probe.cleanup_mode = null;
    Probe.saw_save_rules = false;
    const testing = std.testing;
    const registry = @import("registry.zig");
    const config = blk: {
        var definition = registry.find("port").?.*;
        definition.name = "buffer-from-state";
        definition.apply = Probe.apply;
        definition.state_lifecycle = .{
            .init = Probe.initState,
            .finalize = Probe.finalize,
            .deinit = Probe.deinitState,
        };
        var builder = init(testing.allocator);
        defer builder.deinit();
        try builder.apply(try registry.prepare(registry.find("save").?, &.{ "60", "1" }), .file);
        try builder.apply(try registry.prepare(registry.find("save").?, &.{ "300", "10" }), .file);
        try builder.apply(try registry.prepare(registry.find("port").?, &.{"7000"}), .file);
        try builder.apply(try registry.prepare(&definition, &.{"2048"}), .file);
        try builder.apply(try registry.prepare(&definition, &.{"4096"}), .file);
        try testing.expectEqual(1, Probe.init_calls);
        try testing.expectEqual(0, Probe.finalize_calls);
        try testing.expectEqual(0, builder.config.save_rules.len);
        try testing.expectEqual(Config.default().connection_buffer_size, builder.config.connection_buffer_size);
        break :blk try builder.finish();
    };
    defer testing.allocator.free(config.save_rules);
    try testing.expectEqual(1, Probe.finalize_calls);
    try testing.expectEqual(1, Probe.deinit_calls);
    try testing.expectEqual(directive_definition.CleanupMode.retain_config, Probe.cleanup_mode.?);
    try testing.expect(Probe.saw_save_rules);
    var expected = Config.default();
    expected.port = 7000;
    expected.connection_buffer_size = 4096;
    expected.save_rules = &.{
        .{ .seconds = 60, .changes = 1 },
        .{ .seconds = 300, .changes = 10 },
    };
    try testing.expectEqualDeep(expected, config);
}

test "finish allocation failure leaves state owned for discard" {
    const testing = std.testing;
    const registry = @import("registry.zig");
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    {
        var builder = init(failing.allocator());
        defer builder.deinit();
        try builder.apply(try registry.prepare(registry.find("save").?, &.{ "60", "1" }), .file);
        const state = builder.states.items[0].state;
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, builder.finish());
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(.failed, builder.status);
        try testing.expectEqual(1, builder.states.items.len);
        try testing.expect(builder.states.items[0].state == state);
        try testing.expectEqualDeep(Config.default(), builder.config);
    }
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "finish stops at a later finalizer failure and discards earlier output" {
    const Probe = struct {
        var failing_calls: usize = 0;
        var later_calls: usize = 0;
        var saw_earlier_output: bool = false;

        fn fail(context: *directive_definition.ApplyContext) directive_definition.BuildError!void {
            failing_calls += 1;
            saw_earlier_output = context.config.save_rules.len == 1;
            return error.OutOfMemory;
        }

        fn later(_: *directive_definition.ApplyContext) directive_definition.BuildError!void {
            later_calls += 1;
        }
    };
    Probe.failing_calls = 0;
    Probe.later_calls = 0;
    Probe.saw_earlier_output = false;
    const testing = std.testing;
    const registry = @import("registry.zig");
    const definition = registry.find("save").?;
    var failing_definition = definition.*;
    failing_definition.name = "failing-save";
    failing_definition.state_lifecycle.?.finalize = Probe.fail;
    var later_definition = definition.*;
    later_definition.name = "later-save";
    later_definition.state_lifecycle.?.finalize = Probe.later;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    {
        var builder = init(failing.allocator());
        defer builder.deinit();
        try builder.apply(try registry.prepare(definition, &.{ "60", "1" }), .file);
        try builder.apply(try registry.prepare(&failing_definition, &.{ "300", "10" }), .file);
        try builder.apply(try registry.prepare(&later_definition, &.{ "900", "100" }), .file);
        try testing.expectError(error.OutOfMemory, builder.finish());
        try testing.expectEqual(.failed, builder.status);
        try testing.expectEqual(1, Probe.failing_calls);
        try testing.expectEqual(0, Probe.later_calls);
        try testing.expect(Probe.saw_earlier_output);
        try testing.expectEqualDeep(
            &[_]Config.SaveRule{.{ .seconds = 60, .changes = 1 }},
            builder.config.save_rules,
        );
        try testing.expect(failing.allocated_bytes > failing.freed_bytes);
    }
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "finish cleans up every allocation failure and transfers output ownership on success" {
    const Run = struct {
        fn run(backing_allocator: std.mem.Allocator) !void {
            const registry = @import("registry.zig");
            var failing_resize = std.testing.FailingAllocator.init(backing_allocator, .{ .resize_fail_index = 0 });
            const allocator = failing_resize.allocator();
            const config = blk: {
                var builder = init(allocator);
                defer builder.deinit();
                for (0..64) |index| {
                    try builder.apply(.{
                        .definition = registry.find("save").?,
                        .value = .{ .save = .{ .rule = .{
                            .seconds = @intCast(index + 1),
                            .changes = @intCast(index + 1),
                        } } },
                    }, .file);
                }
                break :blk try builder.finish();
            };
            defer allocator.free(config.save_rules);
            try std.testing.expectEqual(64, config.save_rules.len);
            for (config.save_rules, 0..) |rule, index| {
                try std.testing.expectEqual(@as(i64, @intCast(index + 1)), rule.seconds);
                try std.testing.expectEqual(@as(u32, @intCast(index + 1)), rule.changes);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Run.run, .{});
}
