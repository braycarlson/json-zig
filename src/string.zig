const std = @import("std");

const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Chunk = @Vector(lane_count, u8);
const Duo = @Vector(2, u32);
const Half = @Vector(16, u8);
const Mask = @Int(.unsigned, lane_count);
const Quad = @Vector(4, u32);
const Tokenizer = tokenizer_module.Tokenizer;
const Wide = @Vector(32, u8);
const cut_margin_bytes: u32 = lane_count;
const cut_search_bytes: u32 = lane_count;
const direct_slack_bytes: u32 = 2 + lane_count;
const escape_bytes_max: u32 = 2 * expansion_max;
const escape_words: [0x60]u64 = escape_words_build();
const escapes: [256]Escape = escapes_build();
const expansion_max: u32 = 6;
const group_bytes: u32 = 24;
const group_digit_lanes = [16]i32{ 2, 3, 4, 5, 8, 9, 10, 11, 14, 15, 16, 17, 20, 21, 22, 23 };
const group_enabled = lane_count >= 32;
const group_head_lanes = [8]i32{ 0, 1, 6, 7, 12, 13, 18, 19 };
const group_heads: @Vector(8, u8) = "\\u\\u\\u\\u".*;
const group_output_max: u32 = 16;
const group_pattern: Mask = if (group_enabled) 0x41041 else 0;
const group_three_lanes = [16]i32{ 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 3, 7, 11, 15 };
const group_two_lanes = [16]i32{ 0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15 };
const halves_joined = std.simd.join(lanes_low, ~lanes_low);
const halves_twice = std.simd.join(lanes_low, lanes_low);
const hexadecimal_digits = "0123456789abcdef";
const input_bytes_max = tokenizer_module.input_bytes_max;
const lane_count = tokenizer_module.lane_count;
const lanes_low = std.simd.iota(i32, 16);
const lanes_swap = std.simd.join(lanes_low + @as(@Vector(16, i32), @splat(16)), ~zeros_low);
const shift_cross: [48]u8 = shift_table_build(16);
const shift_enabled = structural.avx2_enabled and lane_count == 32;
const shift_own: [48]u8 = shift_table_build(0);
const short_bytes = "\"\\\x08\x0c\n\r\t";
const short_letters = "\"\\bfnrt";
const sysv: std.lang.CallingConvention = .{ .x86_64_sysv = .{} };
const unescape_failed: u32 = std.math.maxInt(u32);
const zeros_low: @Vector(16, i32) = @splat(0);

comptime {
    assert(lane_count == 16 or lane_count == 32);
    assert(cut_margin_bytes >= lane_count);
    assert(cut_search_bytes >= 2 * expansion_max);
    assert(short_bytes.len == short_letters.len);
    assert(escape_bytes_max == 12);
    assert(input_bytes_max < unescape_failed);
}

extern fn @"llvm.x86.avx2.pshuf.b"(table: Wide, indices: Wide) callconv(sysv) Wide;

const Decoded = struct {
    buffer: [4]u8,
    consumed: u32,
    count: u32,
};

const Escape = struct {
    length: u8,
    text: [expansion_max]u8,
};

const Lanes = struct {
    chunk: Wide,
    swapped: Wide,

    inline fn of(chunk: Wide) Lanes {
        comptime assert(shift_enabled);
        comptime assert(@sizeOf(@TypeOf(chunk)) == lane_count);

        const zero: Wide = @splat(0);

        return .{ .chunk = chunk, .swapped = @shuffle(u8, chunk, zero, lanes_swap) };
    }

    inline fn shifted(lanes: *const Lanes, count: u32) Wide {
        comptime assert(shift_enabled);
        assert(count <= lane_count);

        const own: Half = shift_own[count..][0..16].*;
        const cross: Half = shift_cross[count..][0..16].*;
        const own_indices = @shuffle(u8, own, undefined, halves_twice);
        const cross_indices = @shuffle(u8, cross, undefined, halves_twice);

        return @"llvm.x86.avx2.pshuf.b"(lanes.chunk, own_indices) |
            @"llvm.x86.avx2.pshuf.b"(lanes.swapped, cross_indices);
    }
};

const Piece = struct {
    consumed: u32,
    produced: u32,
};

const Sequence = struct {
    codepoint: u21,
    length: u32,
};

const Stops = enum {
    backslash,
    high,
    trusted,
    unicode,
};

pub const UnescapeError = error{
    Malformed,
    Overflow,
};

pub const Unquoted = struct {
    close: u32,
    high: bool,
    written: u32,
};

pub const UTF8 = enum(u2) {
    ascii,
    bmp,
    checked,
    trusted,
};

pub fn unescape(raw: []const u8, target: []u8) UnescapeError![]const u8 {
    assert(raw.len <= input_bytes_max);
    assert(target.len <= input_bytes_max);

    var source: u32 = 0;
    var written: u32 = 0;

    for (0..raw.len + 1) |_| {
        const stop = stop_find(raw, source, .backslash);
        const run = stop - source;
        if (run > target.len - written) return error.Overflow;

        @memcpy(target[written..][0..run], raw[source..stop]);
        written += run;

        if (stop == raw.len) break;

        const length = try tokenizer_module.escape_length(raw[stop..]);
        const decoded = try escape_decode(raw[stop..], length);
        if (decoded.count > target.len - written) return error.Overflow;

        @memcpy(target[written..][0..decoded.count], decoded.buffer[0..decoded.count]);
        written += decoded.count;
        source = stop + decoded.consumed;
    }

    assert(written <= raw.len);
    assert(written <= target.len);

    return target[0..written];
}

pub fn unescape_validated(window: []const u8, length: u32, target: []u8) u32 {
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    const result = unescape_wide(false, window, length, target);

    assert(result <= length);

    return result;
}

pub fn unescape_checked(window: []const u8, length: u32, target: []u8) ?u32 {
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    const result = unescape_wide(true, window, length, target);
    if (result == unescape_failed) return null;

    assert(result <= length);

    return result;
}

pub inline fn unescape_short(
    comptime lanes: comptime_int,
    window: []const u8,
    length: u32,
    target: []u8,
) ?u32 {
    comptime assert(lanes == 1 or lanes == 2);

    const span = lanes * lane_count;
    const Span = @Vector(span, u8);
    const SpanMask = @Int(.unsigned, span);

    assert(length < span);
    assert(window.len >= length + span);
    assert(target.len >= length + span);

    const chunk: Span = window[0..span].*;
    const backslashes: SpanMask = @bitCast(chunk == @as(Span, @splat('\\')));
    const below = (@as(SpanMask, 1) << @intCast(length)) - 1;
    const mask = backslashes & below;

    assert(mask != 0);

    target[0..span].* = chunk;

    var cursor: Unescaping = .{ .source = @ctz(mask), .written = @ctz(mask) };

    for (0..span) |_| {
        const slot = target[cursor.written..][0..4];
        const piece = escape_piece(true, window[cursor.source..length], slot) orelse return null;

        cursor.source += piece.consumed;
        cursor.written += piece.produced;

        if (cursor.source == length) return cursor.written;

        const rest = mask >> @intCast(cursor.source);
        const plain: Span = window[cursor.source..][0..span].*;
        const gap: u32 = if (rest == 0) length - cursor.source else @ctz(rest);

        target[cursor.written..][0..span].* = plain;
        cursor.source += gap;
        cursor.written += gap;

        if (rest == 0) return cursor.written;
    }

    unreachable;
}

pub fn unescape_bounded(raw: []const u8, target: []u8) UnescapeError![]const u8 {
    assert(raw.len <= input_bytes_max);
    assert(target.len >= raw.len);

    const cut = unescape_cut(raw) orelse return unescape(raw, target);

    assert(cut + cut_margin_bytes <= raw.len);

    const head = unescape_head(raw, cut, target) orelse return error.Malformed;
    const tail = try unescape(raw[cut..], target[head..]);
    const result = target[0 .. head + tail.len];

    assert(result.len <= raw.len);

    return result;
}

fn unescape_head(window: []const u8, cut: u32, target: []u8) ?u32 {
    assert(cut + lane_count <= window.len);
    assert(cut + lane_count <= target.len);

    var source: u32 = 0;
    var written: u32 = 0;

    for (0..cut + 1) |_| {
        if (source == cut) break;

        const chunk: Chunk = window[source..][0..lane_count].*;
        const backslashes: Mask = @bitCast(chunk == @as(Chunk, @splat('\\')));
        const mask = backslashes & lanes_below(cut - source);

        target[written..][0..lane_count].* = chunk;

        if (mask == 0) {
            const step = @min(cut - source, lane_count);

            source += step;
            written += step;

            continue;
        }

        source += @ctz(mask);
        written += @ctz(mask);

        const piece = escape_piece(true, window[source..cut], target[written..][0..4]) orelse
            return null;

        source += piece.consumed;
        written += piece.produced;
    }

    assert(source == cut);
    assert(written <= source);

    return written;
}

fn unescape_cut(raw: []const u8) ?u32 {
    assert(raw.len <= input_bytes_max);

    if (raw.len < cut_margin_bytes + cut_search_bytes + expansion_max) return null;

    const last: u32 = @intCast(raw.len - cut_margin_bytes);

    for (0..cut_search_bytes) |offset| {
        const position = last - @as(u32, @intCast(offset));

        if (cut_safe(raw, position)) {
            assert(position + cut_margin_bytes <= raw.len);

            return position;
        }
    }

    return null;
}

fn cut_safe(raw: []const u8, position: u32) bool {
    assert(position >= expansion_max);
    assert(position < raw.len);

    const before = raw[position - expansion_max ..][0..expansion_max];

    if (raw[position] != '\\') return std.mem.findScalar(u8, before[1..], '\\') == null;
    if (before[expansion_max - 1] == '\\') return false;
    if (before[0] != '\\') return true;
    if (before[1] != 'u') return true;
    if (before[2] | 0x20 != 'd') return true;

    return switch (before[3] | 0x20) {
        '8', '9', 'a', 'b' => false,
        else => true,
    };
}

pub fn unescape_quoted(window: []const u8, target: []u8) ?Unquoted {
    assert(window.len <= input_bytes_max);
    assert(target.len >= window.len + lane_count);

    var cursor: Unescaping = .{ .source = 0, .written = 0 };
    var high: Mask = 0;

    for (0..window.len + 1) |_| {
        if (window.len - cursor.source < lane_count) {
            return unescape_quoted_tail(window, target, &cursor, high != 0);
        }

        switch (unescape_quoted_chunk(window, target, &cursor, &high)) {
            .done => break,
            .failed => return null,
            .more => {},
        }
    } else unreachable;

    assert(window[cursor.source] == '"');
    assert(cursor.written <= cursor.source);

    return .{ .close = cursor.source, .high = high != 0, .written = cursor.written };
}

inline fn unescape_quoted_chunk(
    window: []const u8,
    target: []u8,
    cursor: *Unescaping,
    high: *Mask,
) UnescapeStep {
    assert(window.len - cursor.source >= lane_count);
    assert(target.len >= window.len + lane_count);

    const base = cursor.source;
    const chunk: Chunk = window[base..][0..lane_count].*;
    const quotes: Mask = @bitCast(chunk == @as(Chunk, @splat('"')));
    const backslashes: Mask = @bitCast(chunk == @as(Chunk, @splat('\\')));
    const controls: Mask = @bitCast(chunk < @as(Chunk, @splat(0x20)));

    const scanned: QuotedChunk = .{
        .base = base,
        .highs = @bitCast(chunk >= @as(Chunk, @splat(0x80))),
        .stops = quotes | backslashes | controls,
    };

    target[cursor.written..][0..lane_count].* = chunk;

    if (scanned.stops == 0) {
        high.* |= scanned.highs;
        cursor.source += lane_count;
        cursor.written += lane_count;

        return .more;
    }

    cursor.source += @ctz(scanned.stops);
    cursor.written += @ctz(scanned.stops);

    return unescape_quoted_stops(window, target, cursor, high, scanned);
}

const QuotedChunk = struct {
    base: u32,
    highs: Mask,
    stops: Mask,
};

