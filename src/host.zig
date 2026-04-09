const std = @import("std");
const Address = @import("address.zig").Address;
const ChannelState = @import("channel.zig").ChannelState;
const checksum = @import("checksum.zig");
const config = @import("config.zig");
const constants = @import("constants.zig");
const endian = @import("endian.zig");
const Packet = @import("packet.zig").Packet;
const protocol = @import("protocol.zig");
const transport_mod = @import("transport.zig");
const wire = @import("wire.zig");

pub const Peer = struct {
    host: *Host,
    incoming_peer_id: u16,
    outgoing_peer_id: u16 = constants.protocol_maximum_peer_id,
    outgoing_session_id: u8 = 0xFF,
    incoming_session_id: u8 = 0xFF,
    connect_id: u32 = 0,
    address: Address = .{},
    state: constants.PeerState = .disconnected,
    channels: []ChannelState = &.{},
    incoming_bandwidth: u32 = 0,
    outgoing_bandwidth: u32 = 0,
    incoming_bandwidth_throttle_epoch: u32 = 0,
    outgoing_bandwidth_throttle_epoch: u32 = 0,
    incoming_data_total: u32 = 0,
    outgoing_data_total: u32 = 0,
    last_send_time: u32 = 0,
    last_receive_time: u32 = 0,
    next_timeout: u32 = 0,
    earliest_timeout: u32 = 0,
    packet_loss_epoch: u32 = 0,
    packets_sent: u32 = 0,
    packets_lost: u32 = 0,
    packet_loss: u32 = 0,
    packet_loss_variance: u32 = 0,
    packet_throttle: u32 = constants.peer_default_packet_throttle,
    packet_throttle_limit: u32 = constants.peer_packet_throttle_scale,
    packet_throttle_counter: u32 = 0,
    packet_throttle_epoch: u32 = 0,
    packet_throttle_acceleration: u32 = constants.peer_packet_throttle_acceleration,
    packet_throttle_deceleration: u32 = constants.peer_packet_throttle_deceleration,
    packet_throttle_interval: u32 = constants.peer_packet_throttle_interval,
    ping_interval: u32 = constants.peer_ping_interval,
    timeout_limit: u32 = constants.peer_timeout_limit,
    timeout_minimum: u32 = constants.peer_timeout_minimum,
    timeout_maximum: u32 = constants.peer_timeout_maximum,
    last_round_trip_time: u32 = constants.peer_default_round_trip_time,
    lowest_round_trip_time: u32 = constants.peer_default_round_trip_time,
    last_round_trip_time_variance: u32 = 0,
    highest_round_trip_time_variance: u32 = 0,
    round_trip_time: u32 = constants.peer_default_round_trip_time,
    round_trip_time_variance: u32 = 0,
    mtu: u32 = constants.host_default_mtu,
    window_size: u32 = constants.protocol_maximum_window_size,
    reliable_data_in_transit: u32 = 0,
    outgoing_reliable_sequence_number: u16 = 0,
    nonce: u16 = 0,
    incoming_unsequenced_group: u16 = 0,
    outgoing_unsequenced_group: u16 = 0,
    unsequenced_window: [constants.peer_unsequenced_window_size / 32]u32 = std.mem.zeroes([constants.peer_unsequenced_window_size / 32]u32),
    event_data: u32 = 0,
    total_waiting_data: usize = 0,
    queued_outgoing: std.ArrayList(protocol.OutgoingCommand),
    sent_reliable: std.ArrayList(protocol.OutgoingCommand),
    acknowledgements: std.ArrayList(protocol.Acknowledgement),
    dispatched_commands: std.ArrayList(protocol.IncomingCommand),

    pub fn init(host: *Host, peer_id: u16) Peer {
        return .{
            .host = host,
            .incoming_peer_id = peer_id,
            .queued_outgoing = .empty,
            .sent_reliable = .empty,
            .acknowledgements = .empty,
            .dispatched_commands = .empty,
        };
    }

    pub fn deinit(self: *Peer) void {
        for (self.queued_outgoing.items) |command| {
            if (command.packet) |packet| packet.release();
        }
        for (self.sent_reliable.items) |command| {
            if (command.packet) |packet| packet.release();
        }
        for (self.dispatched_commands.items) |incoming| {
            incoming.packet.release();
        }
        for (self.channels) |*channel| {
            for (channel.pending_reliable.items) |incoming| incoming.packet.release();
            for (channel.pending_unreliable.items) |incoming| incoming.packet.release();
            for (channel.fragment_assemblies.items) |*assembly| assembly.deinit();
            channel.pending_reliable.deinit(self.host.allocator);
            channel.pending_unreliable.deinit(self.host.allocator);
            channel.fragment_assemblies.deinit(self.host.allocator);
        }
        if (self.channels.len > 0) self.host.allocator.free(self.channels);
        self.queued_outgoing.deinit(self.host.allocator);
        self.sent_reliable.deinit(self.host.allocator);
        self.acknowledgements.deinit(self.host.allocator);
        self.dispatched_commands.deinit(self.host.allocator);
    }

    pub fn configureThrottle(self: *Peer, interval: u32, acceleration: u32, deceleration: u32) void {
        self.packet_throttle_interval = interval;
        self.packet_throttle_acceleration = acceleration;
        self.packet_throttle_deceleration = deceleration;
    }

    pub fn setTimeout(self: *Peer, limit: u32, minimum: u32, maximum: u32) void {
        self.timeout_limit = if (limit == 0) constants.peer_timeout_limit else limit;
        self.timeout_minimum = if (minimum == 0) constants.peer_timeout_minimum else minimum;
        self.timeout_maximum = if (maximum == 0) constants.peer_timeout_maximum else maximum;
    }

    pub fn send(self: *Peer, channel_id: u8, packet: *Packet) !void {
        if (self.state != .connected and self.state != .connecting) return error.PeerNotConnected;
        if (channel_id >= self.channels.len) return error.InvalidChannel;
        if (packet.data.len > self.host.config.maximum_packet_size) return error.PacketTooLarge;

        const channel = &self.channels[channel_id];
        const fragments = try protocol.planFragments(
            self.host.allocator,
            packet,
            self.mtu,
            self.host.config.checksum_fn != null,
            self.host.config.protocol_flavor,
            self.nextOutgoingUnreliableStart(channel_id),
            self.nextOutgoingReliableStart(channel_id),
        );
        defer self.host.allocator.free(fragments);
        var retained_count: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < retained_count) : (i += 1) packet.release();
        }

        if (fragments.len == 0) {
            const command: constants.ProtocolCommand = if ((packet.flags & (constants.packet_flag_reliable | constants.packet_flag_unsequenced)) == constants.packet_flag_unsequenced)
                .send_unsequenced
            else if ((packet.flags & constants.packet_flag_reliable) != 0 or channel.outgoing_unreliable_sequence_number >= 0xFFFF)
                .send_reliable
            else
                .send_unreliable;

            packet.retain();
            retained_count += 1;
            try self.queued_outgoing.append(self.host.allocator, .{
                .command = command,
                .command_flags = if (command == .send_reliable) constants.command_flag_acknowledge else 0,
                .channel_id = channel_id,
                .packet = packet,
            });
        } else {
            for (fragments) |fragment| {
                packet.retain();
                retained_count += 1;
                try self.queued_outgoing.append(self.host.allocator, .{
                    .command = fragment.command,
                    .command_flags = if (fragment.command == .send_fragment) constants.command_flag_acknowledge else 0,
                    .channel_id = channel_id,
                    .packet = packet,
                    .start_sequence_number = @truncate(fragment.start_sequence_number),
                    .fragment_offset = fragment.offset,
                    .fragment_length = fragment.length,
                    .fragment_number = fragment.fragment_number,
                    .fragment_count = fragment.fragment_count,
                    .total_length = @intCast(packet.data.len),
                });
            }
        }
    }

    pub fn disconnect(self: *Peer, data: u32) !void {
        if (self.state == .disconnected) return;
        self.state = .disconnecting;
        self.event_data = data;
        try self.queued_outgoing.append(self.host.allocator, .{
            .command = .disconnect,
            .command_flags = constants.command_flag_unsequenced,
            .channel_id = 0xFF,
        });
    }

    fn nextOutgoingReliableStart(self: *Peer, channel_id: u8) u16 {
        const channel = &self.channels[channel_id];
        var next = channel.outgoing_reliable_sequence_number;
        for (self.queued_outgoing.items) |command| {
            if (command.channel_id != channel_id) continue;
            switch (command.command) {
                .send_reliable, .send_fragment => next +%= 1,
                else => {},
            }
        }
        return next;
    }

    fn nextOutgoingUnreliableStart(self: *Peer, channel_id: u8) u16 {
        const channel = &self.channels[channel_id];
        var next = channel.outgoing_unreliable_sequence_number;
        for (self.queued_outgoing.items) |command| {
            if (command.channel_id != channel_id) continue;
            switch (command.command) {
                .send_unreliable, .send_unreliable_fragment => next +%= 1,
                else => {},
            }
        }
        return next;
    }
};

