const std = @import("std");
const builtin = @import("builtin");

const lacuna = @import("lacuna");

const objects = @import("objects.zig");
const shortest = @import("shortest.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const PyObject = c.PyObject;

pub const float_text_max: u32 = 32;
pub const stack_bytes: u32 = 4096;

const chunk_bytes: u32 = 16;
const escape_bytes_max: u32 = 6;
const integer_text_max: u32 = 20;
const eight_digits_limit: u32 = 100_000_000;
const four_digits_limit: u32 = 10_000;

const wide_enabled =
    builtin.target.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx2);

const wide_bytes: u32 = if (wide_enabled) 32 else chunk_bytes;

const Chunk = @Vector(chunk_bytes, u8);
const Wide = @Vector(wide_bytes, u8);

const powers_ten: [integer_text_max]u64 = powers: {
    var table: [integer_text_max]u64 = undefined;
    var power: u64 = 1;

    for (&table, 0..) |*entry, index| {
        entry.* = power;
        if (index + 1 < integer_text_max) power *= 10;
    }

    break :powers table;
};

comptime {
    assert(float_text_max >= 24 + 1);
    assert(escape_bytes_max == "\\u001f".len);
    assert(stack_bytes >= float_text_max);
    assert(eight_digits_limit == powers_ten[8]);
}

pub const Output = struct {
    capacity: u64,
    object: ?*PyObject,
    stack: [stack_bytes]u8,

    pub fn bytes(output: *Output) []u8 {
        assert(output.capacity >= stack_bytes);
        assert(output.object != null or output.capacity == stack_bytes);

        if (output.object) |object| return c.PyBytes_AsString(object).?[0..output.capacity];
        return &output.stack;
    }

    pub fn deinit(output: *Output) void {
        assert(output.capacity >= stack_bytes);
        assert(output.object != null or output.capacity == stack_bytes);

        if (output.object) |object| c.Py_DecRef(object);

        output.object = null;
        output.capacity = stack_bytes;
    }

    pub noinline fn grow(output: *Output, growth: Growth) lacuna.PythonError![]u8 {
        assert(output.capacity - growth.used < growth.extra);
        assert(growth.used <= output.capacity);

        const capacity = @max(output.capacity * 2, growth.used + growth.extra);

        if (output.object == null) {
            const object = c.PyBytes_FromStringAndSize(null, @intCast(capacity)) orelse {
                return error.PythonError;
            };

            const target = c.PyBytes_AsString(object).?[0..capacity];

            @memcpy(target[0..growth.used], output.stack[0..growth.used]);
            output.object = object;
        } else if (objects.versioned) {
            if (c._PyBytes_Resize(&output.object, @intCast(capacity)) != 0) {
                output.object = null;
                output.capacity = stack_bytes;

                return error.PythonError;
            }
        } else {
            try output.replace(.{ .capacity = capacity, .used = growth.used });
        }

        output.capacity = capacity;

        const result = output.bytes();

        assert(result.len - growth.used >= growth.extra);

        return result;
    }

    fn replace(output: *Output, resize: Resize) lacuna.PythonError!void {
        assert(output.object != null);
        assert(resize.used <= output.capacity);

        const capacity = resize.capacity;
        const used = resize.used;

        const object = c.PyBytes_FromStringAndSize(null, @intCast(capacity)) orelse {
            return error.PythonError;
        };

        const target = c.PyBytes_AsString(object).?[0..capacity];

        @memcpy(target[0..used], output.bytes()[0..used]);
        c.Py_DecRef(output.object.?);
        output.object = object;

        assert(output.object != null);
    }

    pub fn finish(output: *Output, length: u64) ?*PyObject {
        assert(length <= output.capacity);
        assert(output.capacity >= stack_bytes);

        if (output.object == null) {
            return c.PyBytes_FromStringAndSize(&output.stack, @intCast(length));
        }

        if (objects.versioned) {
            const result = output.object.?;

            objects.truncate(result, length);
            output.object = null;
            output.capacity = stack_bytes;

            return result;
        }

        const result = c.PyBytes_FromStringAndSize(output.bytes().ptr, @intCast(length));

        output.deinit();

        return result;
    }
};

const Resize = struct {
    capacity: u64,
    used: u64,
};

pub const Growth = struct {
    extra: u64,
    used: u64,
};

