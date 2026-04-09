const std = @import("std");
const constants = @import("constants.zig");
const endian = @import("endian.zig");

pub const ProtocolHeader = packed struct {
    peer_id: u16,
    sent_time: u16,
};

pub const NewProtocolHeader = packed struct {
    integrity0: u16,
    integrity1: u16,
    integrity2: u16,
    peer_id: u16,
    sent_time: u16,
};

pub const ProtocolCommandHeader = packed struct {
    command: u8,
    channel_id: u8,
    reliable_sequence_number: u16,
};

pub const ProtocolAcknowledge = packed struct {
    header: ProtocolCommandHeader,
    received_reliable_sequence_number: u16,
    received_sent_time: u16,
};

pub const ProtocolConnect = packed struct {
    header: ProtocolCommandHeader,
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

pub const ProtocolVerifyConnect = packed struct {
    header: ProtocolCommandHeader,
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

pub const ProtocolBandwidthLimit = packed struct {
    header: ProtocolCommandHeader,
    incoming_bandwidth: u32,
    outgoing_bandwidth: u32,
};

pub const ProtocolThrottleConfigure = packed struct {
    header: ProtocolCommandHeader,
    packet_throttle_interval: u32,
    packet_throttle_acceleration: u32,
    packet_throttle_deceleration: u32,
};

pub const ProtocolDisconnect = packed struct {
    header: ProtocolCommandHeader,
    data: u32,
};

pub const ProtocolPing = packed struct {
    header: ProtocolCommandHeader,
};

pub const ProtocolSendReliable = packed struct {
    header: ProtocolCommandHeader,
    data_length: u16,
};

pub const ProtocolSendUnreliable = packed struct {
    header: ProtocolCommandHeader,
    unreliable_sequence_number: u16,
    data_length: u16,
};

pub const ProtocolSendUnsequenced = packed struct {
    header: ProtocolCommandHeader,
    unsequenced_group: u16,
    data_length: u16,
};

pub const ProtocolSendFragment = packed struct {
    header: ProtocolCommandHeader,
    start_sequence_number: u16,
    data_length: u16,
    fragment_count: u32,
    fragment_number: u32,
    total_length: u32,
    fragment_offset: u32,
};

pub const HeaderView = struct {
    peer_id: u16,
    session_id: u8,
    flags: u16,
    header_len: usize,
    sent_time: ?u16,
    integrity: ?[3]u16 = null,
};

pub const HeaderEncode = struct {
    peer_id: u16,
    session_id: u8 = 0,
    flags: u16 = 0,
    sent_time: ?u16 = null,
    integrity: ?[3]u16 = null,
};

pub const protocol_header_size: usize = 4;
pub const new_protocol_header_size: usize = 10;
pub const protocol_command_header_size: usize = 4;
pub const protocol_acknowledge_size: usize = 8;
pub const protocol_connect_size: usize = 48;
pub const protocol_verify_connect_size: usize = 44;
pub const protocol_bandwidth_limit_size: usize = 12;
pub const protocol_throttle_configure_size: usize = 16;
pub const protocol_disconnect_size: usize = 8;
pub const protocol_ping_size: usize = 4;
pub const protocol_send_reliable_size: usize = 6;
pub const protocol_send_unreliable_size: usize = 8;
pub const protocol_send_unsequenced_size: usize = 8;
pub const protocol_send_fragment_size: usize = 24;

pub fn commandSize(command: constants.ProtocolCommand) usize {
    return switch (command) {
        .none => 0,
        .acknowledge => protocol_acknowledge_size,
        .connect => protocol_connect_size,
        .verify_connect => protocol_verify_connect_size,
        .disconnect => protocol_disconnect_size,
        .ping => protocol_ping_size,
        .send_reliable => protocol_send_reliable_size,
        .send_unreliable => protocol_send_unreliable_size,
        .send_fragment, .send_unreliable_fragment => protocol_send_fragment_size,
        .send_unsequenced => protocol_send_unsequenced_size,
        .bandwidth_limit => protocol_bandwidth_limit_size,
        .throttle_configure => protocol_throttle_configure_size,
    };
}

pub fn headerPrefixLen(using_new_packet: bool, has_sent_time: bool) usize {
    if (using_new_packet) {
        return if (has_sent_time) new_protocol_header_size else 8;
    }
    return if (has_sent_time) protocol_header_size else 2;
}

pub fn headerLen(using_new_packet: bool, flags: u16, checksum_enabled: bool) usize {
    return headerPrefixLen(using_new_packet, (flags & constants.header_flag_sent_time) != 0) + @as(usize, if (checksum_enabled) @sizeOf(u32) else 0);
}

pub fn encodeHeader(out: []u8, using_new_packet: bool, header: HeaderEncode, checksum_enabled: bool) !usize {
    const encoded_flags = header.flags & constants.header_flag_mask;
    const has_sent_time = header.sent_time != null;
    const len = headerLen(using_new_packet, encoded_flags | if (has_sent_time) constants.header_flag_sent_time else 0, checksum_enabled);
    if (out.len < len) return error.BufferTooSmall;

    @memset(out[0..len], 0);

    const packed_peer_id: u16 = (header.peer_id & constants.protocol_maximum_peer_id) |
        ((@as(u16, header.session_id & 0x03)) << constants.header_session_shift) |
        encoded_flags |
        if (has_sent_time) constants.header_flag_sent_time else 0;

    if (using_new_packet) {
        const integrity = header.integrity orelse [_]u16{ 0, 0, 0 };
        endian.writeU16(out[0..2], integrity[0]);
        endian.writeU16(out[2..4], integrity[1]);
        endian.writeU16(out[4..6], integrity[2]);
        endian.writeU16(out[6..8], packed_peer_id);
        if (header.sent_time) |sent_time| endian.writeU16(out[8..10], sent_time);
    } else {
        endian.writeU16(out[0..2], packed_peer_id);
        if (header.sent_time) |sent_time| endian.writeU16(out[2..4], sent_time);
    }

    return len;
}

pub fn parseHeader(bytes: []const u8, using_new_packet_for_server: bool, checksum_enabled: bool) !HeaderView {
    const min_len = headerPrefixLen(using_new_packet_for_server, false) + @as(usize, if (checksum_enabled) @sizeOf(u32) else 0);
    if (bytes.len < min_len) return error.ShortHeader;

    var raw_peer_id: u16 = undefined;
    var integrity: ?[3]u16 = null;

    if (using_new_packet_for_server) {
        if (bytes.len < 8) return error.ShortHeader;
        raw_peer_id = endian.readU16(bytes[6..8]);
        integrity = .{
            endian.readU16(bytes[0..2]),
            endian.readU16(bytes[2..4]),
            endian.readU16(bytes[4..6]),
        };
    } else {
        raw_peer_id = endian.readU16(bytes[0..2]);
    }

    const flags = raw_peer_id & constants.header_flag_mask;
    const session_id: u8 = @intCast((raw_peer_id & constants.header_session_mask) >> constants.header_session_shift);
    const peer_id = raw_peer_id & ~(constants.header_flag_mask | constants.header_session_mask);
    const len = headerLen(using_new_packet_for_server, flags, checksum_enabled);
    if (bytes.len < len) return error.ShortHeader;

    var sent_time: ?u16 = null;
    if ((flags & constants.header_flag_sent_time) != 0) {
        sent_time = if (using_new_packet_for_server) endian.readU16(bytes[8..10]) else endian.readU16(bytes[2..4]);
    }

    return .{
        .peer_id = peer_id,
        .session_id = session_id,
        .flags = flags,
        .header_len = len,
        .sent_time = sent_time,
        .integrity = integrity,
    };
}

pub fn appendU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    const start = bytes.items.len;
    try bytes.resize(allocator, start + 2);
    endian.writeU16(bytes.items[start .. start + 2], value);
}

pub fn appendU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    const start = bytes.items.len;
    try bytes.resize(allocator, start + 4);
    endian.writeU32(bytes.items[start .. start + 4], value);
}

