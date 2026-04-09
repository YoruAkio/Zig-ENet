const std = @import("std");
const checksum = @import("checksum.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

const range_coder_top: u32 = 1 << 24;
const range_coder_bottom: u32 = 1 << 16;
const context_symbol_delta: u8 = 3;
const context_symbol_minimum: u16 = 1;
const context_escape_minimum: u16 = 1;
const subcontext_order: usize = 2;
const subcontext_symbol_delta: u8 = 2;
const subcontext_escape_delta: u16 = 5;
const max_symbols: usize = 4096;

const Symbol = struct {
    value: u8 = 0,
    count: u8 = 0,
    under: u16 = 0,
    left: u16 = 0,
    right: u16 = 0,
    symbols: u16 = 0,
    escapes: u16 = 0,
    total: u16 = 0,
    parent: u16 = 0,
};

const ParentTarget = union(enum) {
    predicted,
    symbol: u16,
};

const EncodeResult = struct {
    symbol_index: u16,
    under: u16,
    count: u16,
};

const DecodeResult = struct {
    symbol_index: u16,
    value: u8,
    under: u16,
    count: u16,
};

const Engine = struct {
    symbols: [max_symbols]Symbol = [_]Symbol{.{}} ** max_symbols,
    next_symbol: usize = 0,
    predicted: u16 = 0,
    order: usize = 0,

    fn reset(self: *Engine) void {
        self.symbols = [_]Symbol{.{}} ** max_symbols;
        self.next_symbol = 0;
        _ = self.contextCreate(context_escape_minimum, context_symbol_minimum);
        self.predicted = 0;
        self.order = 0;
    }

    fn createSymbol(self: *Engine, value: u8, count: u8) !u16 {
        if (self.next_symbol >= self.symbols.len) return error.OutOfSymbols;
        const index: u16 = @intCast(self.next_symbol);
        self.next_symbol += 1;
        self.symbols[index] = .{
            .value = value,
            .count = count,
            .under = count,
        };
        return index;
    }

    fn contextCreate(self: *Engine, escapes: u16, minimum: u16) u16 {
        const index = self.createSymbol(0, 0) catch unreachable;
        self.symbols[index].escapes = escapes;
        self.symbols[index].total = escapes + 256 * minimum;
        self.symbols[index].symbols = 0;
        return index;
    }

    fn freeSymbolsIfNeeded(self: *Engine) void {
        if (self.next_symbol >= self.symbols.len - subcontext_order) {
            self.reset();
        }
    }

    fn setParent(self: *Engine, target: ParentTarget, value: u16) void {
        switch (target) {
            .predicted => self.predicted = value,
            .symbol => |index| self.symbols[index].parent = value,
        }
    }

    fn symbolRescale(self: *Engine, index: u16) u16 {
        var total: u16 = 0;
        var current = index;
        while (true) {
            self.symbols[current].count -%= self.symbols[current].count >> 1;
            self.symbols[current].under = self.symbols[current].count;
            if (self.symbols[current].left != 0) {
                self.symbols[current].under +%= self.symbolRescale(current + self.symbols[current].left);
            }
            total +%= self.symbols[current].under;
            if (self.symbols[current].right == 0) break;
            current +%= self.symbols[current].right;
        }
        return total;
    }

    fn contextRescale(self: *Engine, context_index: u16, minimum: u16) void {
        if (self.symbols[context_index].symbols != 0) {
            self.symbols[context_index].total = self.symbolRescale(context_index + self.symbols[context_index].symbols);
        } else {
            self.symbols[context_index].total = 0;
        }
        self.symbols[context_index].escapes -%= self.symbols[context_index].escapes >> 1;
        self.symbols[context_index].total +%= self.symbols[context_index].escapes + 256 * minimum;
    }

    fn contextEncode(self: *Engine, context_index: u16, value: u8, update: u8, minimum: u16) !EncodeResult {
        var under: u16 = @as(u16, value) * minimum;
        var count: u16 = minimum;

        if (self.symbols[context_index].symbols == 0) {
            const symbol_index = try self.createSymbol(value, update);
            self.symbols[context_index].symbols = symbol_index - context_index;
            return .{
                .symbol_index = symbol_index,
                .under = under,
                .count = count,
            };
        }

        var node_index: u16 = context_index + self.symbols[context_index].symbols;
        while (true) {
            if (value < self.symbols[node_index].value) {
                self.symbols[node_index].under +%= update;
                if (self.symbols[node_index].left != 0) {
                    node_index +%= self.symbols[node_index].left;
                    continue;
                }
                const symbol_index = try self.createSymbol(value, update);
                self.symbols[node_index].left = symbol_index - node_index;
                return .{
                    .symbol_index = symbol_index,
                    .under = under,
                    .count = count,
                };
            }

            if (value > self.symbols[node_index].value) {
                under +%= self.symbols[node_index].under;
                if (self.symbols[node_index].right != 0) {
                    node_index +%= self.symbols[node_index].right;
                    continue;
                }
                const symbol_index = try self.createSymbol(value, update);
                self.symbols[node_index].right = symbol_index - node_index;
                return .{
                    .symbol_index = symbol_index,
                    .under = under,
                    .count = count,
                };
            }

            count +%= self.symbols[node_index].count;
            under +%= self.symbols[node_index].under - self.symbols[node_index].count;
            self.symbols[node_index].under +%= update;
            self.symbols[node_index].count +%= update;
            return .{
                .symbol_index = node_index,
                .under = under,
                .count = count,
            };
        }
    }

    fn tryDecodeContext(self: *Engine, context_index: u16, code: u16, update: u8, minimum: u16) ?DecodeResult {
        if (self.symbols[context_index].symbols == 0) return null;

        var under: u16 = 0;
        var count: u16 = minimum;
        var node_index: u16 = context_index + self.symbols[context_index].symbols;

        while (true) {
            const after: u16 = under + self.symbols[node_index].under + (@as(u16, self.symbols[node_index].value) + 1) * minimum;
            const before: u16 = self.symbols[node_index].count + minimum;

            if (code >= after) {
                under +%= self.symbols[node_index].under;
                if (self.symbols[node_index].right == 0) return null;
                node_index +%= self.symbols[node_index].right;
                continue;
            }

            if (code < after - before) {
                self.symbols[node_index].under +%= update;
                if (self.symbols[node_index].left == 0) return null;
                node_index +%= self.symbols[node_index].left;
                continue;
            }

            count +%= self.symbols[node_index].count;
            under = after - before;
            self.symbols[node_index].under +%= update;
            self.symbols[node_index].count +%= update;
            return .{
                .symbol_index = node_index,
                .value = self.symbols[node_index].value,
                .under = under,
                .count = count,
            };
        }
    }

    fn decodeRoot(self: *Engine, code: u16, update: u8, minimum: u16) !DecodeResult {
        var under: u16 = 0;
        var count: u16 = minimum;

        if (self.symbols[0].symbols == 0) {
            const value: u8 = @intCast(code / minimum);
            under = code - (code % minimum);
            const symbol_index = try self.createSymbol(value, update);
            self.symbols[0].symbols = symbol_index;
            return .{
                .symbol_index = symbol_index,
                .value = value,
                .under = under,
                .count = count,
            };
        }

        var node_index: u16 = self.symbols[0].symbols;
        while (true) {
            const after: u16 = under + self.symbols[node_index].under + (@as(u16, self.symbols[node_index].value) + 1) * minimum;
            const before: u16 = self.symbols[node_index].count + minimum;

            if (code >= after) {
                under +%= self.symbols[node_index].under;
                if (self.symbols[node_index].right != 0) {
                    node_index +%= self.symbols[node_index].right;
                    continue;
                }
                const value: u8 = @intCast(@as(u16, self.symbols[node_index].value) + 1 + ((code - after) / minimum));
                under = code - ((code - after) % minimum);
                const symbol_index = try self.createSymbol(value, update);
                self.symbols[node_index].right = symbol_index - node_index;
                return .{
                    .symbol_index = symbol_index,
                    .value = value,
                    .under = under,
                    .count = count,
                };
            }

            if (code < after - before) {
                self.symbols[node_index].under +%= update;
                if (self.symbols[node_index].left != 0) {
                    node_index +%= self.symbols[node_index].left;
                    continue;
                }
                const delta: u16 = (after - before - code - 1) / minimum;
                const value: u8 = @intCast(@as(u16, self.symbols[node_index].value) - 1 - delta);
                under = code - ((after - before - code - 1) % minimum);
                const symbol_index = try self.createSymbol(value, update);
                self.symbols[node_index].left = symbol_index - node_index;
                return .{
                    .symbol_index = symbol_index,
                    .value = value,
                    .under = under,
                    .count = count,
                };
            }

            count +%= self.symbols[node_index].count;
            under = after - before;
            self.symbols[node_index].under +%= update;
            self.symbols[node_index].count +%= update;
            return .{
                .symbol_index = node_index,
                .value = self.symbols[node_index].value,
                .under = under,
                .count = count,
            };
        }
    }

    fn encodeRange(out: []u8, out_index: *usize, encode_low: *u32, encode_range: *u32, under: u16, count: u16, total: u16) !void {
        encode_range.* /= total;
        encode_low.* +%= @as(u32, under) * encode_range.*;
        encode_range.* *%= count;

        while (true) {
            if ((encode_low.* ^ (encode_low.* +% encode_range.*)) >= range_coder_top) {
                if (encode_range.* >= range_coder_bottom) break;
                encode_range.* = (0 -% encode_low.*) & (range_coder_bottom - 1);
            }
            if (out_index.* >= out.len) return error.BufferTooSmall;
            out[out_index.*] = @truncate(encode_low.* >> 24);
            out_index.* += 1;
            encode_range.* <<= 8;
            encode_low.* <<= 8;
        }
    }

    fn flushRange(out: []u8, out_index: *usize, encode_low: *u32) !void {
        while (encode_low.* != 0) {
            if (out_index.* >= out.len) return error.BufferTooSmall;
            out[out_index.*] = @truncate(encode_low.* >> 24);
            out_index.* += 1;
            encode_low.* <<= 8;
        }
    }

    fn seedDecode(input: []const u8, input_index: *usize) u32 {
        var decode_code: u32 = 0;
        if (input_index.* < input.len) {
            decode_code |= @as(u32, input[input_index.*]) << 24;
            input_index.* += 1;
        }
        if (input_index.* < input.len) {
            decode_code |= @as(u32, input[input_index.*]) << 16;
            input_index.* += 1;
        }
        if (input_index.* < input.len) {
            decode_code |= @as(u32, input[input_index.*]) << 8;
            input_index.* += 1;
        }
        if (input_index.* < input.len) {
            decode_code |= input[input_index.*];
            input_index.* += 1;
        }
        return decode_code;
    }

    fn readCode(decode_low: u32, decode_code: u32, decode_range: *u32, total: u16) u16 {
        decode_range.* /= total;
        return @intCast((decode_code -% decode_low) / decode_range.*);
    }

    fn decodeRange(input: []const u8, input_index: *usize, decode_low: *u32, decode_code: *u32, decode_range: *u32, under: u16, count: u16) void {
        decode_low.* +%= @as(u32, under) * decode_range.*;
        decode_range.* *%= count;

        while (true) {
            if ((decode_low.* ^ (decode_low.* +% decode_range.*)) >= range_coder_top) {
                if (decode_range.* >= range_coder_bottom) break;
                decode_range.* = (0 -% decode_low.*) & (range_coder_bottom - 1);
            }
            decode_code.* <<= 8;
            if (input_index.* < input.len) {
                decode_code.* |= input[input_index.*];
                input_index.* += 1;
            }
            decode_range.* <<= 8;
            decode_low.* <<= 8;
        }
    }

    fn compress(self: *Engine, input: []const checksum.Buffer, output: []u8) !usize {
        if (input.len == 0 or output.len == 0) return 0;

        self.reset();
        var out_index: usize = 0;
        var encode_low: u32 = 0;
        var encode_range: u32 = ~@as(u32, 0);
        var buffer_index: usize = 0;
        var byte_index: usize = 0;

        while (true) {
            while (buffer_index < input.len and byte_index >= input[buffer_index].data.len) {
                buffer_index += 1;
                byte_index = 0;
            }
            if (buffer_index >= input.len) break;

            const value = input[buffer_index].data[byte_index];
            byte_index += 1;

            var parent_target: ParentTarget = .predicted;
            var encoded = false;
            var subcontext_index = self.predicted;

            while (subcontext_index != 0) {
                const result = try self.contextEncode(subcontext_index, value, subcontext_symbol_delta, 0);
                self.setParent(parent_target, result.symbol_index);
                parent_target = .{ .symbol = result.symbol_index };

                const total = self.symbols[subcontext_index].total;
                if (result.count > 0) {
                    try encodeRange(output, &out_index, &encode_low, &encode_range, self.symbols[subcontext_index].escapes + result.under, result.count, total);
                    encoded = true;
                } else {
                    if (self.symbols[subcontext_index].escapes > 0 and self.symbols[subcontext_index].escapes < total) {
                        try encodeRange(output, &out_index, &encode_low, &encode_range, 0, self.symbols[subcontext_index].escapes, total);
                    }
                    self.symbols[subcontext_index].escapes +%= subcontext_escape_delta;
                    self.symbols[subcontext_index].total +%= subcontext_escape_delta;
                }

                self.symbols[subcontext_index].total +%= subcontext_symbol_delta;
                if (result.count > 0xFF - 2 * subcontext_symbol_delta or self.symbols[subcontext_index].total > range_coder_bottom - 0x100) {
                    self.contextRescale(subcontext_index, 0);
                }
                if (encoded) break;
                subcontext_index = self.symbols[subcontext_index].parent;
            }

            if (!encoded) {
                const result = try self.contextEncode(0, value, context_symbol_delta, context_symbol_minimum);
                self.setParent(parent_target, result.symbol_index);
                try encodeRange(output, &out_index, &encode_low, &encode_range, self.symbols[0].escapes + result.under, result.count, self.symbols[0].total);
                self.symbols[0].total +%= context_symbol_delta;
                if (result.count > 0xFF - 2 * context_symbol_delta + context_symbol_minimum or self.symbols[0].total > range_coder_bottom - 0x100) {
                    self.contextRescale(0, context_symbol_minimum);
                }
            }

            if (self.order >= subcontext_order) {
                self.predicted = self.symbols[self.predicted].parent;
            } else {
                self.order += 1;
            }
            self.freeSymbolsIfNeeded();
        }

        try flushRange(output, &out_index, &encode_low);
        return out_index;
    }

    fn decompress(self: *Engine, input: []const u8, output: []u8) !usize {
        if (input.len == 0 or output.len == 0) return 0;

        self.reset();
        var in_index: usize = 0;
        var out_index: usize = 0;
        var decode_low: u32 = 0;
        var decode_range: u32 = ~@as(u32, 0);
        var decode_code = seedDecode(input, &in_index);

        while (true) {
            const patch_start = self.predicted;
            var subcontext_index = patch_start;
            var parent_target: ParentTarget = .predicted;
            var decoded: ?DecodeResult = null;
            var stop_context: u16 = 0;

            while (subcontext_index != 0) {
                if (self.symbols[subcontext_index].escapes == 0) {
                    subcontext_index = self.symbols[subcontext_index].parent;
                    continue;
                }

                const total = self.symbols[subcontext_index].total;
                if (self.symbols[subcontext_index].escapes >= total) {
                    subcontext_index = self.symbols[subcontext_index].parent;
                    continue;
                }

                var code = readCode(decode_low, decode_code, &decode_range, total);
                if (code < self.symbols[subcontext_index].escapes) {
                    decodeRange(input, &in_index, &decode_low, &decode_code, &decode_range, 0, self.symbols[subcontext_index].escapes);
                    subcontext_index = self.symbols[subcontext_index].parent;
                    continue;
                }

                code -%= self.symbols[subcontext_index].escapes;
                const result = self.tryDecodeContext(subcontext_index, code, subcontext_symbol_delta, 0) orelse return error.InvalidCompressedPacket;
                decoded = result;
                stop_context = subcontext_index;
                decodeRange(input, &in_index, &decode_low, &decode_code, &decode_range, self.symbols[subcontext_index].escapes + result.under, result.count);
                self.symbols[subcontext_index].total +%= subcontext_symbol_delta;
                if (result.count > 0xFF - 2 * subcontext_symbol_delta or self.symbols[subcontext_index].total > range_coder_bottom - 0x100) {
                    self.contextRescale(subcontext_index, 0);
                }
                break;
            }

            if (decoded == null) {
                const total = self.symbols[0].total;
                var code = readCode(decode_low, decode_code, &decode_range, total);
                if (code < self.symbols[0].escapes) {
                    decodeRange(input, &in_index, &decode_low, &decode_code, &decode_range, 0, self.symbols[0].escapes);
                    break;
                }
                code -%= self.symbols[0].escapes;
                const result = try self.decodeRoot(code, context_symbol_delta, context_symbol_minimum);
                decoded = result;
                stop_context = 0;
                decodeRange(input, &in_index, &decode_low, &decode_code, &decode_range, self.symbols[0].escapes + result.under, result.count);
                self.symbols[0].total +%= context_symbol_delta;
                if (result.count > 0xFF - 2 * context_symbol_delta + context_symbol_minimum or self.symbols[0].total > range_coder_bottom - 0x100) {
                    self.contextRescale(0, context_symbol_minimum);
                }
            }

            const result = decoded.?;
            var patch_index = patch_start;
            while (patch_index != stop_context) {
                const encoded = try self.contextEncode(patch_index, result.value, subcontext_symbol_delta, 0);
                self.setParent(parent_target, encoded.symbol_index);
                parent_target = .{ .symbol = encoded.symbol_index };
                if (encoded.count <= 0) {
                    self.symbols[patch_index].escapes +%= subcontext_escape_delta;
                    self.symbols[patch_index].total +%= subcontext_escape_delta;
                }
                self.symbols[patch_index].total +%= subcontext_symbol_delta;
                if (encoded.count > 0xFF - 2 * subcontext_symbol_delta or self.symbols[patch_index].total > range_coder_bottom - 0x100) {
                    self.contextRescale(patch_index, 0);
                }
                patch_index = self.symbols[patch_index].parent;
            }
            self.setParent(parent_target, result.symbol_index);

            if (out_index >= output.len) return error.BufferTooSmall;
            output[out_index] = result.value;
            out_index += 1;

            if (self.order >= subcontext_order) {
                self.predicted = self.symbols[self.predicted].parent;
            } else {
                self.order += 1;
            }
            self.freeSymbolsIfNeeded();
        }

        return out_index;
    }
};

const State = struct {
    allocator: Allocator,
    engine: Engine = .{},
};

pub const RangeCoder = struct {
    context: ?*State,

    pub fn init() !RangeCoder {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(allocator: Allocator) !RangeCoder {
        const context = try allocator.create(State);
        context.* = .{
            .allocator = allocator,
        };
        return .{
            .context = context,
        };
    }

    pub fn deinit(self: *RangeCoder) void {
        const context = self.context orelse return;
        context.allocator.destroy(context);
        self.context = null;
    }

    pub fn callbacks(self: *RangeCoder) config.CompressionCallbacks {
        const context = self.context orelse @panic("range coder callbacks requested after ownership transfer");
        self.context = null;
        return .{
            .context = context,
            .compress = compressCallback,
            .decompress = decompressCallback,
            .destroy = destroyCallback,
        };
    }

    fn compressCallback(context: ?*anyopaque, input: []const checksum.Buffer, _: usize, output: []u8) !usize {
        const state = @as(*State, @ptrCast(@alignCast(context orelse return error.InvalidCompressor)));
        return state.engine.compress(input, output);
    }

    fn decompressCallback(context: ?*anyopaque, input: []const u8, output: []u8) !usize {
        const state = @as(*State, @ptrCast(@alignCast(context orelse return error.InvalidCompressor)));
        return state.engine.decompress(input, output);
    }

    fn destroyCallback(context: ?*anyopaque) void {
        const state = @as(*State, @ptrCast(@alignCast(context orelse return)));
        state.allocator.destroy(state);
    }
};

test "range coder round trips enet payload" {
    var coder = try RangeCoder.init();
    const callbacks = coder.callbacks();

    const source = "enet zig zig enet zig enet reliable reliable reliable";
    var compressed: [256]u8 = undefined;
    const compressed_len = try callbacks.compress.?(callbacks.context, &[_]checksum.Buffer{
        .{ .data = source },
    }, source.len, &compressed);
    try std.testing.expect(compressed_len > 0);

    var restored: [256]u8 = undefined;
    const restored_len = try callbacks.decompress.?(callbacks.context, compressed[0..compressed_len], &restored);
    try std.testing.expectEqualStrings(source, restored[0..restored_len]);
    callbacks.destroy.?(callbacks.context);
}
