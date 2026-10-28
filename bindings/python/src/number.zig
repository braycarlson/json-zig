const std = @import("std");

const json = @import("json");
const lacuna = @import("lacuna");

const integers = @import("integers.zig");
const objects = @import("objects.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const PyObject = c.PyObject;

pub const Error = lacuna.PythonError;
pub const Failure = error{Declined} || Error;

const decimal_digits_max: u32 = 19;
const exact_digits_max: u32 = 15;
const exact_mantissa_max: u64 = 1 << 53;
const exact_places_max: u32 = 22;
const far_bytes_min: u32 = 24;
const exponent_magnitude_max: i32 = 100_000;
const quotient_bits_min: u32 = 56;

const powers_integer: [decimal_digits_max + 1]u64 = powers: {
    var table: [decimal_digits_max + 1]u64 = undefined;
    var power: u64 = 1;

    for (&table, 0..) |*entry, exponent| {
        entry.* = power;
        if (exponent < decimal_digits_max) power *= 10;
    }

    break :powers table;
};

const powers_exact: [exact_places_max + 1]f64 = powers: {
    var table: [exact_places_max + 1]f64 = undefined;
    var power: f64 = 1;

    for (&table) |*entry| {
        entry.* = power;
        power *= 10;
    }

    break :powers table;
};

comptime {
    assert(powers_integer[decimal_digits_max] < std.math.maxInt(u64));
    assert(quotient_bits_min < 64);
    assert(exact_mantissa_max == @as(u64, 1) << (std.math.floatMantissaBits(f64) + 1));
    assert(powers_exact[exact_places_max] == 1e22);
    assert(std.math.pow(u128, 5, exact_places_max) < exact_mantissa_max);
    assert(powers_integer[exact_digits_max] < exact_mantissa_max);
}

pub const Number = struct {
    length: u32,
    reach: []const u8,

    fn text(number: Number) []const u8 {
        assert(number.length > 0);
        assert(number.length <= number.reach.len);

        return number.reach[0..number.length];
    }
};

pub const Decimal = struct {
    end: u32,
    exponent: i32,
    fractional: bool,
    mantissa: u64,
    negative: bool,
};

pub fn object_of(number: Number) Error!*PyObject {
    assert(number.length > 0);
    assert(number.length <= json.limits.input_bytes_max);

    const text = number.text();
    const decimal = decimal_of(number) orelse {
        if (std.mem.findAny(u8, text, ".eE") != null) return float_object(float_parsed(text));
        return python_number("int", text);
    };

    if (decimal.fractional) return float_object(float_of(decimal) orelse float_parsed(text));

    if (!decimal.negative) {
        return c.PyLong_FromUnsignedLongLong(decimal.mantissa) orelse error.PythonError;
    }

    if (decimal.mantissa > @as(u64, std.math.maxInt(i64)) + 1) return python_number("int", text);

    const value: i64 = @intCast(-@as(i128, decimal.mantissa));

    return c.PyLong_FromLongLong(value) orelse error.PythonError;
}

const exponent_digits_max: u32 = 5;

const decimal_zero: Decimal = .{
    .end = 0,
    .exponent = 0,
    .fractional = false,
    .mantissa = 0,
    .negative = false,
};

pub const Span = struct {
    end: u32,
    start: u32,
};

pub const Parsed = struct {
    end: u32,
    object: *PyObject,
};

pub const Scanned = struct {
    decimal: Decimal,
    slow: bool,
};

pub inline fn fused_of(input: [:0]const u8, start: u32, cache: *integers.Cache) Failure!*PyObject {
    assert(start < input.len);
    assert(input.len <= json.limits.input_bytes_max);

    if (input.len - start < far_bytes_min) return general_object(input, start);

    const decimal = quick_scan(input, start) orelse return general_object(input, start);

    return quick_object(decimal, cache);
}

pub inline fn parsed_of(input: [:0]const u8, start: u32, cache: *integers.Cache) Failure!Parsed {
    assert(start < input.len);
    assert(input.len <= json.limits.input_bytes_max);

    if (input.len - start >= far_bytes_min) {
        if (quick_scan(input, start)) |decimal| {
            const object = try quick_object(decimal, cache);

            return .{ .end = decimal.end, .object = object };
        }
    }

    return general_parsed(input, start);
}

noinline fn general_parsed(input: [:0]const u8, start: u32) Failure!Parsed {
    assert(start < input.len);
    assert(input.len <= json.limits.input_bytes_max);

    const scanned = scan_near(input, start) orelse return error.Declined;
    if (scanned.slow) return slow_parsed(input, start);

    const object = try decimal_object(scanned.decimal, input[start..scanned.decimal.end]);

    return .{ .end = scanned.decimal.end, .object = object };
}

noinline fn general_object(input: [:0]const u8, start: u32) Failure!*PyObject {
    assert(start < input.len);
    assert(input.len <= json.limits.input_bytes_max);

    const scanned = scan_near(input, start) orelse return error.Declined;
    if (scanned.slow) return slow_object(input, start);

    return decimal_object(scanned.decimal, input[start..scanned.decimal.end]);
}

pub fn root_object(input: [:0]const u8, span: Span) Failure!*PyObject {
    assert(span.start < span.end);
    assert(span.end <= input.len);

    const scanned = scan_near(input, span.start) orelse return error.Declined;
    if (scanned.decimal.end != span.end) return error.Declined;
    if (scanned.slow) return slow_object(input, span.start);

    return decimal_object(scanned.decimal, input[span.start..span.end]);
}

inline fn quick_object(decimal: Decimal, cache: *integers.Cache) Error!*PyObject {
    assert(decimal.mantissa < powers_integer[decimal_digits_max]);
    assert(@abs(decimal.exponent) <= decimal_digits_max);

    if (!decimal.fractional) {
        const magnitude: i64 = @intCast(decimal.mantissa);
        const sign = -@as(i64, @intFromBool(decimal.negative));
        const value = (magnitude ^ sign) - sign;

        if (integers.small_is(value)) return c.PyLong_FromLongLong(value) orelse error.PythonError;

        const object = cache.object_of(value) orelse return error.PythonError;

        objects.acquire(object);

        return object;
    }

    const magnitude: u64 = @bitCast(quick_magnitude(decimal.mantissa, decimal.exponent));
    const sign = @as(u64, @intFromBool(decimal.negative)) << 63;

    return float_object(@bitCast(magnitude | sign));
}

inline fn quick_magnitude(mantissa: u64, exponent: i32) f64 {
    assert(mantissa < powers_integer[decimal_digits_max]);
    assert(@abs(exponent) <= decimal_digits_max);

    if (mantissa < powers_integer[exact_digits_max]) return exact_of(mantissa, exponent);

    const places: u32 = @intCast(@abs(exponent));
    if (exponent >= 0) return product_rounded(mantissa, places);
    return reciprocal_rounded(mantissa, places) orelse quotient_rounded(mantissa, places);
}

inline fn quick_scan(input: [:0]const u8, start: u32) ?Decimal {
    assert(input.len - start >= far_bytes_min);
    assert(input[input.len] == 0);

    const negative = input[start] == '-';
    const digits_start = start + @intFromBool(negative);
    const first = input[digits_start] -% '0';

    if (first >= 10) return null;

    const integer = run_short(input, digits_start, first) orelse return null;

    if (first == 0) {
        if (integer.count > 1) return null;
    }

    const end = digits_start + integer.count;

    var decimal: Decimal = .{
        .end = end,
        .exponent = 0,
        .fractional = false,
        .mantissa = integer.value,
        .negative = negative,
    };

    switch (stop_classes[integer.stop]) {
        .end => return decimal,
        .exponent => return exponent_quick(input, end, decimal),
        .fraction => {},
        .invalid => return null,
    }

    const fraction = fraction_run(input, end + 1) orelse return null;
    if (fraction.count == 0) return null;
    if (integer.count + fraction.count > decimal_digits_max) return null;

    decimal.mantissa = decimal.mantissa * powers_integer[fraction.count] + fraction.value;
    decimal.exponent = -@as(i32, @intCast(fraction.count));
    decimal.fractional = true;
    decimal.end = end + 1 + fraction.count;

    return switch (stop_classes[fraction.stop]) {
        .end => decimal,
        .exponent => exponent_quick(input, end + 1 + fraction.count, decimal),
        .fraction, .invalid => null,
    };
}

const Stop = enum {
    end,
    exponent,
    fraction,
    invalid,
};

const stop_classes: [256]Stop = classes: {
    var table: [256]Stop = @splat(.invalid);

    for (" \t\n\r,:[]{}") |byte| table[byte] = .end;

    table['.'] = .fraction;
    table['e'] = .exponent;
    table['E'] = .exponent;

    break :classes table;
};

fn exponent_quick(input: [:0]const u8, marker: u32, decimal: Decimal) ?Decimal {
    assert(input[marker] | 0x20 == 'e');
    assert(@abs(decimal.exponent) <= decimal_digits_max);

    const exponent = exponent_scan(input, marker + 1) orelse return null;
    if (exponent.count > exponent_digits_max) return null;
    if (stop_classes[input[exponent.end]] != .end) return null;

    var result = decimal;

    result.end = exponent.end;
    result.exponent += exponent.value;
    result.fractional = true;
    if (@abs(result.exponent) > decimal_digits_max) return null;

    return result;
}

inline fn fraction_run(input: [:0]const u8, index: u32) ?Run {
    assert(index <= input.len);
    assert(input[input.len] == 0);

    if (input.len - index < 16) return null;

    const head = word_at(input, index);
    const head_mask = digits_mask(head);

    if (head_mask != 0) {
        const count: u32 = @ctz(head_mask) >> 3;
        const stop: u8 = @truncate(head >> @intCast(8 * count));
        if (count == 0) return .{ .count = 0, .stop = stop, .value = 0 };

        return .{ .count = count, .stop = stop, .value = run_value(head, count) };
    }

    const tail = word_at(input, index + 8);
    const tail_mask = digits_mask(tail);
    if (tail_mask == 0) return null;

    const tail_count: u32 = @ctz(tail_mask) >> 3;
    const stop: u8 = @truncate(tail >> @intCast(8 * tail_count));
    const value = eight_digits_of(head);
    if (tail_count == 0) return .{ .count = 8, .stop = stop, .value = value };

    const result: Run = .{
        .count = 8 + tail_count,
        .stop = stop,
        .value = value * powers_integer[tail_count] + run_value(tail, tail_count),
    };

    assert(result.value < powers_integer[result.count]);

    return result;
}

const Run = struct {
    count: u32,
    stop: u8,
    value: u64,
};

inline fn run_short(input: [:0]const u8, digits_start: u32, first: u8) ?Run {
    assert(first < 10);
    assert(input.len - digits_start >= far_bytes_min - 1);

    const second = input[digits_start + 1] -% '0';
    if (second >= 10) return .{ .count = 1, .stop = second +% '0', .value = first };

    const third = input[digits_start + 2] -% '0';
    if (third >= 10) {
        return .{ .count = 2, .stop = third +% '0', .value = @as(u64, first) * 10 + second };
    }

    const fourth = input[digits_start + 3] -% '0';

    if (fourth >= 10) {
        return .{
            .count = 3,
            .stop = fourth +% '0',
            .value = @as(u64, first) * 100 + @as(u64, second) * 10 + third,
        };
    }

    return run_of(input, digits_start);
}

inline fn run_of(input: [:0]const u8, digits_start: u32) ?Run {
    assert(input.len - digits_start >= far_bytes_min - 1);
    assert(input[digits_start] -% '0' < 10);

    const head = word_at(input, digits_start);
    const head_count: u32 = @ctz(digits_mask(head)) >> 3;

    if (head_count < 8) {
        return .{
            .count = head_count,
            .stop = @truncate(head >> @intCast(8 * head_count)),
            .value = run_value(head, head_count),
        };
    }

    const tail = word_at(input, digits_start + 8);
    const tail_count: u32 = @ctz(digits_mask(tail)) >> 3;

    if (tail_count == 8) return null;
    if (tail_count == 0) {
        return .{ .count = 8, .stop = @truncate(tail), .value = eight_digits_of(head) };
    }

    const result: Run = .{
        .count = 8 + tail_count,
        .stop = @truncate(tail >> @intCast(8 * tail_count)),
        .value = eight_digits_of(head) * powers_integer[tail_count] + run_value(tail, tail_count),
    };

    assert(result.value < powers_integer[result.count]);

    return result;
}

inline fn word_at(input: [:0]const u8, index: u32) u64 {
    assert(input.len - index >= 8);
    assert(input[input.len] == 0);

    return std.mem.readInt(u64, input[index..][0..8], .little);
}

inline fn scalar_end(byte: u8) bool {
    assert(scalar_end_table.len == 256);
    if (std.debug.runtime_safety) assert(scalar_end_table[byte] == ends_listed.isSet(byte));

    return scalar_end_table[byte];
}

const ends_listed: std.StaticBitSet(256) = listed: {
    var set: std.StaticBitSet(256) = .initEmpty();

    for (scalar_end_bytes) |byte| set.set(byte);

    break :listed set;
};

const scalar_end_bytes = " \t\n\r,:[]{}";

const scalar_end_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (scalar_end_bytes) |byte| table[byte] = true;

    break :table table;
};

