const std = @import("std");
const posix = std.posix;

pub const Error = posix.UnexpectedError || error{
    BadFileDescriptor,
    NotSocket,
    SystemResources,
    InvalidSocketAddress,
    AddressFamilyUnsupported,
};

pub fn localEndpoint(_: std.Io, handle: std.Io.net.Socket.Handle) Error!std.Io.net.IpAddress {
    var address: std.Io.Threaded.PosixAddress = undefined;
    var length: posix.socklen_t = @sizeOf(std.Io.Threaded.PosixAddress);
    while (true) {
        switch (posix.errno(posix.system.getsockname(handle, &address.any, &length))) {
            .SUCCESS => break,
            .INTR => continue,
            .BADF => return error.BadFileDescriptor,
            .NOTSOCK => return error.NotSocket,
            .NOBUFS => return error.SystemResources,
            .INVAL => return error.InvalidSocketAddress,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    if (length < @sizeOf(posix.sockaddr)) return error.InvalidSocketAddress;
    const required_length: posix.socklen_t = switch (address.any.family) {
        posix.AF.INET => @sizeOf(posix.sockaddr.in),
        posix.AF.INET6 => @sizeOf(posix.sockaddr.in6),
        else => return error.AddressFamilyUnsupported,
    };
    if (length < required_length) return error.InvalidSocketAddress;
    return std.Io.Threaded.addressFromPosix(&address);
}
