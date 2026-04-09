const std = @import("std");
const Address = @import("address.zig").Address;
const config = @import("config.zig");
const host_mod = @import("host.zig");
const Packet = @import("packet.zig").Packet;

pub const ENetAddress = Address;
pub const ENetHost = host_mod.Host;
pub const ENetPeer = host_mod.Peer;
pub const ENetEvent = host_mod.Event;

pub fn enet_host_create(allocator: std.mem.Allocator, address: ?*const ENetAddress, peer_count: usize, channel_limit: usize, incoming_bandwidth: u32, outgoing_bandwidth: u32) !*ENetHost {
    return host_mod.Host.init(allocator, .{
        .address = if (address) |addr| addr.* else null,
        .peer_limit = peer_count,
        .channel_limit = channel_limit,
        .bandwidth = .{
            .incoming = incoming_bandwidth,
            .outgoing = outgoing_bandwidth,
        },
    });
}

pub fn enet_host_connect(host: *ENetHost, address: *const ENetAddress, channel_count: usize, data: u32) !*ENetPeer {
    return host.connect(address.*, channel_count, data);
}

pub fn enet_host_service(host: *ENetHost, timeout_ms: u32) !?ENetEvent {
    return host.service(timeout_ms);
}

pub fn enet_host_flush(host: *ENetHost) !void {
    try host.flush();
}

pub fn enet_packet_create(allocator: std.mem.Allocator, data: ?[]const u8, data_length: usize, flags: u32) !*Packet {
    return Packet.create(allocator, data, data_length, flags);
}