inline fn unescape_quoted_stops(
    window: []const u8,
    target: []u8,
    cursor: *Unescaping,
    high: *Mask,
    scanned: QuotedChunk,
) UnescapeStep {
    assert(cursor.source < window.len);
    assert(target.len >= window.len + lane_count);
    assert(cursor.source - scanned.base < lane_count);
    assert(scanned.stops >> @intCast(cursor.source - scanned.base) & 1 == 1);

    for (0..lane_count) |_| {
        const offset = cursor.source - scanned.base;
        const byte = window[cursor.source];

        if (byte != '\\') {
            high.* |= scanned.highs & lanes_before(offset);

            return if (byte == '"') .done else .failed;
        }

        if (unescape_quoted_group(window, target, cursor, scanned.stops >> @intCast(offset))) {
            high.* |= scanned.highs & lanes_before(offset);

            return .more;
        }

        const slot = target[cursor.written..][0..4];
        const piece = escape_piece(true, window[cursor.source..], slot) orelse return .failed;

        cursor.source += piece.consumed;
        cursor.written += piece.produced;

        const next = cursor.source - scanned.base;

        if (next >= lane_count) {
            high.* |= scanned.highs;

            return .more;
        }

        if (window.len - cursor.source < lane_count) {
            high.* |= scanned.highs & lanes_before(next);

            return .more;
        }

        const rest = scanned.stops >> @intCast(next);
        const plain: Chunk = window[cursor.source..][0..lane_count].*;

        target[cursor.written..][0..lane_count].* = plain;

        if (rest == 0) {
            high.* |= scanned.highs;
            cursor.source += lane_count - next;
            cursor.written += lane_count - next;

            return .more;
        }

        cursor.source += @ctz(rest);
        cursor.written += @ctz(rest);
    }

    unreachable;
}

inline fn unescape_quoted_group(
    window: []const u8,
    target: []u8,
    cursor: *Unescaping,
    rest: Mask,
) bool {
    assert(window[cursor.source] == '\\');
    assert(target.len >= window.len + lane_count);
    assert(rest & 1 == 1);

    if (!group_enabled) return false;
    if (window.len - cursor.source < 2) return false;
    if (window[cursor.source + 1] != 'u') return false;

    return unicode_group_try(window, @intCast(window.len), rest, target, cursor);
}

fn unescape_quoted_tail(
    window: []const u8,
    target: []u8,
    cursor: *Unescaping,
    high: bool,
) ?Unquoted {
    assert(window.len - cursor.source < lane_count);
    assert(target.len >= window.len + lane_count);

    var seen = high;

    for (0..lane_count + 1) |_| {
        if (cursor.source == window.len) return null;

        const byte = window[cursor.source];

        if (byte == '"') {
            return .{ .close = cursor.source, .high = seen, .written = cursor.written };
        }

        if (byte == '\\') {
            const slot = target[cursor.written..][0..4];
            const piece = escape_piece(true, window[cursor.source..], slot) orelse return null;

            cursor.source += piece.consumed;
            cursor.written += piece.produced;

            continue;
        }

        if (byte < 0x20) return null;

        seen = seen or byte >= 0x80;
        target[cursor.written] = byte;
        cursor.source += 1;
        cursor.written += 1;
    }

    unreachable;
}

inline fn unescape_wide(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
) u32 {
    assert(length <= window.len);
    assert(window.len <= input_bytes_max);
    assert(target.len >= length + lane_count);

    var cursor: Unescaping = .{ .source = 0, .written = 0 };

    if (window.len >= lane_count) {
        if (!unescape_lanes(checked, window, length, target, &cursor)) return unescape_failed;
    }

    if (cursor.source != length) {
        if (!unescape_tail(checked, window[0..length], target, &cursor)) return unescape_failed;
    }

    assert(cursor.source == length);
    assert(cursor.written <= length);

    return cursor.written;
}

inline fn unescape_lanes(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
    cursor: *Unescaping,
) bool {
    assert(window.len >= lane_count);
    assert(target.len >= length + lane_count);

    const lane_last = window.len - lane_count;

    var wide: UnescapingWide = .{ .source = cursor.source, .written = cursor.written };
    defer cursor.* = .{ .source = @intCast(wide.source), .written = @intCast(wide.written) };

    for (0..length + 1) |_| {
        if (wide.source > lane_last) break;

        const base = wide.source;
        const chunk: Chunk = window[base..][0..lane_count].*;
        const backslashes: Mask = @bitCast(chunk == @as(Chunk, @splat('\\')));
        const offset: u32 = @ctz(backslashes);
        const remaining = length - base;

        target[wide.written..][0..lane_count].* = chunk;

        if (offset >= remaining) {
            wide.source = length;
            wide.written += remaining;

            break;
        }

        if (backslashes == 0) {
            wide.source = base + lane_count;
            wide.written += lane_count;

            switch (unescape_clean(checked, window, length, target, &wide)) {
                .done => break,
                .failed => return false,
                .more => continue,
            }
        }

        wide.source = base + offset;
        wide.written += offset;

        const lane: Lane = .{ .backslashes = backslashes, .base = @intCast(base) };

        switch (unescape_lane_escapes(checked, window, length, target, &wide, lane)) {
            .done => break,
            .failed => return false,
            .more => {},
        }
    }

    return true;
}

inline fn unescape_clean(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
    wide: *UnescapingWide,
) UnescapeStep {
    assert(wide.written <= wide.source);
    assert(wide.source <= length);
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    for (0..length + 1) |_| {
        if (length - wide.source < 2 * lane_count) return .more;

        const base = wide.source;
        const first: Chunk = window[base..][0..lane_count].*;
        const second: Chunk = window[base + lane_count ..][0..lane_count].*;
        const mask_first: Mask = @bitCast(first == @as(Chunk, @splat('\\')));
        const mask_second: Mask = @bitCast(second == @as(Chunk, @splat('\\')));
        const mask = @as(u64, mask_second) << lane_count | mask_first;

        target[wide.written..][0..lane_count].* = first;
        target[wide.written + lane_count ..][0..lane_count].* = second;

        if (mask != 0) {
            const offset: u32 = @ctz(mask);
            const stop = base + offset;

            if (length - stop >= 2) {
                const byte = escape_bytes[window[stop + 1]];

                if (byte != 0) {
                    target[wide.written + offset] = byte;
                    wide.source = stop + 2;
                    wide.written += offset + 1;

                    continue;
                }
            }

            const lane_offset = offset & lane_count;
            const lane_base: u32 = @intCast(base + lane_offset);
            const backslashes: Mask = @truncate(mask >> @intCast(lane_offset));
            const lane: Lane = .{ .backslashes = backslashes, .base = lane_base };

            wide.source = base + offset;
            wide.written += offset;

            return unescape_lane_escapes(checked, window, length, target, wide, lane);
        }

        wide.source = base + 2 * lane_count;
        wide.written += 2 * lane_count;
    }

    unreachable;
}

inline fn unescape_lane_escapes(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
    wide: *UnescapingWide,
    lane: Lane,
) UnescapeStep {
    assert(wide.source < length);
    assert(wide.source - lane.base < lane_count);
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    for (0..lane_count) |_| {
        const rest = lane.backslashes >> @intCast(wide.source - lane.base);
        if (!unescape_lane_escape(checked, window, length, target, wide, rest)) return .failed;

        const passed = wide.source - lane.base;
        if (passed >= lane_count) return .more;
        if (window.len - wide.source < lane_count) return .more;

        const following = lane.backslashes >> @intCast(passed);
        const plain: Chunk = window[wide.source..][0..lane_count].*;
        const gap = if (following == 0) lane_count - passed else @ctz(following);
        const remaining = length - wide.source;

        target[wide.written..][0..lane_count].* = plain;

        if (gap >= remaining) {
            wide.source = length;
            wide.written += remaining;

            return .done;
        }

        wide.source += gap;
        wide.written += gap;

        if (following == 0) return .more;
    }

    unreachable;
}

inline fn unescape_lane_escape(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
    wide: *UnescapingWide,
    rest: Mask,
) bool {
    assert(wide.source < length);
    assert(window[wide.source] == '\\');
    assert(target.len >= length + lane_count);
    assert(rest & 1 == 1);

    if (checked) if (length - wide.source < 2) return false;

    const letter = window[wide.source + 1];
    if (letter == 'u') return unescape_lane_unicode(checked, window, length, target, wide, rest);

    const byte = escape_bytes[letter];
    if (checked) if (byte == 0) return false;

    target[wide.written] = byte;
    wide.source += 2;
    wide.written += 1;

    return true;
}

inline fn unescape_lane_unicode(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
    wide: *UnescapingWide,
    rest: Mask,
) bool {
    assert(wide.source < length);
    assert(window[wide.source + 1] == 'u');
    assert(target.len >= length + lane_count);
    assert(rest & 1 == 1);

    if (group_enabled) {
        var cursor: Unescaping = .{
            .source = @intCast(wide.source),
            .written = @intCast(wide.written),
        };

        if (unicode_group_try(window, length, rest, target, &cursor)) {
            wide.* = .{ .source = cursor.source, .written = cursor.written };

            return true;
        }
    }

    const slot = target[wide.written..][0..4];

    const piece = if (checked)
        unicode_piece_checked(window[wide.source..length], slot) orelse return false
    else
        escape_decode_validated(window[wide.source..length], slot);

    wide.source += piece.consumed;
    wide.written += piece.produced;

    return true;
}

const Lane = struct {
    backslashes: Mask,
    base: u32,
};

const Unescaping = struct {
    source: u32,
    written: u32,
};

const UnescapingWide = struct {
    source: usize,
    written: usize,
};

fn unescape_tail(comptime checked: bool, raw: []const u8, target: []u8, cursor: *Unescaping) bool {
    assert(cursor.source < raw.len);
    assert(target.len >= raw.len);

    for (0..raw.len + 1) |_| {
        const source = cursor.source;
        if (source == raw.len) return true;

        const found = std.mem.findScalarPos(u8, raw, source, '\\');
        const stop: u32 = @intCast(found orelse raw.len);

        @memcpy(target[cursor.written..][0 .. stop - source], raw[source..stop]);
        cursor.written += stop - source;
        cursor.source = stop;

        if (stop == raw.len) return true;

        const slot = target[cursor.written..][0..4];
        const piece = escape_piece(checked, raw[stop..], slot) orelse return false;

        cursor.source += piece.consumed;
        cursor.written += piece.produced;
    }

    unreachable;
}

const UnescapeStep = enum {
    done,
    failed,
    more,
};

inline fn unicode_group_try(
    window: []const u8,
    length: u32,
    rest: Mask,
    target: []u8,
    cursor: *Unescaping,
) bool {
    assert(cursor.source < length);
    assert(length <= window.len);
    assert(target.len >= length + lane_count);
    assert(rest & 1 == 1);

    if (rest & group_pattern != group_pattern) return false;

    return unicode_group_run(window, length, target, cursor);
}

inline fn unicode_group_run(
    window: []const u8,
    length: u32,
    target: []u8,
    cursor: *Unescaping,
) bool {
    assert(cursor.source < length);
    assert(window[cursor.source] == '\\');
    assert(target.len >= length + lane_count);

    const source_start = cursor.source;

    for (0..@divFloor(length, group_bytes) + 1) |_| {
        if (length - cursor.source < group_bytes) break;
        if (window.len - cursor.source < lane_count) break;

        const text = window[cursor.source..][0..lane_count];
        const slot = target[cursor.written..][0..group_output_max];
        const produced = unicode_group(text, slot);
        if (produced == 0) break;

        assert(produced < group_bytes);
        assert(produced >= 8);

        cursor.source += group_bytes;
        cursor.written += produced;
    }

    return cursor.source != source_start;
}

inline fn unicode_group(text: *const [lane_count]u8, target: *[group_output_max]u8) u32 {
    assert(lane_count >= group_bytes);
    assert(group_output_max < group_bytes);

    const bytes: Chunk = text.*;
    const heads: @Vector(8, u8) = @shuffle(u8, bytes, undefined, group_head_lanes);
    if (!@reduce(.And, heads == group_heads)) return 0;

    const digits: Half = @shuffle(u8, bytes, undefined, group_digit_lanes);
    const lower = digits | @as(Half, @splat(0x20));
    const decimal: u16 = @bitCast(digits -% @as(Half, @splat('0')) < @as(Half, @splat(10)));
    const letter: u16 = @bitCast(lower -% @as(Half, @splat('a')) < @as(Half, @splat(6)));
    if (decimal | letter != std.math.maxInt(u16)) return 0;

    const letter_bonus = (digits >> @splat(6)) * @as(Half, @splat(9));
    const nibbles = (digits & @as(Half, @splat(0x0f))) + letter_bonus;
    const nibble_lanes: @Vector(8, u16) = @bitCast(nibbles);
    const byte_low: @Vector(8, u16) = @splat(0xff);
    const pairs = (nibble_lanes & byte_low) << @splat(4) | nibble_lanes >> @splat(8);
    const pair_lanes: Quad = @bitCast(pairs);
    const units = (pair_lanes & @as(Quad, @splat(0xffff))) << @splat(8) | pair_lanes >> @splat(16);

    const surrogates = units & @as(Quad, @splat(0xf800)) == @as(Quad, @splat(0xd800));
    if (@reduce(.Or, surrogates)) return group_pairs(units, target);

    return group_encode(units, target);
}

