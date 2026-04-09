const std = @import("std");

pub fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

pub fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

pub fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}

pub fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}

test "endian helpers round trip" {
    var buf16: [2]u8 = undefined;
    var buf32: [4]u8 = undefined;

    writeU16(&buf16, 0xABCD);
    writeU32(&buf32, 0xAABB_CCDD);

    try std.testing.expectEqual(@as(u16, 0xABCD), readU16(&buf16));
    try std.testing.expectEqual(@as(u32, 0xAABB_CCDD), readU32(&buf32));
}