pub const Cursor = struct {
    bytes: []u8,
    length: u64,

    pub inline fn free(cursor: *const Cursor) u64 {
        assert(cursor.length <= cursor.bytes.len);
        assert(cursor.bytes.len >= stack_bytes);

        return cursor.bytes.len - cursor.length;
    }

    pub inline fn byte_put(cursor: *Cursor, byte: u8) void {
        assert(cursor.length < cursor.bytes.len);
        assert(cursor.bytes.len >= stack_bytes);

        cursor.bytes[cursor.length] = byte;
        cursor.length += 1;
    }

    pub inline fn put(cursor: *Cursor, text: []const u8) void {
        assert(cursor.bytes.len - cursor.length >= text.len);
        assert(text.len <= std.math.maxInt(u32));

        @memcpy(cursor.bytes[cursor.length..][0..text.len], text);
        cursor.length += text.len;
    }

    pub inline fn literal_put(cursor: *Cursor, comptime text: []const u8) void {
        comptime assert(text.len <= 8);
        assert(cursor.bytes.len - cursor.length >= 8);

        cursor.bytes[cursor.length..][0..text.len].* = text[0..text.len].*;
        cursor.length += text.len;
    }

    pub inline fn close(cursor: *Cursor, closing: u8) void {
        assert(cursor.length > 0);
        assert(cursor.length < cursor.bytes.len);

        assert(cursor.bytes[cursor.length - 1] == ',');

        cursor.bytes[cursor.length - 1] = closing;
        cursor.bytes[cursor.length] = ',';
        cursor.length += 1;
    }

    pub inline fn compact_put(cursor: *Cursor, compact: objects.Compact) void {
        assert(cursor.bytes.len - cursor.length >= integer_text_max + 9);
        assert(compact.magnitude < 1 << 30);

        const window = cursor.bytes[cursor.length..];
        const start: u64 = @intFromBool(compact.negative);
        const digits = window[start..];

        window[0] = '-';

        if (compact.magnitude < four_digits_limit) {
            const count = four_write(digits, compact.magnitude);

            digits[count] = ',';
            cursor.length += start + count + 1;

            return;
        }

        if (compact.magnitude < eight_digits_limit) {
            const count = short_write(digits, compact.magnitude);

            digits[count] = ',';
            cursor.length += start + count + 1;

            return;
        }

        const top: u32 = @divFloor(compact.magnitude, eight_digits_limit);
        const low = compact.magnitude - top * eight_digits_limit;
        const top_count: u64 = if (top < 10) 1 else 2;
        const head: [2]u8 = if (top < 10) .{ '0' + @as(u8, @intCast(top)), '0' } else "10".*;

        digits[0..2].* = head;
        digits[top_count..][0..8].* = @bitCast(eight_digits(low));
        digits[top_count + 8] = ',';
        cursor.length += start + top_count + 9;
    }

    pub inline fn integer_put(cursor: *Cursor, negative: bool, magnitude: u64) void {
        assert(cursor.bytes.len - cursor.length >= integer_text_max + 9);
        if (std.debug.runtime_safety) assert(digits_count(magnitude) <= integer_text_max);

        const window = cursor.bytes[cursor.length..];
        const start: u64 = @intFromBool(negative);
        const count = digits_count(magnitude);

        window[0] = '-';
        digits_write(window[start..], count, magnitude);
        window[start + count] = ',';
        cursor.length += start + count + 1;
    }

    pub inline fn float_put(cursor: *Cursor, value: f64) void {
        assert(std.math.isFinite(value));
        assert(cursor.bytes.len - cursor.length >= float_text_max);

        const target = cursor.bytes[cursor.length..][0..float_text_max];
        const length = float_write(target, value);

        target[length] = ',';
        cursor.length += length + 1;
    }

    pub inline fn regular_put(cursor: *Cursor, bits: u64) void {
        assert(shortest.regular_is(bits));
        assert(cursor.bytes.len - cursor.length >= float_text_max);

        const target = cursor.bytes[cursor.length..][0..float_text_max];
        const start = bits >> 63;

        target[0] = '-';

        const length = start + regular_write(target[start..], shortest.scaled_of(bits));

        target[length] = ',';
        cursor.length += length + 1;
    }

    pub inline fn regular_run_put(cursor: *Cursor, comptime count: u32, values: [count]u64) void {
        comptime assert(count >= 2);
        assert(cursor.bytes.len - cursor.length >= count * float_text_max);
        if (std.debug.runtime_safety) assert(shortest.regular_is(values[0]));

        var layouts: [count]Layout = undefined;

        inline for (values, &layouts) |bits, *layout| {
            assert(shortest.regular_is(bits));

            layout.* = layout_of(shortest.scaled_of(bits));
        }

        const target = cursor.bytes[cursor.length..];

        var length: u64 = 0;

        inline for (values, layouts) |bits, layout| {
            const window = target[length..];
            const start = bits >> 63;

            window[0] = '-';

            const body = window[start..];
            const written = start + significand_write(body, layout.significand, layout.point);

            window[written] = ',';
            length += written + 1;
        }

        cursor.length += length;
    }

    pub inline fn text_put(cursor: *Cursor, text: []const u8, comptime suffix: u8) void {
        assert(cursor.bytes.len - cursor.length >= text_bytes_max(text.len));
        assert(text.len <= std.math.maxInt(u32));

        const target = cursor.bytes[cursor.length..];
        const body = target[1..];

        target[0] = '"';

        const written = if (text.len < chunk_bytes)
            text_short(body, text)
        else if (text.len < wide_bytes)
            text_middle(body, text)
        else
            text_long(body, text);

        body[written..][0..2].* = .{ '"', suffix };
        cursor.length += written + 3;
    }
};

pub fn text_bytes_max(length: u64) u64 {
    assert(length <= std.math.maxInt(u32));
    assert(escape_bytes_max == 6);

    return length * escape_bytes_max + 3 + chunk_bytes;
}

