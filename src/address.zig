const std = @import("std");
const constants = @import("constants.zig");

pub const Address = struct {
    host: u32 = constants.host_any,
    port: u16 = constants.port_any,

    pub fn any(port: u16) Address {
        return .{ .host = constants.host_any, .port = port };
    }

    pub fn broadcast(port: u16) Address {
        return .{ .host = constants.host_broadcast, .port = port };
    }

    pub fn fromIpv4Octets(parts: [4]u8, port: u16) Address {
        return .{
            .host = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) | (@as(u32, parts[2]) << 8) | parts[3],
            .port = port,
        };
    }

    pub fn octets(self: Address) [4]u8 {
        return .{
            @truncate(self.host >> 24),
            @truncate(self.host >> 16),
            @truncate(self.host >> 8),
            @truncate(self.host),
        };
    }

    pub fn eql(self: Address, other: Address) bool {
        return self.host == other.host and self.port == other.port;
    }

    pub fn toNetAddress(self: Address) std.net.Address {
        return std.net.Address.initIp4(self.octets(), self.port);
    }

    pub fn fromNetAddress(address: std.net.Address) !Address {
        return switch (address.any.family) {
            std.posix.AF.INET => Address.fromIpv4Octets(@as(*const [4]u8, @ptrCast(&address.in.sa.addr)).*, address.in.getPort()),
            else => error.UnsupportedAddressFamily,
        };
    }

    pub fn format(self: Address, writer: *std.Io.Writer) !void {
        try self.toNetAddress().format(writer);
    }
};

test "address keeps network order host representation" {
    const address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091);
    try std.testing.expectEqual(@as(u32, 0x7F00_0001), address.host);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 127, 0, 0, 1 }, &address.octets());
}