inline fn group_pairs(units: Quad, target: *[group_output_max]u8) u32 {
    assert(@reduce(.And, units <= @as(Quad, @splat(0xffff))));
    assert(@reduce(.Or, units & @as(Quad, @splat(0xf800)) == @as(Quad, @splat(0xd800))));

    const high: Duo = @shuffle(u32, units, undefined, [2]i32{ 0, 2 });
    const low: Duo = @shuffle(u32, units, undefined, [2]i32{ 1, 3 });
    const ten_bits: Duo = @splat(0xfc00);

    if (!@reduce(.And, high & ten_bits == @as(Duo, @splat(0xd800)))) return 0;
    if (!@reduce(.And, low & ten_bits == @as(Duo, @splat(0xdc00)))) return 0;

    const high_bits = high - @as(Duo, @splat(0xd800));
    const low_bits = low - @as(Duo, @splat(0xdc00));
    const codepoints = (high_bits << @splat(10) | low_bits) + @as(Duo, @splat(0x10000));
    const six_bits: Duo = @splat(0x3f);
    const continuation: Duo = @splat(0x80);
    const first = codepoints >> @splat(18) | @as(Duo, @splat(0xf0));
    const second = (codepoints >> @splat(12)) & six_bits | continuation;
    const third = (codepoints >> @splat(6)) & six_bits | continuation;
    const fourth = codepoints & six_bits | continuation;
    const words = first | second << @splat(8) | third << @splat(16) | fourth << @splat(24);
    const lanes: Quad = @shuffle(u32, words, @as(Duo, @splat(0)), [4]i32{ 0, 1, -1, -1 });

    target.* = @bitCast(lanes);

    return 8;
}

inline fn group_encode(units: Quad, target: *[group_output_max]u8) u32 {
    assert(@reduce(.And, units <= @as(Quad, @splat(0xffff))));
    assert(!@reduce(.Or, units & @as(Quad, @splat(0xf800)) == @as(Quad, @splat(0xd800))));

    const six_bits: Quad = @splat(0x3f);
    const continuation: Quad = @splat(0x80);
    const tail = units & six_bits | continuation;

    if (@reduce(.And, units >= @as(Quad, @splat(0x800)))) {
        const lead = units >> @splat(12) | @as(Quad, @splat(0xe0));
        const middle = (units >> @splat(6)) & six_bits | continuation;
        const words: Half = @bitCast(lead | middle << @splat(8) | tail << @splat(16));

        target.* = @shuffle(u8, words, undefined, group_three_lanes);

        return 12;
    }

    const two_bytes = units -% @as(Quad, @splat(0x80)) < @as(Quad, @splat(0x800 - 0x80));

    if (@reduce(.And, two_bytes)) {
        const lead = units >> @splat(6) | @as(Quad, @splat(0xc0));
        const words: Half = @bitCast(lead | tail << @splat(8));

        target.* = @shuffle(u8, words, undefined, group_two_lanes);

        return 8;
    }

    return 0;
}

inline fn escape_piece(comptime checked: bool, text: []const u8, target: *[4]u8) ?Piece {
    assert(text.len > 0);
    assert(text[0] == '\\');

    if (!checked) return escape_decode_validated(text, target);
    if (text.len < 2) return null;
    if (text[1] == 'u') return unicode_piece_checked(text, target);

    const byte = escape_bytes[text[1]];
    if (byte == 0) return null;

    target[0] = byte;

    return .{ .consumed = 2, .produced = 1 };
}

pub inline fn unicode_piece_checked(text: []const u8, target: *[4]u8) ?Piece {
    assert(text.len >= 2);
    assert(text[1] == 'u');

    if (text.len < 6) return null;

    const high = hex_checked(text[2..6]) orelse return null;

    if (high & 0xf800 != 0xd800) {
        return .{ .consumed = 6, .produced = utf8_bmp_write(high, target) };
    }

    if (high > 0xdbff) return null;
    if (text.len < 12) return null;
    if (text[6] != '\\') return null;
    if (text[7] != 'u') return null;

    const low = hex_checked(text[8..12]) orelse return null;
    if (low & 0xfc00 != 0xdc00) return null;

    assert(high >= 0xd800);
    assert(low >= 0xdc00);

    const codepoint = 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);

    return .{ .consumed = 12, .produced = utf8_write(codepoint, target) };
}

inline fn hex_checked(digits: *const [4]u8) ?u16 {
    const value = hex_shifted[0][digits[0]] |
        hex_shifted[1][digits[1]] |
        hex_shifted[2][digits[2]] |
        hex_shifted[3][digits[3]];

    if (value > std.math.maxInt(u16)) return null;

    assert(value >> 12 == hex_shifted[0][digits[0]] >> 12);

    return @intCast(value);
}

inline fn utf8_bmp_write(codepoint: u32, target: *[4]u8) u32 {
    assert(codepoint <= 0xffff);
    assert(codepoint < 0xd800 or codepoint > 0xdfff);

    if (codepoint < 0x80) {
        target[0] = @intCast(codepoint);

        return 1;
    }

    const tail = 0x80 | (codepoint & 0x3f);

    if (codepoint < 0x800) {
        std.mem.writeInt(u16, target[0..2], @intCast((0xc0 | codepoint >> 6) | tail << 8), .little);

        return 2;
    }

    const middle = 0x80 | ((codepoint >> 6) & 0x3f);
    const word = (0xe0 | codepoint >> 12) | middle << 8 | tail << 16;

    std.mem.writeInt(u32, target, word, .little);

    return 3;
}

const hex_shifted: [4][256]u32 = tables: {
    var tables: [4][256]u32 = @splat(@splat(std.math.maxInt(u32)));

    for (&tables, 0..) |*table, position| {
        const shift = 4 * (3 - position);

        for ("0123456789abcdef", 0..) |byte, value| table[byte] = value << shift;
        for ("ABCDEF", 10..) |byte, value| table[byte] = value << shift;
    }

    break :tables tables;
};

inline fn lanes_below(remaining: u32) Mask {
    assert(remaining > 0);
    assert(remaining <= input_bytes_max);

    const count: u32 = @min(remaining, lane_count);

    return @truncate((@as(u64, 1) << @intCast(count)) - 1);
}

inline fn lanes_before(count: u32) Mask {
    assert(count <= lane_count);
    assert(lane_count < 64);

    return @truncate((@as(u64, 1) << @intCast(count)) - 1);
}

inline fn escape_decode_validated(text: []const u8, target: *[4]u8) Piece {
    assert(text.len >= 2);
    assert(text[0] == '\\');

    if (text[1] != 'u') {
        target[0] = escape_bytes[text[1]];

        return .{ .consumed = 2, .produced = 1 };
    }

    const high = hex_value(text[2..6]);

    if (high < 0xd800) return .{ .consumed = 6, .produced = utf8_write(high, target) };
    if (high > 0xdbff) return .{ .consumed = 6, .produced = utf8_write(high, target) };

    const low = hex_value(text[8..12]);
    const codepoint = 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);

    return .{ .consumed = 12, .produced = utf8_write(codepoint, target) };
}

