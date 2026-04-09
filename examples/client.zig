const std = @import("std");
const builtin = @import("builtin");
const zigenet = @import("zigenet");

pub fn main() !void {
    const transport = if (builtin.os.tag == .windows)
        try zigenet.transport.windows.UdpSocket.bind(std.heap.page_allocator, null)
    else
        try zigenet.transport.unix.UdpSocket.bind(std.heap.page_allocator, null);
    var host = try zigenet.Host.withTransport(std.heap.page_allocator, .{
        .peer_limit = 1,
        .channel_limit = 2,
        .using_new_packet = false,
        .using_new_packet_for_server = false,
    }, transport);
    defer host.deinit();

    const peer = try host.connect(zigenet.Address.fromIpv4Octets(.{ 127, 0, 0, 1 }, 17091), 2, 0);
    std.debug.print("client queued connect for {f}\n", .{peer.address});
    try host.flush();

    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (try host.service(16)) |event| {
            switch (event.type) {
                .connect => {
                    std.debug.print("connected, sending payload\n", .{});
                    var packet = try zigenet.Packet.create(std.heap.page_allocator, "hello from zig", 14, zigenet.constants.packet_flag_reliable);
                    defer packet.release();
                    packet.retain();
                    try event.peer.?.send(0, packet);
                    try host.flush();
                    return;
                },
                .disconnect => return,
                .receive => {
                    defer event.packet.?.release();
                    std.debug.print("received {d} bytes\n", .{event.packet.?.data.len});
                },
                else => {},
            }
        }
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}
