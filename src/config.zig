const Address = @import("address.zig").Address;
const checksum = @import("checksum.zig");
const constants = @import("constants.zig");

pub const ProtocolFlavor = enum {
    vanilla,
    growtopia_client,
    growtopia_server,
};

pub const CompressionCallbacks = struct {
    context: ?*anyopaque = null,
    compress: ?*const fn (context: ?*anyopaque, input: []const checksum.Buffer, input_limit: usize, output: []u8) anyerror!usize = null,
    decompress: ?*const fn (context: ?*anyopaque, input: []const u8, output: []u8) anyerror!usize = null,
    destroy: ?*const fn (context: ?*anyopaque) void = null,
};

pub const ChecksumFn = *const fn (buffers: []const checksum.Buffer) u32;

pub const BandwidthLimits = struct {
    incoming: u32 = 0,
    outgoing: u32 = 0,
};

pub const HostConfig = struct {
    address: ?Address = null,
    peer_limit: usize = 1,
    channel_limit: usize = constants.protocol_maximum_channel_count,
    bandwidth: BandwidthLimits = .{},
    mtu: u32 = constants.host_default_mtu,
    maximum_packet_size: usize = constants.host_default_maximum_packet_size,
    maximum_waiting_data: usize = constants.host_default_maximum_waiting_data,
    protocol_flavor: ProtocolFlavor = .growtopia_server,
    checksum_fn: ?ChecksumFn = null,
    compression: CompressionCallbacks = .{},
};