pub const Event = struct {
    type: constants.EventType = .none,
    peer: ?*Peer = null,
    channel_id: u8 = 0,
    data: u32 = 0,
    packet: ?*Packet = null,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    config: config.HostConfig,
    mtu: u32,
    peers: []Peer,
    events: std.ArrayList(Event),
    transport: ?transport_mod.Transport = null,
    service_time: u32 = 0,
    random_seed: u32 = 0,
    bandwidth_throttle_epoch: u32 = 0,
    recalculate_bandwidth_limits: bool = false,
    total_sent_data: u32 = 0,
    total_sent_packets: u32 = 0,
    total_received_data: u32 = 0,
    total_received_packets: u32 = 0,
    connected_peers: usize = 0,
    bandwidth_limited_peers: usize = 0,

    pub fn init(allocator: std.mem.Allocator, host_config: config.HostConfig) !*Host {
        const clamped_channel_limit = protocol.clampChannelCount(host_config.channel_limit);
        const peer_limit = host_config.peer_limit;
        if (peer_limit > constants.protocol_maximum_peer_id) return error.TooManyPeers;

        const host = try allocator.create(Host);
        errdefer allocator.destroy(host);

        host.* = .{
            .allocator = allocator,
            .config = host_config,
            .mtu = protocol.clampMtu(host_config.mtu),
            .peers = try allocator.alloc(Peer, peer_limit),
            .events = .empty,
            .random_seed = seedFromTime(),
        };
        errdefer allocator.free(host.peers);
        errdefer host.events.deinit(allocator);

        host.config.channel_limit = clamped_channel_limit;

        for (host.peers, 0..) |*peer, index| {
            peer.* = Peer.init(host, @intCast(index));
            peer.window_size = protocol.defaultWindowSize(host.config.bandwidth.outgoing);
            peer.mtu = host.mtu;
        }

        return host;
    }

    pub fn withTransport(allocator: std.mem.Allocator, host_config: config.HostConfig, transport: transport_mod.Transport) !*Host {
        var host = try Host.init(allocator, host_config);
        host.transport = transport;
        return host;
    }

    pub fn deinit(self: *Host) void {
        for (self.peers) |*peer| {
            peer.deinit();
        }
        self.allocator.free(self.peers);

        for (self.events.items) |event| {
            if (event.packet) |packet| packet.release();
        }
        self.events.deinit(self.allocator);

        if (self.transport) |*transport| {
            transport.deinit();
        }
        if (self.config.compression.destroy) |destroy| {
            destroy(self.config.compression.context);
        }
        self.allocator.destroy(self);
    }

    pub fn connect(self: *Host, address: Address, channel_count: usize, data: u32) !*Peer {
        const clamped_channel_count = protocol.clampChannelCount(channel_count);
        for (self.peers) |*peer| {
            if (peer.state == .disconnected) {
                if (peer.channels.len > 0) self.allocator.free(peer.channels);
                peer.channels = try self.allocator.alloc(ChannelState, clamped_channel_count);
                for (peer.channels) |*channel| channel.* = .{};

                peer.state = .connecting;
                peer.address = address;
                peer.connect_id = nextRandom(self);
                peer.mtu = self.mtu;
                peer.window_size = protocol.defaultWindowSize(self.config.bandwidth.outgoing);
                peer.incoming_bandwidth = self.config.bandwidth.incoming;
                peer.outgoing_bandwidth = self.config.bandwidth.outgoing;
                peer.event_data = data;

                try peer.queued_outgoing.append(self.allocator, .{
                    .command = .connect,
                    .command_flags = constants.command_flag_acknowledge,
                    .channel_id = 0xFF,
                });

                return peer;
            }
        }
        return error.NoAvailablePeers;
    }

    pub fn broadcast(self: *Host, channel_id: u8, packet: *Packet) !void {
        packet.retain();
        defer packet.release();

        for (self.peers) |*peer| {
            if (peer.state != .connected) continue;
            try peer.send(channel_id, packet);
        }
    }

    pub fn flush(self: *Host) !void {
        var transport = self.transport orelse return;

        try self.bandwidthThrottle();

        for (self.peers) |*peer| {
            try self.flushPeerAcknowledgements(peer, &transport);
            try self.flushPeerResends(peer, &transport);
            try self.flushPeerQueuedCommands(peer, &transport);
        }

        self.transport = transport;
    }

    pub fn service(self: *Host, timeout_ms: u32) !?Event {
        self.service_time +%= @max(timeout_ms, 1);
        try self.queuePeerPings();
        try self.bandwidthThrottle();

        if (self.events.items.len > 0) {
            return self.events.orderedRemove(0);
        }

        var transport = self.transport orelse return null;
        var buffer: [@as(usize, constants.host_default_mtu)]u8 = undefined;
        const received = try transport.receive(&buffer);
        self.transport = transport;

        if (received) |datagram| {
            self.total_received_packets += 1;
            self.total_received_data += @intCast(datagram.len);
            if (try self.parseIncomingEvent(datagram.address, buffer[0..datagram.len])) |event| {
                return event;
            }
            if (self.events.items.len > 0) {
                return self.events.orderedRemove(0);
            }
        }

        try self.flush();

        if (self.events.items.len > 0) {
            return self.events.orderedRemove(0);
        }

        return null;
    }

    fn flushPeerAcknowledgements(self: *Host, peer: *Peer, transport: *transport_mod.Transport) !void {
        while (peer.acknowledgements.items.len > 0) {
            const acknowledgement = peer.acknowledgements.orderedRemove(0);
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(self.allocator);

            const header_len = wire.headerLen(self.config.protocol_flavor, constants.header_flag_sent_time, self.config.checksum_fn != null);
            try frame.resize(self.allocator, header_len);

            peer.outgoing_reliable_sequence_number +%= 1;
            _ = try wire.encodeHeader(frame.items, self.config.protocol_flavor, .{
                .peer_id = peer.outgoing_peer_id,
                .session_id = peer.outgoing_session_id,
                .flags = constants.header_flag_sent_time,
                .sent_time = @truncate(self.service_time),
            }, self.config.checksum_fn != null);

            try wire.appendCommandHeader(&frame, self.allocator, @intFromEnum(constants.ProtocolCommand.acknowledge), acknowledgement.channel_id, peer.outgoing_reliable_sequence_number);
            try wire.appendU16(&frame, self.allocator, acknowledgement.reliable_sequence_number);
            try wire.appendU16(&frame, self.allocator, acknowledgement.sent_time);

            try self.finalizeFrameChecksum(peer, &frame, header_len);
            _ = try transport.send(peer.address, frame.items);
            self.total_sent_data += @intCast(frame.items.len);
            self.total_sent_packets += 1;
        }
    }

    fn flushPeerResends(self: *Host, peer: *Peer, transport: *transport_mod.Transport) !void {
        for (peer.sent_reliable.items) |*command| {
            if (command.round_trip_timeout == 0 or self.service_time < command.round_trip_timeout) continue;
            if (peer.earliest_timeout == 0) peer.earliest_timeout = command.queue_time;
            if (peer.next_timeout == 0 or command.round_trip_timeout < peer.next_timeout) peer.next_timeout = command.round_trip_timeout;

            if (command.send_attempts >= peer.timeout_limit or
                (peer.earliest_timeout != 0 and self.service_time -% peer.earliest_timeout >= peer.timeout_maximum) or
                (command.queue_time != 0 and self.service_time -% command.queue_time >= peer.timeout_maximum))
            {
                peer.state = .zombie;
                try self.events.append(self.allocator, .{
                    .type = .disconnect,
                    .peer = peer,
                    .data = peer.event_data,
                });
                return;
            }

            command.send_attempts +%= 1;
            command.sent_time = self.service_time;
            command.round_trip_timeout = self.service_time +% @max(peer.timeout_minimum, peer.round_trip_time +% (4 * @max(peer.round_trip_time_variance, 1)));
            try self.sendCommandFrame(peer, command, transport);
        }
    }

    fn flushPeerQueuedCommands(self: *Host, peer: *Peer, transport: *transport_mod.Transport) !void {
        while (peer.queued_outgoing.items.len > 0) {
            var command = peer.queued_outgoing.orderedRemove(0);
            if (self.shouldDropForThrottle(peer, &command)) {
                if (command.packet) |packet| packet.release();
                continue;
            }
            self.assignSequenceNumbers(peer, &command);
            try self.sendCommandFrame(peer, &command, transport);
            peer.outgoing_data_total +%= payloadLengthForCommand(&command);

            if (self.commandNeedsTracking(&command)) {
                command.send_attempts = 1;
                command.sent_time = self.service_time;
                command.queue_time = if (command.queue_time == 0) self.service_time else command.queue_time;
                command.round_trip_timeout = self.service_time +% @max(peer.timeout_minimum, peer.round_trip_time +% (4 * @max(peer.round_trip_time_variance, 1)));
                if (peer.earliest_timeout == 0) peer.earliest_timeout = command.queue_time;
                if (peer.next_timeout == 0 or command.round_trip_timeout < peer.next_timeout) peer.next_timeout = command.round_trip_timeout;
                peer.reliable_data_in_transit +%= payloadLengthForCommand(&command);
                try peer.sent_reliable.append(self.allocator, command);
            } else if (command.packet) |packet| {
                packet.release();
            }
        }
    }

    fn commandNeedsTracking(self: *Host, command: *const protocol.OutgoingCommand) bool {
        _ = self;
        return switch (command.command) {
            .connect, .verify_connect, .ping, .send_reliable, .send_fragment, .bandwidth_limit, .throttle_configure => true,
            else => false,
        };
    }

    fn sendCommandFrame(self: *Host, peer: *Peer, command: *const protocol.OutgoingCommand, transport: *transport_mod.Transport) !void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);

        const header_len = wire.headerLen(self.config.protocol_flavor, constants.header_flag_sent_time, self.config.checksum_fn != null);
        try frame.resize(self.allocator, header_len);
        _ = try wire.encodeHeader(frame.items, self.config.protocol_flavor, .{
            .peer_id = peer.outgoing_peer_id,
            .session_id = peer.outgoing_session_id,
            .flags = constants.header_flag_sent_time,
            .sent_time = @truncate(self.service_time),
            .integrity = self.outgoingIntegrity(peer),
        }, self.config.checksum_fn != null);

        try wire.appendCommandHeader(&frame, self.allocator, @intFromEnum(command.command) | command.command_flags, command.channel_id, command.reliable_sequence_number);
        try self.appendCommandPayload(peer, command, &frame);
        try self.compressFrame(&frame, header_len, peer);
        try self.finalizeFrameChecksum(peer, &frame, header_len);

        _ = try transport.send(peer.address, frame.items);
        self.total_sent_data += @intCast(frame.items.len);
        self.total_sent_packets += 1;
        peer.last_send_time = self.service_time;
        peer.packets_sent +%= 1;
    }

    fn appendCommandPayload(self: *Host, peer: *Peer, command: *const protocol.OutgoingCommand, frame: *std.ArrayList(u8)) !void {
        switch (command.command) {
            .connect => {
                try wire.appendU16(frame, self.allocator, peer.incoming_peer_id);
                try frame.append(self.allocator, peer.incoming_session_id);
                try frame.append(self.allocator, peer.outgoing_session_id);
                try wire.appendU32(frame, self.allocator, peer.mtu);
                try wire.appendU32(frame, self.allocator, peer.window_size);
                try wire.appendU32(frame, self.allocator, @intCast(peer.channels.len));
                try wire.appendU32(frame, self.allocator, self.config.bandwidth.incoming);
                try wire.appendU32(frame, self.allocator, self.config.bandwidth.outgoing);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_interval);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_acceleration);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_deceleration);
                try wire.appendU32(frame, self.allocator, peer.connect_id);
                try wire.appendU32(frame, self.allocator, peer.event_data);
            },
            .verify_connect => {
                try wire.appendU16(frame, self.allocator, peer.incoming_peer_id);
                try frame.append(self.allocator, peer.incoming_session_id);
                try frame.append(self.allocator, peer.outgoing_session_id);
                try wire.appendU32(frame, self.allocator, peer.mtu);
                try wire.appendU32(frame, self.allocator, peer.window_size);
                try wire.appendU32(frame, self.allocator, @intCast(peer.channels.len));
                try wire.appendU32(frame, self.allocator, self.config.bandwidth.incoming);
                try wire.appendU32(frame, self.allocator, self.config.bandwidth.outgoing);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_interval);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_acceleration);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_deceleration);
                try wire.appendU32(frame, self.allocator, peer.connect_id);
            },
            .disconnect => try wire.appendU32(frame, self.allocator, peer.event_data),
            .ping, .acknowledge, .none => {},
            .bandwidth_limit => {
                try wire.appendU32(frame, self.allocator, peer.incoming_bandwidth);
                try wire.appendU32(frame, self.allocator, peer.outgoing_bandwidth);
            },
            .throttle_configure => {
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_interval);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_acceleration);
                try wire.appendU32(frame, self.allocator, peer.packet_throttle_deceleration);
            },
            .send_reliable => {
                const packet = command.packet orelse return error.MissingPacket;
                try wire.appendU16(frame, self.allocator, @intCast(packet.data.len));
                try frame.appendSlice(self.allocator, packet.data);
            },
            .send_unreliable => {
                const packet = command.packet orelse return error.MissingPacket;
                try wire.appendU16(frame, self.allocator, command.unreliable_sequence_number);
                try wire.appendU16(frame, self.allocator, @intCast(packet.data.len));
                try frame.appendSlice(self.allocator, packet.data);
            },
            .send_unsequenced => {
                const packet = command.packet orelse return error.MissingPacket;
                try wire.appendU16(frame, self.allocator, peer.outgoing_unsequenced_group);
                try wire.appendU16(frame, self.allocator, @intCast(packet.data.len));
                try frame.appendSlice(self.allocator, packet.data);
            },
            .send_fragment, .send_unreliable_fragment => {
                const packet = command.packet orelse return error.MissingPacket;
                const start = @as(usize, @intCast(command.fragment_offset));
                const end = start + @as(usize, command.fragment_length);
                try wire.appendU16(frame, self.allocator, command.start_sequence_number);
                try wire.appendU16(frame, self.allocator, command.fragment_length);
                try wire.appendU32(frame, self.allocator, command.fragment_count);
                try wire.appendU32(frame, self.allocator, command.fragment_number);
                try wire.appendU32(frame, self.allocator, command.total_length);
                try wire.appendU32(frame, self.allocator, command.fragment_offset);
                try frame.appendSlice(self.allocator, packet.data[start..end]);
            },
        }
    }

    fn compressFrame(self: *Host, frame: *std.ArrayList(u8), header_len: usize, peer: *Peer) !void {
        const compress = self.config.compression.compress orelse return;
        if (frame.items.len <= header_len) return;

        const original = frame.items[header_len..];
        var compressed = try self.allocator.alloc(u8, original.len);
        defer self.allocator.free(compressed);

        const compressed_len = try compress(
            self.config.compression.context,
            &[_]checksum.Buffer{.{ .data = original }},
            original.len,
            compressed,
        );
        if (compressed_len == 0 or compressed_len >= original.len) return;

        try frame.resize(self.allocator, header_len + compressed_len);
        @memcpy(frame.items[header_len .. header_len + compressed_len], compressed[0..compressed_len]);
        _ = try wire.encodeHeader(frame.items, self.config.protocol_flavor, .{
            .peer_id = peer.outgoing_peer_id,
            .session_id = peer.outgoing_session_id,
            .flags = constants.header_flag_sent_time | constants.header_flag_compressed,
            .sent_time = @truncate(self.service_time),
            .integrity = self.outgoingIntegrity(peer),
        }, self.config.checksum_fn != null);
    }

    fn finalizeFrameChecksum(self: *Host, peer: *Peer, frame: *std.ArrayList(u8), header_len: usize) !void {
        if (self.config.checksum_fn) |checksum_fn| {
            const seed: u32 = if (peer.outgoing_peer_id < constants.protocol_maximum_peer_id) peer.connect_id else 0;
            endian.writeU32(frame.items[header_len - 4 .. header_len], seed);
            const computed = checksum_fn(&[_]checksum.Buffer{
                .{ .data = frame.items },
            });
            endian.writeU32(frame.items[header_len - 4 .. header_len], computed);
        }
    }

    fn outgoingIntegrity(self: *Host, peer: *const Peer) ?[3]u16 {
        if (self.config.protocol_flavor != .growtopia_server) return null;
        const port = if (self.config.address) |address| address.port else 0;
        return .{ port, port ^ peer.nonce, peer.nonce };
    }

    fn parseIncomingEvent(self: *Host, source: Address, datagram: []const u8) !?Event {
        var working_datagram = datagram;
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.allocator);

        var header = try wire.parseHeader(working_datagram, self.config.protocol_flavor, self.config.checksum_fn != null);
        if (working_datagram.len < header.header_len + wire.protocol_command_header_size) return null;

        const command_offset = header.header_len;
        const command_byte = working_datagram[command_offset];
        const command: constants.ProtocolCommand = @enumFromInt(command_byte & 0x0F);
        const channel_id = working_datagram[command_offset + 1];
        const reliable_sequence_number = endian.readU16(working_datagram[command_offset + 2 .. command_offset + 4]);
        var peer = try self.findPeerForIncoming(header, source, command);
        if (!self.validateChecksum(peer, working_datagram, header.header_len)) return null;
        if (!self.validateGrowtopiaIntegrity(peer, header)) return null;

        if ((header.flags & constants.header_flag_compressed) != 0) {
            working_datagram = try self.decompressDatagram(working_datagram, header, &scratch);
            header = try wire.parseHeader(working_datagram, self.config.protocol_flavor, self.config.checksum_fn != null);
        }
        peer.last_receive_time = self.service_time;
        peer.incoming_data_total +%= @intCast(working_datagram.len);

        const event = switch (command) {
            .connect => blk: {
                try self.handleConnect(peer, source, working_datagram[command_offset..]);
                break :blk null;
            },
            .verify_connect => blk: {
                try self.handleVerifyConnect(peer, working_datagram[command_offset..]);
                break :blk Event{
                    .type = .connect,
                    .peer = peer,
                };
            },
            .acknowledge => try self.handleAcknowledge(peer, channel_id, working_datagram[command_offset..]),
            .ping => null,
            .disconnect => blk: {
                if (peer.state != .disconnected) {
                    if (self.connected_peers > 0) self.connected_peers -= 1;
                }
                peer.state = .disconnected;
                const data_offset = command_offset + wire.protocol_command_header_size;
                const data = if (working_datagram.len >= data_offset + 4) endian.readU32(working_datagram[data_offset .. data_offset + 4]) else 0;
                break :blk Event{
                    .type = .disconnect,
                    .peer = peer,
                    .data = data,
                };
            },
            .bandwidth_limit => blk: {
                try self.handleBandwidthLimit(peer, working_datagram[command_offset..]);
                break :blk null;
            },
            .throttle_configure => blk: {
                try self.handleThrottleConfigure(peer, working_datagram[command_offset..]);
                break :blk null;
            },
            .send_reliable, .send_unreliable, .send_unsequenced, .send_fragment, .send_unreliable_fragment => blk: {
                try self.handleIncomingPayload(peer, channel_id, command, reliable_sequence_number, working_datagram[command_offset..]);
                break :blk null;
            },
            else => null,
        };

        if ((command_byte & constants.command_flag_acknowledge) != 0 and header.sent_time != null and command != .acknowledge) {
            try peer.acknowledgements.append(self.allocator, .{
                .channel_id = channel_id,
                .reliable_sequence_number = reliable_sequence_number,
                .sent_time = header.sent_time.?,
                .command = command,
            });
        }

        return event;
    }

    fn decompressDatagram(self: *Host, datagram: []const u8, header: wire.HeaderView, storage: *std.ArrayList(u8)) ![]const u8 {
        const decompress = self.config.compression.decompress orelse return error.MissingDecompressor;
        try storage.resize(self.allocator, header.header_len + self.config.maximum_packet_size);
        @memcpy(storage.items[0..header.header_len], datagram[0..header.header_len]);

        const output_len = try decompress(
            self.config.compression.context,
            datagram[header.header_len..],
            storage.items[header.header_len..],
        );
        if (output_len == 0) return error.InvalidCompressedPacket;
        try storage.resize(self.allocator, header.header_len + output_len);
        return storage.items;
    }

    fn validateChecksum(self: *Host, peer: *Peer, datagram: []const u8, header_len: usize) bool {
        const checksum_fn = self.config.checksum_fn orelse return true;
        if (header_len < 4 or datagram.len < header_len) return false;

        const checksum_offset = header_len - 4;
        const desired = endian.readU32(datagram[checksum_offset .. checksum_offset + 4]);
        var seed_bytes: [4]u8 = undefined;
        const seed: u32 = if (peer.outgoing_peer_id < constants.protocol_maximum_peer_id) peer.connect_id else 0;
        endian.writeU32(&seed_bytes, seed);

        const computed = checksum_fn(&[_]checksum.Buffer{
            .{ .data = datagram[0..checksum_offset] },
            .{ .data = &seed_bytes },
            .{ .data = datagram[checksum_offset + 4 ..] },
        });
        return computed == desired;
    }

    fn validateGrowtopiaIntegrity(self: *Host, peer: *Peer, header: wire.HeaderView) bool {
        if (self.config.protocol_flavor != .growtopia_server) return true;
        if (peer.state == .connected) return true;
        const integrity = header.integrity orelse return true;
        const port = if (self.config.address) |address| address.port else 0;
        if (port == 0) return true;
        if (integrity[0] > port) return false;
        if (integrity[0] != (integrity[1] ^ port)) return false;
        if (port != (integrity[0] ^ integrity[1])) return false;
        if (integrity[2] == peer.nonce) return false;
        peer.nonce = integrity[2];
        return true;
    }

    fn handleConnect(self: *Host, peer: *Peer, source: Address, bytes: []const u8) !void {
        const connect_request = try protocol.parseConnect(bytes);
        if (connect_request.channel_count < constants.protocol_minimum_channel_count or connect_request.channel_count > constants.protocol_maximum_channel_count) {
            return error.InvalidChannelCount;
        }

        const channel_count = protocol.clampChannelCount(connect_request.channel_count);
        try self.resetPeerChannels(peer, channel_count);

        peer.state = .acknowledging_connect;
        peer.address = source;
        peer.connect_id = connect_request.connect_id;
        peer.outgoing_peer_id = connect_request.outgoing_peer_id;
        peer.incoming_bandwidth = connect_request.incoming_bandwidth;
        peer.outgoing_bandwidth = connect_request.outgoing_bandwidth;
        peer.packet_throttle_interval = connect_request.packet_throttle_interval;
        peer.packet_throttle_acceleration = connect_request.packet_throttle_acceleration;
        peer.packet_throttle_deceleration = connect_request.packet_throttle_deceleration;
        peer.event_data = connect_request.data;
        peer.mtu = @min(protocol.clampMtu(connect_request.mtu), self.mtu);
        peer.window_size = @min(protocol.defaultWindowSize(@min(self.config.bandwidth.outgoing, connect_request.incoming_bandwidth)), std.math.clamp(connect_request.window_size, constants.protocol_minimum_window_size, constants.protocol_maximum_window_size));

        peer.outgoing_session_id = rotateSession(peer.outgoing_session_id, connect_request.incoming_session_id, peer.incoming_session_id);
        peer.incoming_session_id = rotateSession(peer.incoming_session_id, connect_request.outgoing_session_id, peer.outgoing_session_id);

        try peer.queued_outgoing.append(self.allocator, .{
            .command = .verify_connect,
            .command_flags = constants.command_flag_acknowledge,
            .channel_id = 0xFF,
        });
    }

    fn handleVerifyConnect(self: *Host, peer: *Peer, bytes: []const u8) !void {
        const verify = try protocol.parseVerifyConnect(bytes);
        if (peer.state != .connecting) return error.UnexpectedVerifyConnect;
        if (verify.packet_throttle_interval != peer.packet_throttle_interval or
            verify.packet_throttle_acceleration != peer.packet_throttle_acceleration or
            verify.packet_throttle_deceleration != peer.packet_throttle_deceleration or
            verify.connect_id != peer.connect_id)
        {
            peer.state = .zombie;
            return error.InvalidVerifyConnect;
        }

        if (verify.channel_count < peer.channels.len) {
            peer.channels = peer.channels[0..verify.channel_count];
        }
        peer.outgoing_peer_id = verify.outgoing_peer_id;
        peer.incoming_session_id = verify.incoming_session_id;
        peer.outgoing_session_id = verify.outgoing_session_id;
        peer.mtu = @min(peer.mtu, protocol.clampMtu(verify.mtu));
        peer.window_size = @min(peer.window_size, std.math.clamp(verify.window_size, constants.protocol_minimum_window_size, constants.protocol_maximum_window_size));
        peer.incoming_bandwidth = verify.incoming_bandwidth;
        peer.outgoing_bandwidth = verify.outgoing_bandwidth;
        peer.state = .connected;
        self.connected_peers += 1;
    }

    fn handleAcknowledge(self: *Host, peer: *Peer, channel_id: u8, bytes: []const u8) !?Event {
        if (bytes.len < wire.protocol_acknowledge_size) return null;
        const acknowledged_sequence_number = endian.readU16(bytes[4..6]);
        const received_sent_time = endian.readU16(bytes[6..8]);

        var index: usize = 0;
        while (index < peer.sent_reliable.items.len) : (index += 1) {
            const command = peer.sent_reliable.items[index];
            if (command.channel_id != channel_id or command.reliable_sequence_number != acknowledged_sequence_number) continue;

            const acknowledged = peer.sent_reliable.orderedRemove(index);
            const round_trip: u32 = self.service_time -% received_sent_time;
            peer.last_round_trip_time = round_trip;
            if (peer.lowest_round_trip_time == 0 or round_trip < peer.lowest_round_trip_time) peer.lowest_round_trip_time = round_trip;
            peer.round_trip_time_variance = (peer.round_trip_time_variance * 3 + @max(round_trip, peer.round_trip_time) - @min(round_trip, peer.round_trip_time)) / 4;
            peer.round_trip_time = (peer.round_trip_time * 7 + round_trip) / 8;
            peer.last_round_trip_time_variance = peer.round_trip_time_variance;
            if (peer.round_trip_time_variance > peer.highest_round_trip_time_variance) peer.highest_round_trip_time_variance = peer.round_trip_time_variance;
            switch (protocol.throttle(
                peer.packet_throttle,
                peer.packet_throttle_limit,
                peer.packet_throttle_acceleration,
                peer.packet_throttle_deceleration,
                peer.last_round_trip_time,
                peer.last_round_trip_time_variance,
                round_trip,
            )) {
                1 => peer.packet_throttle = @min(peer.packet_throttle + peer.packet_throttle_acceleration, peer.packet_throttle_limit),
                -1 => peer.packet_throttle = if (peer.packet_throttle > peer.packet_throttle_deceleration) peer.packet_throttle - peer.packet_throttle_deceleration else 0,
                else => {},
            }
            if (peer.reliable_data_in_transit >= payloadLengthForCommand(&acknowledged)) {
                peer.reliable_data_in_transit -= payloadLengthForCommand(&acknowledged);
            } else {
                peer.reliable_data_in_transit = 0;
            }
            peer.earliest_timeout = if (peer.sent_reliable.items.len > 0) peer.sent_reliable.items[0].queue_time else 0;
            peer.next_timeout = if (peer.sent_reliable.items.len > 0) peer.sent_reliable.items[0].round_trip_timeout else 0;

            if (acknowledged.packet) |packet| packet.release();
            if (acknowledged.command == .verify_connect and peer.state == .acknowledging_connect) {
                peer.state = .connected;
                self.connected_peers += 1;
                return Event{
                    .type = .connect,
                    .peer = peer,
                };
            }
            if (acknowledged.command == .disconnect and peer.state == .disconnecting) {
                peer.state = .disconnected;
                if (self.connected_peers > 0) self.connected_peers -= 1;
                return Event{
                    .type = .disconnect,
                    .peer = peer,
                    .data = peer.event_data,
                };
            }
            return null;
        }
        return null;
    }

    fn handleBandwidthLimit(self: *Host, peer: *Peer, bytes: []const u8) !void {
        if (bytes.len < wire.protocol_bandwidth_limit_size) return error.ShortBandwidthLimit;

        peer.incoming_bandwidth = endian.readU32(bytes[4..8]);
        peer.outgoing_bandwidth = endian.readU32(bytes[8..12]);

        if (peer.incoming_bandwidth == 0 and self.config.bandwidth.outgoing == 0) {
            peer.window_size = constants.protocol_maximum_window_size;
        } else if (peer.incoming_bandwidth == 0 or self.config.bandwidth.outgoing == 0) {
            peer.window_size = protocol.defaultWindowSize(@max(peer.incoming_bandwidth, self.config.bandwidth.outgoing));
        } else {
            peer.window_size = protocol.defaultWindowSize(@min(peer.incoming_bandwidth, self.config.bandwidth.outgoing));
        }
    }

    fn handleThrottleConfigure(self: *Host, peer: *Peer, bytes: []const u8) !void {
        _ = self;
        if (bytes.len < wire.protocol_throttle_configure_size) return error.ShortThrottleConfigure;
        peer.packet_throttle_interval = endian.readU32(bytes[4..8]);
        peer.packet_throttle_acceleration = endian.readU32(bytes[8..12]);
        peer.packet_throttle_deceleration = endian.readU32(bytes[12..16]);
    }

    fn handleIncomingPayload(self: *Host, peer: *Peer, channel_id: u8, command: constants.ProtocolCommand, reliable_sequence_number: u16, bytes: []const u8) !void {
        if (channel_id >= peer.channels.len) return;
        if (peer.state != .connected and peer.state != .disconnect_later and peer.state != .acknowledging_connect and peer.state != .connection_pending) return;

        switch (command) {
            .send_fragment, .send_unreliable_fragment => try self.handleIncomingFragment(peer, channel_id, command, reliable_sequence_number, bytes),
            else => {
                const packet = try self.packetFromIncoming(command, bytes);
                errdefer packet.release();
                try self.queueIncomingCommand(peer, .{
                    .channel_id = channel_id,
                    .reliable_sequence_number = reliable_sequence_number,
                    .unreliable_sequence_number = switch (command) {
                        .send_unreliable => endian.readU16(bytes[4..6]),
                        .send_unsequenced => endian.readU16(bytes[4..6]),
                        else => 0,
                    },
                    .command = command,
                    .flags = switch (command) {
                        .send_reliable => constants.packet_flag_reliable,
                        .send_unsequenced => constants.packet_flag_unsequenced,
                        else => 0,
                    },
                    .packet = packet,
                });
            },
        }
    }

    fn handleIncomingFragment(self: *Host, peer: *Peer, channel_id: u8, command: constants.ProtocolCommand, reliable_sequence_number: u16, bytes: []const u8) !void {
        if (bytes.len < wire.protocol_send_fragment_size) return error.ShortPacket;

        const start_sequence_number = endian.readU16(bytes[4..6]);
        const fragment_length: usize = endian.readU16(bytes[6..8]);
        const fragment_count = endian.readU32(bytes[8..12]);
        const fragment_number = endian.readU32(bytes[12..16]);
        const total_length = endian.readU32(bytes[16..20]);
        const fragment_offset = endian.readU32(bytes[20..24]);
        if (fragment_count == 0 or fragment_count > constants.protocol_maximum_fragment_count) return;
        if (fragment_number >= fragment_count) return;
        if (total_length == 0 or total_length > self.config.maximum_packet_size) return;
        if (fragment_offset >= total_length) return;
        if (fragment_length > total_length - fragment_offset) return;
        if (bytes.len < wire.protocol_send_fragment_size + fragment_length) return error.ShortPacket;

        const payload = bytes[wire.protocol_send_fragment_size .. wire.protocol_send_fragment_size + fragment_length];
        const channel = &peer.channels[channel_id];
        var assembly_index: ?usize = null;

        for (channel.fragment_assemblies.items, 0..) |*candidate, index| {
            if (candidate.command != command) continue;
            if (candidate.start_sequence_number != start_sequence_number) continue;
            if (command == .send_unreliable_fragment and candidate.reliable_sequence_number != reliable_sequence_number) continue;
            if (candidate.fragment_count != fragment_count or candidate.total_length != total_length) return;
            assembly_index = index;
            break;
        }

        if (assembly_index == null) {
            var assembly = try protocol.FragmentAssembly.init(self.allocator, channel_id, start_sequence_number, command, fragment_count, total_length);
            assembly.reliable_sequence_number = if (command == .send_fragment) start_sequence_number else reliable_sequence_number;
            assembly.unreliable_sequence_number = if (command == .send_unreliable_fragment) start_sequence_number else 0;
            try channel.fragment_assemblies.append(self.allocator, assembly);
            assembly_index = channel.fragment_assemblies.items.len - 1;
        }

        const assembly = &channel.fragment_assemblies.items[assembly_index.?];
        _ = assembly.insertFragment(fragment_number, fragment_offset, payload);
        if (!assembly.isComplete()) return;

        const complete = channel.fragment_assemblies.orderedRemove(assembly_index.?);
        defer {
            var temp = complete;
            temp.deinit();
        }

        const packet = complete.packet;
        packet.retain();
        errdefer packet.release();
        try self.queueIncomingCommand(peer, .{
            .channel_id = channel_id,
            .reliable_sequence_number = complete.reliable_sequence_number,
            .unreliable_sequence_number = complete.unreliable_sequence_number,
            .command = command,
            .flags = if (command == .send_fragment) constants.packet_flag_reliable else constants.packet_flag_unreliable_fragment,
            .fragment_count = if (command == .send_fragment) fragment_count else 0,
            .packet = packet,
        });
    }

    fn packetFromIncoming(self: *Host, command: constants.ProtocolCommand, bytes: []const u8) !*Packet {
        const data_offset: usize = switch (command) {
            .send_reliable => wire.protocol_send_reliable_size,
            .send_unreliable => wire.protocol_send_unreliable_size,
            .send_unsequenced => wire.protocol_send_unsequenced_size,
            else => return error.UnsupportedIncomingCommand,
        };
        if (bytes.len < data_offset) return error.ShortPacket;

        const data_len: usize = switch (command) {
            .send_reliable => endian.readU16(bytes[4..6]),
            .send_unreliable => endian.readU16(bytes[6..8]),
            .send_unsequenced => endian.readU16(bytes[6..8]),
            else => unreachable,
        };

        if (bytes.len < data_offset + data_len) return error.ShortPacket;
        const packet = try Packet.create(self.allocator, bytes[data_offset .. data_offset + data_len], data_len, 0);
        packet.retain();
        return packet;
    }

    fn queueIncomingCommand(self: *Host, peer: *Peer, incoming: protocol.IncomingCommand) !void {
        if (incoming.channel_id >= peer.channels.len) {
            incoming.packet.release();
            return;
        }
        if (peer.total_waiting_data + incoming.packet.data.len > self.config.maximum_waiting_data) {
            incoming.packet.release();
            return;
        }

        var command = incoming;
        const channel = &peer.channels[command.channel_id];
        const inserted = switch (command.command) {
            .send_reliable, .send_fragment => try self.insertIncomingReliable(channel, command),
            .send_unreliable, .send_unreliable_fragment, .send_unsequenced => try self.insertIncomingUnreliable(channel, command),
            else => false,
        };
        if (!inserted) {
            command.packet.release();
            return;
        }
        peer.total_waiting_data += command.packet.data.len;

        try self.dispatchIncomingReliableCommands(peer, command.channel_id);
        try self.dispatchIncomingUnreliableCommands(peer, command.channel_id);
    }

    fn insertIncomingReliable(self: *Host, channel: *ChannelState, command: protocol.IncomingCommand) !bool {
        if (!self.reliableSequenceInWindow(channel, command.reliable_sequence_number)) return false;
        if (command.reliable_sequence_number == channel.incoming_reliable_sequence_number) return false;

        var index: usize = 0;
        while (index < channel.pending_reliable.items.len) : (index += 1) {
            const current = channel.pending_reliable.items[index];
            if (current.reliable_sequence_number == command.reliable_sequence_number) return false;
            if (self.sequenceDistance(channel.incoming_reliable_sequence_number, command.reliable_sequence_number) <
                self.sequenceDistance(channel.incoming_reliable_sequence_number, current.reliable_sequence_number))
            {
                break;
            }
        }

        try channel.pending_reliable.append(self.allocator, command);
        var cursor = channel.pending_reliable.items.len - 1;
        while (cursor > index) : (cursor -= 1) {
            std.mem.swap(protocol.IncomingCommand, &channel.pending_reliable.items[cursor], &channel.pending_reliable.items[cursor - 1]);
        }
        return true;
    }

    fn insertIncomingUnreliable(self: *Host, channel: *ChannelState, command: protocol.IncomingCommand) !bool {
        if (command.command != .send_unsequenced and !self.reliableSequenceInWindow(channel, command.reliable_sequence_number)) return false;
        if (command.command != .send_unsequenced and
            command.reliable_sequence_number == channel.incoming_reliable_sequence_number and
            command.unreliable_sequence_number <= channel.incoming_unreliable_sequence_number)
        {
            return false;
        }

        var index: usize = 0;
        while (index < channel.pending_unreliable.items.len) : (index += 1) {
            const current = channel.pending_unreliable.items[index];
            if (current.command != .send_unsequenced and
                current.reliable_sequence_number == command.reliable_sequence_number and
                current.unreliable_sequence_number == command.unreliable_sequence_number)
            {
                return false;
            }

            if (command.command == .send_unsequenced) continue;

            const current_distance = self.sequenceDistance(channel.incoming_reliable_sequence_number, current.reliable_sequence_number);
            const command_distance = self.sequenceDistance(channel.incoming_reliable_sequence_number, command.reliable_sequence_number);
            if (command_distance < current_distance or
                (command_distance == current_distance and command.unreliable_sequence_number < current.unreliable_sequence_number))
            {
                break;
            }
        }

        try channel.pending_unreliable.append(self.allocator, command);
        var cursor = channel.pending_unreliable.items.len - 1;
        while (cursor > index) : (cursor -= 1) {
            std.mem.swap(protocol.IncomingCommand, &channel.pending_unreliable.items[cursor], &channel.pending_unreliable.items[cursor - 1]);
        }
        return true;
    }

    fn dispatchIncomingReliableCommands(self: *Host, peer: *Peer, channel_id: u8) !void {
        const channel = &peer.channels[channel_id];
        while (channel.pending_reliable.items.len > 0) {
            const next_sequence = channel.incoming_reliable_sequence_number +% 1;
            if (channel.pending_reliable.items[0].reliable_sequence_number != next_sequence) break;

            const incoming = channel.pending_reliable.orderedRemove(0);
            channel.incoming_reliable_sequence_number = incoming.reliable_sequence_number;
            if (incoming.fragment_count > 0) {
                channel.incoming_reliable_sequence_number +%= @truncate(incoming.fragment_count - 1);
            }
            channel.incoming_unreliable_sequence_number = 0;
            try self.dispatchIncomingCommand(peer, incoming);
        }
    }

    fn dispatchIncomingUnreliableCommands(self: *Host, peer: *Peer, channel_id: u8) !void {
        const channel = &peer.channels[channel_id];
        while (channel.pending_unreliable.items.len > 0) {
            const current = channel.pending_unreliable.items[0];

            if (current.command == .send_unsequenced) {
                const incoming = channel.pending_unreliable.orderedRemove(0);
                try self.dispatchIncomingCommand(peer, incoming);
                continue;
            }

            if (current.reliable_sequence_number < channel.incoming_reliable_sequence_number) {
                var stale = channel.pending_unreliable.orderedRemove(0);
                stale.packet.release();
                continue;
            }
            if (current.reliable_sequence_number != channel.incoming_reliable_sequence_number) break;
            if (current.unreliable_sequence_number <= channel.incoming_unreliable_sequence_number) {
                var duplicate = channel.pending_unreliable.orderedRemove(0);
                duplicate.packet.release();
                continue;
            }

            const incoming = channel.pending_unreliable.orderedRemove(0);
            channel.incoming_unreliable_sequence_number = incoming.unreliable_sequence_number;
            try self.dispatchIncomingCommand(peer, incoming);
        }
    }

    fn dispatchIncomingCommand(self: *Host, peer: *Peer, incoming: protocol.IncomingCommand) !void {
        if (peer.total_waiting_data >= incoming.packet.data.len) {
            peer.total_waiting_data -= incoming.packet.data.len;
        } else {
            peer.total_waiting_data = 0;
        }

        try self.events.append(self.allocator, .{
            .type = .receive,
            .peer = peer,
            .channel_id = incoming.channel_id,
            .packet = incoming.packet,
        });
    }

    fn payloadLengthForCommand(command: *const protocol.OutgoingCommand) u32 {
        return switch (command.command) {
            .send_reliable, .send_unreliable, .send_unsequenced, .send_fragment, .send_unreliable_fragment => if (command.packet) |packet| @intCast(@min(packet.data.len, command.fragment_length)) else 0,
            else => 0,
        };
    }

    fn reliableSequenceInWindow(self: *Host, channel: *const ChannelState, reliable_sequence_number: u16) bool {
        _ = self;
        var reliable_window: u16 = reliable_sequence_number / constants.peer_reliable_window_size;
        const current_window: u16 = channel.incoming_reliable_sequence_number / constants.peer_reliable_window_size;
        if (reliable_sequence_number < channel.incoming_reliable_sequence_number) {
            reliable_window += constants.peer_reliable_windows;
        }
        return reliable_window >= current_window and reliable_window < current_window + constants.peer_free_reliable_windows - 1;
    }

    fn sequenceDistance(self: *Host, base: u16, sequence_number: u16) u16 {
        _ = self;
        return sequence_number -% base;
    }

    fn findPeerByAddress(self: *Host, address: Address) ?*Peer {
        for (self.peers) |*peer| {
            if (peer.state != .disconnected and peer.address.eql(address)) return peer;
        }
        return null;
    }

    fn allocatePeerForIncoming(self: *Host, address: Address) !*Peer {
        for (self.peers) |*peer| {
            if (peer.state == .disconnected) {
                peer.address = address;
                peer.state = .connection_pending;
                return peer;
            }
        }
        return error.NoAvailablePeers;
    }

    fn findPeerForIncoming(self: *Host, header: wire.HeaderView, address: Address, command: constants.ProtocolCommand) !*Peer {
        if (command != .connect and header.peer_id < self.peers.len) {
            const peer = &self.peers[header.peer_id];
            if (peer.state != .disconnected and peer.address.eql(address)) return peer;
        }
        return self.findPeerByAddress(address) orelse try self.allocatePeerForIncoming(address);
    }

    fn resetPeerChannels(self: *Host, peer: *Peer, channel_count: usize) !void {
        if (peer.channels.len > 0) {
            for (peer.channels) |*channel| {
                for (channel.pending_reliable.items) |incoming| incoming.packet.release();
                for (channel.pending_unreliable.items) |incoming| incoming.packet.release();
                for (channel.fragment_assemblies.items) |*assembly| assembly.deinit();
                channel.pending_reliable.deinit(self.allocator);
                channel.pending_unreliable.deinit(self.allocator);
                channel.fragment_assemblies.deinit(self.allocator);
            }
            self.allocator.free(peer.channels);
        }
        peer.channels = try self.allocator.alloc(ChannelState, channel_count);
        for (peer.channels) |*channel| channel.* = .{};
        peer.outgoing_reliable_sequence_number = 0;
    }

    fn assignSequenceNumbers(self: *Host, peer: *Peer, command: *protocol.OutgoingCommand) void {
        _ = self;
        if (command.sequence_assigned) return;
        command.sequence_assigned = true;

        if (command.channel_id == 0xFF) {
            peer.outgoing_reliable_sequence_number +%= 1;
            command.reliable_sequence_number = peer.outgoing_reliable_sequence_number;
            return;
        }

        const channel = &peer.channels[command.channel_id];
        switch (command.command) {
            .send_reliable, .send_fragment => {
                channel.outgoing_reliable_sequence_number +%= 1;
                command.reliable_sequence_number = channel.outgoing_reliable_sequence_number;
            },
            .send_unreliable, .send_unreliable_fragment => {
                channel.outgoing_unreliable_sequence_number +%= 1;
                command.unreliable_sequence_number = channel.outgoing_unreliable_sequence_number;
                command.reliable_sequence_number = channel.outgoing_reliable_sequence_number;
            },
            .send_unsequenced => {
                command.reliable_sequence_number = channel.outgoing_reliable_sequence_number;
            },
            else => {},
        }
    }

    fn shouldDropForThrottle(self: *Host, peer: *Peer, command: *const protocol.OutgoingCommand) bool {
        return switch (command.command) {
            .send_unreliable, .send_unreliable_fragment => blk: {
                if (peer.packet_throttle >= peer.packet_throttle_limit and peer.packet_throttle_limit >= constants.peer_packet_throttle_scale) break :blk false;
                if (peer.packet_throttle == 0) break :blk true;
                break :blk (self.nextRandom() % constants.peer_packet_throttle_scale) >= peer.packet_throttle;
            },
            else => false,
        };
    }

    fn bandwidthThrottle(self: *Host) !void {
        const elapsed_time = self.service_time -% self.bandwidth_throttle_epoch;
        if (elapsed_time < constants.host_bandwidth_throttle_interval) return;
        self.bandwidth_throttle_epoch = self.service_time;
        if (self.connected_peers == 0) return;

        var peers_remaining: u32 = @intCast(self.connected_peers);
        var data_total: u32 = 0;
        var bandwidth: u32 = std.math.maxInt(u32);
        var throttle: u32 = constants.peer_packet_throttle_scale;
        var needs_adjustment = self.bandwidth_limited_peers > 0;

        if (self.config.bandwidth.outgoing != 0) {
            bandwidth = @intCast((@as(u64, self.config.bandwidth.outgoing) * elapsed_time) / 1000);
            for (self.peers) |*peer| {
                if (peer.state != .connected and peer.state != .disconnect_later) continue;
                data_total +%= peer.outgoing_data_total;
            }
        }

        while (peers_remaining > 0 and needs_adjustment) {
            needs_adjustment = false;
            throttle = if (data_total <= bandwidth or data_total == 0)
                constants.peer_packet_throttle_scale
            else
                @intCast((@as(u64, bandwidth) * constants.peer_packet_throttle_scale) / data_total);

            for (self.peers) |*peer| {
                if ((peer.state != .connected and peer.state != .disconnect_later) or
                    peer.incoming_bandwidth == 0 or
                    peer.outgoing_bandwidth_throttle_epoch == self.service_time)
                {
                    continue;
                }

                const peer_bandwidth: u32 = @intCast((@as(u64, peer.incoming_bandwidth) * elapsed_time) / 1000);
                if ((@as(u64, throttle) * peer.outgoing_data_total) / constants.peer_packet_throttle_scale <= peer_bandwidth) continue;

                peer.packet_throttle_limit = @max(1, @as(u32, @intCast((@as(u64, peer_bandwidth) * constants.peer_packet_throttle_scale) / @max(peer.outgoing_data_total, 1))));
                if (peer.packet_throttle > peer.packet_throttle_limit) peer.packet_throttle = peer.packet_throttle_limit;
                peer.outgoing_bandwidth_throttle_epoch = self.service_time;
                peer.incoming_data_total = 0;
                peer.outgoing_data_total = 0;
                needs_adjustment = true;
                peers_remaining -= 1;
                bandwidth -|= peer_bandwidth;
                data_total -|= peer_bandwidth;
            }
        }

        if (peers_remaining > 0) {
            throttle = if (data_total <= bandwidth or data_total == 0)
                constants.peer_packet_throttle_scale
            else
                @intCast((@as(u64, bandwidth) * constants.peer_packet_throttle_scale) / data_total);

            for (self.peers) |*peer| {
                if ((peer.state != .connected and peer.state != .disconnect_later) or
                    peer.outgoing_bandwidth_throttle_epoch == self.service_time)
                {
                    continue;
                }
                peer.packet_throttle_limit = throttle;
                if (peer.packet_throttle > peer.packet_throttle_limit) peer.packet_throttle = peer.packet_throttle_limit;
                peer.incoming_data_total = 0;
                peer.outgoing_data_total = 0;
            }
        }

        if (!self.recalculate_bandwidth_limits) return;
        self.recalculate_bandwidth_limits = false;

        peers_remaining = @intCast(self.connected_peers);
        bandwidth = self.config.bandwidth.incoming;
        needs_adjustment = true;
        var bandwidth_limit: u32 = 0;

        if (bandwidth != 0) while (peers_remaining > 0 and needs_adjustment) {
            needs_adjustment = false;
            bandwidth_limit = bandwidth / peers_remaining;
            for (self.peers) |*peer| {
                if ((peer.state != .connected and peer.state != .disconnect_later) or
                    peer.incoming_bandwidth_throttle_epoch == self.service_time)
                {
                    continue;
                }
                if (peer.outgoing_bandwidth > 0 and peer.outgoing_bandwidth >= bandwidth_limit) continue;

                peer.incoming_bandwidth_throttle_epoch = self.service_time;
                needs_adjustment = true;
                peers_remaining -= 1;
                bandwidth -|= peer.outgoing_bandwidth;
            }
        };

        for (self.peers) |*peer| {
            if (peer.state != .connected and peer.state != .disconnect_later) continue;
            peer.outgoing_bandwidth = self.config.bandwidth.outgoing;
            peer.incoming_bandwidth = if (peer.incoming_bandwidth_throttle_epoch == self.service_time) peer.outgoing_bandwidth else bandwidth_limit;
            try peer.queued_outgoing.append(self.allocator, .{
                .command = .bandwidth_limit,
                .command_flags = constants.command_flag_acknowledge,
                .channel_id = 0xFF,
            });
        }
    }

    fn acceptIncomingSequence(self: *Host, peer: *Peer, channel_id: u8, command: constants.ProtocolCommand, reliable_sequence_number: u16, bytes: []const u8) bool {
        _ = self;
        if (channel_id >= peer.channels.len) return false;
        const channel = &peer.channels[channel_id];
        return switch (command) {
            .send_reliable, .send_fragment => blk: {
                if (reliable_sequence_number <= channel.incoming_reliable_sequence_number) break :blk false;
                channel.incoming_reliable_sequence_number = reliable_sequence_number;
                break :blk true;
            },
            .send_unreliable, .send_unreliable_fragment => blk: {
                const unreliable_sequence = endian.readU16(bytes[4..6]);
                if (reliable_sequence_number < channel.incoming_reliable_sequence_number or unreliable_sequence <= channel.incoming_unreliable_sequence_number) break :blk false;
                channel.incoming_reliable_sequence_number = @max(channel.incoming_reliable_sequence_number, reliable_sequence_number);
                channel.incoming_unreliable_sequence_number = unreliable_sequence;
                break :blk true;
            },
            .send_unsequenced => true,
            else => true,
        };
    }

    fn rotateSession(current: u8, requested: u8, other: u8) u8 {
        var session = if (requested == 0xFF) current else requested;
        session = (session +% 1) & 0x03;
        if (session == other) session = (session +% 1) & 0x03;
        return session;
    }

    fn seedFromTime() u32 {
        return @intCast(@as(u64, @intCast(std.time.timestamp())));
    }

    fn nextRandom(self: *Host) u32 {
        var n = self.random_seed +% 0x6D2B_79F5;
        n = (n ^ (n >> 15)) *% (n | 1);
        n ^= n +% ((n ^ (n >> 7)) *% (n | 61));
        self.random_seed = n ^ (n >> 14);
        return self.random_seed;
    }

    fn queuePeerPings(self: *Host) !void {
        for (self.peers) |*peer| {
            if (peer.state != .connected and peer.state != .disconnect_later) continue;
            if (peer.sent_reliable.items.len > 0 and peer.earliest_timeout != 0 and self.service_time -% peer.earliest_timeout >= peer.timeout_maximum) {
                peer.state = .zombie;
                try self.events.append(self.allocator, .{
                    .type = .disconnect,
                    .peer = peer,
                    .data = peer.event_data,
                });
                continue;
            }
            if (self.service_time -% peer.last_send_time < peer.ping_interval) continue;
            try peer.queued_outgoing.append(self.allocator, .{
                .command = .ping,
                .command_flags = constants.command_flag_acknowledge,
                .channel_id = 0xFF,
            });
            peer.last_send_time = self.service_time;
        }
    }
};