inline fn scan_near(input: [:0]const u8, start: u32) ?Scanned {
    assert(start < input.len);
    assert(input[input.len] == 0);

    const negative = input[start] == '-';
    const digits_start = start + @intFromBool(negative);

    var index = digits_start;
    const mantissa = digits_add(input, &index, 0);

    const integer_count = index - digits_start;
    if (integer_count == 0) return null;
    if (input[digits_start] == '0') {
        if (integer_count > 1) return null;
    }

    if (integer_count > decimal_digits_max) {
        var decimal = decimal_zero;

        decimal.end = index;

        return .{ .decimal = decimal, .slow = true };
    }

    const head: Head = .{
        .digits_start = digits_start,
        .index = index,
        .mantissa = mantissa,
        .negative = negative,
    };

    return scan_rest(input, head);
}

const Head = struct {
    digits_start: u32,
    index: u32,
    mantissa: u64,
    negative: bool,
};

inline fn scan_rest(input: [:0]const u8, head: Head) ?Scanned {
    assert(head.index > head.digits_start);
    assert(head.index <= input.len);

    var index = head.index;
    var mantissa = head.mantissa;
    var exponent: i32 = 0;
    var fractional = false;

    if (input[index] == '.') {
        index += 1;

        const fraction_start = index;

        mantissa = fraction_add(input, &index, mantissa);

        const fraction_count = index - fraction_start;
        if (fraction_count == 0) return null;

        exponent = -@as(i32, @intCast(fraction_count));
        fractional = true;
    }

    const digit_count = index - head.digits_start - @intFromBool(fractional);
    var slow = digit_count > decimal_digits_max;

    if (input[index] | 0x20 == 'e') {
        const scanned = exponent_scan(input, index + 1) orelse return null;

        slow = slow or scanned.count > exponent_digits_max;
        exponent += scanned.value;
        fractional = true;
        index = scanned.end;
    }

    if (!slow) if (!json.structural.scalar_ended(input, index)) return null;

    return .{
        .decimal = .{
            .end = index,
            .exponent = exponent,
            .fractional = fractional,
            .mantissa = mantissa,
            .negative = head.negative,
        },
        .slow = slow,
    };
}