inline fn text_short(target: []u8, text: []const u8) u64 {
    assert(text.len < chunk_bytes);
    assert(target.len >= text.len + chunk_bytes);

    if (plain_is(text)) return plain_write(target, text);
    return escaped_write(target, text);
}

inline fn text_middle(target: []u8, text: []const u8) u64 {
    assert(text.len >= chunk_bytes);
    assert(text.len < wide_bytes);
    if (std.debug.runtime_safety) assert(target.len >= text.len);

    const head: Chunk = text[0..chunk_bytes].*;
    const tail: Chunk = text[text.len - chunk_bytes ..][0..chunk_bytes].*;

    target[0..chunk_bytes].* = head;
    target[text.len - chunk_bytes ..][0..chunk_bytes].* = tail;
    if (special_mask(chunk_bytes, head) | special_mask(chunk_bytes, tail) == 0) return text.len;
    return escaped_finish(target, text, 0);
}

inline fn text_long(target: []u8, text: []const u8) u64 {
    assert(text.len >= wide_bytes);
    assert(target.len >= text.len * escape_bytes_max + chunk_bytes);

    var index: u64 = 0;

    for (0..@divFloor(text.len, wide_bytes)) |_| {
        const chunk: Wide = text[index..][0..wide_bytes].*;

        target[index..][0..wide_bytes].* = chunk;
        if (special_mask(wide_bytes, chunk) != 0) return escaped_finish(target, text, index);

        index += wide_bytes;
    }

    if (index == text.len) return text.len;

    const tail = text.len - wide_bytes;
    const chunk: Wide = text[tail..][0..wide_bytes].*;

    target[tail..][0..wide_bytes].* = chunk;
    if (special_mask(wide_bytes, chunk) != 0) return escaped_finish(target, text, index);
    return text.len;
}

noinline fn escaped_finish(target: []u8, text: []const u8, start: u64) u64 {
    assert(start <= text.len);
    assert(target.len >= text.len * escape_bytes_max + chunk_bytes);

    const initial: Progress = .{ .index = start, .written = start };
    const wide = escaped_chunks(wide_bytes, target, text, initial);
    const narrow = escaped_chunks(chunk_bytes, target, text, wide);
    const written = narrow.written + escaped_write(target[narrow.written..], text[narrow.index..]);

    assert(written >= text.len);

    return written;
}

const Progress = struct {
    index: u64,
    written: u64,
};

inline fn escaped_chunks(
    comptime width: u32,
    target: []u8,
    text: []const u8,
    initial: Progress,
) Progress {
    comptime assert(width == chunk_bytes or width == wide_bytes);
    assert(initial.index <= text.len);
    assert(initial.written >= initial.index);
    if (std.debug.runtime_safety) assert(target.len >= text.len);

    var progress = initial;

    for (0..text.len + 1) |_| {
        if (text.len - progress.index < width) break;

        const chunk: @Vector(width, u8) = text[progress.index..][0..width].*;
        const special = special_mask(width, chunk);

        target[progress.written..][0..width].* = chunk;

        if (special == 0) {
            progress.written += width;
            progress.index += width;

            continue;
        }

        const plain = @ctz(special);

        progress.written += plain;
        progress.index += plain;
        progress.written += escape_write(target[progress.written..], text[progress.index]);
        progress.index += 1;
    }

    assert(text.len - progress.index < width);

    return progress;
}

inline fn plain_write(target: []u8, text: []const u8) u64 {
    assert(target.len >= text.len + chunk_bytes);
    assert(text.len < chunk_bytes);

    if (text.len >= 8) {
        target[0..8].* = text[0..8].*;
        target[text.len - 8 ..][0..8].* = text[text.len - 8 ..][0..8].*;
    } else if (text.len >= 4) {
        target[0..4].* = text[0..4].*;
        target[text.len - 4 ..][0..4].* = text[text.len - 4 ..][0..4].*;
    } else if (text.len > 0) {
        const middle = text.len >> 1;

        target[0] = text[0];
        target[middle] = text[middle];
        target[text.len - 1] = text[text.len - 1];
    } else {
        assert(text.len == 0);
    }

    return text.len;
}

noinline fn escaped_write(target: []u8, text: []const u8) u64 {
    assert(target.len >= text.len * escape_bytes_max + 2);
    assert(text.len <= std.math.maxInt(u32));

    var written: u64 = 0;

    for (text) |byte| {
        if (byte_special(byte)) {
            written += escape_write(target[written..], byte);
        } else {
            target[written] = byte;
            written += 1;
        }
    }

    assert(written >= text.len);

    return written;
}

fn escape_write(target: []u8, byte: u8) u64 {
    assert(byte_special(byte));
    assert(target.len >= 8);

    const entry = escapes[byte];

    target[0..8].* = @bitCast(entry);

    return entry >> 56;
}

const escapes: [0x60]u64 = table: {
    var table: [0x60]u64 = @splat(0);
    const hex = "0123456789abcdef";

    for (0..0x20) |byte| {
        const letter: u8 = switch (byte) {
            0x08 => 'b',
            0x09 => 't',
            0x0a => 'n',
            0x0c => 'f',
            0x0d => 'r',
            else => 0,
        };

        const sequence: []const u8 = if (letter != 0)
            &.{ '\\', letter }
        else
            &.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] };

        table[byte] = escape_entry(sequence);
    }

    table['"'] = escape_entry("\\\"");
    table['\\'] = escape_entry("\\\\");

    break :table table;
};

