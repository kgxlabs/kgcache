const std = @import("std");
const semver = @import("semver");

test "SemVer accepts and rejects the shared contract fixtures" {
    const Case = struct { value: []const u8, valid: bool };
    const cases = try std.json.parseFromSlice([]const Case, std.testing.allocator, @embedFile("semver-cases.json"), .{});
    defer cases.deinit();
    for (cases.value) |case| {
        errdefer std.debug.print("version: {s}\n", .{case.value});
        try std.testing.expectEqual(case.valid, semver.isValid(case.value));
    }
}