test "host connect queues connect command" {
    var host = try Host.init(std.testing.allocator, .{
        .peer_limit = 2,
        .channel_limit = 2,
    });
    defer host.deinit();

    const peer = try host.connect(Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091), 2, 0);
    try std.testing.expectEqual(constants.PeerState.connecting, peer.state);
    try std.testing.expectEqual(@as(usize, 1), peer.queued_outgoing.items.len);
    try std.testing.expectEqual(constants.ProtocolCommand.connect, peer.queued_outgoing.items[0].command);
}

test "peer send queues reliable packet" {
    var host = try Host.init(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
    });
    defer host.deinit();

    const peer = try host.connect(Address.fromIpv4Octets(.{ 10, 0, 0, 1 }, 17091), 2, 0);
    peer.state = .connected;

    var packet = try Packet.create(std.testing.allocator, "hello", 5, constants.packet_flag_reliable);
    packet.retain();
    defer packet.release();

    try peer.send(0, packet);
    try std.testing.expectEqual(@as(usize, 2), peer.queued_outgoing.items.len);
}

test "hosts exchange connect event over mock transport" {
    var client_mock = try transport_mod.MockTransport.init(std.testing.allocator);
    var server_mock = try transport_mod.MockTransport.init(std.testing.allocator);

    var client = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
    }, client_mock.transport());
    defer client.deinit();

    var server = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 4,
        .channel_limit = 2,
    }, server_mock.transport());
    defer server.deinit();

    _ = try client.connect(Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091), 2, 0);
    try client.flush();

    const sent = client_mock.popSent().?;
    defer std.testing.allocator.free(sent.bytes);

    try server_mock.inject(Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 40000), sent.bytes);

    try std.testing.expectEqual(@as(?Event, null), try server.service(0));
    try std.testing.expectEqual(constants.PeerState.acknowledging_connect, server.peers[0].state);

    try server.flush();
    while (server_mock.popSent()) |packet| {
        defer std.testing.allocator.free(packet.bytes);
        try client_mock.inject(Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091), packet.bytes);
    }

    var client_event: ?Event = null;
    var attempts: usize = 0;
    while (client_event == null and attempts < 4) : (attempts += 1) {
        client_event = try client.service(0);
    }
    const resolved = client_event.?;
    try std.testing.expectEqual(constants.EventType.connect, resolved.type);
    try std.testing.expect(resolved.peer != null);
    try std.testing.expectEqual(constants.PeerState.connected, resolved.peer.?.state);

    try client.flush();
    while (client_mock.popSent()) |packet| {
        defer std.testing.allocator.free(packet.bytes);
        try server_mock.inject(Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 40000), packet.bytes);
    }

    const server_event = (try server.service(0)).?;
    try std.testing.expectEqual(constants.EventType.connect, server_event.type);
    try std.testing.expect(server_event.peer != null);
    try std.testing.expectEqual(constants.PeerState.connected, server_event.peer.?.state);
}

