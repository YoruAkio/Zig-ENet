const std = @import("std");

pub const Buffer = struct {
    data: []const u8,
};

const crc_table = blk: {
    @setEvalBranchQuota(5000);
    var table: [256]u32 = undefined;
    var i: usize = 0;
    while (i < table.len) : (i += 1) {
        var crc = @as(u32, @intCast(i));
        var bit: usize = 0;
        while (bit < 8) : (bit += 1) {
            crc = if ((crc & 1) != 0) (crc >> 1) ^ 0xEDB8_8320 else crc >> 1;
        }
        table[i] = crc;
    }
    break :blk table;
};

pub fn crc32(buffers: []const Buffer) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (buffers) |buffer| {
        for (buffer.data) |byte| {
            const index: usize = @intCast((crc ^ byte) & 0xFF);
            crc = (crc >> 8) ^ crc_table[index];
        }
    }
    return ~crc;
}

test "crc32 matches canonical vector" {
    const sum = crc32(&[_]Buffer{
        .{ .data = "123456789" },
    });
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), sum);
}