inline fn utf8_write(codepoint: u21, target: *[4]u8) u32 {
    assert(codepoint <= 0x10ffff);
    assert(codepoint < 0xd800 or codepoint > 0xdfff);

    if (codepoint < 0x80) {
        target[0] = @intCast(codepoint);

        return 1;
    }

    if (codepoint < 0x800) {
        target[0] = @intCast(0xc0 | (codepoint >> 6));
        target[1] = @intCast(0x80 | (codepoint & 0x3f));

        return 2;
    }

    if (codepoint < 0x10000) {
        target[0] = @intCast(0xe0 | (codepoint >> 12));
        target[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        target[2] = @intCast(0x80 | (codepoint & 0x3f));

        return 3;
    }

    target[0] = @intCast(0xf0 | (codepoint >> 18));
    target[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
    target[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
    target[3] = @intCast(0x80 | (codepoint & 0x3f));

    return 4;
}

inline fn hex_value(digits: *const [4]u8) u16 {
    var result: u16 = 0;

    inline for (digits) |digit| {
        assert(std.ascii.isHex(digit));

        result = result << 4 | ((digit & 0x0f) + 9 * (digit >> 6));
    }

    return result;
}

const escape_bytes: [256]u8 = table: {
    var table: [256]u8 = @splat(0);

    for (short_letters, short_bytes) |letter, byte| table[letter] = byte;

    table['/'] = '/';

    break :table table;
};

pub fn escape_decode(text: []const u8, length: u32) error{Malformed}!Decoded {
    assert(length == 2 or length == 6 or length == 12);
    assert(text.len >= length);

    var decoded: Decoded = .{ .buffer = undefined, .consumed = length, .count = 1 };

    if (length == 2) {
        decoded.buffer[0] = switch (text[1]) {
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => text[1],
        };

        return decoded;
    }

    const high = try tokenizer_module.code_unit_of(text);
    var codepoint: u21 = high;

    if (length == 12) {
        const low = try tokenizer_module.code_unit_of(text[6..]);

        codepoint = 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);
    }

    const count = std.unicode.utf8Encode(codepoint, &decoded.buffer) catch return error.Malformed;

    decoded.count = count;

    assert(decoded.count <= decoded.buffer.len);
    assert(decoded.count <= decoded.consumed);

    return decoded;
}

pub inline fn escape_write(
    sink: *std.Io.Writer,
    text: []const u8,
    utf8: UTF8,
) std.Io.Writer.Error!void {
    assert(text.len <= input_bytes_max);
    assert(sink.end <= sink.buffer.len);

    switch (utf8) {
        inline else => |policy| {
            const room = expansion_max * text.len + direct_slack_bytes;
            const stops = comptime stops_of(policy);

            if (sink.unusedCapacityLen() >= room) {
                const target = sink.unusedCapacitySlice();
                const written = if (policy == .trusted)
                    escape_trusted(target, text, 0)
                else
                    escape_direct(target, text, policy, stops);

                sink.advance(written);
            } else {
                try escape_streamed(sink, text, policy, stops);
            }
        },
    }
}

pub inline fn escaped_write(
    sink: *std.Io.Writer,
    escaped: []const u8,
    utf8: UTF8,
) std.Io.Writer.Error!void {
    assert(escaped.len <= input_bytes_max);
    assert(sink.end <= sink.buffer.len);

    switch (utf8) {
        .ascii => try escape_streamed(sink, escaped, .ascii, .high),
        .bmp => try escape_streamed(sink, escaped, .bmp, .high),
        .checked, .trusted => try sink.writeAll(escaped),
    }
}

pub inline fn trusted_room(length: u64) u64 {
    assert(length <= input_bytes_max);
    assert(expansion_max == 6);

    return expansion_max * length + direct_slack_bytes;
}

pub inline fn trusted_write(target: []u8, text: []const u8) u32 {
    assert(text.len <= input_bytes_max);
    assert(target.len >= trusted_room(text.len));

    const result = result: {
        if (text.len < 16) break :result trusted_short(target, text);
        if (text.len >= lane_count) break :result trusted_long(target, text);

        const head: @Vector(16, u8) = text[0..16].*;
        const tail: @Vector(16, u8) = text[text.len - 16 ..][0..16].*;

        target[0..16].* = head;
        target[text.len - 16 ..][0..16].* = tail;

        if (stop_mask(16, &head, .trusted) | stop_mask(16, &tail, .trusted) != 0) {
            break :result escape_trusted(target, text, 0);
        }

        break :result @as(u32, @intCast(text.len));
    };

    assert(result >= text.len);

    return result;
}

inline fn trusted_short(target: []u8, text: []const u8) u32 {
    assert(text.len < 16);
    assert(target.len >= trusted_room(text.len));

    const result = result: {
        var stops: u64 = 0;

        if (text.len >= 8) {
            const head = std.mem.readInt(u64, text[0..8], .little);
            const tail = std.mem.readInt(u64, text[text.len - 8 ..][0..8], .little);

            target[0..8].* = text[0..8].*;
            target[text.len - 8 ..][0..8].* = text[text.len - 8 ..][0..8].*;
            stops = word_stops(head) | word_stops(tail);
        } else if (text.len >= 4) {
            const head: u64 = std.mem.readInt(u32, text[0..4], .little);
            const tail: u64 = std.mem.readInt(u32, text[text.len - 4 ..][0..4], .little);

            target[0..4].* = text[0..4].*;
            target[text.len - 4 ..][0..4].* = text[text.len - 4 ..][0..4].*;
            stops = word_stops(head | tail << 32);
        } else if (text.len > 0) {
            const middle = text.len >> 1;
            const filler: u64 = 0x6161_6161_6100_0000;
            const word = filler | @as(u64, text[0]) | @as(u64, text[middle]) << 8 |
                @as(u64, text[text.len - 1]) << 16;

            target[0] = text[0];
            target[middle] = text[middle];
            target[text.len - 1] = text[text.len - 1];
            stops = word_stops(word);
        } else {
            break :result 0;
        }

        if (stops != 0) break :result escape_trusted(target, text, 0);

        break :result @as(u32, @intCast(text.len));
    };

    assert(result >= text.len);

    return result;
}

noinline fn trusted_long(target: []u8, text: []const u8) u32 {
    assert(text.len >= lane_count);
    assert(target.len >= trusted_room(text.len));

    var index: usize = 0;
    var stopped = false;

    for (0..@divFloor(text.len, lane_count)) |_| {
        const chunk: Chunk = text[index..][0..lane_count].*;

        target[index..][0..lane_count].* = chunk;
        stopped = stop_mask(lane_count, &chunk, .trusted) != 0;

        if (stopped) break;

        index += lane_count;
    }

    if (!stopped) {
        if (index != text.len) {
            const lane_last = text.len - lane_count;
            const tail: Chunk = text[lane_last..][0..lane_count].*;

            target[lane_last..][0..lane_count].* = tail;
            stopped = stop_mask(lane_count, &tail, .trusted) != 0;
        }
    }

    var result: u32 = @intCast(text.len);

    if (stopped) result = escape_trusted(target, text, @intCast(index));

    assert(result >= text.len);

    return result;
}

fn word_stops(word: u64) u64 {
    assert(@sizeOf(u64) == 8);
    assert(lane_count >= @sizeOf(u64));

    const ones: u64 = 0x0101_0101_0101_0101;
    const highs: u64 = 0x8080_8080_8080_8080;
    const control = (word -% ones *% 0x20) & ~word;
    const quote = word ^ (ones *% '"');
    const backslash = word ^ (ones *% '\\');
    const quote_zero = (quote -% ones) & ~quote;
    const backslash_zero = (backslash -% ones) & ~backslash;

    return (control | quote_zero | backslash_zero) & highs;
}

pub fn escape_free(text: []const u8) bool {
    assert(text.len <= input_bytes_max);

    const stop = stop_find(text, 0, .trusted);

    assert(stop <= text.len);

    return stop == text.len;
}

pub fn backslash_free(text: []const u8) bool {
    assert(text.len <= input_bytes_max);

    const stop = stop_find(text, 0, .backslash);

    assert(stop <= text.len);

    return stop == text.len;
}

pub fn verbatim_is(comptime text: []const u8) bool {
    comptime assert(text.len <= input_bytes_max);
    comptime assert(escapes[0x80].length == expansion_max);

    for (text) |byte| {
        if (escapes[byte].length != 0) return false;
    }

    return true;
}

const escape_direct = if (structural.functions_aligned)
    escape_direct_aligned
else
    escape_direct_unaligned;

noinline fn escape_direct_aligned(
    target: []u8,
    text: []const u8,
    comptime utf8: UTF8,
    comptime stops: Stops,
) align(64) u32 {
    assert(text.len <= input_bytes_max);
    assert(target.len >= expansion_max * text.len + direct_slack_bytes);

    return escape_direct_body(target, text, utf8, stops);
}

noinline fn escape_direct_unaligned(
    target: []u8,
    text: []const u8,
    comptime utf8: UTF8,
    comptime stops: Stops,
) u32 {
    assert(text.len <= input_bytes_max);
    assert(target.len >= expansion_max * text.len + direct_slack_bytes);

    return escape_direct_body(target, text, utf8, stops);
}

inline fn escape_direct_body(
    target: []u8,
    text: []const u8,
    comptime utf8: UTF8,
    comptime stops: Stops,
) u32 {
    assert(text.len <= input_bytes_max);
    assert(target.len >= expansion_max * text.len + direct_slack_bytes);

    var source: u32 = 0;
    var written: u32 = 0;

    for (0..text.len + 1) |_| {
        if (source == text.len) break;

        const mask = chunk_scan(target[written..], text[source..], stops);

        if (mask == 0) {
            const step = @min(text.len - source, lane_count);

            source += step;
            written += step;

            continue;
        }

        const offset: u32 = @ctz(mask);
        const run = special_run(target[written + offset ..], text, source + offset, utf8);

        source += offset + run.consumed;
        written += offset + run.produced;
    }

    assert(source == text.len);
    assert(written >= text.len);
    assert(written <= expansion_max * text.len);

    return written;
}

const escape_trusted = if (shift_enabled) escape_shifted else escape_trusted_direct;

inline fn escape_trusted_direct(target: []u8, text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(target.len >= trusted_room(text.len));

    const result = start + escape_direct(target[start..], text[start..], .trusted, .trusted);

    assert(result >= text.len);

    return result;
}

noinline fn escape_shifted(target: []u8, text: []const u8, start: u32) align(64) u32 {
    comptime assert(shift_enabled);
    assert(start <= text.len);
    assert(target.len >= trusted_room(text.len));

    var source = start;
    var written = start;

    for (0..@divFloor(text.len, lane_count) + 1) |_| {
        if (text.len - source < lane_count) break;

        const chunk: Wide = text[source..][0..lane_count].*;
        const stops = stop_mask(lane_count, &chunk, .trusted);

        target[written..][0..lane_count].* = chunk;

        if (stops != 0) {
            const lanes: Lanes = .of(chunk);

            written += specials_write(target[written..], text[source..], &lanes, stops);
        }

        source += lane_count;
        written += lane_count;
    }

    if (source == text.len) return written;

    const done: Piece = .{ .consumed = source, .produced = written };

    if (text.len >= lane_count) return tail_write(target, text, done);

    assert(source == 0);

    return short_write(target, text);
}

inline fn tail_write(target: []u8, text: []const u8, done: Piece) u32 {
    comptime assert(shift_enabled);
    assert(target.len >= trusted_room(text.len));
    assert(text.len >= lane_count);
    assert(done.consumed < text.len);
    assert(text.len - done.consumed < lane_count);

    const base: u32 = @intCast(text.len - lane_count);
    const skip = done.consumed - base;
    const fresh = ~@as(Mask, 0) << @intCast(skip);
    const lanes: Lanes = .of(text[base..][0..lane_count].*);
    const stops = stop_mask(lane_count, &lanes.chunk, .trusted) & fresh;
    const origin = target[done.produced - skip ..];

    target[done.produced..][0..lane_count].* = lanes.shifted(skip);

    const growth = if (stops == 0) 0 else specials_write(origin, text[base..], &lanes, stops);
    const result = done.produced + lane_count - skip + growth;

    assert(result >= text.len);
    assert(result <= expansion_max * text.len);

    return result;
}

inline fn short_write(target: []u8, text: []const u8) u32 {
    comptime assert(shift_enabled);
    assert(target.len >= trusted_room(text.len));
    assert(text.len > 0);
    assert(text.len < lane_count);

    const lanes: Lanes = .of(chunk_short(text));
    const valid = (@as(Mask, 1) << @intCast(text.len)) - 1;
    const stops = stop_mask(lane_count, &lanes.chunk, .trusted) & valid;

    target[0..lane_count].* = lanes.chunk;

    const growth = if (stops == 0) 0 else specials_write(target, text, &lanes, stops);
    const result: u32 = @intCast(text.len + growth);

    assert(result >= text.len);
    assert(result <= expansion_max * text.len);

    return result;
}

inline fn specials_write(target: []u8, bytes: []const u8, lanes: *const Lanes, stops: Mask) u32 {
    comptime assert(shift_enabled);
    assert(target.len >= 2 * lane_count - @clz(stops));
    assert(stops != 0);
    assert(bytes.len >= lane_count - @clz(stops));

    var remaining = stops;
    var growth: u32 = 0;

    for (0..lane_count) |_| {
        const position: u32 = @ctz(remaining);
        const word = escape_words[bytes[position]];
        const length: u32 = @intCast(word >> 56);
        const at = position + growth;

        assert(length >= 2);

        std.mem.writeInt(u64, target[at..][0..8], word, .little);
        target[at + length ..][0..lane_count].* = lanes.shifted(position + 1);
        growth += length - 1;
        remaining &= remaining - 1;

        if (remaining == 0) break;
    }

    assert(growth >= @popCount(stops));
    assert(growth <= (expansion_max - 1) * @popCount(stops));

    return growth;
}

inline fn chunk_short(text: []const u8) Wide {
    comptime assert(shift_enabled);
    assert(text.len > 0);
    assert(text.len < lane_count);

    if (text.len < 16) {
        const words = words_short(text);
        const quad: @Vector(4, u64) = .{ words[0], words[1], 0, 0 };

        return @bitCast(quad);
    }

    const head: Half = text[0..16].*;
    const tail: Half = text[text.len - 16 ..][0..16].*;
    const own: Half = shift_own[lane_count - text.len ..][0..16].*;
    const identity: Half = shift_own[0..16].*;
    const pair = @shuffle(u8, head, tail, halves_joined);
    const indices = @shuffle(u8, identity, own, halves_joined);

    return @"llvm.x86.avx2.pshuf.b"(pair, indices);
}

inline fn words_short(text: []const u8) [2]u64 {
    assert(text.len > 0);
    assert(text.len < 16);

    if (text.len >= 8) {
        const head = std.mem.readInt(u64, text[0..8], .little);
        const tail = std.mem.readInt(u64, text[text.len - 8 ..][0..8], .little);
        const dropped: u6 = @intCast(8 * (15 - text.len));

        return .{ head, tail >> 8 >> dropped };
    }

    if (text.len >= 4) {
        const head: u64 = std.mem.readInt(u32, text[0..4], .little);
        const tail: u64 = std.mem.readInt(u32, text[text.len - 4 ..][0..4], .little);
        const dropped: u6 = @intCast(8 * (8 - text.len));

        return .{ head | tail >> dropped << 32, 0 };
    }

    const middle = text.len >> 1;

    const word = @as(u64, text[0]) | @as(u64, text[middle]) << @intCast(8 * middle) |
        @as(u64, text[text.len - 1]) << @intCast(8 * (text.len - 1));

    return .{ word, 0 };
}

noinline fn escape_streamed(
    sink: *std.Io.Writer,
    text: []const u8,
    comptime utf8: UTF8,
    comptime stops: Stops,
) std.Io.Writer.Error!void {
    assert(text.len <= input_bytes_max);
    assert(sink.end <= sink.buffer.len);

    var scratch: [escape_bytes_max]u8 = undefined;
    var clean: u32 = 0;
    var source: u32 = 0;

    for (0..text.len + 1) |_| {
        const stop = stop_find(text, source, stops);
        if (stop == text.len) break;

        const piece = special_encode(text, stop, utf8, &scratch);

        source = stop + piece.consumed;

        if (piece.consumed == piece.produced) continue;

        try sink.writeAll(text[clean..stop]);
        try sink.writeAll(scratch[0..piece.produced]);

        clean = source;
    }

    try sink.writeAll(text[clean..]);
}

fn special_run(target: []u8, text: []const u8, index: u32, comptime utf8: UTF8) Piece {
    assert(index < text.len);
    assert(target.len >= expansion_max * (text.len - index));

    if (utf8 == .trusted) return special_encode(text, index, utf8, target[0..escape_bytes_max]);

    var run: Piece = .{ .consumed = 0, .produced = 0 };

    for (0..text.len - index) |_| {
        const escape_target = target[run.produced..][0..escape_bytes_max];
        const piece = special_encode(text, index + run.consumed, utf8, escape_target);

        run.consumed += piece.consumed;
        run.produced += piece.produced;

        if (index + run.consumed == text.len) break;
        if (escapes[text[index + run.consumed]].length == 0) break;
    }

    assert(run.consumed > 0);
    assert(index + run.consumed <= text.len);

    return run;
}

fn special_encode(
    text: []const u8,
    index: u32,
    comptime utf8: UTF8,
    target: *[escape_bytes_max]u8,
) Piece {
    assert(index < text.len);
    assert(text.len <= input_bytes_max);

    const byte = text[index];

    if (utf8 != .trusted) {
        if (byte >= 0x80) return sequence_encode(text, index, utf8, target);
    }

    const escape = &escapes[byte];

    assert(escape.length >= 2);

    target[0..expansion_max].* = escape.text;

    return .{ .consumed = 1, .produced = escape.length };
}

fn sequence_encode(
    text: []const u8,
    index: u32,
    comptime utf8: UTF8,
    target: *[escape_bytes_max]u8,
) Piece {
    comptime assert(utf8 != .trusted);
    assert(index < text.len);
    assert(text[index] >= 0x80);

    const sequence = sequence_of(text, index);

    if (sequence.length == 0) {
        target[0..expansion_max].* = escapes[text[index]].text;

        return .{ .consumed = 1, .produced = expansion_max };
    }

    const escaped = switch (utf8) {
        .ascii => true,
        .bmp => sequence.length == 4,
        .checked => false,
        .trusted => unreachable,
    };

    if (!escaped) {
        const last = sequence.length - 2;
        target[0..2].* = text[index..][0..2].*;
        target[last..][0..2].* = text[index + last ..][0..2].*;

        return .{ .consumed = sequence.length, .produced = sequence.length };
    }

    if (sequence.length == 4) {
        surrogates_write(sequence.codepoint, target);

        return .{ .consumed = 4, .produced = escape_bytes_max };
    }

    code_unit_write(@intCast(sequence.codepoint), target[0..expansion_max]);

    return .{ .consumed = sequence.length, .produced = expansion_max };
}

fn sequence_of(text: []const u8, index: u32) Sequence {
    assert(index < text.len);
    assert(text[index] >= 0x80);

    const invalid: Sequence = .{ .codepoint = 0, .length = 0 };
    const lead = text[index];
    if (lead < 0xc2) return invalid;
    if (lead > 0xf4) return invalid;

    const length: u32 = if (lead >= 0xf0) 4 else if (lead >= 0xe0) 3 else 2;
    if (length > text.len - index) return invalid;

    const second = text[index + 1];

    const second_min: u8 = switch (lead) {
        0xe0 => 0xa0,
        0xf0 => 0x90,
        else => 0x80,
    };

    const second_max: u8 = switch (lead) {
        0xed => 0x9f,
        0xf4 => 0x8f,
        else => 0xbf,
    };

    if (second < second_min) return invalid;
    if (second > second_max) return invalid;

    var codepoint: u21 = lead & (@as(u8, 0x7f) >> @intCast(length));
    codepoint = codepoint << 6 | (second & 0x3f);

    for (text[index + 2 ..][0 .. length - 2]) |byte| {
        if (byte & 0xc0 != 0x80) return invalid;

        codepoint = codepoint << 6 | (byte & 0x3f);
    }

    const result: Sequence = .{ .codepoint = codepoint, .length = length };

    assert(result.length >= 2);
    assert(std.unicode.utf8CodepointSequenceLength(codepoint) catch 0 == length);

    return result;
}

fn surrogates_write(codepoint: u21, target: *[escape_bytes_max]u8) void {
    assert(codepoint >= 0x10000);
    assert(codepoint <= 0x10ffff);

    const offset = codepoint - 0x10000;

    code_unit_write(@intCast(0xd800 + (offset >> 10)), target[0..expansion_max]);
    code_unit_write(@intCast(0xdc00 + (offset & 0x3ff)), target[expansion_max..]);
}

fn code_unit_write(unit: u16, target: *[expansion_max]u8) void {
    assert(unit >= 0x80);

    target.* = .{
        '\\',
        'u',
        hexadecimal_digits[unit >> 12],
        hexadecimal_digits[(unit >> 8) & 0xf],
        hexadecimal_digits[(unit >> 4) & 0xf],
        hexadecimal_digits[unit & 0xf],
    };
}

fn stop_find(text: []const u8, start: u32, comptime stops: Stops) u32 {
    assert(start <= text.len);
    assert(text.len <= input_bytes_max);

    var result: u32 = @intCast(text.len);
    var index = start;

    for (0..@divFloor(text.len - start, lane_count) + 1) |_| {
        if (index == text.len) break;

        const remaining: u32 = @intCast(text.len - index);
        const mask = chunk_scan(null, text[index..], stops);

        if (mask != 0) {
            result = index + @ctz(mask);

            break;
        }

        index += @min(remaining, lane_count);
    }

    assert(result >= start);
    assert(result <= text.len);

    return result;
}

fn stops_of(comptime utf8: UTF8) Stops {
    return switch (utf8) {
        .ascii, .bmp, .checked => .unicode,
        .trusted => .trusted,
    };
}

inline fn chunk_scan(target: ?[]u8, text: []const u8, comptime stops: Stops) Mask {
    assert(text.len > 0);
    assert(text.len <= input_bytes_max);
    if (target) |bytes| assert(bytes.len >= @min(text.len, lane_count));

    if (text.len >= lane_count) return piece_scan(lane_count, target, text[0..lane_count], stops);
    if (text.len >= 16) return piece_scan(16, target, text, stops);
    if (text.len >= 8) return piece_scan(8, target, text, stops);
    if (text.len >= 4) return piece_scan(4, target, text, stops);

    const middle: u32 = @intCast(text.len >> 1);
    const centre_target = if (target) |bytes| bytes[middle..] else null;
    const centre = piece_scan(1, centre_target, text[middle..][0..1], stops);

    return piece_scan(1, target, text, stops) | centre << @intCast(middle);
}

inline fn piece_scan(
    comptime width: u32,
    target: ?[]u8,
    text: []const u8,
    comptime stops: Stops,
) Mask {
    comptime assert(width <= lane_count);
    assert(text.len >= width);
    assert(text.len < 2 * width or width == 1);
    if (target) |bytes| assert(bytes.len >= text.len);

    const offset: u32 = @intCast(text.len - width);
    const head: @Vector(width, u8) = text[0..width].*;
    const tail: @Vector(width, u8) = text[offset..][0..width].*;

    if (target) |bytes| {
        bytes[0..width].* = head;
        bytes[offset..][0..width].* = tail;
    }

    const result = @as(Mask, stop_mask(width, &head, stops)) |
        @as(Mask, stop_mask(width, &tail, stops)) << @intCast(offset);

    assert(result >> @intCast(text.len - 1) <= 1);

    return result;
}

inline fn stop_mask(
    comptime width: u32,
    chunk: *const @Vector(width, u8),
    comptime stops: Stops,
) @Int(.unsigned, width) {
    comptime assert(width <= lane_count);
    comptime assert(width > 0);

    const Bits = @Vector(width, u1);
    const Bytes = @Vector(width, u8);
    const bytes = chunk.*;
    const backslash: Bits = @intFromBool(bytes == @as(Bytes, @splat('\\')));
    const quote: Bits = @intFromBool(bytes == @as(Bytes, @splat('"')));
    const control: Bits = @intFromBool(bytes < @as(Bytes, @splat(0x20)));
    const high: Bits = @intFromBool(bytes >= @as(Bytes, @splat(0x80)));

    const stopped: Bits = switch (stops) {
        .backslash => backslash,
        .high => high,
        .trusted => backslash | quote | control,
        .unicode => backslash | quote | control | high,
    };

    return @bitCast(stopped);
}

fn escapes_build() [256]Escape {
    var result: [256]Escape = undefined;

    for (&result, 0..) |*escape, byte| {
        escape.* = .{
            .length = expansion_max,
            .text = .{
                '\\',
                'u',
                '0',
                '0',
                hexadecimal_digits[byte >> 4],
                hexadecimal_digits[byte & 0xf],
            },
        };
    }

    for (result[0x20..0x80]) |*escape| escape.length = 0;

    for (short_bytes, short_letters) |byte, letter| {
        result[byte] = .{ .length = 2, .text = .{ '\\', letter, 0, 0, 0, 0 } };
    }

    assert(result['"'].length == 2);
    assert(result[0x7f].length == 0);

    return result;
}

fn escape_words_build() [0x60]u64 {
    var result: [0x60]u64 = undefined;

    for (&result, escapes[0..0x60]) |*word, escape| {
        var bytes: [8]u8 = @splat(0);

        bytes[0..expansion_max].* = escape.text;
        bytes[7] = escape.length;
        word.* = std.mem.readInt(u64, &bytes, .little);
    }

    assert(result['\\'] >> 56 == 2);
    assert(result[0] >> 56 == expansion_max);

    return result;
}

fn shift_table_build(offset: u32) [48]u8 {
    assert(offset % 16 == 0);
    assert(offset <= 16);

    var result: [48]u8 = @splat(0x80);

    for (result[offset..][0..16], 0..) |*index, value| index.* = @intCast(value);

    return result;
}

const testing = std.testing;

const EscapeScratch = struct {
    allocating: std.Io.Writer.Allocating,
    decoded: [256]u8,
    expected: [800]u8,
    fixed: [800]u8,
    slack: u32,
    transformed: [256]u8,
};

const sequence_probes = [_][]const u8{
    "\xc3\xa9",
    "\xe2\x82\xac",
    "\xef\xbf\xbf",
    "\xee\x80\x80",
    "\xed\x9f\xbf",
    "\xf0\x9f\x98\x80",
    "\xf4\x8f\xbf\xbf",
    "\xc0\xaf",
    "\xe0\x80\xaf",
    "\xed\xa0\x80",
    "\xf0\x8f\xbf\xbf",
    "\xf4\x90\x80\x80",
    "\xf8\x88\x80\x80\x80",
    "\xc3",
    "\xe2\x82",
    "\xf0\x9f\x98",
    "\x80",
    "\xff",
};

pub fn sequence_reference(text: []const u8, index: u32) u32 {
    assert(index < text.len);
    assert(text[index] >= 0x80);

    const lead = text[index];

    const length: u32 = switch (lead) {
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => return 0,
    };

    if (length > text.len - index) return 0;

    const second = text[index + 1];

    const second_valid = switch (lead) {
        0xe0 => second >= 0xa0,
        0xed => second <= 0x9f,
        0xf0 => second >= 0x90,
        0xf4 => second <= 0x8f,
        else => true,
    };

    if (!second_valid) return 0;

    for (text[index + 1 ..][0 .. length - 1]) |continuation| {
        if (continuation & 0xc0 != 0x80) return 0;
    }

    assert(length >= 2);

    return length;
}

fn escape_reference(text: []const u8, utf8: UTF8, writer: *std.Io.Writer) !void {
    assert(text.len <= 256);
    assert(writer.buffer.len > 0);

    var index: u32 = 0;

    for (0..text.len) |_| {
        if (index == text.len) break;

        const byte = text[index];

        if (byte >= 0x80) {
            index += try high_reference(text, index, utf8, writer);

            continue;
        }

        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }

        index += 1;
    }
}

fn high_reference(text: []const u8, index: u32, utf8: UTF8, writer: *std.Io.Writer) !u32 {
    assert(index < text.len);
    assert(text[index] >= 0x80);

    if (utf8 == .trusted) {
        try writer.writeByte(text[index]);

        return 1;
    }

    const length = sequence_reference(text, index);

    if (length == 0) {
        try writer.print("\\u{x:0>4}", .{text[index]});

        return 1;
    }

    const sequence = text[index..][0..length];
    const codepoint = try std.unicode.utf8Decode(sequence);

    const escaped = switch (utf8) {
        .ascii => true,
        .bmp => codepoint >= 0x10000,
        .checked => false,
        .trusted => unreachable,
    };

    if (!escaped) {
        try writer.writeAll(sequence);
    } else if (codepoint >= 0x10000) {
        const offset = codepoint - 0x10000;
        const high = 0xd800 + (offset >> 10);
        const low = 0xdc00 + (offset & 0x3ff);

        try writer.print("\\u{x:0>4}\\u{x:0>4}", .{ high, low });
    } else {
        try writer.print("\\u{x:0>4}", .{codepoint});
    }

    assert(length <= 4);

    return length;
}

pub fn checked_transform(text: []const u8, target: []u8) []const u8 {
    assert(text.len <= 256);
    assert(target.len >= 2 * text.len);

    var index: u32 = 0;
    var written: u32 = 0;

    for (0..text.len) |_| {
        if (index == text.len) break;

        const byte = text[index];
        const length = if (byte < 0x80) 1 else sequence_reference(text, index);

        if (length == 0) {
            target[written] = 0xc0 | (byte >> 6);

            target[written + 1] = 0x80 | (byte & 0x3f);
            written += 2;
            index += 1;
        } else {
            @memcpy(target[written..][0..length], text[index..][0..length]);
            written += length;
            index += length;
        }
    }

    return target[0..written];
}

fn escape_expect(scratch: *EscapeScratch, text: []const u8, utf8: UTF8) !void {
    assert(text.len <= 100);
    assert(scratch.slack <= 64);

    var expected_writer: std.Io.Writer = .fixed(&scratch.expected);

    try escape_reference(text, utf8, &expected_writer);

    const expected = expected_writer.buffered();

    scratch.allocating.clearRetainingCapacity();
    try escape_write(&scratch.allocating.writer, text, utf8);
    try testing.expectEqualStrings(expected, scratch.allocating.written());

    scratch.slack = @rem(scratch.slack, 64) + 1;

    var fixed: std.Io.Writer = .fixed(scratch.fixed[0 .. expected.len + scratch.slack]);

    try escape_write(&fixed, text, utf8);
    try testing.expectEqualStrings(expected, fixed.buffered());

    const valid = std.unicode.utf8ValidateSlice(text);

    if (utf8 == .trusted) {
        if (!valid) return;
    }

    const original = if (valid) text else checked_transform(text, &scratch.transformed);

    scratch.fixed[0] = '"';

    @memcpy(scratch.fixed[1..][0..expected.len], expected);
    scratch.fixed[expected.len + 1] = '"';

    var tokenizer: Tokenizer = .init(scratch.fixed[0 .. expected.len + 2]);
    const token = try tokenizer.next();

    try testing.expectEqualStrings(original, try unescape(token.string, &scratch.decoded));
}

fn escape_scratch_create() !*EscapeScratch {
    const scratch = try testing.allocator.create(EscapeScratch);
    errdefer testing.allocator.destroy(scratch);

    scratch.allocating = try .initCapacity(testing.allocator, 4096);
    scratch.slack = 0;

    assert(scratch.allocating.writer.unusedCapacityLen() >= 4096);

    return scratch;
}

fn escape_scratch_destroy(scratch: *EscapeScratch) void {
    assert(scratch.slack <= 64);

    scratch.allocating.deinit();
    testing.allocator.destroy(scratch);
}

fn unescape_reference(raw: []const u8, target: []u8) UnescapeError![]const u8 {
    assert(raw.len <= input_bytes_max);
    assert(target.len <= input_bytes_max);

    var source: u32 = 0;
    var written: u32 = 0;

    for (0..raw.len) |_| {
        if (source == raw.len) break;

        if (raw[source] != '\\') {
            if (written == target.len) return error.Overflow;

            target[written] = raw[source];
            written += 1;
            source += 1;

            continue;
        }

        const length = try tokenizer_module.escape_length(raw[source..]);
        const decoded = try escape_decode(raw[source..], length);
        if (decoded.count > target.len - written) return error.Overflow;

        @memcpy(target[written..][0..decoded.count], decoded.buffer[0..decoded.count]);
        written += decoded.count;
        source += decoded.consumed;
    }

    return target[0..written];
}

fn quoted_reference(window: []const u8, target: []u8) ?Unquoted {
    assert(window.len <= target.len);
    assert(window.len <= input_bytes_max);

    var index: u32 = 0;
    var high = false;

    for (0..window.len + 1) |_| {
        if (index == window.len) return null;

        const byte = window[index];

        if (byte == '"') break;
        if (byte < 0x20) return null;

        if (byte == '\\') {
            index += tokenizer_module.escape_length(window[index..]) catch return null;

            continue;
        }

        high = high or byte >= 0x80;
        index += 1;
    } else unreachable;

    const text = unescape_reference(window[0..index], target) catch return null;

    return .{ .close = index, .high = high, .written = @intCast(text.len) };
}

fn quoted_window(random: std.Random, input: *[800]u8) []const u8 {
    const pieces = [_][]const u8{
        "a",
        " ",
        "\x7f",
        "0123456789abcdefghijklmnopqrstuvwxyz",
        "caf\xc3\xa9",
        "\xe4\xb8\xad\xe6\x96\x87",
        "\\\"",
        "\\\\",
        "\\/",
        "\\n",
        "\\t",
        "\\u0041",
        "\\u00e9",
        "\\u20ac",
        "\\ud83d\\ude00",
        "\\u00e9\\u00e9\\u00e9\\u00e9",
        "\\u4e2d\\u6587\\u4e2d\\u6587\\u4e2d",
        "\\ud83d\\ude00\\ud83d\\ude00",
        "\\ud83d",
        "\\x",
        "\\u12",
        "\x01",
    };

    const prefix = random.uintLessThan(u32, 40);
    const count = random.uintLessThan(u32, 40);

    var end = prefix;

    for (0..count) |_| {
        const piece = pieces[random.uintLessThan(u32, pieces.len)];
        if (end + piece.len > 600) break;

        @memcpy(input[end..][0..piece.len], piece);
        end += @intCast(piece.len);
    }

    if (random.uintLessThan(u32, 8) != 0) {
        const accents = "\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9\xc3\xa9";

        const trailers = [_][]const u8{
            "",
            ",\"next\"",
            ", \"" ++ accents ++ accents ++ accents ++ "\"",
            "\xc3\xa9\\\"",
            "\"\"\\",
            " \x01",
            ", \"0123456789abcdefghijklmnopqrstuvwxyz\xe4\xb8\xad\\u12\x01",
        };

        const trailer = trailers[random.uintLessThan(u32, trailers.len)];

        input[end] = '"';
        @memcpy(input[end + 1 ..][0..trailer.len], trailer);
        end += 1 + @as(u32, @intCast(trailer.len));
    }

    assert(prefix <= end);
    assert(end <= input.len);

    return input[prefix..end];
}

fn unescape_agree(raw: []const u8, limit: u32) !void {
    assert(raw.len <= 256);
    assert(limit <= 256);

    var ours: [256]u8 = undefined;
    var theirs: [256]u8 = undefined;

    const expected = unescape_reference(raw, theirs[0..limit]);
    const actual = unescape(raw, ours[0..limit]);

    if (expected) |text| {
        try testing.expectEqualStrings(text, try actual);
    } else |err| {
        try testing.expectError(err, actual);
    }
}

test "unescape_validated matches the reference on random valid escapes" {
    var prng: std.Random.DefaultPrng = .init(0x756e6573);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        "z",
        " ",
        "\\\"",
        "\\\\",
        "\\/",
        "\\b",
        "\\f",
        "\\n",
        "\\r",
        "\\t",
        "\\u0041",
        "\\u00e9",
        "\\u20ac",
        "\\uFFFF",
        "\\ud83d\\ude00",
        "\\uDBFF\\uDFFF",
        "caf\xc3\xa9",
        "0123456789abcdef",
    };

    var raw: [512]u8 = undefined;
    var expected: [512]u8 = undefined;
    var actual: [512 + lane_count]u8 = undefined;

    for (0..5_000) |_| {
        var length: u32 = 0;
        const count = random.uintLessThan(u32, 40);

        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(u32, pieces.len)];
            if (length + piece.len > raw.len) break;

            @memcpy(raw[length..][0..piece.len], piece);
            length += @intCast(piece.len);
        }

        const text = raw[0..length];
        const reference = try unescape_reference(text, &expected);
        const produced = unescape_validated(text, length, actual[0 .. length + lane_count]);

        try testing.expectEqualStrings(reference, actual[0..produced]);
    }
}