fn setupConnectedPeers(
    sender: *Host,
    receiver: *Host,
    sender_address: Address,
    receiver_address: Address,
) !struct { sender: *Peer, receiver: *Peer } {
    const sender_peer = &sender.peers[0];
    try sender.resetPeerChannels(sender_peer, 2);
    sender_peer.address = receiver_address;
    sender_peer.state = .connected;
    sender_peer.outgoing_peer_id = 0;
    sender_peer.outgoing_session_id = 0;
    sender_peer.incoming_session_id = 0;
    sender.connected_peers = 1;

    const receiver_peer = &receiver.peers[0];
    try receiver.resetPeerChannels(receiver_peer, 2);
    receiver_peer.address = sender_address;
    receiver_peer.state = .connected;
    receiver_peer.outgoing_peer_id = 0;
    receiver_peer.outgoing_session_id = 0;
    receiver_peer.incoming_session_id = 0;
    receiver.connected_peers = 1;

    return .{
        .sender = sender_peer,
        .receiver = receiver_peer,
    };
}

test "reliable packets dispatch in sequence order" {
    var sender_mock = try transport_mod.MockTransport.init(std.testing.allocator);
    var receiver_mock = try transport_mod.MockTransport.init(std.testing.allocator);

    var sender = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
    }, sender_mock.transport());
    defer sender.deinit();

    var receiver = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
    }, receiver_mock.transport());
    defer receiver.deinit();

    const sender_address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 40000);
    const receiver_address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091);
    const peers = try setupConnectedPeers(sender, receiver, sender_address, receiver_address);

    var first = try Packet.create(std.testing.allocator, "one", 3, constants.packet_flag_reliable);
    defer first.release();
    first.retain();
    var second = try Packet.create(std.testing.allocator, "two", 3, constants.packet_flag_reliable);
    defer second.release();
    second.retain();

    try peers.sender.send(0, first);
    try peers.sender.send(0, second);
    try sender.flush();

    const sent_one = sender_mock.popSent().?;
    defer std.testing.allocator.free(sent_one.bytes);
    const sent_two = sender_mock.popSent().?;
    defer std.testing.allocator.free(sent_two.bytes);

    try receiver_mock.inject(sender_address, sent_two.bytes);
    try receiver_mock.inject(sender_address, sent_one.bytes);

    try std.testing.expectEqual(@as(?Event, null), try receiver.service(0));

    const event_one = (try receiver.service(0)).?;
    defer event_one.packet.?.release();
    try std.testing.expectEqual(constants.EventType.receive, event_one.type);
    try std.testing.expectEqualStrings("one", event_one.packet.?.data);

    const event_two = (try receiver.service(0)).?;
    defer event_two.packet.?.release();
    try std.testing.expectEqual(constants.EventType.receive, event_two.type);
    try std.testing.expectEqualStrings("two", event_two.packet.?.data);
}

