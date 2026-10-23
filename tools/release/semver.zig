const std = @import("std");

// Validate SemVer 2.0.0 without converting numeric identifiers to bounded integers.
pub fn isValid(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, '+');
    const version = parts.first();
    if (parts.next()) |metadata| {
        if (!identifiersValid(metadata, false) or parts.next() != null) return false;
    }

    const separator = std.mem.indexOfScalar(u8, version, '-');
    const core = if (separator) |index| version[0..index] else version;
    if (separator) |index| {
        if (!identifiersValid(version[index + 1 ..], true)) return false;
    }

    var numbers = std.mem.splitScalar(u8, core, '.');
    for (0..3) |_| {
        const number = numbers.next() orelse return false;
        if (!numericValid(number)) return false;
    }
    return numbers.next() == null;
}

fn numericValid(value: []const u8) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn identifiersValid(value: []const u8, prerelease: bool) bool {
    var identifiers = std.mem.splitScalar(u8, value, '.');
    while (identifiers.next()) |identifier| {
        if (identifier.len == 0) return false;
        var numeric = true;
        for (identifier) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
            if (!std.ascii.isDigit(byte)) numeric = false;
        }
        if (prerelease and numeric and !numericValid(identifier)) return false;
    }
    return true;
}
