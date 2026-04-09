pub const version_major: u8 = 1;
pub const version_minor: u8 = 3;
pub const version_patch: u8 = 18;

pub const host_any: u32 = 0;
pub const host_broadcast: u32 = 0xFFFF_FFFF;
pub const port_any: u16 = 0;

pub const protocol_minimum_mtu: u32 = 576;
pub const protocol_maximum_mtu: u32 = 4096;
pub const protocol_maximum_packet_commands: usize = 32;
pub const protocol_minimum_window_size: u32 = 4096;
pub const protocol_maximum_window_size: u32 = 65536;
pub const protocol_minimum_channel_count: usize = 1;
pub const protocol_maximum_channel_count: usize = 255;
pub const protocol_maximum_peer_id: u16 = 0x0FFF;
pub const protocol_maximum_fragment_count: u32 = 1024 * 1024;

pub const host_receive_buffer_size: usize = 256 * 1024;
pub const host_send_buffer_size: usize = 256 * 1024;
pub const host_bandwidth_throttle_interval: u32 = 1000;
pub const host_default_mtu: u32 = 1392;
pub const host_default_maximum_packet_size: usize = 32 * 1024 * 1024;
pub const host_default_maximum_waiting_data: usize = 32 * 1024 * 1024;

pub const peer_default_round_trip_time: u32 = 500;
pub const peer_default_packet_throttle: u32 = 32;
pub const peer_packet_throttle_scale: u32 = 32;
pub const peer_packet_throttle_counter: u32 = 7;
pub const peer_packet_throttle_acceleration: u32 = 2;
pub const peer_packet_throttle_deceleration: u32 = 2;
pub const peer_packet_throttle_interval: u32 = 5000;
pub const peer_packet_loss_scale: u32 = 1 << 16;
pub const peer_packet_loss_interval: u32 = 10000;
pub const peer_window_size_scale: u32 = 64 * 1024;
pub const peer_timeout_limit: u32 = 32;
pub const peer_timeout_minimum: u32 = 5000;
pub const peer_timeout_maximum: u32 = 30000;
pub const peer_ping_interval: u32 = 500;
pub const peer_unsequenced_windows: usize = 64;
pub const peer_unsequenced_window_size: usize = 1024;
pub const peer_free_unsequenced_windows: usize = 32;
pub const peer_reliable_windows: usize = 16;
pub const peer_reliable_window_size: u16 = 0x1000;
pub const peer_free_reliable_windows: usize = 8;

pub const buffer_maximum: usize = 1 + 2 * protocol_maximum_packet_commands;

pub const header_flag_compressed: u16 = 1 << 14;
pub const header_flag_sent_time: u16 = 1 << 15;
pub const header_flag_mask: u16 = header_flag_compressed | header_flag_sent_time;
pub const header_session_mask: u16 = 3 << 12;
pub const header_session_shift: u4 = 12;

pub const packet_flag_reliable: u32 = 1 << 0;
pub const packet_flag_unsequenced: u32 = 1 << 1;
pub const packet_flag_no_allocate: u32 = 1 << 2;
pub const packet_flag_unreliable_fragment: u32 = 1 << 3;
pub const packet_flag_sent: u32 = 1 << 8;

pub const command_flag_acknowledge: u8 = 1 << 7;
pub const command_flag_unsequenced: u8 = 1 << 6;

pub const ProtocolCommand = enum(u8) {
    none = 0,
    acknowledge = 1,
    connect = 2,
    verify_connect = 3,
    disconnect = 4,
    ping = 5,
    send_reliable = 6,
    send_unreliable = 7,
    send_fragment = 8,
    send_unsequenced = 9,
    bandwidth_limit = 10,
    throttle_configure = 11,
    send_unreliable_fragment = 12,
};

pub const PeerState = enum(u8) {
    disconnected = 0,
    connecting = 1,
    acknowledging_connect = 2,
    connection_pending = 3,
    connection_succeeded = 4,
    connected = 5,
    disconnect_later = 6,
    disconnecting = 7,
    acknowledging_disconnect = 8,
    zombie = 9,
};

pub const EventType = enum(u8) {
    none = 0,
    connect = 1,
    disconnect = 2,
    receive = 3,
};