test "fragmented reliable packet reassembles before dispatch" {
    var sender_mock = try transport_mod.MockTransport.init(std.testing.allocator);
    var receiver_mock = try transport_mod.MockTransport.init(std.testing.allocator);

    var sender = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
        .mtu = constants.protocol_minimum_mtu,
    }, sender_mock.transport());
    defer sender.deinit();

    var receiver = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
        .mtu = constants.protocol_minimum_mtu,
    }, receiver_mock.transport());
    defer receiver.deinit();

    const sender_address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 40001);
    const receiver_address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17092);
    const peers = try setupConnectedPeers(sender, receiver, sender_address, receiver_address);

    const payload = try std.testing.allocator.alloc(u8, 1600);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index);

    var packet = try Packet.create(std.testing.allocator, payload, payload.len, constants.packet_flag_reliable);
    defer packet.release();
    packet.retain();

    try peers.sender.send(0, packet);
    try sender.flush();

    const CapturedDatagram = struct {
        address: Address,
        bytes: []u8,
    };
    var captured: std.ArrayList(CapturedDatagram) = .empty;
    defer {
        for (captured.items) |datagram| std.testing.allocator.free(datagram.bytes);
        captured.deinit(std.testing.allocator);
    }

    while (sender_mock.popSent()) |datagram| {
        try captured.append(std.testing.allocator, .{
            .address = datagram.address,
            .bytes = datagram.bytes,
        });
    }
    try std.testing.expect(captured.items.len > 1);

    var index = captured.items.len;
    while (index > 0) : (index -= 1) {
        try receiver_mock.inject(sender_address, captured.items[index - 1].bytes);
    }

    var resolved: ?Event = null;
    var attempts: usize = 0;
    while (resolved == null and attempts < captured.items.len + 2) : (attempts += 1) {
        resolved = try receiver.service(0);
    }
    const event = resolved.?;
    defer event.packet.?.release();
    try std.testing.expectEqual(constants.EventType.receive, event.type);
    try std.testing.expectEqual(payload.len, event.packet.?.data.len);
    try std.testing.expectEqualSlices(u8, payload, event.packet.?.data);
}

