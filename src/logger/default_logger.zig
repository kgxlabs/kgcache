const std = @import("std");
const Logger = @import("interface.zig");

/// Logger for normal application threads. It is not the fork-safe child sink
/// required by persistence work.
const DefaultLogger = @This();

_io: std.Io,
// Error events use several writes. Without serialization, output can interleave:
//   [error] operation A failed: ErrorA
//   [error] operation B failed: ErrorB
//   error return trace:
//     0xA
// Keep every event's lines together.
_mutex: std.Io.Mutex = .init,

pub fn init(io: std.Io) DefaultLogger {
    return .{ ._io = io };
}

pub fn logger(self: *DefaultLogger) Logger {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: Logger.VTable = .{
    .log = log,
    .err = err,
};

fn log(ptr: *anyopaque, level: Logger.Level, message: []const u8) void {
    const self: *DefaultLogger = @ptrCast(@alignCast(ptr));
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    var buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "[{s}] {s}\n", .{ @tagName(level), message }) catch {
        self.writeStdout("[log] unable to format message\n");
        return;
    };
    self.writeStdout(line);
}

fn err(ptr: *anyopaque, message: []const u8, source: anyerror, trace: Logger.ErrorTrace) void {
    const self: *DefaultLogger = @ptrCast(@alignCast(ptr));
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    var error_buffer: [256]u8 = undefined;
    const error_line = std.fmt.bufPrint(&error_buffer, "[error] {s}: {s}\n", .{ message, @errorName(source) }) catch
        "[error] unable to format error\n";
    self.writeStderr(error_line);

    const return_trace = trace orelse return;
    self.writeStderr("error return trace:\n");

    const frame_count = @min(return_trace.index, return_trace.instruction_addresses.len);
    if (frame_count == 0) {
        self.writeStderr("  (empty)\n");
        return;
    }

    for (return_trace.instruction_addresses[0..frame_count]) |address| {
        var address_buffer: [64]u8 = undefined;
        const address_line = std.fmt.bufPrint(&address_buffer, "  0x{x}\n", .{address}) catch
            "  <unable to format trace address>\n";
        self.writeStderr(address_line);
    }

    if (return_trace.index > frame_count) {
        var omitted_buffer: [96]u8 = undefined;
        const omitted_line = std.fmt.bufPrint(
            &omitted_buffer,
            "  ({d} earlier return frames omitted)\n",
            .{return_trace.index - frame_count},
        ) catch "  (earlier return frames omitted)\n";
        self.writeStderr(omitted_line);
    }
}

fn writeStdout(self: *DefaultLogger, bytes: []const u8) void {
    std.Io.File.writeStreamingAll(std.Io.File.stdout(), self._io, bytes) catch {};
}

fn writeStderr(self: *DefaultLogger, bytes: []const u8) void {
    std.Io.File.writeStreamingAll(std.Io.File.stderr(), self._io, bytes) catch {};
}
