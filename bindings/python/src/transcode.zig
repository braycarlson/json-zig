const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

pub const enabled = builtin.zig_backend == .stage2_llvm and
    builtin.target.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .ssse3);

pub const target_room_min: u32 = 8;
pub const window_bytes: u32 = 16;

const mask_bits: u32 = 12;
const mask_count: u32 = 1 << mask_bits;
const pairs_count: u32 = 64;
const pairs_points: u32 = 6;
const pattern_count: u32 = pairs_count + triples_count;
const pattern_none: u8 = 0xff;
const triples_count: u32 = 81;
const triples_points: u32 = 4;
const triples_ends: u12 = 0b1001_0010_0100;
const triples_uniform: u8 = pattern_count - 1;
const zero_lane: u8 = 0x80;

const Bytes = @Vector(window_bytes, u8);
const Units = @Vector(8, u16);
const Words = @Vector(4, u32);

comptime {
    assert(pairs_count == 1 << pairs_points);
    assert(triples_count == std.math.pow(u32, 3, triples_points));
    assert(pattern_count < pattern_none);
    assert(pairs_points * 2 <= mask_bits);
    assert(triples_points * 3 <= mask_bits);
    assert(tables.entries[triples_ends].pattern == triples_uniform);
    assert(tables.entries[triples_ends].consumed == 12);
}

const Entry = struct {
    consumed: u8,
    pattern: u8,
};

pub const Step = struct {
    source_count: u32,
    target_count: u32,
};

const Tables = struct {
    entries: [mask_count]Entry,
    patterns: [pattern_count]Bytes,
};

extern fn @"llvm.x86.ssse3.pshuf.b.128"(table: Bytes, indices: Bytes) Bytes;

const tables: Tables = tables_build();

pub fn step(
    comptime Unit: type,
    comptime triples_first: bool,
    window: *const [window_bytes]u8,
    target: []Unit,
) Step {
    comptime assert(enabled);
    comptime assert(Unit == u8 or Unit == u16);
    assert(target.len >= target_room_min);
    assert(window[0] & 0xc0 != 0x80);

    const bytes: Bytes = window.*;
    const trailing = bytes & @as(Bytes, @splat(0xc0)) == @as(Bytes, @splat(0x80));
    const continuation: u16 = @bitCast(trailing);
    const ends: u12 = @truncate(~continuation >> 1);
    if (triples_first) {
        comptime assert(Unit == u16);

        if (ends == triples_ends) {
            triples_write(Unit, bytes, triples_uniform, target);

            return .{ .source_count = 12, .target_count = triples_points };
        }
    }

    const entry = tables.entries[ends];
    if (entry.pattern == pattern_none) return .{ .source_count = 0, .target_count = 0 };

    if (entry.pattern < pairs_count) {
        pairs_write(Unit, bytes, entry.pattern, target);

        return .{ .source_count = entry.consumed, .target_count = pairs_points };
    }

    if (Unit == u8) unreachable;

    triples_write(Unit, bytes, entry.pattern, target);

    return .{ .source_count = entry.consumed, .target_count = triples_points };
}

inline fn pairs_write(comptime Unit: type, bytes: Bytes, pattern: u8, target: []Unit) void {
    assert(bytes[0] & 0xc0 != 0x80);
    assert(pattern < pairs_count);
    assert(target.len >= target_room_min);

    const shuffled = @"llvm.x86.ssse3.pshuf.b.128"(bytes, tables.patterns[pattern]);
    const lanes: Units = @bitCast(shuffled);
    const low = lanes & @as(Units, @splat(0x7f));
    const high = (lanes & @as(Units, @splat(0x1f00))) >> @splat(2);
    const points: @Vector(8, Unit) = @intCast(low | high);

    target[0..8].* = points;
}

inline fn triples_write(comptime Unit: type, bytes: Bytes, pattern: u8, target: []Unit) void {
    comptime assert(Unit == u16);
    assert(bytes[0] & 0xc0 != 0x80);
    assert(pattern >= pairs_count);
    assert(target.len >= target_room_min);

    const shuffled = @"llvm.x86.ssse3.pshuf.b.128"(bytes, tables.patterns[pattern]);
    const lanes: Words = @bitCast(shuffled);
    const low = lanes & @as(Words, @splat(0x7f));
    const middle = (lanes & @as(Words, @splat(0x3f00))) >> @splat(2);
    const high = (lanes & @as(Words, @splat(0x0f0000))) >> @splat(4);
    const points: @Vector(4, Unit) = @intCast(low | middle | high);

    target[0..4].* = points;
}

fn tables_build() Tables {
    @setEvalBranchQuota(400_000);

    var result: Tables = undefined;

    for (0..pairs_count) |index| {
        result.patterns[index] = pairs_pattern(index);
    }

    for (0..triples_count) |index| {
        result.patterns[pairs_count + index] = triples_pattern(index);
    }

    for (0..mask_count) |mask| {
        result.entries[mask] = entry_of(mask);
    }

    return result;
}

