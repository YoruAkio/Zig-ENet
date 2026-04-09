const std = @import("std");

pub const Packet = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    flags: u32,
    user_data: ?*anyopaque = null,
    free_callback: ?*const fn (packet: *Packet) void = null,
    reference_count: usize = 0,
    owns_memory: bool = true,

    pub fn create(allocator: std.mem.Allocator, initial_data: ?[]const u8, data_len: usize, flags: u32) !*Packet {
        const packet = try allocator.create(Packet);
        errdefer allocator.destroy(packet);

        var buffer = try allocator.alloc(u8, data_len);
        errdefer allocator.free(buffer);

        if (initial_data) |bytes| {
            const len = @min(bytes.len, data_len);
            @memcpy(buffer[0..len], bytes[0..len]);
            if (len < data_len) @memset(buffer[len..], 0);
        } else {
            @memset(buffer, 0);
        }

        packet.* = .{
            .allocator = allocator,
            .data = buffer,
            .flags = flags,
        };
        return packet;
    }

    pub fn wrapBorrowed(allocator: std.mem.Allocator, data: []u8, flags: u32) !*Packet {
        const packet = try allocator.create(Packet);
        packet.* = .{
            .allocator = allocator,
            .data = data,
            .flags = flags,
            .owns_memory = false,
        };
        return packet;
    }

    pub fn retain(self: *Packet) void {
        self.reference_count += 1;
    }

    pub fn release(self: *Packet) void {
        if (self.reference_count > 0) {
            self.reference_count -= 1;
        }
        if (self.reference_count == 0) {
            self.destroy();
        }
    }

    pub fn resize(self: *Packet, new_len: usize) !void {
        if (!self.owns_memory) return error.CannotResizeBorrowedPacket;
        self.data = try self.allocator.realloc(self.data, new_len);
    }

    pub fn destroy(self: *Packet) void {
        if (self.free_callback) |callback| callback(self);
        if (self.owns_memory) {
            self.allocator.free(self.data);
        }
        self.allocator.destroy(self);
    }
};

test "packet resize preserves prefix" {
    var packet = try Packet.create(std.testing.allocator, "abc", 3, 0);
    defer packet.release();
    packet.retain();

    try packet.resize(5);
    try std.testing.expectEqualSlices(u8, "abc", packet.data[0..3]);
}
