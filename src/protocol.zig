const std = @import("std");
const constants = @import("constants.zig");
const ProtocolFlavor = @import("config.zig").ProtocolFlavor;
const Packet = @import("packet.zig").Packet;

pub const OutgoingCommand = struct {
    command: constants.ProtocolCommand,
    command_flags: u8,
    channel_id: u8,
    sequence_assigned: bool = false,
    reliable_sequence_number: u16 = 0,
    unreliable_sequence_number: u16 = 0,
    start_sequence_number: u16 = 0,
    sent_time: u32 = 0,
    round_trip_timeout: u32 = 0,
    queue_time: u32 = 0,
    fragment_offset: u32 = 0,
    fragment_length: u16 = 0,
    fragment_number: u32 = 0,
    fragment_count: u32 = 0,
    total_length: u32 = 0,
    send_attempts: u16 = 0,
    packet: ?*Packet = null,
};

pub const Acknowledgement = struct {
    channel_id: u8,
    reliable_sequence_number: u16,
    sent_time: u16,
    command: constants.ProtocolCommand,
};

pub const IncomingCommand = struct {
    channel_id: u8,
    reliable_sequence_number: u16,
    unreliable_sequence_number: u16 = 0,
    command: constants.ProtocolCommand,
    flags: u32,
    fragment_count: u32 = 0,
    packet: *Packet,
};

pub const Fragment = struct {
    command: constants.ProtocolCommand,
    offset: u32,
    length: u16,
    start_sequence_number: u16,
    fragment_number: u32,
    fragment_count: u32,
};

pub const FragmentAssembly = struct {
    allocator: std.mem.Allocator,
    channel_id: u8,
    reliable_sequence_number: u16,
    unreliable_sequence_number: u16 = 0,
    start_sequence_number: u16,
    command: constants.ProtocolCommand,
    fragment_count: u32,
    fragments_remaining: u32,
    total_length: usize,
    packet: *Packet,
    received: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        channel_id: u8,
        start_sequence_number: u16,
        command: constants.ProtocolCommand,
        fragment_count: u32,
        total_length: usize,
    ) !FragmentAssembly {
        var packet = try Packet.create(allocator, null, total_length, if (command == .send_fragment) constants.packet_flag_reliable else 0);
        errdefer packet.release();
        packet.retain();

        const received = try allocator.alloc(bool, @intCast(fragment_count));
        errdefer allocator.free(received);
        @memset(received, false);

        return .{
            .allocator = allocator,
            .channel_id = channel_id,
            .reliable_sequence_number = start_sequence_number,
            .start_sequence_number = start_sequence_number,
            .command = command,
            .fragment_count = fragment_count,
            .fragments_remaining = fragment_count,
            .total_length = total_length,
            .packet = packet,
            .received = received,
        };
    }

    pub fn deinit(self: *FragmentAssembly) void {
        self.packet.release();
        self.allocator.free(self.received);
    }

    pub fn insertFragment(self: *FragmentAssembly, fragment_number: u32, fragment_offset: u32, bytes: []const u8) bool {
        if (fragment_number >= self.fragment_count) return false;
        const index: usize = @intCast(fragment_number);
        if (self.received[index]) return false;

        const start: usize = @intCast(fragment_offset);
        const end = start + bytes.len;
        if (end > self.packet.data.len) return false;

        @memcpy(self.packet.data[start..end], bytes);
        self.received[index] = true;
        self.fragments_remaining -= 1;
        return true;
    }

    pub fn isComplete(self: *const FragmentAssembly) bool {
        return self.fragments_remaining == 0;
    }
};

pub const ConnectRequest = struct {
    outgoing_peer_id: u16,
    incoming_session_id: u8,
    outgoing_session_id: u8,
    mtu: u32,
    window_size: u32,
    channel_count: u32,
    incoming_bandwidth: u32,
    outgoing_bandwidth: u32,
    packet_throttle_interval: u32,
    packet_throttle_acceleration: u32,
    packet_throttle_deceleration: u32,
    connect_id: u32,
    data: u32,
};

pub const VerifyConnect = struct {
    outgoing_peer_id: u16,
    incoming_session_id: u8,
    outgoing_session_id: u8,
    mtu: u32,
    window_size: u32,
    channel_count: u32,
    incoming_bandwidth: u32,
    outgoing_bandwidth: u32,
    packet_throttle_interval: u32,
    packet_throttle_acceleration: u32,
    packet_throttle_deceleration: u32,
    connect_id: u32,
};

pub fn clampChannelCount(count: usize) usize {
    return std.math.clamp(count, constants.protocol_minimum_channel_count, constants.protocol_maximum_channel_count);
}

pub fn clampMtu(mtu: u32) u32 {
    return std.math.clamp(mtu, constants.protocol_minimum_mtu, constants.protocol_maximum_mtu);
}

pub fn defaultWindowSize(outgoing_bandwidth: u32) u32 {
    if (outgoing_bandwidth == 0) return constants.protocol_maximum_window_size;

    const candidate = (outgoing_bandwidth / constants.peer_window_size_scale) * constants.protocol_minimum_window_size;
    return std.math.clamp(candidate, constants.protocol_minimum_window_size, constants.protocol_maximum_window_size);
}