fn escape_entry(comptime sequence: []const u8) u64 {
    comptime assert(sequence.len >= 2);
    comptime assert(sequence.len <= escape_bytes_max);

    var result: u64 = @as(u64, sequence.len) << 56;

    for (sequence, 0..) |byte, index| result |= @as(u64, byte) << (8 * index);

    assert(result >> 56 == sequence.len);

    return result;
}

inline fn plain_is(text: []const u8) bool {
    assert(text.len < chunk_bytes);
    assert(chunk_bytes == 16);

    if (text.len >= 8) {
        const head = std.mem.readInt(u64, text[0..8], .little);
        const tail = std.mem.readInt(u64, text[text.len - 8 ..][0..8], .little);

        return word_special(head) | word_special(tail) == 0;
    }

    if (text.len >= 4) {
        const head: u64 = std.mem.readInt(u32, text[0..4], .little);
        const tail: u64 = std.mem.readInt(u32, text[text.len - 4 ..][0..4], .little);
        const word = head | tail << 32;

        return word_special(word) == 0;
    }

    if (text.len == 0) return true;

    const filler: u64 = 0x6161_6161_6100_0000;
    const middle = text.len >> 1;
    const word = filler | @as(u64, text[0]) | @as(u64, text[middle]) << 8 |
        @as(u64, text[text.len - 1]) << 16;

    return word_special(word) == 0;
}

fn word_special(word: u64) u64 {
    assert(@sizeOf(u64) == 8);
    assert(chunk_bytes == 16);

    const ones: u64 = 0x0101_0101_0101_0101;
    const highs: u64 = 0x8080_8080_8080_8080;
    const control = (word -% ones *% 0x20) & ~word;
    const quote = word ^ (ones *% '"');
    const backslash = word ^ (ones *% '\\');
    const quote_zero = (quote -% ones) & ~quote;
    const backslash_zero = (backslash -% ones) & ~backslash;

    return (control | quote_zero | backslash_zero) & highs;
}

fn special_mask(comptime width: u32, chunk: @Vector(width, u8)) @Int(.unsigned, width) {
    comptime assert(width == chunk_bytes or width == wide_bytes);
    assert(@sizeOf(@TypeOf(chunk)) == width);

    const Vector = @Vector(width, u8);
    const Mask = @Int(.unsigned, width);
    const control = chunk < @as(Vector, @splat(0x20));
    const quote = chunk == @as(Vector, @splat('"'));
    const backslash = chunk == @as(Vector, @splat('\\'));
    const control_bits: Mask = @bitCast(control);
    const quote_bits: Mask = @bitCast(quote);
    const backslash_bits: Mask = @bitCast(backslash);

    return control_bits | quote_bits | backslash_bits;
}

fn byte_special(byte: u8) bool {
    assert(@sizeOf(u8) == 1);
    assert(escape_bytes_max > 2);

    return switch (byte) {
        0...0x1f, '"', '\\' => true,
        else => false,
    };
}

inline fn four_write(window: []u8, value: u32) u64 {
    assert(value < four_digits_limit);
    assert(window.len >= 4);

    const result: u64 = 1 + @as(u64, @intFromBool(value >= 10)) + @intFromBool(value >= 100) +
        @intFromBool(value >= 1000);
    const hundreds = (value * 5243) >> 19;
    const pairs = hundreds | (value - hundreds * 100) << 16;
    const tens = ((pairs * 103) >> 10) & 0x000f_000f;
    const raw = tens | (pairs - tens * 10) << 8;
    const zeros: u5 = @intCast(4 - result);
    const word = (raw + 0x3030_3030) >> (zeros * 8);

    window[0..4].* = @bitCast(word);

    assert(result == digits_count(value));

    return result;
}

inline fn short_write(window: []u8, value: u32) u64 {
    assert(value < eight_digits_limit);
    assert(window.len >= 8);

    const result: u64 = digits_count(value);
    const raw = eight_digits_raw(value);
    const zeros: u6 = @intCast(8 - result);
    const word = (raw + 0x3030_3030_3030_3030) >> (zeros * 8);

    window[0..8].* = @bitCast(word);

    assert(result >= 1);
    assert(result == 8 - (@ctz(raw | @as(u64, 1) << 56) >> 3));

    return result;
}

fn digits_count(value: u64) u32 {
    assert(@clz(value | 1) < 64);
    assert(powers_ten[integer_text_max - 1] == 10_000_000_000_000_000_000);

    const bits: u32 = 64 - @clz(value | 1);
    const guess = (bits * 1233) >> 12;
    const result = guess + @intFromBool(value | 1 >= powers_ten[guess]);

    assert(result >= 1);
    assert(result <= integer_text_max);

    return result;
}