inline fn fraction_add(input: [:0]const u8, index: *u32, mantissa_start: u64) u64 {
    assert(index.* <= input.len);
    assert(mantissa_start < powers_integer[decimal_digits_max]);

    if (input.len - index.* < 16) return digits_add(input, index, mantissa_start);

    const start = index.*;
    const head = std.mem.readInt(u64, input[start..][0..8], .little);
    const head_count: u32 = @ctz(digits_mask(head)) >> 3;

    if (head_count < 8) {
        if (head_count == 0) return mantissa_start;

        index.* += head_count;

        const result = mantissa_start *% powers_integer[head_count] +% run_value(head, head_count);

        assert(index.* - start == head_count);

        return result;
    }

    const tail = std.mem.readInt(u64, input[start + 8 ..][0..8], .little);
    const tail_count: u32 = @ctz(digits_mask(tail)) >> 3;
    const mantissa = mantissa_start *% powers_integer[8] +% eight_digits_of(head);

    const result = if (tail_count == 0)
        mantissa
    else
        mantissa *% powers_integer[tail_count] +% run_value(tail, tail_count);

    index.* += 8 + tail_count;

    if (tail_count < 8) {
        assert(index.* - start == 8 + tail_count);

        return result;
    }

    const extended = digits_add(input, index, result);

    assert(index.* - start >= 16);

    return extended;
}

