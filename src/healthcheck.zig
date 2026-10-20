const std = @import("std");
const Config = @import("config.zig");

const request = "*1\r\n$4\r\nPING\r\n";
const response = "+PONG\r\n";

pub const Error = error{
    InvalidBindAddress,
    PortZero,
    ConnectFailed,
    NetworkFailed,
    Timeout,
    UnexpectedReply,
    ProbeUnavailable,
} || std.Io.Cancelable;

pub fn endpoint(config: Config) Error!std.Io.net.IpAddress {
    const address = std.Io.net.IpAddress.parseIp4(config.bind_address, config.port) catch
        return error.InvalidBindAddress;
    if (config.port == 0) return error.PortZero;
    if (std.mem.eql(u8, &address.ip4.bytes, &.{ 0, 0, 0, 0 })) {
        return .{ .ip4 = .loopback(config.port) };
    }
    return address;
}

/// Check one response frame. All network work shares one monotonic deadline.
pub fn probe(io: std.Io, config: Config) Error!void {
    const address = try endpoint(config);
    const deadline = std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{
        .raw = .fromMilliseconds(1000),
        .clock = .awake,
    });
    const Outcome = union(enum) {
        network: Error!void,
        deadline: std.Io.Cancelable!void,
    };
    var buffer: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &buffer);
    // Cancellation interrupts connect/read/write in the pinned Threaded runtime.
    // Its connect timeout option is not implemented on POSIX in Zig 0.16.
    defer select.cancelDiscard();

    select.concurrent(.deadline, std.Io.Clock.Timestamp.wait, .{ deadline, io }) catch
        return error.ProbeUnavailable;
    select.concurrent(.network, exchange, .{ io, address }) catch
        return error.ProbeUnavailable;

    switch (try select.await()) {
        .network => |result| {
            try result;
            // A late result must not win merely because the timer was delayed.
            if (deadline.raw.nanoseconds <= std.Io.Clock.now(.awake, io).nanoseconds)
                return error.Timeout;
        },
        .deadline => |result| {
            try result;
            return error.Timeout;
        },
    }
}

fn exchange(io: std.Io, address: std.Io.net.IpAddress) Error!void {
    const stream = address.connect(io, .{ .mode = .stream }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Timeout => return error.Timeout,
        else => return error.ConnectFailed,
    };
    defer stream.close(io);

    try exchangeFrame(io, stream.socket.handle);
}

fn exchangeFrame(io: std.Io, handle: std.Io.net.Socket.Handle) Error!void {
    var sent: usize = 0;
    while (sent < request.len) {
        const count = io.vtable.netWrite(io.userdata, handle, request[sent..], &.{""}, 0) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.NetworkFailed,
        };
        if (count == 0) return error.NetworkFailed;
        sent += count;
    }

    var reply: [response.len]u8 = undefined;
    var received: usize = 0;
    while (received < reply.len) {
        var buffers = [_][]u8{reply[received..]};
        const count = io.vtable.netRead(io.userdata, handle, &buffers) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Timeout => return error.Timeout,
            else => return error.NetworkFailed,
        };
        if (count == 0) return error.UnexpectedReply;

        if (!std.mem.eql(u8, reply[received..][0..count], response[received..][0..count]))
            return error.UnexpectedReply;

        received += count;
    }
}

pub fn diagnostic(err: Error) []const u8 {
    return switch (err) {
        error.InvalidBindAddress => "healthcheck: endpoint requires a numeric IPv4 bind address",
        error.PortZero => "healthcheck: endpoint requires a concrete port (port 0 is unsupported)",
        error.ConnectFailed => "healthcheck: connection failed",
        error.Timeout => "healthcheck: network deadline expired",
        error.UnexpectedReply => "healthcheck: unexpected reply",
        error.NetworkFailed => "healthcheck: network operation failed",
        error.ProbeUnavailable, error.Canceled => "healthcheck: probe unavailable",
    };
}

test "health endpoint follows server IPv4 rules and maps wildcard to loopback" {
    const testing = std.testing;
    const defaults = try endpoint(.{});

    try testing.expectEqual(6379, defaults.getPort());
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &defaults.ip4.bytes);

    const wildcard = try endpoint(.{ .bind_address = "0.0.0.0", .port = 7000 });
    try testing.expectEqual(7000, wildcard.getPort());
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &wildcard.ip4.bytes);

    const concrete = try endpoint(.{ .bind_address = "192.0.2.5", .port = 7001 });
    try testing.expectEqualSlices(u8, &.{ 192, 0, 2, 5 }, &concrete.ip4.bytes);

    for ([_][]const u8{ "localhost", "::1", "127.0.0.999", "127.1", "" }) |bind| {
        try testing.expectError(error.InvalidBindAddress, endpoint(.{ .bind_address = bind }));
    }
    try testing.expectError(error.PortZero, endpoint(.{ .port = 0 }));
}

