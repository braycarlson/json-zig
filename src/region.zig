const std = @import("std");

const assert = std.debug.assert;

pub const alignment_bytes: u32 = 16;
pub const region_bytes_max: u32 = std.math.maxInt(u32);

comptime {
    assert(std.math.isPowerOfTwo(alignment_bytes));
}

pub const Error = error{RegionFull};

pub const Mark = enum(u32) {
    _,
};

pub const Region = struct {
    buffer: []align(alignment_bytes) u8,
    top: u32,
    used: u32,

    pub fn init(buffer: []u8) Region {
        assert(buffer.len >= alignment_bytes);
        assert(buffer.len <= region_bytes_max);

        const address: u64 = @intFromPtr(buffer.ptr);
        const start = std.mem.alignForward(u64, address, alignment_bytes);
        const padding: u32 = @intCast(start - address);
        const aligned: []align(alignment_bytes) u8 = @alignCast(buffer[padding..]);

        assert(padding < alignment_bytes);
        assert(@intFromPtr(aligned.ptr) % alignment_bytes == 0);

        const result = Region{ .buffer = aligned, .top = @intCast(aligned.len), .used = 0 };

        assert(result.unused_bytes() == aligned.len);

        return result;
    }

    pub fn reset(region: *Region) void {
        assert(region.used <= region.top);
        assert(region.top <= region.buffer.len);

        region.used = 0;
        region.top = @intCast(region.buffer.len);

        assert(region.unused_bytes() == region.buffer.len);
    }

    pub fn reserve(region: *Region, comptime T: type, count: u32) Error![]T {
        comptime assert(@sizeOf(T) > 0);
        comptime assert(@alignOf(T) <= alignment_bytes);
        assert(region.used <= region.top);
        assert(@as(u64, count) <= @divFloor(std.math.maxInt(u64), @sizeOf(T)));

        if (count == 0) return &.{};

        const start = std.mem.alignForward(u64, region.used, @alignOf(T));
        const size = @as(u64, @sizeOf(T)) * count;
        if (start + size > region.top) return error.RegionFull;

        const bytes = region.buffer[@intCast(start)..][0..@intCast(size)];
        const items: []T = @alignCast(std.mem.bytesAsSlice(T, bytes));

        region.used = @intCast(start + size);

        assert(items.len == count);
        assert(region.used <= region.top);

        return items;
    }

    pub fn mark(region: *const Region) Mark {
        assert(region.used <= region.top);
        assert(region.top <= region.buffer.len);

        return @fromBackingInt(region.top);
    }

    pub fn push(region: *Region, comptime T: type) Error!*T {
        comptime assert(@sizeOf(T) > 0);
        comptime assert(@alignOf(T) <= alignment_bytes);
        assert(region.used <= region.top);

        if (region.top < @sizeOf(T)) return error.RegionFull;

        const start = std.mem.alignBackward(u32, region.top - @sizeOf(T), @alignOf(T));
        if (start < region.used) return error.RegionFull;

        region.top = start;

        const bytes = region.buffer[start..][0..@sizeOf(T)];
        const item: *T = @alignCast(std.mem.bytesAsValue(T, bytes));

        assert(region.used <= region.top);

        return item;
    }

    pub fn take(region: *Region, comptime T: type, stack_mark: Mark, count: u32) Error![]T {
        comptime assert(@sizeOf(T) > 0);
        assert(@backingInt(stack_mark) <= region.buffer.len);
        assert(region.top <= @backingInt(stack_mark));

        const stack_top = @backingInt(stack_mark);

        assert(count <= @divFloor(stack_top - region.top, @sizeOf(T)) + 1);

        if (count == 0) {
            assert(region.top == stack_top);

            return &.{};
        }

        const first = std.mem.alignBackward(u32, stack_top - @sizeOf(T), @alignOf(T));

        assert(region.top == first - (count - 1) * @sizeOf(T));

        const items = try region.reserve(T, count);

        for (items, 0..) |*item, index| {
            const offset = first - @as(u32, @intCast(index)) * @sizeOf(T);
            const bytes = region.buffer[offset..][0..@sizeOf(T)];
            const source: *const T = @alignCast(std.mem.bytesAsValue(T, bytes));

            item.* = source.*;
        }

        region.top = stack_top;

        assert(region.used <= region.top);

        return items;
    }

    pub fn unused_bytes(region: *const Region) u32 {
        assert(region.used <= region.top);
        assert(region.top <= region.buffer.len);

        const result = region.top - region.used;

        assert(result <= region.buffer.len);

        return result;
    }
};

const testing = std.testing;

test "front reservations are aligned, disjoint, and refused past the stack" {
    var buffer: [256]u8 align(alignment_bytes) = undefined;
    var region: Region = .init(&buffer);

    const bytes = try region.reserve(u8, 3);
    const words = try region.reserve(u64, 4);

    try testing.expectEqual(@as(usize, 3), bytes.len);
    try testing.expectEqual(@as(usize, 4), words.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(words.ptr) % @alignOf(u64));
    try testing.expect(@intFromPtr(words.ptr) >= @intFromPtr(bytes.ptr) + bytes.len);
    try testing.expectEqual(@as(u32, 256 - 40), region.unused_bytes());
    try testing.expectError(error.RegionFull, region.reserve(u64, 64));
    try testing.expectEqual(@as(u32, 256 - 40), region.unused_bytes());

    region.reset();

    try testing.expectEqual(@as(u32, 256), region.unused_bytes());
}

test "items pushed onto the stack move to the front in push order" {
    var buffer: [512]u8 align(alignment_bytes) = undefined;
    var region: Region = .init(&buffer);
    const outer_mark = region.mark();

    for (0..3) |outer| {
        const slot = try region.push([]const u32);
        const inner_mark = region.mark();
        const prefix = try region.reserve(u8, @intCast(outer + 1));

        @memset(prefix, 'x');

        for (0..outer + 2) |inner| (try region.push(u32)).* = @intCast(outer * 10 + inner);

        slot.* = try region.take(u32, inner_mark, @intCast(outer + 2));
    }

    const rows = try region.take([]const u32, outer_mark, 3);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, rows[0]);
    try testing.expectEqualSlices(u32, &.{ 10, 11, 12 }, rows[1]);
    try testing.expectEqualSlices(u32, &.{ 20, 21, 22, 23 }, rows[2]);
    try testing.expectEqual(outer_mark, region.mark());
}

test "the stack and the front refuse to overlap" {
    var buffer: [32]u8 align(alignment_bytes) = undefined;
    var region: Region = .init(&buffer);

    _ = try region.reserve(u8, 21);
    _ = try region.push(u32);
    _ = try region.push(u32);

    try testing.expectError(error.RegionFull, region.push(u32));
    try testing.expectError(error.RegionFull, region.reserve(u8, 5));
    try testing.expectEqual(@as(u32, 3), region.unused_bytes());
}

test Region {
    var buffer: [64]u8 = undefined;
    var region: Region = .init(buffer[1..]);

    const words = try region.reserve(u32, 4);

    try testing.expectEqual(@as(usize, 4), words.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(words.ptr) % alignment_bytes);
    try testing.expect(region.unused_bytes() < 64 - 16);

    region.reset();

    try testing.expect(region.unused_bytes() >= 64 - alignment_bytes);
}