fn pairs_pattern(index: u32) Bytes {
    assert(index < pairs_count);

    var result: [window_bytes]u8 = @splat(zero_lane);
    var start: u8 = 0;

    for (0..pairs_points) |point| {
        const length: u8 = 1 + @as(u8, @intCast((index >> @intCast(point)) & 1));

        result[2 * point] = start + length - 1;
        if (length == 2) result[2 * point + 1] = start;
        start += length;
    }

    assert(start <= mask_bits);

    return result;
}

fn triples_pattern(index: u32) Bytes {
    assert(index < triples_count);

    var result: [window_bytes]u8 = @splat(zero_lane);
    var digits = index;
    var start: u8 = 0;

    for (0..triples_points) |point| {
        const length: u8 = 1 + @as(u8, @intCast(digits % 3));

        digits /= 3;
        result[4 * point] = start + length - 1;
        if (length >= 2) result[4 * point + 1] = start + length - 2;
        if (length == 3) result[4 * point + 2] = start;
        start += length;
    }

    assert(digits == 0);
    assert(start <= mask_bits);

    return result;
}

fn entry_of(mask: u32) Entry {
    assert(mask < mask_count);

    var lengths: [mask_bits]u8 = undefined;
    var count: u32 = 0;
    var start: u32 = 0;

    for (0..mask_bits) |position| {
        if ((mask >> @intCast(position)) & 1 == 0) continue;

        lengths[count] = @intCast(position + 1 - start);
        count += 1;
        start = @intCast(position + 1);
    }

    const none: Entry = .{ .consumed = 0, .pattern = pattern_none };

    if (count >= pairs_points) {
        if (lengths_fit(lengths[0..pairs_points], 2)) return pairs_entry(lengths[0..pairs_points]);
    }

    if (count < triples_points) return none;
    if (!lengths_fit(lengths[0..triples_points], 3)) return none;
    return triples_entry(lengths[0..triples_points]);
}

fn lengths_fit(lengths: []const u8, length_max: u8) bool {
    assert(lengths.len <= mask_bits);
    assert(length_max <= 3);

    for (lengths) |length| {
        if (length > length_max) return false;
    }

    return true;
}

fn pairs_entry(lengths: *const [pairs_points]u8) Entry {
    assert(lengths_fit(lengths, 2));

    var pattern: u8 = 0;
    var consumed: u8 = 0;

    for (lengths, 0..) |length, point| {
        pattern |= (length - 1) << @intCast(point);
        consumed += length;
    }

    assert(pattern < pairs_count);

    return .{ .consumed = consumed, .pattern = pattern };
}

fn triples_entry(lengths: *const [triples_points]u8) Entry {
    assert(lengths_fit(lengths, 3));

    var pattern: u32 = 0;
    var consumed: u8 = 0;
    var scale: u32 = 1;

    for (lengths) |length| {
        pattern += (length - 1) * scale;
        scale *= 3;
        consumed += length;
    }

    assert(pattern < triples_count);

    return .{ .consumed = consumed, .pattern = @intCast(pairs_count + pattern) };
}

test "a step decodes the code points it consumes like the standard library" {
    if (!enabled) return error.SkipZigTest;

    var prng: std.Random.DefaultPrng = .init(0x7472616e);
    const random = prng.random();

    const limits = [_]u32{ 0x80, 0x800, 0x10000 };

    for (0..50_000) |_| {
        var text: [64]u8 = undefined;
        var expected: [64]u16 = undefined;
        var expected_count: u32 = 0;
        var length: u32 = 0;
        const limit: u21 = @intCast(limits[random.uintLessThan(u32, limits.len)]);
        const floor: u21 = if (random.boolean()) 0 else limit >> 1;

        for (0..text.len) |_| {
            if (length + 3 > text.len) break;

            const point = random.intRangeLessThan(u21, floor, limit);
            if (point >= 0xd800) {
                if (point <= 0xdfff) continue;
            }

            length += std.unicode.utf8Encode(point, text[length..]) catch unreachable;
            expected[expected_count] = @intCast(point);
            expected_count += 1;
        }

        inline for (.{ false, true }) |triples_first| {
            try step_expect(triples_first, text[0..window_bytes], expected[0..expected_count]);
        }
    }
}

fn step_expect(
    comptime triples_first: bool,
    window: *const [window_bytes]u8,
    expected: []const u16,
) !void {
    assert(expected.len > 0);
    assert(window[0] & 0xc0 != 0x80);

    var target: [16]u16 = undefined;
    const progress = step(u16, triples_first, window, &target);
    if (progress.source_count == 0) return;

    try std.testing.expect(progress.source_count <= mask_bits);
    try std.testing.expectEqualSlices(
        u16,
        expected[0..progress.target_count],
        target[0..progress.target_count],
    );

    var consumed: u32 = 0;

    for (expected[0..progress.target_count]) |point| {
        consumed += std.unicode.utf8CodepointSequenceLength(point) catch unreachable;
    }

    try std.testing.expectEqual(consumed, progress.source_count);
}