inline fn digits_add(input: [:0]const u8, index: *u32, mantissa_start: u64) u64 {
    assert(index.* <= input.len);
    assert(input[input.len] == 0);

    var mantissa = mantissa_start;

    for (0..input.len - index.* + 1) |_| {
        const digit = input[index.*] -% '0';
        if (digit >= 10) break;

        mantissa = mantissa *% 10 +% digit;
        index.* += 1;
    }

    return mantissa;
}

const Exponent = struct {
    count: u32,
    end: u32,
    value: i32,
};

fn exponent_scan(input: [:0]const u8, start: u32) ?Exponent {
    assert(start <= input.len);
    assert(start > 0);

    const sign_length: u32 = switch (input[start]) {
        '+', '-' => 1,
        else => 0,
    };

    const digits_start = start + sign_length;
    const negative = input[start] == '-';

    var index = digits_start;
    var magnitude: i32 = 0;

    for (0..exponent_digits_max + 1) |_| {
        const digit = input[index] -% '0';
        if (digit >= 10) break;

        magnitude = magnitude * 10 + digit;
        index += 1;
    }

    const count = index - digits_start;
    if (count == 0) return null;

    if (count > exponent_digits_max) {
        return .{ .count = count, .end = index, .value = 0 };
    }

    return .{ .count = count, .end = index, .value = if (negative) -magnitude else magnitude };
}