test "unescape_checked reads past the text within its window and agrees with unescape" {
    var prng: std.Random.DefaultPrng = .init(0x77696e64);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        " ",
        "\\\"",
        "\\\\",
        "\\/",
        "\\n",
        "\\t",
        "\\u0041",
        "\\u20ac",
        "\\ud83d\\ude00",
        "\\ud83d",
        "\\x",
        "\\u12",
        "\\",
        "0123456789abcdefghijklmnopqrstuvwxyz",
    };

    var input: [700]u8 = undefined;
    var expected: [700]u8 = undefined;
    var actual: [700 + lane_count]u8 = undefined;

    for (0..20_000) |_| {
        const prefix = random.uintLessThan(u32, 40);
        const count = random.uintLessThan(u32, 30);

        var length: u32 = 0;

        @memset(&input, '\\');

        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(u32, pieces.len)];
            if (prefix + length + piece.len > 500) break;

            @memcpy(input[prefix + length ..][0..piece.len], piece);
            length += @intCast(piece.len);
        }

        const suffix = random.uintLessThan(u32, 100);
        const window = input[prefix .. prefix + length + suffix];
        const reference = unescape(window[0..length], &expected) catch null;
        const target = actual[0 .. length + lane_count];
        const produced = unescape_checked(window, length, target);

        if (reference) |text| {
            try testing.expectEqualStrings(text, actual[0 .. produced orelse return error.Refused]);
        } else {
            try testing.expectEqual(@as(?u32, null), produced);
        }
    }
}