pub fn fragmentLength(mtu: u32, checksum_enabled: bool, flavor: ProtocolFlavor) usize {
    const header: usize = switch (flavor) {
        .growtopia_server => @import("wire.zig").new_protocol_header_size,
        else => @import("wire.zig").protocol_header_size,
    };
    var length: usize = @intCast(mtu);
    length -= header + @import("wire.zig").protocol_send_fragment_size;
    if (checksum_enabled) length -= @sizeOf(u32);
    return length;
}

pub fn throttle(current: u32, limit: u32, acceleration: u32, deceleration: u32, last_round_trip_time: u32, last_round_trip_time_variance: u32, rtt: u32) i8 {
    _ = limit;
    if (last_round_trip_time <= last_round_trip_time_variance) return 0;
    if (rtt <= last_round_trip_time) {
        _ = current;
        _ = acceleration;
        return 1;
    }
    if (rtt > last_round_trip_time + (2 * last_round_trip_time_variance)) {
        _ = deceleration;
        return -1;
    }
    return 0;
}

pub fn planFragments(allocator: std.mem.Allocator, packet: *Packet, mtu: u32, checksum_enabled: bool, flavor: ProtocolFlavor, unreliable_sequence_number: u16, reliable_sequence_number: u16) ![]Fragment {
    const max_fragment = fragmentLength(mtu, checksum_enabled, flavor);
    if (packet.data.len <= max_fragment) return allocator.alloc(Fragment, 0);

    const fragment_count: u32 = @intCast((packet.data.len + max_fragment - 1) / max_fragment);
    if (fragment_count > constants.protocol_maximum_fragment_count) return error.TooManyFragments;

    const use_unreliable = (packet.flags & (constants.packet_flag_reliable | constants.packet_flag_unreliable_fragment)) == constants.packet_flag_unreliable_fragment and unreliable_sequence_number < 0xFFFF;
    const fragments = try allocator.alloc(Fragment, @intCast(fragment_count));

    var offset: usize = 0;
    var index: usize = 0;
    while (offset < packet.data.len) : (index += 1) {
        const remaining = packet.data.len - offset;
        const frag_len: u16 = @intCast(@min(remaining, max_fragment));
        fragments[index] = .{
            .command = if (use_unreliable) .send_unreliable_fragment else .send_fragment,
            .offset = @intCast(offset),
            .length = frag_len,
            .start_sequence_number = if (use_unreliable) unreliable_sequence_number + 1 else reliable_sequence_number + 1,
            .fragment_number = @intCast(index),
            .fragment_count = fragment_count,
        };
        offset += @as(usize, frag_len);
    }

    return fragments;
}

pub fn parseConnect(bytes: []const u8) !ConnectRequest {
    if (bytes.len < @import("wire.zig").protocol_connect_size) return error.ShortConnect;
    return .{
        .outgoing_peer_id = @import("endian.zig").readU16(bytes[4..6]),
        .incoming_session_id = bytes[6],
        .outgoing_session_id = bytes[7],
        .mtu = @import("endian.zig").readU32(bytes[8..12]),
        .window_size = @import("endian.zig").readU32(bytes[12..16]),
        .channel_count = @import("endian.zig").readU32(bytes[16..20]),
        .incoming_bandwidth = @import("endian.zig").readU32(bytes[20..24]),
        .outgoing_bandwidth = @import("endian.zig").readU32(bytes[24..28]),
        .packet_throttle_interval = @import("endian.zig").readU32(bytes[28..32]),
        .packet_throttle_acceleration = @import("endian.zig").readU32(bytes[32..36]),
        .packet_throttle_deceleration = @import("endian.zig").readU32(bytes[36..40]),
        .connect_id = @import("endian.zig").readU32(bytes[40..44]),
        .data = @import("endian.zig").readU32(bytes[44..48]),
    };
}

pub fn parseVerifyConnect(bytes: []const u8) !VerifyConnect {
    if (bytes.len < @import("wire.zig").protocol_verify_connect_size) return error.ShortVerifyConnect;
    return .{
        .outgoing_peer_id = @import("endian.zig").readU16(bytes[4..6]),
        .incoming_session_id = bytes[6],
        .outgoing_session_id = bytes[7],
        .mtu = @import("endian.zig").readU32(bytes[8..12]),
        .window_size = @import("endian.zig").readU32(bytes[12..16]),
        .channel_count = @import("endian.zig").readU32(bytes[16..20]),
        .incoming_bandwidth = @import("endian.zig").readU32(bytes[20..24]),
        .outgoing_bandwidth = @import("endian.zig").readU32(bytes[24..28]),
        .packet_throttle_interval = @import("endian.zig").readU32(bytes[28..32]),
        .packet_throttle_acceleration = @import("endian.zig").readU32(bytes[32..36]),
        .packet_throttle_deceleration = @import("endian.zig").readU32(bytes[36..40]),
        .connect_id = @import("endian.zig").readU32(bytes[40..44]),
    };
}

test "default window size matches enet clamp behavior" {
    try std.testing.expectEqual(constants.protocol_maximum_window_size, defaultWindowSize(0));
    try std.testing.expectEqual(constants.protocol_minimum_window_size, defaultWindowSize(1));
}

test "fragment planning matches packet length" {
    var packet = try Packet.create(std.testing.allocator, null, 4096, 0);
    defer packet.release();
    packet.retain();

    const fragments = try planFragments(std.testing.allocator, packet, constants.host_default_mtu, false, .vanilla, 0, 1);
    defer std.testing.allocator.free(fragments);

    try std.testing.expect(fragments.len > 1);
    try std.testing.expectEqual(@as(u32, @intCast(fragments.len)), fragments[0].fragment_count);
}