fn decimal_object(decimal: Decimal, text: []const u8) Error!*PyObject {
    assert(text.len > 0);
    assert(decimal.mantissa < powers_integer[decimal_digits_max]);

    if (decimal.fractional) return float_object(float_of(decimal) orelse float_parsed(text));

    if (!decimal.negative) {
        return c.PyLong_FromUnsignedLongLong(decimal.mantissa) orelse error.PythonError;
    }

    if (decimal.mantissa > @as(u64, std.math.maxInt(i64)) + 1) return python_number("int", text);

    const value: i64 = @intCast(-@as(i128, decimal.mantissa));

    return c.PyLong_FromLongLong(value) orelse error.PythonError;
}

fn slow_object(input: [:0]const u8, start: u32) Failure!*PyObject {
    assert(start < input.len);
    assert(input.len <= json.limits.input_bytes_max);

    const parsed = try slow_parsed(input, start);

    return parsed.object;
}

fn slow_parsed(input: [:0]const u8, start: u32) Failure!Parsed {
    assert(start < input.len);
    assert(input.len <= json.limits.input_bytes_max);

    const end = if (input[start] == '-')
        json.structural.number_end(input, start, true) catch return error.Declined
    else
        json.structural.number_end(input, start, false) catch return error.Declined;

    if (!json.structural.scalar_ended(input, end)) return error.Declined;

    const object = try object_of(.{ .length = end - start, .reach = input[start..] });

    return .{ .end = end, .object = object };
}

fn float_object(value: f64) Error!*PyObject {
    assert(!std.math.isNan(value));
    assert(@sizeOf(f64) == 8);

    return c.PyFloat_FromDouble(value) orelse error.PythonError;
}

fn float_parsed(text: []const u8) f64 {
    assert(text.len > 0);
    assert(text.len <= json.limits.input_bytes_max);

    const result = std.fmt.parseFloat(f64, text) catch unreachable;

    assert(!std.math.isNan(result));

    return result;
}

inline fn decimal_of(number: Number) ?Decimal {
    assert(number.length > 0);
    assert(number.length <= number.reach.len);

    const text = number.text();
    const negative = text[0] == '-';
    const integer = run_scan(number, @intFromBool(negative), 0) orelse return null;

    var result: Decimal = .{
        .end = number.length,
        .exponent = 0,
        .fractional = false,
        .mantissa = integer.mantissa,
        .negative = negative,
    };

    var index = integer.index;
    if (index == text.len) return result;

    result.fractional = true;

    if (text[index] == '.') {
        const fraction = run_scan(number, index + 1, result.mantissa) orelse return null;

        result.exponent = -@as(i32, @intCast(fraction.index - index - 1));
        result.mantissa = fraction.mantissa;
        index = fraction.index;

        if (index == text.len) return result;
    }

    return exponent_add(result, text[index + 1 ..]);
}

const Scan = struct {
    index: u32,
    mantissa: u64,
};

inline fn digits_scan(text: []const u8, start: u32, mantissa_start: u64) ?Scan {
    assert(start <= text.len);
    assert(mantissa_start < powers_integer[decimal_digits_max]);

    var result: Scan = .{ .index = start, .mantissa = mantissa_start };

    for (0..text.len) |_| {
        if (result.index == text.len) return result;

        const digit = text[result.index] -% '0';
        if (digit >= 10) return result;
        if (result.mantissa >= powers_integer[decimal_digits_max - 1]) return null;

        result.mantissa = result.mantissa * 10 + digit;
        result.index += 1;
    }

    return result;
}

inline fn run_scan(number: Number, start: u32, mantissa_start: u64) ?Scan {
    assert(start <= number.length);
    assert(mantissa_start < powers_integer[decimal_digits_max]);

    const reach = number.reach;

    var result: Scan = .{ .index = start, .mantissa = mantissa_start };

    for (0..number.length) |_| {
        if (reach.len - result.index < 8) {
            return digits_scan(number.text(), result.index, result.mantissa);
        }

        const word = std.mem.readInt(u64, reach[result.index..][0..8], .little);
        const mask = digits_mask(word);
        const count: u32 = if (mask == 0) 8 else @ctz(mask) >> 3;
        if (count == 0) return result;
        if (result.mantissa >= powers_integer[decimal_digits_max - count]) return null;

        result.mantissa = result.mantissa * powers_integer[count] + run_value(word, count);
        result.index += count;

        if (count < 8) return result;
    }

    assert(result.index <= number.length);

    return result;
}