fn boundaries_mark(raw: []const u8, boundaries: []bool) void {
    assert(boundaries.len == raw.len + 1);
    assert(raw.len <= input_bytes_max);

    @memset(boundaries, false);

    var index: u32 = 0;

    for (0..raw.len + 1) |_| {
        boundaries[index] = true;
        if (index == raw.len) return;

        if (raw[index] != '\\') {
            index += 1;

            continue;
        }

        const length = tokenizer_module.escape_length(raw[index..]) catch return;
        const decoded = escape_decode(raw[index..], length) catch return;

        index += decoded.consumed;
    }
}

pub fn pieces_fill(random: std.Random, pieces: []const []const u8, target: []u8) u32 {
    assert(pieces.len > 0);
    assert(target.len <= input_bytes_max);

    const count = random.uintLessThan(u32, 60);

    var length: u32 = 0;

    for (0..count) |_| {
        const piece = pieces[random.uintLessThan(u32, @intCast(pieces.len))];
        if (length + piece.len > target.len) break;

        @memcpy(target[length..][0..piece.len], piece);
        length += @intCast(piece.len);
    }

    assert(length <= target.len);

    return length;
}

test "a cut for a short target lands on an escape boundary outside every surrogate pair" {
    var prng: std.Random.DefaultPrng = .init(0x63757473);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        " ",
        "u",
        "uD83D",
        "0123456789abcdef",
        "caf\xc3\xa9",
        "\\\"",
        "\\\\",
        "\\/",
        "\\n",
        "\\u0041",
        "\\u4e2d",
        "\\uD83D\\uDE00",
        "\\udbff\\udfff",
    };

    var raw: [480]u8 = undefined;
    var boundaries: [raw.len + 1]bool = undefined;
    var cuts: u32 = 0;

    for (0..20_000) |_| {
        const length = pieces_fill(random, &pieces, &raw);
        const text = raw[0..length];

        boundaries_mark(text, boundaries[0 .. length + 1]);

        for (@min(expansion_max, length)..length) |position| {
            if (cut_safe(text, @intCast(position))) try testing.expect(boundaries[position]);
        }

        if (unescape_cut(text)) |cut| {
            try testing.expect(boundaries[cut]);
            try testing.expect(cut + cut_margin_bytes <= length);

            cuts += 1;
        }
    }

    try testing.expect(cuts > 10_000);
}

