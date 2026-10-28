const std = @import("std");

const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Chunk = @Vector(lane_count, u8);
const Mask = @Int(.unsigned, lane_count);
const direct_slack_bytes: u32 = 2 + lane_count;
const escape_bytes_max: u32 = 2 * expansion_max;
const escapes: [256]Escape = escapes_build();
const expansion_max: u32 = 6;
const hexadecimal_digits = "0123456789abcdef";
const input_bytes_max = tokenizer_module.input_bytes_max;
const lane_count = tokenizer_module.lane_count;
const short_bytes = "\"\\\x08\x0c\n\r\t";
const short_letters = "\"\\bfnrt";

comptime {
    assert(lane_count == 16 or lane_count == 32);
    assert(short_bytes.len == short_letters.len);
    assert(escape_bytes_max == 12);
}

const Decoded = struct {
    buffer: [4]u8,
    consumed: u32,
    count: u32,
};

const Escape = struct {
    length: u8,
    text: [expansion_max]u8,
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

    const result = unescape_wide(false, window, length, target) orelse unreachable;

    assert(result <= length);

    return result;
}

pub fn unescape_checked(window: []const u8, length: u32, target: []u8) ?u32 {
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    const result = unescape_wide(true, window, length, target);

    if (result) |written| assert(written <= length);

    return result;
}

inline fn unescape_wide(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
) ?u32 {
    assert(length <= window.len);
    assert(window.len <= input_bytes_max);
    assert(target.len >= length + lane_count);

    var cursor: Unescaping = .{ .source = 0, .written = 0 };

    for (0..length + 1) |_| {
        unescape_plain(window[0..length], target, &cursor);
        if (cursor.source == length) break;

        switch (unescape_step(checked, window, length, target, &cursor)) {
            .done => break,
            .failed => return null,
            .more => {},
        }
    }

    assert(cursor.source == length);
    assert(cursor.written <= length);

    return cursor.written;
}

const Unescaping = struct {
    source: u32,
    written: u32,
};

const UnescapeStep = enum {
    done,
    failed,
    more,
};

inline fn unescape_plain(raw: []const u8, target: []u8, cursor: *Unescaping) void {
    assert(cursor.source <= raw.len);
    assert(target.len >= raw.len + lane_count);

    const length: u32 = @intCast(raw.len);

    var source = cursor.source;
    var written = cursor.written;
    defer cursor.* = .{ .source = source, .written = written };

    while (length - source >= 2 * lane_count) {
        const first: Chunk = raw[source..][0..lane_count].*;
        const second: Chunk = raw[source + lane_count ..][0..lane_count].*;
        const mask_first: Mask = @bitCast(first == @as(Chunk, @splat('\\')));
        const mask_second: Mask = @bitCast(second == @as(Chunk, @splat('\\')));
        const mask = @as(u64, mask_second) << lane_count | mask_first;

        target[written..][0..lane_count].* = first;
        target[written + lane_count ..][0..lane_count].* = second;

        if (mask == 0) {
            source += 2 * lane_count;
            written += 2 * lane_count;

            continue;
        }

        source += @ctz(mask);
        written += @ctz(mask);

        if (source + 1 == length) break;

        const byte = escape_bytes[raw[source + 1]];
        if (byte == 0) break;

        target[written] = byte;
        source += 2;
        written += 1;
    }
}

inline fn unescape_step(
    comptime checked: bool,
    window: []const u8,
    length: u32,
    target: []u8,
    cursor: *Unescaping,
) UnescapeStep {
    assert(cursor.source < length);
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    const raw = window[0..length];

    if (length - cursor.source < 2 * lane_count) {
        if (!unescape_seek(window, length, target, cursor)) return .done;
    }

    const source = cursor.source;

    assert(raw[source] == '\\');

    if (checked) {
        if (raw.len - source < 2) return .failed;
    }

    const byte = escape_bytes[raw[source + 1]];

    if (byte != 0) {
        target[cursor.written] = byte;
        cursor.source += 2;
        cursor.written += 1;

        return .more;
    }

    if (checked) _ = tokenizer_module.escape_length(raw[source..]) catch return .failed;

    const piece = escape_decode_validated(raw[source..], target[cursor.written..][0..4]);

    cursor.source += piece.consumed;
    cursor.written += piece.produced;

    return .more;
}

inline fn unescape_seek(window: []const u8, length: u32, target: []u8, cursor: *Unescaping) bool {
    assert(cursor.source < length);
    assert(length - cursor.source < 2 * lane_count);
    assert(length <= window.len);
    assert(target.len >= length + lane_count);

    const raw = window[0..length];

    var source = cursor.source;
    var written = cursor.written;
    defer cursor.* = .{ .source = source, .written = written };

    for (0..3) |_| {
        if (source == length) return false;

        const remaining = length - source;

        if (window.len - source < lane_count) {
            const stop: u32 = @intCast(std.mem.findScalarPos(u8, raw, source, '\\') orelse raw.len);

            @memcpy(target[written..][0 .. stop - source], raw[source..stop]);
            written += stop - source;
            source = stop;

            return source != length;
        }

        const chunk: Chunk = window[source..][0..lane_count].*;
        const backslashes: Mask = @bitCast(chunk == @as(Chunk, @splat('\\')));
        const mask = backslashes & lanes_below(remaining);

        target[written..][0..lane_count].* = chunk;

        if (mask != 0) {
            source += @ctz(mask);
            written += @ctz(mask);

            return true;
        }

        const step = @min(remaining, lane_count);

        source += step;
        written += step;
    }

    assert(source == length);

    return false;
}

inline fn lanes_below(remaining: u32) Mask {
    assert(remaining > 0);
    assert(remaining <= input_bytes_max);

    if (remaining >= lane_count) return std.math.maxInt(Mask);
    return (@as(Mask, 1) << @intCast(remaining)) - 1;
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
                sink.advance(escape_direct(sink.unusedCapacitySlice(), text, policy, stops));
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

    var tokenizer: tokenizer_module.Tokenizer = .init(scratch.fixed[0 .. expected.len + 2]);
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
        const produced = unescape_checked(window, length, actual[0 .. length + lane_count]);

        if (reference) |text| {
            try testing.expectEqualStrings(text, actual[0 .. produced orelse return error.Refused]);
        } else {
            try testing.expectEqual(@as(?u32, null), produced);
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