inline fn run_value(word: u64, count: u32) u64 {
    assert(count >= 1);
    assert(count <= 8);
    assert(@ctz(digits_mask(word)) >> 3 >= count);

    const shift: u6 = @intCast(64 - 8 * count);
    const zeros = 0x3030303030303030 & ((@as(u64, 1) << shift) - 1);
    const result = eight_digits_of((word << shift) | zeros);

    assert(result < powers_integer[count]);

    return result;
}

inline fn eight_digits_of(word: u64) u64 {
    assert(digits_mask(word) == 0);
    assert(@sizeOf(u64) == 8);

    const mask: u64 = 0x000000ff000000ff;
    const values = word - 0x3030303030303030;
    const pairs = values *% 10 +% (values >> 8);
    const low = (pairs & mask) *% (100 + (1000000 << 32));
    const high = ((pairs >> 16) & mask) *% (1 + (10000 << 32));
    const result = (low +% high) >> 32;

    assert(result < powers_integer[8]);

    return result;
}

inline fn digits_mask(word: u64) u64 {
    const below = word -% 0x3030303030303030;
    const above = word +% 0x4646464646464646;
    const result = (below | above | word) & 0x8080808080808080;

    assert(result & 0x7f7f7f7f7f7f7f7f == 0);

    return result;
}

fn exponent_add(decimal: Decimal, text: []const u8) ?Decimal {
    assert(text.len > 0);
    assert(decimal.fractional);

    const negative = text[0] == '-';
    const digits = text[@intFromBool(text[0] == '-' or text[0] == '+')..];
    const magnitude = std.fmt.parseInt(i32, digits, 10) catch return null;
    if (magnitude > exponent_magnitude_max) return null;

    var result = decimal;

    result.exponent += if (negative) -magnitude else magnitude;

    assert(result.fractional);

    return result;
}

pub inline fn float_of(decimal: Decimal) ?f64 {
    assert(decimal.fractional);
    assert(decimal.mantissa <= powers_integer[decimal_digits_max]);

    const magnitude = magnitude_of(decimal.mantissa, decimal.exponent) orelse return null;
    const result = if (decimal.negative) -magnitude else magnitude;

    assert(std.math.signbit(result) == decimal.negative);

    return result;
}

inline fn magnitude_of(mantissa: u64, exponent: i32) ?f64 {
    assert(mantissa <= powers_integer[decimal_digits_max]);
    assert(@abs(exponent) <= exponent_magnitude_max * 2);

    if (mantissa < powers_integer[exact_digits_max]) {
        if (@abs(exponent) <= exact_places_max) return exact_of(mantissa, exponent);
    }

    if (mantissa == 0) return 0;
    if (@abs(exponent) > decimal_digits_max) return null;

    const places: u32 = @intCast(@abs(exponent));
    const result = if (exponent >= 0)
        product_rounded(mantissa, places)
    else
        reciprocal_rounded(mantissa, places) orelse quotient_rounded(mantissa, places);

    assert(result > 0);

    return result;
}

inline fn exact_of(mantissa: u64, exponent: i32) f64 {
    assert(mantissa <= exact_mantissa_max);
    assert(@abs(exponent) <= exact_places_max);

    const value: f64 = @floatFromInt(@as(i64, @intCast(mantissa)));
    const power: f64 = powers_exact[@abs(exponent)];
    const result = if (exponent < 0) value / power else value * power;

    if (std.debug.runtime_safety) assert(result >= 0);

    return result;
}

const Factor = struct {
    scale: u64,
    shift: u32,
};

const factors_ten: [decimal_digits_max + 1]Factor = factors: {
    var table: [decimal_digits_max + 1]Factor = undefined;

    for (&table, 0..) |*factor, places| {
        const power = powers_integer[places];
        const shift = @clz(power);

        factor.* = .{ .scale = power << shift, .shift = shift };
    }

    break :factors table;
};

const factors_fifth: [decimal_digits_max + 1]Factor = factors: {
    @setEvalBranchQuota(10_000);

    var table: [decimal_digits_max + 1]Factor = undefined;
    var power: u128 = 1;

    for (&table, 0..) |*factor, places| {
        const bits = 128 - @clz(power) - 1;
        const scale: u128 = @divFloor(@as(u128, 1) << (64 + bits), power);

        factor.* = .{ .scale = @intCast(@min(scale, std.math.maxInt(u64))), .shift = bits };
        power *= 5;

        assert(places == 0 or scale >> 63 == 1);
    }

    break :factors table;
};