test "unescape_bounded agrees with the reference at every short slack" {
    var prng: std.Random.DefaultPrng = .init(0x736c6163);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        " ",
        "uD83D",
        "0123456789abcdefghijklmnopqrstuvwxyz",
        "caf\xc3\xa9",
        "\\\"",
        "\\\\",
        "\\\\\\\\\\\\",
        "\\/",
        "\\n",
        "\\t",
        "\\u0001",
        "\\u20ac",
        "\\u4e2d\\u6587\\u4e2d\\u6587",
        "\\ud83d\\ude00",
        "\\ud83d",
        "\\x",
        "\\u12",
    };

    var input: [700]u8 = undefined;
    var expected: [700]u8 = undefined;
    var actual: [700 + lane_count]u8 = undefined;
    var shorts: u32 = 0;

    for (0..20_000) |_| {
        const prefix = random.uintLessThan(u32, 40);

        @memset(&input, '\\');

        const length = pieces_fill(random, &pieces, input[prefix..][0..500]);
        const suffix = random.uintLessThan(u32, 100);
        const window = input[prefix .. prefix + length + suffix];
        const slack = random.uintLessThan(u32, lane_count);
        const target = actual[0 .. length + slack];
        const reference = unescape_reference(window[0..length], &expected) catch null;

        @memset(&actual, 0xaa);

        const produced = unescape_bounded(window[0..length], target);

        for (actual[target.len..]) |byte| try testing.expectEqual(@as(u8, 0xaa), byte);

        if (reference) |text| {
            try testing.expectEqualStrings(text, try produced);
        } else {
            try testing.expectError(error.Malformed, produced);
        }

        if (unescape_cut(window[0..length]) != null) shorts += 1;
    }

    try testing.expect(shorts > 5_000);
}

test "unescape_checked agrees with unescape on escape runs of every width at every offset" {
    const texts = [_][]const u8{
        "\\u0001\\u007f\\u0080\\u07ff\\u0800\\uffff",
        "\\u3042\\u3044\\u3046\\u3048\\u304a\\u304b\\u304d\\u304f\\u3051\\u3053",
        "\\u0430\\u0431\\u0432\\u0433\\u0434\\u0435\\u0436\\u0437\\u0438",
        "\\u3042\\u3044\\u3046\\u30G8\\u304a",
        "\\uD83D\\uDE00\\u3042\\u3044\\u3046\\u3048",
        "\\uD83D\\u3042\\u3044\\u3046\\u3048",
        "\\uDE00\\uD83D\\uDE00\\uD83D\\uDE00",
        "\\u0430\\u0431\\u0432x\\u0433\\u0434 \\u0435",
        "\\u3042\\u0430\\u3044\\u0041\\u0431",
        "\\uD83D\\uDE00\\u3042x\\u3042\\uD83D\\uDE00",
        "\\uD83D\\uDE00\\uD83D",
        "\\u3042\\u3044\\u30",
        "\\u0430\\u0431\\u043",
        "\\u0430\\u0431x\\u0432\\n\\u0433\\\"\\u0434",
        "\\uD83D\\uDE00\\ud83d\\ude01\\uDBFF\\uDFFF",
        "\\uABCD\\uabcd\\uAbCd",
        "\\u12G4",
        "\\u123",
        "\\uD83D\\u0041",
        "\\uD83D\\uD83D",
        "\\uDE00",
        "\\uD83D\\x",
        "\\uD83D\\",
        "\\u",
        "\\",
    };

    var input: [256]u8 = undefined;
    var expected: [256]u8 = undefined;
    var actual: [256 + lane_count]u8 = undefined;

    for (texts) |text| {
        for (0..71 * 3) |case| {
            const offset = @divFloor(case, 3);
            const suffix = ([_]u32{ 0, 1, 33 })[case % 3];
            const length: u32 = @intCast(offset + text.len);

            @memset(&input, 'x');
            @memcpy(input[offset..][0..text.len], text);

            const window = input[0 .. length + suffix];
            const reference = unescape(window[0..length], &expected) catch null;
            const target = actual[0 .. length + lane_count];
            const produced = unescape_checked(window, length, target);

            if (reference) |decoded| {
                const size = produced orelse return error.Refused;

                try testing.expectEqualStrings(decoded, actual[0..size]);
            } else {
                try testing.expectEqual(@as(?u32, null), produced);
            }
        }
    }
}

test "unescape_checked refuses an escape that only the window past the text completes" {
    const cases = [_][2][]const u8{
        .{ "\\u30", "42" },
        .{ "\\u", "0041" },
        .{ "\\", "n" },
        .{ "\\ud83d", "\\ude00" },
        .{ "\\ud83d\\", "ude00" },
        .{ "\\ud83d\\u", "de00" },
        .{ "\\ud83d\\ude0", "0" },
        .{ "\\u0041", "\\u0042" },
        .{ "\\ud83d\\ude00", "\\u0041" },
    };

    const offset_count = 4 * lane_count + 8;

    var input: [256]u8 = undefined;
    var expected: [256]u8 = undefined;
    var actual: [256 + lane_count]u8 = undefined;
    var refused: u32 = 0;

    for (cases) |case| {
        for (0..offset_count) |offset| {
            const length: u32 = @intCast(offset + case[0].len);

            @memset(&input, 'x');
            @memcpy(input[offset..][0..case[0].len], case[0]);
            @memcpy(input[length..][0..case[1].len], case[1]);

            const window = input[0 .. length + lane_count];
            const target = actual[0 .. length + lane_count];
            const reference = unescape(window[0..length], &expected) catch null;
            const produced = unescape_checked(window, length, target);

            refused += @intFromBool(reference == null);

            try unescape_window_expect(reference, produced, target);

            if (length < lane_count) {
                const short = unescape_short(1, window, length, target);

                try unescape_window_expect(reference, short, target);
            }

            if (length < 2 * lane_count) {
                const span = 2 * lane_count;
                const target_pair = actual[0 .. length + span];
                const pair = unescape_short(2, input[0 .. length + span], length, target_pair);

                try unescape_window_expect(reference, pair, target_pair);
            }
        }
    }

    try testing.expectEqual(@as(u32, 7 * offset_count), refused);
}

fn unescape_window_expect(reference: ?[]const u8, produced: ?u32, target: []const u8) !void {
    assert(target.len >= lane_count);
    if (reference) |decoded| assert(decoded.len + lane_count <= target.len);
    if (produced) |size| assert(size <= target.len);

    if (reference) |decoded| {
        const size = produced orelse return error.Refused;

        try testing.expectEqualStrings(decoded, target[0..size]);
    } else {
        try testing.expectEqual(@as(?u32, null), produced);
    }
}

test "every mix of four unicode escapes decodes as the reference does at every offset" {
    const items = [_][]const u8{
        "\\u0000",
        "\\u007f",
        "\\u0080",
        "\\u07FF",
        "\\u0800",
        "\\uffff",
        "\\uD83D\\uDE00",
        "\\udbff\\udfff",
        "\\uD83D",
        "\\uDE00",
    };
    const sequence_count = items.len * items.len * items.len * items.len;

    var input: [192]u8 = undefined;
    var expected: [192]u8 = undefined;
    var actual_checked: [192 + lane_count]u8 = undefined;
    var actual_quoted: [192 + lane_count]u8 = undefined;
    var refused: u32 = 0;

    for (0..sequence_count) |sequence| {
        var text_buffer: [64]u8 = undefined;
        const text = test_sequence_write(&items, sequence, &text_buffer);

        for (0..lane_count) |offset| {
            const length: u32 = @intCast(offset + text.len);

            @memset(&input, 'x');
            @memcpy(input[offset..][0..text.len], text);
            input[length] = '"';

            const window = input[0 .. length + lane_count];
            const target_checked = actual_checked[0 .. length + lane_count];
            const target_quoted = actual_quoted[0 .. window.len + lane_count];
            const reference = unescape(window[0..length], &expected) catch null;
            const checked = unescape_checked(window, length, target_checked);
            const quoted = unescape_quoted(window, target_quoted);

            refused += @intFromBool(reference == null);

            if (reference) |decoded| {
                const size = checked orelse return error.Refused;
                const unquoted = quoted orelse return error.Refused;

                try testing.expectEqualStrings(decoded, target_checked[0..size]);
                try testing.expectEqualStrings(decoded, target_quoted[0..unquoted.written]);
                try testing.expectEqual(length, unquoted.close);
            } else {
                try testing.expectEqual(@as(?u32, null), checked);
                try testing.expectEqual(@as(?Unquoted, null), quoted);
            }
        }
    }

    try testing.expect(refused > 0);
    try testing.expect(refused < sequence_count * lane_count);
}

fn test_sequence_write(items: []const []const u8, sequence: u64, target: *[64]u8) []const u8 {
    assert(items.len > 0);
    assert(sequence < std.math.pow(u64, items.len, 4));

    var length: u32 = 0;
    var digits = sequence;

    for (0..4) |_| {
        const index: usize = @intCast(digits % items.len);
        const item = items[index];

        digits /= items.len;
        @memcpy(target[length..][0..item.len], item);
        length += @intCast(item.len);
    }

    assert(length <= target.len);

    return target[0..length];
}

test "unescape_quoted stops at the closing quote and agrees with the scalar reference" {
    var prng: std.Random.DefaultPrng = .init(0x71756f74);
    const random = prng.random();

    var input: [800]u8 = undefined;
    var expected: [800]u8 = undefined;
    var actual: [800 + lane_count]u8 = undefined;

    for (0..30_000) |_| {
        const window = quoted_window(random, &input);
        const target = actual[0 .. window.len + lane_count];
        const reference = quoted_reference(window, &expected);
        const result = unescape_quoted(window, target);

        if (reference) |want| {
            const got = result orelse return error.Refused;

            try testing.expectEqual(want.close, got.close);
            try testing.expectEqual(want.high, got.high);
            try testing.expectEqualStrings(expected[0..want.written], target[0..got.written]);
        } else {
            try testing.expectEqual(@as(?Unquoted, null), result);
        }
    }
}

test "unescape decodes simple escapes, unicode, and surrogate pairs, and refuses lone halves" {
    var buffer: [64]u8 = undefined;

    try testing.expectEqualStrings("a\"b\\c/\n", try unescape("a\\\"b\\\\c\\/\\n", &buffer));
    try testing.expectEqualStrings("caf\u{e9}", try unescape("caf\\u00e9", &buffer));
    try testing.expectEqualStrings("\u{1f600}", try unescape("\\ud83d\\ude00", &buffer));
    try testing.expectError(error.Malformed, unescape("\\ud83dx", &buffer));
    try testing.expectError(error.Malformed, unescape("\\ude00", &buffer));
    try testing.expectError(error.Overflow, unescape("abcd", buffer[0..3]));
}

test "the vectorized unescape agrees with the scalar reference at every offset and limit" {
    const escapes_probed = [_][]const u8{
        "\\n",
        "\\\"",
        "\\/",
        "\\u00e9",
        "\\u20ac",
        "\\ud83d\\ude00",
        "\\q",
        "\\u12",
        "\\ud83d",
        "\\",
    };

    var raw: [128]u8 = undefined;

    for (escapes_probed) |escape| {
        for (0..71) |offset| {
            for ([_]u32{ 0, 1, 31, 32, 33 }) |tail| {
                const length = offset + escape.len + tail;

                @memset(raw[0..length], 'x');
                @memcpy(raw[offset..][0..escape.len], escape);

                const limits = [_]u32{
                    0,
                    @intCast(offset),
                    @intCast(length - 1),
                    @intCast(length),
                };

                for (limits) |limit| try unescape_agree(raw[0..length], limit);
            }
        }
    }
}

test "every byte at every offset escapes as the reference does under both policies and paths" {
    const scratch = try escape_scratch_create();
    defer escape_scratch_destroy(scratch);

    var text: [100]u8 = undefined;

    for (1..101) |length| {
        for (0..@min(length, 71)) |offset| {
            for (0..256) |byte| {
                @memset(text[0..length], 'a');
                text[offset] = @intCast(byte);

                for (std.enums.values(UTF8)) |utf8| {
                    try escape_expect(scratch, text[0..length], utf8);
                }
            }
        }
    }
}

test "every sequence class at every offset escapes as the reference does" {
    const scratch = try escape_scratch_create();
    defer escape_scratch_destroy(scratch);

    var text: [100]u8 = undefined;

    for (sequence_probes) |sequence| {
        for (sequence.len..101) |length| {
            for (0..@min(length - sequence.len + 1, 71)) |offset| {
                @memset(text[0..length], 'a');
                @memcpy(text[offset..][0..sequence.len], sequence);

                for (std.enums.values(UTF8)) |utf8| {
                    try escape_expect(scratch, text[0..length], utf8);
                }
            }
        }
    }
}

