const std = @import("std");
const Address = @import("../address.zig").Address;
const transport_mod = @import("../transport.zig");

const posix = std.posix;

pub const UdpSocket = struct {
    socket: posix.socket_t,
    local_address: Address,

    pub fn bind(allocator: std.mem.Allocator, address: ?Address) !transport_mod.Transport {
        const self = try allocator.create(UdpSocket);
        errdefer allocator.destroy(self);

        const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(socket);

        const reuse_addr: i32 = 1;
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&reuse_addr));

        const bind_address = (address orelse Address.any(0)).toNetAddress();
        try posix.bind(socket, &bind_address.any, bind_address.getOsSockLen());

        var resolved = bind_address;
        var resolved_len = resolved.getOsSockLen();
        try posix.getsockname(socket, &resolved.any, &resolved_len);

        self.* = .{
            .socket = socket,
            .local_address = try Address.fromNetAddress(resolved),
        };

        return .{
            .allocator = allocator,
            .ctx = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn deinitOpaque(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *UdpSocket = @ptrCast(@alignCast(ctx));
        posix.close(self.socket);
        allocator.destroy(self);
    }

    fn sendOpaque(ctx: *anyopaque, address: Address, bytes: []const u8) !usize {
        const self: *UdpSocket = @ptrCast(@alignCast(ctx));
        const net_address = address.toNetAddress();
        return posix.sendto(self.socket, bytes, 0, &net_address.any, net_address.getOsSockLen());
    }

    fn receiveOpaque(ctx: *anyopaque, buffer: []u8) !?transport_mod.ReceiveResult {
        const self: *UdpSocket = @ptrCast(@alignCast(ctx));
        var net_address: std.net.Address = undefined;
        var addr_len = @as(posix.socklen_t, @intCast(@sizeOf(std.net.Address)));
        const received = posix.recvfrom(self.socket, buffer, 0, &net_address.any, &addr_len) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };

        return .{
            .address = try Address.fromNetAddress(net_address),
            .len = received,
        };
    }

    const vtable = transport_mod.VTable{
        .deinit = deinitOpaque,
        .send = sendOpaque,
        .receive = receiveOpaque,
    };
};