inline fn product_rounded(mantissa: u64, places: u32) f64 {
    assert(mantissa > 0);
    assert(places <= decimal_digits_max);

    const shift = @clz(mantissa);
    const factor = factors_ten[places];
    const product = std.math.mulWide(u64, mantissa << @intCast(shift), factor.scale);
    const high: u64 = @intCast(product >> 64);
    const sticky = high | @intFromBool(@as(u64, @truncate(product)) != 0);
    const exponent = 64 - @as(i32, shift) - @as(i32, @intCast(factor.shift));
    const result = power_two_scaled(@floatFromInt(sticky), exponent);

    assert(result >= @as(f64, @floatFromInt(mantissa)));

    return result;
}

inline fn reciprocal_rounded(mantissa: u64, places: u32) ?f64 {
    assert(mantissa > 0);
    assert(places > 0);

    const shift = @clz(mantissa);
    const factor = factors_fifth[places];
    const product = std.math.mulWide(u64, mantissa << @intCast(shift), factor.scale);
    const high: u64 = @intCast(product >> 64);
    const dropped: u6 = @intCast(64 - @clz(high) - std.math.floatMantissaBits(f64) - 1);
    const half = @as(u64, 1) << (dropped - 1);
    const below = high & ((@as(u64, 1) << dropped) - 1);
    if (below == half) return null;
    if (below + 1 == half) return null;

    const scale: i32 = @intCast(factor.shift + shift + places);
    const exponent = -scale;
    const result = power_two_scaled(@floatFromInt(high), exponent);

    assert(result > 0);

    return result;
}

inline fn power_two_scaled(value: f64, exponent: i32) f64 {
    assert(value > 0);
    assert(@abs(exponent) < std.math.floatExponentMax(f64));

    const bits: u64 = @as(u64, @intCast(exponent + std.math.floatExponentMax(f64))) << 52;
    const result = value * @as(f64, @bitCast(bits));

    assert(result > 0);

    return result;
}

fn quotient_rounded(mantissa: u64, places: u32) f64 {
    assert(mantissa > 0);
    assert(places > 0);

    const shift: u7 = @intCast(127 - (64 - @clz(mantissa)));
    const numerator = @as(u128, mantissa) << shift;
    const divisor = powers_integer[places];
    const quotient = @divFloor(numerator, divisor);
    const remainder = @mod(numerator, divisor);

    assert(quotient >> quotient_bits_min != 0);

    const sticky = quotient | @intFromBool(remainder != 0);
    const result = std.math.ldexp(@as(f64, @floatFromInt(sticky)), -@as(i32, shift));

    assert(result > 0);

    return result;
}

fn python_number(comptime name: [:0]const u8, text: []const u8) Error!*PyObject {
    assert(text.len > 0);
    assert(name.len > 0);

    const builtins = c.PyImport_ImportModule("builtins") orelse return error.PythonError;
    defer c.Py_DecRef(builtins);

    const object: lacuna.Object = .{ .pointer = builtins };

    var constructor = try object.attribute(name);
    defer constructor.release();

    const result = try constructor.object().?.call(.{text});

    return result.pointer orelse error.PythonError;
}

test "scanning agrees with the json-zig grammar and the standard library value" {
    var prng: std.Random.DefaultPrng = .init(0x6e756d62);
    const random = prng.random();

    var buffer: [48:0]u8 = undefined;

    for (0..200_000) |_| {
        const length = text_random(random, &buffer);
        const input: [:0]const u8 = std.mem.sliceTo(&buffer, 0);
        const valid = grammar_valid(input);
        const scanned = scan(input, 0) orelse {
            try std.testing.expect(!valid);

            continue;
        };

        if (scanned.slow) continue;

        try std.testing.expect(valid);
        try std.testing.expectEqual(length, scanned.decimal.end);

        const text = input[0..length];

        if (scanned.decimal.fractional) {
            const expected = std.fmt.parseFloat(f64, text) catch unreachable;
            const actual = float_of(scanned.decimal) orelse expected;
            const expected_bits: u64 = @bitCast(expected);
            const actual_bits: u64 = @bitCast(actual);

            try std.testing.expectEqual(expected_bits, actual_bits);
        } else {
            const expected = std.fmt.parseInt(i128, text, 10) catch unreachable;
            const magnitude: i128 = scanned.decimal.mantissa;
            const actual = if (scanned.decimal.negative) -magnitude else magnitude;

            try std.testing.expectEqual(expected, actual);
        }
    }
}

