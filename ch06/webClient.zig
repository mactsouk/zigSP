const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;

pub const WebClientError = error{
    ConnectionFailed,
    ResolutionFailed,
    WriteFailed,
    ReadFailed,
    InvalidResponse,
    InvalidArguments,
    InvalidPort,
};

const Address = struct {
    host: []const u8,
    port: u16,
    is_ip: bool,
    ip: std.Io.net.IpAddress,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        std.debug.print("Usage: {s} <server:port> <url>\n", .{args[0]});
        std.debug.print("Example: {s} localhost:8080 /\n", .{args[0]});
        return WebClientError.InvalidArguments;
    }

    const server = args[1];
    const url = args[2];

    const response = try fetch(io, allocator, server, url);
    defer allocator.free(response);
    std.debug.print("{s}", .{response});
}

pub fn fetch(
    io: std.Io,
    allocator: mem.Allocator,
    server: []const u8,
    url: []const u8,
) ![]const u8 {
    const address = try parseAddress(allocator, server);
    defer if (!address.is_ip) allocator.free(address.host);

    const stream = try connectToAddress(io, address);
    defer stream.close(io);
    try sendRequest(
        io,
        allocator,
        stream,
        address.host,
        url,
        address.port,
    );
    return try readResponse(io, allocator, stream);
}

fn parseAddress(allocator: mem.Allocator, server: []const u8) !Address {
    const colon_index = mem.indexOf(u8, server, ":") orelse {
        if (std.Io.net.IpAddress.parseIp4(server, 80)) |ip| {
            return Address{
                .host = try allocator.dupe(u8, server),
                .port = 80,
                .is_ip = true,
                .ip = ip,
            };
        } else |_| {
            const host = try allocator.dupe(u8, server);
            return Address{
                .host = host,
                .port = 80,
                .is_ip = false,
                .ip = undefined,
            };
        }
    };

    const host_part = server[0..colon_index];
    const port_part = server[colon_index + 1 ..];
    const port = fmt.parseUnsigned(u16, port_part, 10) catch {
        return WebClientError.InvalidPort;
    };

    if (std.Io.net.IpAddress.parseIp4(host_part, port)) |ip| {
        return Address{
            .host = try allocator.dupe(u8, host_part),
            .port = port,
            .is_ip = true,
            .ip = ip,
        };
    } else |_| {
        const host = try allocator.dupe(u8, host_part);
        return Address{
            .host = host,
            .port = port,
            .is_ip = false,
            .ip = undefined,
        };
    }
}

fn connectToAddress(io: std.Io, address: Address) !std.Io.net.Stream {
    if (address.is_ip) {
        return address.ip.connect(io, .{ .mode = .stream }) catch |err| {
            std.log.err("Failed to connect to IP: {}", .{err});
            return err;
        };
    } else {
        const resolved = std.Io.net.IpAddress.resolve(
            io,
            address.host,
            address.port,
        ) catch {
            return WebClientError.ResolutionFailed;
        };
        return resolved.connect(io, .{ .mode = .stream }) catch |err| {
            std.log.err("Failed to connect to host: {}", .{err});
            return err;
        };
    }
}

fn sendRequest(
    io: std.Io,
    allocator: mem.Allocator,
    stream: std.Io.net.Stream,
    host: []const u8,
    url: []const u8,
    port: u16,
) !void {
    const request = if (port == 80)
        try fmt.allocPrint(
            allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n",
            .{ url, host },
        )
    else
        try fmt.allocPrint(
            allocator,
            "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n",
            .{ url, host, port },
        );
    defer allocator.free(request);

    var wbuf: [4096]u8 = undefined;
    var writer_impl = stream.writer(io, &wbuf);
    const writer = &writer_impl.interface;
    try writer.writeAll(request);
    try writer.flush();
}

fn readResponse(
    io: std.Io,
    allocator: mem.Allocator,
    stream: std.Io.net.Stream,
) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var rbuf: [4096]u8 = undefined;
    var reader_impl = stream.reader(io, &rbuf);
    const reader = &reader_impl.interface;

    while (true) {
        const n = reader.readSliceShort(&rbuf) catch |err| {
            std.log.err("Failed to read response: {}", .{err});
            return WebClientError.ReadFailed;
        };
        if (n == 0) break;
        try buffer.appendSlice(allocator, rbuf[0..n]);
    }

    return buffer.toOwnedSlice(allocator);
}

test "parseAddress - hostname with port" {
    const allocator = testing.allocator;
    const address = try parseAddress(allocator, "localhost:8080");
    defer {
        if (!address.is_ip) allocator.free(address.host);
        if (address.is_ip) allocator.free(address.host);
    }

    try testing.expect(!address.is_ip);
    try testing.expectEqualStrings("localhost", address.host);
    try testing.expectEqual(@as(u16, 8080), address.port);
}

test "parseAddress - ip with port" {
    const allocator = testing.allocator;
    const address = try parseAddress(allocator, "127.0.0.1:8080");
    defer allocator.free(address.host);

    try testing.expect(address.is_ip);
    try testing.expectEqualStrings("127.0.0.1", address.host);
    try testing.expectEqual(@as(u16, 8080), address.port);
}

test "parseAddress - default port" {
    const allocator = testing.allocator;
    const address = try parseAddress(allocator, "example.com");
    defer {
        if (!address.is_ip) allocator.free(address.host);
        if (address.is_ip) allocator.free(address.host);
    }

    try testing.expectEqual(@as(u16, 80), address.port);
}
