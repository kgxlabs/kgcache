const std = @import("std");

/// Unix time expressed as milliseconds since 1970-01-01T00:00:00Z.
///
/// This is an absolute timestamp, not a relative duration such as `EX 10`.
pub const UnixMs = i64;

pub fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

pub fn isPastTime(io: std.Io, value: UnixMs) bool {
    return nowMs(io) >= value;
}
