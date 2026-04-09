const std = @import("std");
const Address = @import("address.zig").Address;

pub const unix = @import("transport/unix.zig");
pub const windows = @import("transport/windows.zig");

pub const ReceiveResult = struct {
    address: Address,
    len: usize,
};

pub const VTable = struct {
    deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    send: *const fn (ctx: *anyopaque, address: Address, bytes: []const u8) anyerror!usize,
    receive: *const fn (ctx: *anyopaque, buffer: []u8) anyerror!?ReceiveResult,
};

pub const Transport = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub fn deinit(self: *Transport) void {
        self.vtable.deinit(self.ctx, self.allocator);
    }

    pub fn send(self: *Transport, address: Address, bytes: []const u8) !usize {
        return self.vtable.send(self.ctx, address, bytes);
    }

    pub fn receive(self: *Transport, buffer: []u8) !?ReceiveResult {
        return self.vtable.receive(self.ctx, buffer);
    }
};

pub const MockTransport = struct {
    allocator: std.mem.Allocator,
    inbox: std.ArrayList(Datagram),
    outbox: std.ArrayList(Datagram),

    const Datagram = struct {
        address: Address,
        bytes: []u8,
    };

    const mock_vtable = VTable{
        .deinit = deinitOpaque,
        .send = sendOpaque,
        .receive = receiveOpaque,
    };

    pub fn init(allocator: std.mem.Allocator) !*MockTransport {
        const self = try allocator.create(MockTransport);
        self.* = .{
            .allocator = allocator,
            .inbox = .empty,
            .outbox = .empty,
        };
        return self;
    }

    pub fn inject(self: *MockTransport, address: Address, bytes: []const u8) !void {
        try self.inbox.append(self.allocator, .{
            .address = address,
            .bytes = try self.allocator.dupe(u8, bytes),
        });
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{
            .allocator = self.allocator,
            .ctx = @ptrCast(self),
            .vtable = &mock_vtable,
        };
    }

    pub fn popSent(self: *MockTransport) ?Datagram {
        if (self.outbox.items.len == 0) return null;
        return self.outbox.orderedRemove(0);
    }

    fn deinitOpaque(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        for (self.inbox.items) |datagram| allocator.free(datagram.bytes);
        for (self.outbox.items) |datagram| allocator.free(datagram.bytes);
        self.inbox.deinit(allocator);
        self.outbox.deinit(allocator);
        allocator.destroy(self);
    }

    fn sendOpaque(ctx: *anyopaque, address: Address, bytes: []const u8) !usize {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        try self.outbox.append(self.allocator, .{
            .address = address,
            .bytes = try self.allocator.dupe(u8, bytes),
        });
        return bytes.len;
    }

    fn receiveOpaque(ctx: *anyopaque, buffer: []u8) !?ReceiveResult {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        if (self.inbox.items.len == 0) return null;

        const datagram = self.inbox.orderedRemove(0);
        defer self.allocator.free(datagram.bytes);

        const len = @min(buffer.len, datagram.bytes.len);
        @memcpy(buffer[0..len], datagram.bytes[0..len]);
        return .{
            .address = datagram.address,
            .len = len,
        };
    }
};

test "mock transport round trips datagrams" {
    var mock = try MockTransport.init(std.testing.allocator);
    var transport = mock.transport();
    defer transport.deinit();

    try mock.inject(.{ .host = 1, .port = 2 }, "abc");
    var buffer: [8]u8 = undefined;
    const result = (try transport.receive(&buffer)).?;
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualSlices(u8, "abc", buffer[0..3]);
}