test "compressed and checksummed payload round trips" {
    const TestCompressor = struct {
        fn compress(_: ?*anyopaque, input: []const checksum.Buffer, _: usize, output: []u8) !usize {
            if (input.len != 1 or input[0].data.len == 0) return 0;
            const source = input[0].data;
            if (source.len < 7) return 0;
            const prefix_len: usize = 6;
            const repeated = source[prefix_len];
            for (source[prefix_len..]) |byte| {
                if (byte != repeated) return 0;
            }
            if (output.len < prefix_len + 2) return error.BufferTooSmall;
            @memcpy(output[0..prefix_len], source[0..prefix_len]);
            output[prefix_len] = @truncate(source.len - prefix_len);
            output[prefix_len + 1] = repeated;
            return prefix_len + 2;
        }

        fn decompress(_: ?*anyopaque, input: []const u8, output: []u8) !usize {
            if (input.len != 8) return error.InvalidInput;
            const prefix_len: usize = 6;
            const count = input[prefix_len];
            if (output.len < prefix_len + count) return error.BufferTooSmall;
            @memcpy(output[0..prefix_len], input[0..prefix_len]);
            @memset(output[prefix_len .. prefix_len + count], input[prefix_len + 1]);
            return prefix_len + count;
        }
    };

    var sender_mock = try transport_mod.MockTransport.init(std.testing.allocator);
    var receiver_mock = try transport_mod.MockTransport.init(std.testing.allocator);

    var sender = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
        .checksum_fn = checksum.crc32,
        .compression = .{
            .compress = TestCompressor.compress,
            .decompress = TestCompressor.decompress,
        },
    }, sender_mock.transport());
    defer sender.deinit();

    var receiver = try Host.withTransport(std.testing.allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
        .checksum_fn = checksum.crc32,
        .compression = .{
            .compress = TestCompressor.compress,
            .decompress = TestCompressor.decompress,
        },
    }, receiver_mock.transport());
    defer receiver.deinit();

    const sender_address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 40002);
    const receiver_address = Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17093);
    const peers = try setupConnectedPeers(sender, receiver, sender_address, receiver_address);

    var packet = try Packet.create(std.testing.allocator, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 40, constants.packet_flag_reliable);
    defer packet.release();
    packet.retain();

    try peers.sender.send(0, packet);
    try sender.flush();

    const sent = sender_mock.popSent().?;
    defer std.testing.allocator.free(sent.bytes);
    const header = try wire.parseHeader(sent.bytes, sender.config.protocol_flavor, true);
    try std.testing.expect((header.flags & constants.header_flag_compressed) != 0);

    try receiver_mock.inject(sender_address, sent.bytes);
    const event = (try receiver.service(0)).?;
    defer event.packet.?.release();
    try std.testing.expectEqual(constants.EventType.receive, event.type);
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", event.packet.?.data);
}