inline fn digits_write(window: []u8, count: u32, value: u64) void {
    assert(count >= 1);
    assert(window.len >= count + 8);
    assert(count == integer_text_max or value < powers_ten[count]);

    if (count <= 8) return digits_short(window, count, value);

    const low: u32 = @intCast(value % powers_ten[8]);
    const rest = @divFloor(value, powers_ten[8]);

    if (count <= 16) {
        digits_short(window, count - 8, rest);
        window[count - 8 ..][0..8].* = @bitCast(eight_digits(low));

        return;
    }

    const middle: u32 = @intCast(rest % powers_ten[8]);
    const top = @divFloor(rest, powers_ten[8]);

    if (count == 17) {
        window[0] = '0' + @as(u8, @intCast(top));
    } else {
        digits_short(window, count - 16, top);
    }

    window[count - 16 ..][0..8].* = @bitCast(eight_digits(middle));
    window[count - 8 ..][0..8].* = @bitCast(eight_digits(low));
}

fn digits_short(window: []u8, count: u32, value: u64) void {
    assert(count >= 1);
    assert(count <= 8);
    assert(value < powers_ten[count]);
    assert(window.len >= 8);

    const shift: u6 = @intCast(8 * (8 - count));
    const word = eight_digits(@intCast(value)) >> shift;

    window[0..8].* = @bitCast(word);
}

fn eight_digits(value: u32) u64 {
    assert(value < powers_ten[8]);
    assert(@sizeOf(u64) == 8);

    const result = eight_digits_raw(value) + 0x3030_3030_3030_3030;

    assert(result & 0xf0f0_f0f0_f0f0_f0f0 == 0x3030_3030_3030_3030);

    return result;
}

inline fn eight_digits_raw(value: u32) u64 {
    assert(value < powers_ten[8]);
    assert(@sizeOf(u64) == 8);

    const high: u64 = @divFloor(value, 10_000);
    const low: u64 = value - high * 10_000;
    const quads = high | low << 32;
    const hundreds = ((quads * 10_486) >> 20) & 0x0000_007f_0000_007f;
    const pairs = hundreds | (quads - hundreds * 100) << 16;
    const tens = ((pairs * 103) >> 10) & 0x000f_000f_000f_000f;
    const result = tens | (pairs - tens * 10) << 8;

    assert(result & 0xf0f0_f0f0_f0f0_f0f0 == 0);

    return result;
}

pub fn float_format(value: f64, buffer: *[float_text_max]u8) []const u8 {
    assert(std.math.isFinite(value));
    assert(buffer.len == float_text_max);

    const length = float_write(buffer, value);

    assert(length < float_text_max);

    return buffer[0..length];
}

inline fn float_write(target: *[float_text_max]u8, value: f64) u64 {
    assert(std.math.isFinite(value));
    assert(target.len == float_text_max);

    const bits: u64 = @bitCast(value);
    const start = bits >> 63;
    const body = target[start..];

    target[0] = '-';

    if (shortest.regular_is(bits)) {
        const regular = start + regular_write(body, shortest.scaled_of(bits));
        if (std.debug.runtime_safety) assert(regular < float_text_max);
        return regular;
    }

    if (bits << 1 == 0) {
        body[0..4].* = "0.0,".*;

        const zero = start + 3;
        if (std.debug.runtime_safety) assert(zero <= 4);
        return zero;
    }

    const generic = start + generic_write(body, value);
    if (std.debug.runtime_safety) assert(generic < float_text_max);
    return generic;
}

const Sixteen = @Vector(16, u8);

const Significand = struct {
    count: u32,
    digits: Sixteen,
    extra: u8,
};

const digits_shift_mask: [16]i32 = mask: {
    var mask: [16]i32 = undefined;

    for (&mask, 0..) |*entry, index| entry.* = @max(@as(i32, @intCast(index)) - 1, 0);

    break :mask mask;
};

inline fn regular_write(target: []u8, scaled: shortest.Scaled) u64 {
    assert(scaled.digit <= 9);
    assert(scaled.nearest >= powers_ten[14]);
    if (std.debug.runtime_safety) assert(target.len >= float_text_max - 1);

    const layout = layout_of(scaled);

    return significand_write(target, layout.significand, layout.point);
}

const Layout = struct {
    point: i32,
    significand: Significand,
};

inline fn layout_of(scaled: shortest.Scaled) Layout {
    assert(scaled.digit <= 9);
    assert(scaled.nearest >= powers_ten[14]);

    const big: u64 = @intFromBool(scaled.nearest >= powers_ten[15]);
    const select = 0 -% big;
    const extended = scaled.nearest * 10 + scaled.digit;
    const base = (scaled.nearest & select) | (extended & ~select);
    const digits = sixteen_digits(groups_of(base));

    return .{
        .point = scaled.exponent + 16 + @as(i32, @intCast(big)),
        .significand = significand_from(digits, @intCast(scaled.digit & select)),
    };
}

noinline fn generic_write(target: []u8, value: f64) u64 {
    assert(std.math.isFinite(value));
    assert(value != 0);
    if (std.debug.runtime_safety) assert(target.len >= float_text_max - 1);

    const decimal = shortest.decimal_of(value);
    const count = digits_count(decimal.mantissa);
    const normalized = decimal.mantissa * powers_ten[17 - count];
    const base = @divFloor(normalized, 10);
    const digits = sixteen_digits(groups_of(base));
    const significand = significand_from(digits, @intCast(normalized - base * 10));
    const point = decimal.exponent + @as(i32, @intCast(count));

    return significand_write(target, significand, point);
}

