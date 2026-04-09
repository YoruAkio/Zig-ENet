const builtin = @import("builtin");
const std = @import("std");
const zigenet = @import("zigenet");

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var args = try std.process.argsWithAllocator(arena.allocator());
        defer args.deinit();
        _ = args.next();
        const command = args.next() orelse return usage();
        const value = args.next();
        return run(command, value);
    }

    var args = std.process.args();
    _ = args.next();
    const command = args.next() orelse return usage();
    const value = args.next();
    return run(command, value);
}

fn run(command: []const u8, value: ?[]const u8) !void {
    if (std.mem.eql(u8, command, "crc32")) {
        const input = value orelse return usage();
        std.debug.print("{d}\n", .{zigenet.checksum.crc32(&[_]zigenet.checksum.Buffer{
            .{ .data = input },
        })});
        return;
    }

    if (std.mem.eql(u8, command, "sizes")) {
        std.debug.print("ack={d}\nconnect={d}\nverify_connect={d}\ndisconnect={d}\nping={d}\nsend_reliable={d}\nsend_unreliable={d}\nsend_unsequenced={d}\nsend_fragment={d}\n", .{
            zigenet.wire.commandSize(.acknowledge),
            zigenet.wire.commandSize(.connect),
            zigenet.wire.commandSize(.verify_connect),
            zigenet.wire.commandSize(.disconnect),
            zigenet.wire.commandSize(.ping),
            zigenet.wire.commandSize(.send_reliable),
            zigenet.wire.commandSize(.send_unreliable),
            zigenet.wire.commandSize(.send_unsequenced),
            zigenet.wire.commandSize(.send_fragment),
        });
        return;
    }

    if (std.mem.eql(u8, command, "fixtures")) {
        try printFixture("connect", zigConnectFixture);
        try printFixture("verify_connect", zigVerifyConnectFixture);
        return;
    }

    return usage();
}

fn usage() !void {
    std.debug.print("usage: parity-harness <crc32|string|sizes|fixtures>\n", .{});
}

fn printFixture(name: []const u8, zig_fn: *const fn (allocator: std.mem.Allocator) anyerror![]u8) !void {
    const zig_bytes = try zig_fn(std.heap.page_allocator);
    defer std.heap.page_allocator.free(zig_bytes);

    std.debug.print("{s}=", .{name});
    dumpHex(zig_bytes);
    std.debug.print("\n", .{});
}

fn dumpHex(bytes: []const u8) void {
    for (bytes) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
}

fn zigConnectFixture(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    try zigenet.wire.appendCommandHeader(&bytes, allocator, 0x80 | 0x02, 0xFF, 1);
    try zigenet.wire.appendU16(&bytes, allocator, 7);
    try bytes.append(allocator, 1);
    try bytes.append(allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 1392);
    try zigenet.wire.appendU32(&bytes, allocator, 32768);
    try zigenet.wire.appendU32(&bytes, allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 100000);
    try zigenet.wire.appendU32(&bytes, allocator, 200000);
    try zigenet.wire.appendU32(&bytes, allocator, 5000);
    try zigenet.wire.appendU32(&bytes, allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 0x11223344);
    try zigenet.wire.appendU32(&bytes, allocator, 0x55667788);
    return bytes.toOwnedSlice(allocator);
}

fn zigVerifyConnectFixture(allocator: std.mem.Allocator) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    try zigenet.wire.appendCommandHeader(&bytes, allocator, 0x80 | 0x03, 0xFF, 3);
    try zigenet.wire.appendU16(&bytes, allocator, 9);
    try bytes.append(allocator, 2);
    try bytes.append(allocator, 1);
    try zigenet.wire.appendU32(&bytes, allocator, 1392);
    try zigenet.wire.appendU32(&bytes, allocator, 32768);
    try zigenet.wire.appendU32(&bytes, allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 120000);
    try zigenet.wire.appendU32(&bytes, allocator, 240000);
    try zigenet.wire.appendU32(&bytes, allocator, 5000);
    try zigenet.wire.appendU32(&bytes, allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 2);
    try zigenet.wire.appendU32(&bytes, allocator, 0xAABBCCDD);
    return bytes.toOwnedSlice(allocator);
}
