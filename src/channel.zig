const std = @import("std");
const constants = @import("constants.zig");
const protocol = @import("protocol.zig");

pub const ChannelState = struct {
    outgoing_reliable_sequence_number: u16 = 0,
    outgoing_unreliable_sequence_number: u16 = 0,
    incoming_reliable_sequence_number: u16 = 0,
    incoming_unreliable_sequence_number: u16 = 0,
    used_reliable_windows: u16 = 0,
    reliable_windows: [constants.peer_reliable_windows]u16 = std.mem.zeroes([constants.peer_reliable_windows]u16),
    pending_reliable: std.ArrayList(protocol.IncomingCommand) = .empty,
    pending_unreliable: std.ArrayList(protocol.IncomingCommand) = .empty,
    fragment_assemblies: std.ArrayList(protocol.FragmentAssembly) = .empty,
};