inline fn significand_from(digits: Sixteen, extra: u8) Significand {
    assert(digits[0] != '0');
    assert(extra <= 9);

    const zeros: u16 = @bitCast(digits == @as(Sixteen, @splat('0')));
    const mask = @as(u32, ~zeros) | @as(u32, @intFromBool(extra != 0)) << 16;

    const result: Significand = .{
        .count = 32 - @as(u32, @clz(mask)),
        .digits = digits,
        .extra = '0' + extra,
    };

    assert(result.count >= 1);
    assert(result.count <= 17);

    return result;
}

inline fn significand_write(target: []u8, significand: Significand, point: i32) u64 {
    assert(significand.count >= 1);
    assert(target.len >= float_text_max - 1);
    if (std.debug.runtime_safety) assert(@abs(point) <= 400);

    if (point > 16) {
        const large = scientific_write(target, significand, point - 1);
        if (std.debug.runtime_safety) assert(large < float_text_max);
        return large;
    }

    if (point >= significand.count) {
        const integral = integral_write(target, significand, @intCast(point));
        if (std.debug.runtime_safety) assert(integral < float_text_max);
        return integral;
    }

    if (point > 0) {
        const mixed = mixed_write(target, significand, @intCast(point));
        if (std.debug.runtime_safety) assert(mixed < float_text_max);
        return mixed;
    }

    if (point >= -3) {
        const fraction = fraction_write(target, significand, @intCast(-point));
        if (std.debug.runtime_safety) assert(fraction < float_text_max);
        return fraction;
    }

    const small = scientific_write(target, significand, point - 1);
    if (std.debug.runtime_safety) assert(small < float_text_max);
    return small;
}

inline fn sixteen_digits(groups: @Vector(2, u64)) Sixteen {
    assert(@reduce(.Max, groups & @as(@Vector(2, u64), @splat(0xffff_ffff))) < 10_000);
    assert(@reduce(.Max, groups >> @splat(32)) < 10_000);

    const values: Lanes = @bitCast(groups);
    const hundreds = high_of(values, 5243) >> @splat(3);
    const remainders = values - hundreds * @as(Lanes, @splat(100));
    const hundreds_quads: Quads = @bitCast(hundreds);
    const remainders_quads: Quads = @bitCast(remainders);
    const pairs: Lanes = @bitCast(hundreds_quads | remainders_quads << @splat(16));
    const tens = high_of(pairs, 6554);
    const digits = tens | (pairs - tens * @as(Lanes, @splat(10))) << @splat(8);
    const result: Sixteen = @bitCast(digits);

    assert(@reduce(.Max, result) <= 9);

    return result | @as(Sixteen, @splat('0'));
}

const Lanes = @Vector(8, u16);
const Quads = @Vector(4, u32);

inline fn groups_of(base: u64) @Vector(2, u64) {
    assert(base < powers_ten[16]);
    assert(powers_ten[4] == 10_000);

    const first = @divFloor(base, powers_ten[12]);
    const upper = @divFloor(base, powers_ten[8]);
    const lower = @divFloor(base, powers_ten[4]);
    const second = upper - first * powers_ten[4];
    const third = lower - upper * powers_ten[4];
    const fourth = base - lower * powers_ten[4];

    return .{ first | second << 32, third | fourth << 32 };
}

inline fn high_of(values: Lanes, factor: u16) Lanes {
    assert(factor > 0);
    if (std.debug.runtime_safety) assert(@reduce(.Max, values) < 10_000);

    const product = @as(@Vector(8, u32), values) * @as(@Vector(8, u32), @splat(factor));

    return @intCast(product >> @splat(16));
}

inline fn mixed_write(target: []u8, significand: Significand, point: u32) u64 {
    assert(point >= 1);
    assert(point < significand.count);
    if (std.debug.runtime_safety) assert(target.len >= 18);

    const iota = std.simd.iota(u8, 16);
    const split: Sixteen = @splat(@intCast(point));
    const shifted = @shuffle(u8, significand.digits, undefined, digits_shift_mask);
    const dot: Sixteen = @splat('.');
    const after = @select(u8, iota == split, dot, shifted);

    target[1..17].* = significand.digits;
    target[17] = significand.extra;
    target[0..16].* = @select(u8, iota < split, significand.digits, after);
    target[point] = '.';

    const result = significand.count + 1;
    if (std.debug.runtime_safety) assert(result <= 18);
    return result;
}

inline fn integral_write(target: []u8, significand: Significand, point: u32) u64 {
    assert(point >= significand.count);
    assert(point <= 16);
    if (std.debug.runtime_safety) assert(target.len >= 18);

    target[0..16].* = significand.digits;
    target[point..][0..2].* = ".0".*;

    const result = point + 2;
    if (std.debug.runtime_safety) assert(result <= 18);
    return result;
}

inline fn fraction_write(target: []u8, significand: Significand, zeros: u32) u64 {
    assert(zeros <= 3);
    assert(significand.count >= 1);
    if (std.debug.runtime_safety) assert(target.len >= 22);

    target[0..8].* = "0.000000".*;
    target[2 + zeros ..][0..16].* = significand.digits;
    target[18 + zeros] = significand.extra;

    const result = 2 + zeros + significand.count;
    if (std.debug.runtime_safety) assert(result <= 22);
    return result;
}