pub fn appendCommandHeader(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, command: u8, channel_id: u8, reliable_sequence_number: u16) !void {
    try bytes.append(allocator, command);
    try bytes.append(allocator, channel_id);
    try appendU16(bytes, allocator, reliable_sequence_number);
}

test "command sizes match current enet layout" {
    try std.testing.expectEqual(@as(usize, 8), commandSize(.acknowledge));
    try std.testing.expectEqual(@as(usize, 48), commandSize(.connect));
    try std.testing.expectEqual(@as(usize, 44), commandSize(.verify_connect));
    try std.testing.expectEqual(@as(usize, 24), commandSize(.send_fragment));
}

test "legacy header round trips" {
    var buf: [8]u8 = undefined;
    const len = try encodeHeader(&buf, false, .{
        .peer_id = 7,
        .session_id = 2,
        .flags = constants.header_flag_compressed,
        .sent_time = 1234,
    }, true);
    try std.testing.expectEqual(@as(usize, 8), len);

    const parsed = try parseHeader(buf[0..len], false, true);
    try std.testing.expectEqual(@as(u16, 7), parsed.peer_id);
    try std.testing.expectEqual(@as(u8, 2), parsed.session_id);
    try std.testing.expectEqual(@as(u16, constants.header_flag_compressed | constants.header_flag_sent_time), parsed.flags);
    try std.testing.expectEqual(@as(?u16, 1234), parsed.sent_time);
}

test "new packet header round trips" {
    var buf: [16]u8 = undefined;
    const len = try encodeHeader(&buf, true, .{
        .peer_id = 10,
        .session_id = 1,
        .sent_time = 99,
        .integrity = .{ 1, 2, 3 },
    }, false);
    try std.testing.expectEqual(@as(usize, 10), len);

    const parsed = try parseHeader(buf[0..len], true, false);
    try std.testing.expectEqual(@as(u16, 10), parsed.peer_id);
    try std.testing.expectEqual(@as(u8, 1), parsed.session_id);
    try std.testing.expectEqual(@as(?u16, 99), parsed.sent_time);
    try std.testing.expectEqual([3]u16{ 1, 2, 3 }, parsed.integrity.?);
}
