const std = @import("std");
const builtin = @import("builtin");
const zigenet = @import("zigenet");

pub fn main() !void {
    const bind_address = zigenet.Address.any(17091);
    const transport = if (builtin.os.tag == .windows)
        try zigenet.transport.windows.UdpSocket.bind(std.heap.page_allocator, bind_address)
    else
        try zigenet.transport.unix.UdpSocket.bind(std.heap.page_allocator, bind_address);
    var host = try zigenet.Host.withTransport(std.heap.page_allocator, .{
        .address = bind_address,
        .peer_limit = 32,
        .channel_limit = 2,
        .protocol_flavor = .vanilla,
    }, transport);
    defer host.deinit();

    std.debug.print("server host ready on {f}\n", .{bind_address});

    while (true) {
        if (try host.service(16)) |event| {
            switch (event.type) {
                .connect => std.debug.print("peer connected from {f}\n", .{event.peer.?.address}),
                .disconnect => std.debug.print("peer disconnected\n", .{}),
                .receive => {
                    defer event.packet.?.release();
                    std.debug.print("received {d} bytes on channel {d}\n", .{ event.packet.?.data.len, event.channel_id });
                },
                else => {},
            }
        }
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}