test "health frame handles partial writes and reads with fixed storage" {
    const Fake = struct {
        sent: usize = 0,
        received: usize = 0,
        reply: []const u8 = response,
        zero_write: bool = false,
        fn write(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, bytes: []const u8, _: []const []const u8, _: usize) std.Io.net.Stream.Writer.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(ptr));

            if (self.zero_write) return 0;

            const count = @min(2, bytes.len);
            std.testing.expectEqualSlices(u8, request[self.sent..][0..count], bytes[0..count]) catch unreachable;
            self.sent += count;

            return count;
        }
        fn read(ptr: ?*anyopaque, _: std.Io.net.Socket.Handle, buffers: [][]u8) std.Io.net.Stream.Reader.Error!usize {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (self.received == self.reply.len) return 0;

            buffers[0][0] = self.reply[self.received];
            self.received += 1;

            return 1;
        }
    };

    var vtable = std.testing.io.vtable.*;
    vtable.netWrite = Fake.write;
    vtable.netRead = Fake.read;

    var fake: Fake = .{};
    const io: std.Io = .{ .userdata = &fake, .vtable = &vtable };

    try exchangeFrame(io, 0);
    try std.testing.expectEqual(request.len, fake.sent);
    try std.testing.expectEqual(response.len, fake.received);

    for ([_][]const u8{ "", "+PO", "+PONG\n", "+WRONG\r\n", "-ERR bad\r\n", "$4\r\nPONG\r\n", ":1\r\n" }) |reply| {
        fake = .{ .reply = reply };
        try std.testing.expectError(error.UnexpectedReply, exchangeFrame(io, 0));
    }
    fake = .{ .zero_write = true };

    try std.testing.expectError(error.NetworkFailed, exchangeFrame(io, 0));
}

test "health probe exchanges a fragmented response and closes without waiting for EOF" {
    const io = std.testing.io;
    const Peer = struct {
        fn run(peer_io: std.Io, server: *std.Io.net.Server) !void {
            const stream = try server.accept(peer_io);
            defer stream.close(peer_io);

            var bytes: [request.len]u8 = undefined;
            var reader = stream.reader(peer_io, &.{});
            try reader.interface.readSliceAll(&bytes);
            try std.testing.expectEqualStrings(request, &bytes);

            for (response) |byte| {
                var writer = stream.writer(peer_io, &.{});
                try writer.interface.writeByte(byte);
            }
            // The probe must close after the frame, while this peer is still open.
            var buffers = [_][]u8{&bytes};
            try std.testing.expectEqual(0, try peer_io.vtable.netRead(peer_io.userdata, stream.socket.handle, &buffers));
        }
    };

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var peer = try io.concurrent(Peer.run, .{ io, &server });
    defer _ = peer.cancel(io) catch {};

    try probe(io, .{ .port = server.socket.address.getPort() });
    try peer.await(io);
}

test "health probe closes silent and slow peers at the total deadline" {
    const io = std.testing.io;
    const Peer = struct {
        fn run(peer_io: std.Io, server: *std.Io.net.Server, slow: bool) !void {
            const stream = try server.accept(peer_io);
            defer stream.close(peer_io);

            var reader = stream.reader(peer_io, &.{});
            var bytes: [request.len]u8 = undefined;
            try reader.interface.readSliceAll(&bytes);

            if (slow) {
                var writer = stream.writer(peer_io, &.{});
                for ("+PO") |byte| {
                    try std.Io.sleep(peer_io, .fromMilliseconds(250), .awake);
                    try writer.interface.writeByte(byte);
                }
            }
            var buffers = [_][]u8{&bytes};
            try std.testing.expectEqual(0, try peer_io.vtable.netRead(peer_io.userdata, stream.socket.handle, &buffers));
        }
    };
    for ([_]bool{ false, true }) |slow| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try address.listen(io, .{});
        defer server.deinit(io);

        var peer = try io.concurrent(Peer.run, .{ io, &server, slow });
        defer _ = peer.cancel(io) catch {};

        const started = std.Io.Clock.now(.awake, io);
        try std.testing.expectError(error.Timeout, probe(io, .{ .port = server.socket.address.getPort() }));
        const elapsed = started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();

        try std.testing.expect(elapsed >= 900 and elapsed < 2500);
        try peer.await(io);
    }
}

test "health probe reports refusal" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    const port = server.socket.address.getPort();
    server.deinit(io);
    try std.testing.expectError(error.ConnectFailed, probe(io, .{ .port = port }));
}

test "health deadline cancels connect, write, and read and closes acquired sockets" {
    const Transport = struct {
        const Stage = enum { connect, write, read };
        var active: *@This() = undefined;
        stage: Stage,
        closed: usize = 0,
        blocked: std.Io.Event = .unset,

        fn connect(_: ?*anyopaque, address: *const std.Io.net.IpAddress, _: std.Io.net.IpAddress.ConnectOptions) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
            if (active.stage == .connect) try active.blocked.wait(std.testing.io);
            return .{ .handle = 123, .address = address.* };
        }
        fn write(_: ?*anyopaque, _: std.Io.net.Socket.Handle, bytes: []const u8, _: []const []const u8, _: usize) std.Io.net.Stream.Writer.Error!usize {
            if (active.stage == .write) try active.blocked.wait(std.testing.io);
            return bytes.len;
        }
        fn read(_: ?*anyopaque, _: std.Io.net.Socket.Handle, _: [][]u8) std.Io.net.Stream.Reader.Error!usize {
            try active.blocked.wait(std.testing.io);
            return 0;
        }
        fn close(_: ?*anyopaque, handles: []const std.Io.net.Socket.Handle) void {
            active.closed += handles.len;
        }
    };

    var vtable = std.testing.io.vtable.*;
    vtable.netConnectIp = Transport.connect;
    vtable.netWrite = Transport.write;
    vtable.netRead = Transport.read;
    vtable.netClose = Transport.close;

    var io = std.testing.io;
    io.vtable = &vtable;
    for ([_]Transport.Stage{ .connect, .write, .read }) |stage| {
        var transport: Transport = .{ .stage = stage };
        Transport.active = &transport;
        const started = std.Io.Clock.now(.awake, io);

        try std.testing.expectError(error.Timeout, probe(io, .{}));
        const elapsed = started.durationTo(std.Io.Clock.now(.awake, io)).toMilliseconds();

        try std.testing.expect(elapsed >= 900 and elapsed < 2500);
        try std.testing.expectEqual(@as(usize, if (stage == .connect) 0 else 1), transport.closed);
    }
}