fn scientific_write(target: []u8, significand: Significand, exponent: i32) u64 {
    if (exponent >= -4) assert(exponent >= 16);
    assert(@abs(exponent) <= 400);
    if (std.debug.runtime_safety) assert(significand.count >= 1);
    if (std.debug.runtime_safety) assert(target.len >= float_text_max - 1);

    target[1..17].* = significand.digits;
    target[17] = significand.extra;
    target[0] = significand.digits[0];
    target[1] = '.';

    const mantissa_length: u64 = if (significand.count > 1) significand.count + 1 else 1;
    const magnitude: u32 = @abs(exponent);
    const tail = target[mantissa_length..];

    tail[0..2].* = .{ 'e', if (exponent < 0) '-' else '+' };

    if (magnitude < 100) {
        tail[2..4].* = digit_pair(magnitude);

        const short = mantissa_length + 4;
        if (std.debug.runtime_safety) assert(short < float_text_max);
        return short;
    }

    tail[2] = '0' + @as(u8, @intCast(@divFloor(magnitude, 100)));
    tail[3..5].* = digit_pair(magnitude % 100);

    const long = mantissa_length + 5;
    if (std.debug.runtime_safety) assert(long < float_text_max);
    return long;
}

fn digit_pair(value: u32) [2]u8 {
    assert(value < 100);
    assert(@sizeOf(u8) == 1);

    return .{ '0' + @as(u8, @intCast(@divFloor(value, 10))), '0' + @as(u8, @intCast(value % 10)) };
}

test float_format {
    const Case = struct {
        expected: []const u8,
        value: f64,
    };

    const cases = [_]Case{
        .{ .expected = "0.0", .value = 0.0 },
        .{ .expected = "-0.0", .value = -0.0 },
        .{ .expected = "1.0", .value = 1.0 },
        .{ .expected = "100.0", .value = 100.0 },
        .{ .expected = "0.1", .value = 0.1 },
        .{ .expected = "0.0001", .value = 0.0001 },
        .{ .expected = "1e-05", .value = 0.00001 },
        .{ .expected = "1.5e-05", .value = 0.000015 },
        .{ .expected = "1000000000000000.0", .value = 1e15 },
        .{ .expected = "1e+16", .value = 1e16 },
        .{ .expected = "1.2345678901234568e+17", .value = 123456789012345680.0 },
        .{ .expected = "-65.598343", .value = -65.598343 },
        .{ .expected = "5e-324", .value = 5e-324 },
        .{ .expected = "1.7976931348623157e+308", .value = std.math.floatMax(f64) },
    };

    for (cases) |case| {
        var buffer: [float_text_max]u8 = undefined;

        try std.testing.expectEqualStrings(case.expected, float_format(case.value, &buffer));
    }
}

test "formatted floats parse back to the same value" {
    var prng: std.Random.DefaultPrng = .init(0x666c6f61);
    const random = prng.random();

    for (0..200_000) |_| {
        const bits = random.int(u64);
        const value: f64 = @bitCast(bits);

        if (!std.math.isFinite(value)) continue;

        var buffer: [float_text_max]u8 = undefined;

        const text = float_format(value, &buffer);
        const parsed = std.fmt.parseFloat(f64, text) catch unreachable;

        try std.testing.expectEqual(bits, @as(u64, @bitCast(parsed)));
    }
}