test "exact conversions agree with the standard library" {
    var prng: std.Random.DefaultPrng = .init(0x6578_6163);
    const random = prng.random();

    var buffer: [48]u8 = undefined;

    for (0..200_000) |_| {
        const mantissa = random.uintAtMost(u64, exact_mantissa_max >> random.uintLessThan(u6, 54));
        const exponent = random.intRangeAtMost(i32, -@as(i32, exact_places_max), exact_places_max);
        const text = try std.mem.print(&buffer, "{d}e{d}", .{ mantissa, exponent });
        const expected: u64 = @bitCast(try std.fmt.parseFloat(f64, text));
        const actual: u64 = @bitCast(exact_of(mantissa, exponent));

        try std.testing.expectEqual(expected, actual);
    }
}

test "the quick scanner agrees with the byte scanner" {
    var prng: std.Random.DefaultPrng = .init(0x6661_7273);
    const random = prng.random();

    var buffer: [80:0]u8 = undefined;
    var handled_count: u32 = 0;

    for (0..400_000) |_| {
        var text: [48:0]u8 = undefined;
        const length = text_random(random, &text);
        const filler = random.uintLessThan(u32, 8);

        @memset(buffer[0..80], ' ');
        @memcpy(buffer[0 .. length + 1], text[0 .. length + 1]);

        for (buffer[length + 1 ..][0..filler]) |*byte| {
            byte.* = "0123456789.eE-"[random.uintLessThan(u32, 14)];
        }

        buffer[80] = 0;

        const input: [:0]const u8 = &buffer;
        const decimal = quick_scan(input, 0) orelse continue;
        const expected = scan_near(input, 0) orelse return error.TestUnexpectedResult;

        try std.testing.expect(!expected.slow);
        try std.testing.expectEqual(expected.decimal, decimal);
        try std.testing.expectEqual(expected.decimal.end, quick_end(input, 0));

        if (decimal.fractional) {
            const written = input[0..expected.decimal.end];
            const reference: u64 = @bitCast(try std.fmt.parseFloat(f64, written));
            const magnitude = quick_magnitude(decimal.mantissa, decimal.exponent);
            const value: u64 = @bitCast(if (decimal.negative) -magnitude else magnitude);

            try std.testing.expectEqual(reference, value);
        }

        handled_count += 1;
    }

    try std.testing.expect(handled_count > 100_000);
}

fn scan(input: [:0]const u8, start: u32) ?Scanned {
    assert(start < input.len);
    assert(input[input.len] == 0);

    if (input.len - start >= far_bytes_min) {
        if (quick_scan(input, start)) |decimal| {
            assert(decimal.end == quick_end(input, start));

            return .{ .decimal = decimal, .slow = false };
        }
    }

    return scan_near(input, start);
}

fn quick_end(input: [:0]const u8, start: u32) u32 {
    assert(start < input.len);
    assert(input[input.len] == 0);

    var index = start + @intFromBool(input[start] == '-');

    for (0..input.len - index) |_| {
        switch (input[index]) {
            '0'...'9', '.', 'e', 'E', '+', '-' => index += 1,
            else => break,
        }
    }

    assert(index <= input.len);

    return index;
}

fn text_random(random: std.Random, buffer: *[48:0]u8) u32 {
    assert(buffer.len == 48);
    assert(@sizeOf(std.Random) > 0);

    const alphabet = "0123456789000111.-+eE";
    const delimiters = " ,]}\n";
    const length = random.uintLessThan(u32, 28) + 1;

    for (buffer[0..length]) |*byte| {
        const digits_only = random.uintLessThan(u32, 4) != 0;
        const choices: []const u8 = if (digits_only) alphabet[0..16] else alphabet;
        const choice = random.uintLessThan(u32, @intCast(choices.len));

        byte.* = choices[choice];
    }

    switch (buffer[0]) {
        '-', '0'...'9' => {},
        else => buffer[0] = '1',
    }

    const padding = random.uintLessThan(u32, 20);
    const total = length + 1 + padding;
    const delimiter = random.uintLessThan(u32, @intCast(delimiters.len));

    buffer[length] = delimiters[delimiter];
    @memset(buffer[length + 1 .. total], ' ');
    buffer[total] = 0;

    assert(total <= buffer.len);

    return length;
}

fn grammar_valid(input: [:0]const u8) bool {
    assert(input.len > 0);
    assert(input[input.len] == 0);

    const end = if (input[0] == '-')
        json.structural.number_end(input, 0, true) catch return false
    else
        json.structural.number_end(input, 0, false) catch return false;

    return json.structural.scalar_ended(input, end);
}