test "every pair of escapes at every pair of offsets writes as the reference does" {
    var text: [72]u8 = undefined;
    var target: [trusted_test_room]u8 = undefined;

    for (1..text.len + 1) |length| {
        for (0..length * length) |placement| {
            try trusted_pairs_expect(&target, text[0..length], @intCast(placement));
        }
    }
}

fn trusted_pairs_expect(target: *[trusted_test_room]u8, text: []u8, placement: u32) !void {
    assert(text.len > 0);
    assert(placement < text.len * text.len);

    const pairs = [_][2]u8{ .{ '\n', '"' }, .{ 0x01, '\\' }, .{ '\t', 0x1f } };
    const first = @divFloor(placement, text.len);
    const second = placement % text.len;

    for (pairs) |pair| {
        for (text, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));

        text[first] = pair[0];
        text[second] = pair[1];

        try trusted_expect(target, text);
    }
}

test "random text of every escape density writes as the reference does" {
    var prng: std.Random.DefaultPrng = .init(0x65736370);
    const random = prng.random();

    var text: [100]u8 = undefined;
    var target: [trusted_test_room]u8 = undefined;

    for (0..20_000) |_| {
        const length = random.uintAtMost(u32, text.len);
        const density = random.uintAtMost(u5, 6);

        for (text[0..length]) |*byte| byte.* = trusted_test_byte(random, density);

        try trusted_expect(&target, text[0..length]);
    }
}

const trusted_test_room: u32 = 6 * 100 + 2 + 32;

fn trusted_test_byte(random: std.Random, density: u5) u8 {
    assert(density <= 6);
    assert(short_bytes.len == 7);

    const special = random.uintLessThan(u32, @as(u32, 1) << density) == 0;

    if (special) {
        const choice = random.uintLessThan(u8, 0x22);

        if (choice == 0x20) return '"';
        if (choice == 0x21) return '\\';

        return choice;
    }

    const plain = random.intRangeAtMost(u8, 0x20, 0xfd);

    if (plain == '"') return 0xfe;
    if (plain == '\\') return 0xff;

    return plain;
}

fn trusted_expect(target: *[trusted_test_room]u8, text: []const u8) !void {
    assert(text.len <= 100);
    assert(trusted_room(text.len) <= target.len);

    var expected: [600]u8 = undefined;
    var expected_writer: std.Io.Writer = .fixed(&expected);

    try escape_reference(text, .trusted, &expected_writer);

    const room: u32 = @intCast(trusted_room(text.len));
    const written = trusted_write(target[0..room], text);

    try testing.expectEqualStrings(expected_writer.buffered(), target[0..written]);
}

test "the bmp policy escapes as arc does" {
    const scratch = try escape_scratch_create();
    defer escape_scratch_destroy(scratch);

    const cases = [_][2][]const u8{
        .{ "\x08\x0c", "\\b\\f" },
        .{ "\u{1f600}", "\\ud83d\\ude00" },
        .{ "\u{10ffff}", "\\udbff\\udfff" },
        .{ "\xff", "\\u00ff" },
        .{ "\xe0\x80\xaf", "\\u00e0\\u0080\\u00af" },
        .{ "\xed\xa0\x80", "\\u00ed\\u00a0\\u0080" },
        .{ "\xf4\x90\x80\x80", "\\u00f4\\u0090\\u0080\\u0080" },
        .{ "ok\xc3", "ok\\u00c3" },
        .{ "\u{e9}\u{20ac}/\x7f", "\u{e9}\u{20ac}/\x7f" },
    };

    for (cases) |case| {
        scratch.allocating.clearRetainingCapacity();

        try escape_write(&scratch.allocating.writer, case[0], .bmp);
        try testing.expectEqualStrings(case[1], scratch.allocating.written());
    }
}

test "the checked policy passes valid sequences raw and escapes each invalid byte" {
    const scratch = try escape_scratch_create();
    defer escape_scratch_destroy(scratch);

    const cases = [_][2][]const u8{
        .{ "\u{1f600}", "\u{1f600}" },
        .{ "\u{10ffff}\u{e9}\u{20ac}", "\u{10ffff}\u{e9}\u{20ac}" },
        .{ "\xff", "\\u00ff" },
        .{ "\xe0\x80\xaf", "\\u00e0\\u0080\\u00af" },
        .{ "\xed\xa0\x80", "\\u00ed\\u00a0\\u0080" },
        .{ "ok\xf0\x9f\x98", "ok\\u00f0\\u009f\\u0098" },
        .{ "/\x7f\x01", "/\x7f\\u0001" },
    };

    for (cases) |case| {
        scratch.allocating.clearRetainingCapacity();

        try escape_write(&scratch.allocating.writer, case[0], .checked);
        try testing.expectEqualStrings(case[1], scratch.allocating.written());
    }
}

test "the ascii policy escapes every code point above U+007F" {
    const scratch = try escape_scratch_create();
    defer escape_scratch_destroy(scratch);

    const cases = [_][2][]const u8{
        .{ "caf\u{e9}", "caf\\u00e9" },
        .{ "\u{20ac}\u{ffff}", "\\u20ac\\uffff" },
        .{ "\u{1f600}", "\\ud83d\\ude00" },
        .{ "\u{80}", "\\u0080" },
        .{ "\xff\xc3", "\\u00ff\\u00c3" },
        .{ "/\x7f\x01", "/\x7f\\u0001" },
    };

    for (cases) |case| {
        scratch.allocating.clearRetainingCapacity();

        try escape_write(&scratch.allocating.writer, case[0], .ascii);
        try testing.expectEqualStrings(case[1], scratch.allocating.written());

        for (scratch.allocating.written()) |byte| try testing.expect(byte < 0x80);
    }
}

test "escaped source text keeps its escapes and rewrites only the bytes the policy escapes" {
    var buffer: [128]u8 = undefined;
    const source = "\"caf\u{e9} \\u00e9 \u{1f600}\\n\"";

    const cases = [_]struct { UTF8, []const u8 }{
        .{ .ascii, "\"caf\\u00e9 \\u00e9 \\ud83d\\ude00\\n\"" },
        .{ .bmp, "\"caf\u{e9} \\u00e9 \\ud83d\\ude00\\n\"" },
        .{ .checked, source },
        .{ .trusted, source },
    };

    for (cases) |case| {
        var sink: std.Io.Writer = .fixed(&buffer);

        try escaped_write(&sink, source, case[0]);
        try testing.expectEqualStrings(case[1], sink.buffered());
    }
}

test "a text is escape free exactly when the trusted escaper would copy it unchanged" {
    var text: [80]u8 = undefined;

    for (0..256) |byte| {
        for ([_]u32{ 0, 31, 32, 79 }) |offset| {
            @memset(&text, 'a');
            text[offset] = @intCast(byte);

            const special = byte < 0x20 or byte == '"' or byte == '\\';

            try testing.expectEqual(!special, escape_free(&text));
        }
    }

    try testing.expect(escape_free(""));
    try testing.expect(escape_free("caf\u{e9} \u{1f600} / \x7f"));
}

test "a fixed sink too small for the escaped text fails rather than truncating silently" {
    var buffer: [8]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try testing.expectError(error.WriteFailed, escape_write(&sink, "\x01\x02", .trusted));
    try testing.expectEqualStrings("\\u0001", sink.buffered()[0..6]);
}

test unescape {
    var buffer: [16]u8 = undefined;

    try testing.expectEqualStrings("tab\there", try unescape("tab\\there", &buffer));
    try testing.expectEqualStrings("\u{e9}", try unescape("\\u00e9", &buffer));
    try testing.expectError(error.Overflow, unescape("seventeen bytes!!", &buffer));
}

test "every lead and second byte escapes as the reference does, alone, truncated, and repeated" {
    const scratch = try escape_scratch_create();
    defer escape_scratch_destroy(scratch);

    const tails = [_][2]u8{
        .{ 0x80, 0x80 },
        .{ 0xbf, 0xbf },
        .{ 'a', 0x80 },
    };

    for (0..0x80 * 0x100) |pair| {
        const lead: u8 = @intCast(0x80 + (pair >> 8));
        const second: u8 = @intCast(pair & 0xff);

        for (tails) |tail| {
            const unit = [_]u8{ lead, second, tail[0], tail[1] };
            const text = unit ++ unit;

            for ([_]u32{ 2, 3, 8 }) |length| {
                for (std.enums.values(UTF8)) |utf8| {
                    try escape_expect(scratch, text[0..length], utf8);
                }
            }
        }
    }
}

test "a text is backslash free exactly when it holds no backslash, at every length and offset" {
    var text: [80]u8 = undefined;

    for (0..text.len + 1) |length| {
        @memset(text[0..length], 'a');

        try testing.expect(backslash_free(text[0..length]));

        for (0..length) |offset| {
            text[offset] = '\\';
            const expected = std.mem.findScalar(u8, text[0..length], '\\') == null;

            try testing.expectEqual(expected, backslash_free(text[0..length]));
            try testing.expect(!backslash_free(text[0..length]));

            text[offset] = 0x80 | @as(u8, @intCast(offset));
        }

        try testing.expect(backslash_free(text[0..length]));
    }
}

test "a name is verbatim exactly when no policy escapes any of its bytes" {
    comptime {
        @setEvalBranchQuota(100_000);

        for (0..0x100) |byte| {
            const text = [_]u8{ 'a', @intCast(byte), 'z' };
            const plain = byte >= 0x20 and byte < 0x80 and byte != '"' and byte != '\\';

            assert(verbatim_is(&text) == plain);
        }
    }

    try testing.expect(verbatim_is("statuses"));
    try testing.expect(!verbatim_is("caf\u{e9}"));
}

test "the short unescape decodes a string under one lane as the reference does" {
    var prng: std.Random.DefaultPrng = .init(0x73686f72);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        " ",
        "caf\xc3\xa9",
        "\\\"",
        "\\\\",
        "\\/",
        "\\n",
        "\\b",
        "\\u0041",
        "\\u00e9",
        "\\u4e2d",
        "\\uD83D\\uDE00",
        "\\ud800",
        "\\x",
        "\\u12g4",
    };

    var window: [96]u8 = undefined;
    var target: [96]u8 = undefined;
    var expected_buffer: [96]u8 = undefined;

    for (0..20_000) |_| {
        random.bytes(&window);

        const length = pieces_fill(random, &pieces, window[0 .. lane_count - 1]);
        const raw = window[0..length];
        if (std.mem.findScalar(u8, raw, '\\') == null) continue;

        const expected = unescape_reference(raw, &expected_buffer) catch null;
        const actual = unescape_short(1, &window, length, &target);

        try testing.expectEqual(expected == null, actual == null);

        if (expected) |decoded| {
            try testing.expectEqual(decoded.len, actual.?);
            try testing.expectEqualSlices(u8, decoded, target[0..decoded.len]);
        }
    }
}

test "the short unescape decodes a string under two lanes as the reference does" {
    var prng: std.Random.DefaultPrng = .init(0x70616972);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        " ",
        "abcdefghijklmnopqrstuvwxyzabcdefghijklmn",
        "caf\xc3\xa9",
        "\\\"",
        "\\\\",
        "\\/",
        "\\n",
        "\\b",
        "\\u0041",
        "\\u00e9",
        "\\u4e2d",
        "\\uD83D\\uDE00",
        "\\ud800",
        "\\x",
        "\\u12g4",
    };

    var window: [5 * lane_count]u8 = undefined;
    var target: [5 * lane_count]u8 = undefined;
    var expected_buffer: [5 * lane_count]u8 = undefined;

    for (0..20_000) |_| {
        random.bytes(&window);

        const length = pieces_fill(random, &pieces, window[0 .. 2 * lane_count - 1]);
        const raw = window[0..length];
        if (std.mem.findScalar(u8, raw, '\\') == null) continue;

        const expected = unescape_reference(raw, &expected_buffer) catch null;
        const actual = unescape_short(2, &window, length, &target);

        try testing.expectEqual(expected == null, actual == null);

        if (expected) |decoded| {
            try testing.expectEqual(decoded.len, actual.?);
            try testing.expectEqualSlices(u8, decoded, target[0..decoded.len]);
        }
    }
}