test "floats format like a reference built on the standard library digits" {
    var prng: std.Random.DefaultPrng = .init(0x7265_7072);
    const random = prng.random();

    var actual_buffer: [float_text_max]u8 = undefined;
    var expected_buffer: [64]u8 = undefined;

    for (0..1_000_000) |index| {
        const value = float_random(random, index);

        if (!std.math.isFinite(value)) continue;

        const expected = repr_reference(&expected_buffer, value);
        const actual = float_format(value, &actual_buffer);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

fn float_random(random: std.Random, index: u64) f64 {
    assert(@sizeOf(f64) == 8);
    assert(index < std.math.maxInt(u32));

    const integer: f64 = @floatFromInt(random.int(i64) >> random.uintLessThan(u6, 63));
    const scale = std.math.pow(f64, 10, @floatFromInt(random.intRangeAtMost(i32, -8, 20)));

    const biased: u64 = random.intRangeAtMost(u64, 1000, 1080);

    const result: f64 = switch (index % 5) {
        0 => @bitCast(random.int(u64)),
        1 => integer,
        2 => integer / scale,
        3 => @bitCast(random.int(u64) & 0x800f_ffff_ffff_ffff | biased << 52),
        else => @floatCast(@as(f32, @bitCast(random.int(u32)))),
    };

    if (index % 5 == 1) assert(result == integer);

    return result;
}

fn repr_reference(buffer: []u8, value: f64) []const u8 {
    assert(std.math.isFinite(value));
    assert(buffer.len >= 32);

    var writer: std.Io.Writer = .fixed(buffer);

    if (std.math.signbit(value)) writer.writeByte('-') catch unreachable;

    if (value == 0) {
        writer.writeAll("0.0") catch unreachable;

        return buffer[0..writer.end];
    }

    const bits: u64 = @bitCast(@abs(value));
    const tables = &std.fmt.float.Backend64_TablesFull;
    const decimal = std.fmt.float.binaryToDecimal(u64, bits, 52, 11, false, tables);

    var digits_buffer: [24]u8 = undefined;
    var mantissa = decimal.mantissa;
    var exponent = decimal.exponent;

    for (0..20) |_| {
        if (mantissa % 10 != 0) break;

        mantissa = @divExact(mantissa, 10);
        exponent += 1;
    }

    const digits = std.mem.print(&digits_buffer, "{d}", .{mantissa}) catch unreachable;
    const count: i32 = @intCast(digits.len);
    const leading = exponent + count - 1;
    const scientific = leading < -4 or leading >= 16;

    if (scientific) {
        writer.writeByte(digits[0]) catch unreachable;

        if (digits.len > 1) writer.print(".{s}", .{digits[1..]}) catch unreachable;

        const sign: u8 = if (leading < 0) '-' else '+';

        writer.print("e{c}{d:0>2}", .{ sign, @abs(leading) }) catch unreachable;
    } else if (leading >= 0) {
        const whole: u64 = @intCast(leading + 1);

        if (digits.len > whole) {
            writer.print("{s}.{s}", .{ digits[0..whole], digits[whole..] }) catch unreachable;
        } else {
            writer.writeAll(digits) catch unreachable;
            writer.splatByteAll('0', whole - digits.len) catch unreachable;
            writer.writeAll(".0") catch unreachable;
        }
    } else {
        writer.writeAll("0.") catch unreachable;
        writer.splatByteAll('0', @intCast(-leading - 1)) catch unreachable;
        writer.writeAll(digits) catch unreachable;
    }

    return buffer[0..writer.end];
}

test "integers format like the standard library" {
    var prng: std.Random.DefaultPrng = .init(0x696e7465);
    const random = prng.random();

    for (0..100_000) |_| {
        const shift = random.uintLessThan(u6, 63);
        const value = random.int(i64) >> shift;

        var expected_buffer: [24]u8 = undefined;
        var actual_buffer: [32]u8 = undefined;

        const expected = std.mem.print(&expected_buffer, "{d}", .{value}) catch unreachable;
        const magnitude = @abs(value);
        const count = digits_count(magnitude);

        digits_write(&actual_buffer, count, magnitude);

        const unsigned = expected[@intFromBool(value < 0)..];

        try std.testing.expectEqualStrings(unsigned, actual_buffer[0..count]);
    }
}

test "compact integers format like the standard library" {
    var prng: std.Random.DefaultPrng = .init(0x636f6d70);
    const random = prng.random();

    var bytes: [stack_bytes]u8 = undefined;

    for (0..100_000) |index| {
        const shift = random.uintLessThan(u5, 30);
        const magnitude: u32 = if (index < 1000)
            @intCast(index)
        else
            random.uintLessThan(u32, 1 << 30) >> shift;
        const negative = random.boolean();

        var cursor: Cursor = .{ .bytes = &bytes, .length = 0 };
        var expected_buffer: [24]u8 = undefined;

        cursor.compact_put(.{ .magnitude = magnitude, .negative = negative });

        const sign = if (negative) "-" else "";
        const printed = std.mem.print(&expected_buffer, "{s}{d},", .{ sign, magnitude });
        const expected = printed catch unreachable;

        try std.testing.expectEqualStrings(expected, bytes[0..cursor.length]);
    }
}

test "text writes escape like the standard library" {
    var prng: std.Random.DefaultPrng = .init(0x74657874);
    const random = prng.random();
    const alphabet = "ab\"\\\n\x00\x1f\x7f /\xc3\xa9";

    var bytes: [stack_bytes]u8 = undefined;
    var text: [80]u8 = undefined;
    var expected: [stack_bytes]u8 = undefined;

    for (0..20_000) |_| {
        const length = random.uintLessThan(u32, text.len);

        for (text[0..length]) |*byte| byte.* = alphabet[random.uintLessThan(u32, alphabet.len)];

        var cursor: Cursor = .{ .bytes = &bytes, .length = 0 };

        cursor.text_put(text[0..length], ':');

        const count = escaped_reference(&expected, text[0..length]);

        try std.testing.expectEqualStrings(expected[0..count], bytes[0..cursor.length]);
    }
}

fn escaped_reference(target: []u8, text: []const u8) u64 {
    assert(target.len >= text.len * escape_bytes_max + 3);
    assert(text.len <= std.math.maxInt(u32));

    var writer: std.Io.Writer = .fixed(target);

    writer.writeByte('"') catch unreachable;

    for (text) |byte| {
        const escaped: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };

        if (escaped) |sequence| {
            writer.writeAll(sequence) catch unreachable;
        } else if (byte < 0x20) {
            writer.print("\\u{x:0>4}", .{byte}) catch unreachable;
        } else {
            writer.writeByte(byte) catch unreachable;
        }
    }

    writer.writeAll("\":") catch unreachable;

    return writer.end;
}
