const std = @import("std");

const shortest = @import("shortest.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;
const Tokenizer = tokenizer_module.Tokenizer;

const Form = struct {
    digits: []const u8,
    exponent: i32,
    sign: bool,
};

pub const Decimal = struct {
    end: u32,
    exponent: i32,
    fractional: bool,
    mantissa: u64,
    negative: bool,
};

const Factor = struct {
    scale: u64,
    shift: u32,
};

const Run = struct {
    count: u32,
    stop: u8,
    value: u64,
};

const Scan = struct {
    index: u32,
    mantissa: u64,
};

const Stop = enum {
    end,
    exponent,
    fraction,
    invalid,
};

const Wide = struct {
    high: u64,
    low: u64,
};

const decimal_digits_max: u32 = 19;
pub const decimal_far_bytes_min: u32 = 24;
const exact_digits_max: u32 = 15;
const exact_mantissa_max: u64 = 1 << 53;
const exact_places_max: u32 = 22;
const exponent_digits_max: u32 = 5;
const exponent_magnitude_max: u32 = 324;
const extended_even_max: i32 = 23;
const extended_even_min: i32 = -4;
const extended_exact_max: i32 = 55;
const extended_exact_min: i32 = -27;
pub const float_bytes_max: u32 = 32;
pub const float_decimal_bytes_max: u32 = 352;
pub const float_unsigned_bytes_max: u32 = significand_digits_max + 7;
pub const integer_bytes_max: u32 = 20;
pub const integer_far_bytes_min: u32 = 25;
pub const integer_write_bytes_max: u32 = integer_bytes_max + 8;
const point_digits_max: i32 = 21;
const point_zeros_max: i32 = 6;
const power_five_max: i32 = 308;
const power_five_min: i32 = -342;
const quotient_bits_min: u32 = 56;
const significand_digits_max: u32 = 17;
const spellings = [_][]const u8{ "inf", "infinity", "nan" };

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

const powers_five: [power_five_max - power_five_min + 1]Wide = powers: {
    @setEvalBranchQuota(100_000);

    var table: [power_five_max - power_five_min + 1]Wide = undefined;
    var power: u2048 = 1;

    for (0..-power_five_min + 1) |count| {
        const magnitude: i32 = @intCast(count);

        if (magnitude <= power_five_max) {
            table[@intCast(magnitude - power_five_min)] = power_five_truncated(power);
        }

        if (magnitude > 0) {
            table[@intCast(-power_five_min - magnitude)] = power_five_reciprocal(power, count);
        }

        power *= 5;
    }

    break :powers table;
};

const stop_classes: [256]Stop = classes: {
    var table: [256]Stop = @splat(.invalid);

    for (" \t\n\r,:[]{}") |byte| table[byte] = .end;

    table['.'] = .fraction;
    table['e'] = .exponent;
    table['E'] = .exponent;

    break :classes table;
};

comptime {
    assert(integer_bytes_max == std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 1);
    assert(float_bytes_max > float_unsigned_bytes_max);
    assert(float_decimal_bytes_max > 2 + exponent_magnitude_max + significand_digits_max);
    assert(@as(u32, point_digits_max) + 1 <= float_unsigned_bytes_max);
    assert(powers_integer[decimal_digits_max] < std.math.maxInt(u64));
    assert(quotient_bits_min < 64);
    assert(exact_mantissa_max == @as(u64, 1) << (std.math.floatMantissaBits(f64) + 1));
    assert(powers_exact[exact_places_max] == 1e22);
    assert(std.math.pow(u128, 5, exact_places_max) < exact_mantissa_max);
    assert(powers_integer[exact_digits_max] < exact_mantissa_max);
    assert(decimal_far_bytes_min >= 2 * @sizeOf(u64));
    assert(powers_five[-power_five_min].high == 1 << 63);
    assert(powers_five[-power_five_min].low == 0);
    assert(integer_far_bytes_min > 3 * @sizeOf(u64));
}

pub fn grammar_is(text: []const u8) bool {
    assert(text.len < std.math.maxInt(u32));

    if (text.len == 0) return false;

    const magnitude = if (text[0] == '-') text[1..] else text;
    if (magnitude.len == 0) return false;
    if (std.ascii.isAlphabetic(magnitude[0])) return spelling_is(magnitude);
    return finite_is(magnitude);
}

pub fn non_finite_is(text: []const u8) bool {
    assert(text.len > 0);

    const sign_length: u32 = @intFromBool(text[0] == '-');

    assert(text.len > sign_length);

    return std.ascii.isAlphabetic(text[sign_length]);
}

pub fn spelling_of(value: f64) []const u8 {
    assert(!std.math.isFinite(value));

    const result = if (std.math.isNan(value)) "NaN" else if (value > 0) "Infinity" else "-Infinity";

    assert(grammar_is(result));
    assert(non_finite_is(result));

    return result;
}

pub fn spelling_of_text(text: []const u8) []const u8 {
    assert(grammar_is(text));
    assert(non_finite_is(text));

    const negative = text[0] == '-';
    const letter = text[@intFromBool(negative)];
    const result = if (letter | 0x20 == 'n') "NaN" else if (negative) "-Infinity" else "Infinity";

    assert(non_finite_is(result));

    return result;
}

pub fn integer_of_text(text: []const u8) ?i64 {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const result = integer_parse(i64, text) orelse return null;

    if (result < 0) assert(text[0] == '-');

    return result;
}

pub fn unsigned_of_text(text: []const u8) ?u64 {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const result = integer_parse(u64, text) orelse return null;

    if (text[0] == '-') assert(result == 0);

    return result;
}

pub fn float_of_text(text: []const u8) ?f64 {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    if (float_quick(text)) |result| return result;

    const result = std.fmt.parseFloat(f64, text) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
    };

    if (non_finite_is(text)) return result;
    if (!std.math.isFinite(result)) return null;

    assert(!std.math.isNan(result));

    return result;
}

pub inline fn integer_parse(comptime T: type, text: []const u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(text.len > 0);

    if (comptime @bitSizeOf(T) <= 64) {
        if (integer_quick(T, text)) |result| return result;
    }

    return std.fmt.parseInt(T, text, 10) catch null;
}

pub inline fn float_parse(comptime T: type, text: []const u8) ?T {
    comptime assert(@typeInfo(T) == .float);
    assert(text.len > 0);

    if (comptime T == f64) {
        if (float_quick(text)) |result| return result;
    }

    return std.fmt.parseFloat(T, text) catch null;
}

fn integer_quick(comptime T: type, text: []const u8) ?T {
    comptime assert(@bitSizeOf(T) <= 64);
    assert(text.len > 0);

    const signed = comptime @typeInfo(T).int.signedness == .signed;
    const negative = signed and text[0] == '-';
    const digits_start: u32 = @intFromBool(negative);
    if (text.len - digits_start > decimal_digits_max) return null;
    if (text.len == digits_start) return null;

    const scan = digits_text(text, digits_start, 0);
    if (scan.index != text.len) return null;

    return integer_ranged(T, scan.mantissa, negative);
}

inline fn integer_ranged(comptime T: type, magnitude: u64, negative: bool) ?T {
    comptime assert(@bitSizeOf(T) <= 64);
    assert(magnitude < powers_integer[decimal_digits_max]);

    if (comptime @typeInfo(T).int.signedness == .unsigned) {
        assert(!negative);

        if (magnitude > std.math.maxInt(T)) return null;
        return @intCast(magnitude);
    }

    const positive_max: u64 = @intCast(std.math.maxInt(T));

    if (!negative) {
        if (magnitude > positive_max) return null;
        return @intCast(magnitude);
    }

    if (magnitude > positive_max + 1) return null;

    const wide: i64 = @bitCast(0 -% magnitude);

    return @intCast(wide);
}

pub fn float_quick(text: []const u8) ?f64 {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const decimal = decimal_of_text(text) orelse return null;
    const magnitude = magnitude_of(decimal.mantissa, decimal.exponent) orelse return null;
    const magnitude_bits: u64 = @bitCast(magnitude);
    const sign = @as(u64, @intFromBool(decimal.negative)) << 63;
    const result: f64 = @bitCast(magnitude_bits | sign);

    assert(std.math.signbit(result) == decimal.negative);

    return result;
}

fn decimal_of_text(text: []const u8) ?Decimal {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const negative = text[0] == '-';
    const digits_start: u32 = @intFromBool(negative);
    const integer = digits_text(text, digits_start, 0);
    const integer_count = integer.index - digits_start;
    if (integer_count == 0) return null;
    if (integer_count > decimal_digits_max) return null;

    var result: Decimal = .{
        .end = integer.index,
        .exponent = 0,
        .fractional = false,
        .mantissa = integer.mantissa,
        .negative = negative,
    };

    if (result.end == text.len) return result;

    result.fractional = true;

    if (text[result.end] == '.') {
        const fraction = digits_text(text, result.end + 1, result.mantissa);
        const fraction_count = fraction.index - result.end - 1;
        if (fraction_count == 0) return null;
        if (integer_count + fraction_count > decimal_digits_max) return null;

        result.exponent = -@as(i32, @intCast(fraction_count));
        result.mantissa = fraction.mantissa;
        result.end = fraction.index;

        if (result.end == text.len) return result;
    }

    if (text[result.end] | 0x20 != 'e') return null;

    const exponent = exponent_scan(text, result.end + 1) orelse return null;
    if (exponent.count > exponent_digits_max) return null;
    if (exponent.end != text.len) return null;

    result.exponent += exponent.value;
    result.end = exponent.end;

    return result;
}

inline fn digits_text(text: []const u8, start: u32, mantissa_start: u64) Scan {
    assert(start <= text.len);
    assert(text.len < std.math.maxInt(u32));

    var index = start;
    var mantissa = mantissa_start;

    for (0..@divFloor(text.len - start, @sizeOf(u64))) |_| {
        const word = word_at(text, index);
        if (digits_mask(word) != 0) break;

        mantissa = mantissa *% powers_integer[8] +% eight_digits_of(word);
        index += @sizeOf(u64);
    }

    for (text[index..]) |byte| {
        const digit = byte -% '0';
        if (digit >= 10) break;

        mantissa = mantissa *% 10 +% digit;
        index += 1;
    }

    assert(index <= text.len);

    return .{ .index = index, .mantissa = mantissa };
}

pub fn Far(comptime T: type) type {
    return struct {
        end: u32,
        value: T,
    };
}

pub inline fn integer_far(comptime T: type, input: []const u8, start: u32) ?Far(T) {
    comptime assert(@typeInfo(T) == .int);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(start < input.len);

    if (input.len - start < integer_far_bytes_min) return null;

    const signed = comptime @typeInfo(T).int.signedness == .signed;
    const negative = signed and input[start] == '-';
    const digits_start = start + @intFromBool(negative);
    const run = run_integer(input, digits_start) orelse return null;
    if (stop_classes[run.stop] != .end) return null;

    if (run.count > 1) {
        if (input[digits_start] == '0') return null;
    }

    const value = integer_ranged(T, run.value, negative) orelse return null;

    return .{ .end = digits_start + run.count, .value = value };
}

inline fn run_integer(input: []const u8, digits_start: u32) ?Run {
    assert(input.len - digits_start >= 3 * @sizeOf(u64));
    assert(input.len < std.math.maxInt(u32));

    const head = word_at(input, digits_start);
    const head_mask = digits_mask(head);

    if (head_mask != 0) {
        const count: u32 = @ctz(head_mask) >> 3;
        if (count == 0) return null;

        const stop: u8 = @truncate(head >> @intCast(8 * count));

        return .{ .count = count, .stop = stop, .value = run_value(head, count) };
    }

    return run_integer_long(input, digits_start, eight_digits_of(head));
}

inline fn run_integer_long(input: []const u8, digits_start: u32, head_value: u64) ?Run {
    assert(input.len - digits_start >= 3 * @sizeOf(u64));
    assert(head_value < powers_integer[8]);

    const middle = word_at(input, digits_start + 8);
    const middle_mask = digits_mask(middle);

    if (middle_mask != 0) {
        const count: u32 = @ctz(middle_mask) >> 3;
        const stop: u8 = @truncate(middle >> @intCast(8 * count));
        if (count == 0) return .{ .count = 8, .stop = stop, .value = head_value };

        const value = head_value * powers_integer[count] + run_value(middle, count);

        return .{ .count = 8 + count, .stop = stop, .value = value };
    }

    const tail = word_at(input, digits_start + 16);
    const tail_mask = digits_mask(tail);
    if (tail_mask == 0) return null;

    const count: u32 = @ctz(tail_mask) >> 3;
    if (count > decimal_digits_max - 16) return null;

    const stop: u8 = @truncate(tail >> @intCast(8 * count));
    const upper = head_value * powers_integer[8] + eight_digits_of(middle);
    if (count == 0) return .{ .count = 16, .stop = stop, .value = upper };

    const value = upper * powers_integer[count] + run_value(tail, count);

    return .{ .count = 16 + count, .stop = stop, .value = value };
}

pub inline fn float_far(input: []const u8, start: u32) ?Far(f64) {
    assert(start < input.len);
    assert(input.len < std.math.maxInt(u32));

    if (input.len - start < decimal_far_bytes_min) return null;

    const decimal = decimal_far(input, start) orelse return null;
    const magnitude: u64 = @bitCast(magnitude_near(decimal.mantissa, decimal.exponent));
    const sign = @as(u64, @intFromBool(decimal.negative)) << 63;
    const result: f64 = @bitCast(magnitude | sign);

    assert(std.math.isFinite(result));

    return .{ .end = decimal.end, .value = result };
}

pub inline fn decimal_far(input: []const u8, start: u32) ?Decimal {
    assert(input.len - start >= decimal_far_bytes_min);
    assert(input.len < std.math.maxInt(u32));

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
        .exponent => return exponent_far(input, end, decimal),
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
        .exponent => exponent_far(input, end + 1 + fraction.count, decimal),
        .fraction, .invalid => null,
    };
}

fn exponent_far(input: []const u8, marker: u32, decimal: Decimal) ?Decimal {
    assert(input[marker] | 0x20 == 'e');
    assert(@abs(decimal.exponent) <= decimal_digits_max);

    const exponent = exponent_scan(input, marker + 1) orelse return null;
    if (exponent.count > exponent_digits_max) return null;
    if (exponent.end == input.len) return null;
    if (stop_classes[input[exponent.end]] != .end) return null;

    var result = decimal;

    result.end = exponent.end;
    result.exponent += exponent.value;
    result.fractional = true;
    if (@abs(result.exponent) > decimal_digits_max) return null;

    return result;
}

inline fn fraction_run(input: []const u8, index: u32) ?Run {
    assert(index <= input.len);
    assert(input.len < std.math.maxInt(u32));

    if (input.len - index < 2 * @sizeOf(u64)) return null;

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

inline fn run_short(input: []const u8, digits_start: u32, first: u8) ?Run {
    assert(first < 10);
    assert(input.len - digits_start >= 2 * @sizeOf(u64));

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

inline fn run_of(input: []const u8, digits_start: u32) ?Run {
    assert(input.len - digits_start >= 2 * @sizeOf(u64));
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

inline fn word_at(input: []const u8, index: u32) u64 {
    assert(input.len - index >= @sizeOf(u64));
    assert(input.len < std.math.maxInt(u32));

    return std.mem.readInt(u64, input[index..][0..8], .little);
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

const Exponent = struct {
    count: u32,
    end: u32,
    value: i32,
};

fn exponent_scan(input: []const u8, start: u32) ?Exponent {
    assert(start <= input.len);
    assert(start > 0);

    if (start == input.len) return null;

    const negative = input[start] == '-';
    const digits_start = start + @intFromBool(negative or input[start] == '+');

    var index = digits_start;
    var magnitude: i32 = 0;

    for (0..exponent_digits_max + 1) |_| {
        if (index == input.len) break;

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

pub inline fn magnitude_near(mantissa: u64, exponent: i32) f64 {
    assert(mantissa < powers_integer[decimal_digits_max]);
    assert(@abs(exponent) <= decimal_digits_max);

    if (mantissa < powers_integer[exact_digits_max]) return exact_of(mantissa, exponent);

    const places: u32 = @intCast(@abs(exponent));
    if (exponent >= 0) return product_rounded(mantissa, places);
    return reciprocal_rounded(mantissa, places) orelse quotient_rounded(mantissa, places);
}

pub inline fn magnitude_of(mantissa: u64, exponent: i32) ?f64 {
    assert(mantissa <= powers_integer[decimal_digits_max]);
    assert(@abs(exponent) <= 2 * std.math.pow(u32, 10, exponent_digits_max));

    if (mantissa < powers_integer[exact_digits_max]) {
        if (@abs(exponent) <= exact_places_max) return exact_of(mantissa, exponent);
    }

    if (mantissa == 0) return 0;
    if (@abs(exponent) > decimal_digits_max) return magnitude_extended(mantissa, exponent);

    const places: u32 = @intCast(@abs(exponent));
    const result = if (exponent >= 0)
        product_rounded(mantissa, places)
    else
        reciprocal_rounded(mantissa, places) orelse quotient_rounded(mantissa, places);

    assert(result > 0);

    return result;
}

pub fn magnitude_extended(mantissa: u64, exponent: i32) ?f64 {
    assert(mantissa <= powers_integer[decimal_digits_max]);
    assert(exponent > @divTrunc(std.math.minInt(i32), 2));

    if (mantissa == 0) return 0;
    if (exponent < power_five_min) return 0;
    if (exponent > power_five_max) return null;

    const shift: u6 = @intCast(@clz(mantissa));
    const product = product_extended(mantissa << shift, exponent);

    if (product.low == std.math.maxInt(u64)) {
        if (exponent < extended_exact_min) return null;
        if (exponent > extended_exact_max) return null;
    }

    const upper: u6 = @intCast(product.high >> 63);
    const dropped: u6 = upper + (64 - std.math.floatFractionalBits(f64) - 3);
    const bias: i32 = std.math.floatExponentMax(f64);
    const biased = power_two_of(exponent) + @as(i32, upper) - @as(i32, shift) + bias;
    const significand = product.high >> dropped;

    if (biased <= 0) return subnormal_of(significand, biased);

    const tie = tie_even(product, exponent, significand, dropped);
    const result = normal_of(significand & ~@as(u64, @intFromBool(tie)), biased);

    if (result) |value| assert(value > 0);

    return result;
}

inline fn product_extended(normalized: u64, exponent: i32) Wide {
    assert(normalized >> 63 == 1);
    assert(exponent >= power_five_min);
    assert(exponent <= power_five_max);

    const precision_mask: u64 = std.math.maxInt(u64) >> std.math.floatFractionalBits(f64) + 3;
    const power = powers_five[@intCast(exponent - power_five_min)];
    const first = std.math.mulWide(u64, normalized, power.high);

    var high: u64 = @truncate(first >> 64);
    var low: u64 = @truncate(first);

    if (high & precision_mask == precision_mask) {
        const second = std.math.mulWide(u64, normalized, power.low);
        const carry: u64 = @truncate(second >> 64);

        low +%= carry;
        if (carry > low) high += 1;
    }

    return .{ .high = high, .low = low };
}

inline fn power_two_of(exponent: i32) i32 {
    assert(exponent >= power_five_min);
    assert(exponent <= power_five_max);

    return ((exponent * (152170 + 65536)) >> 16) + 63;
}

inline fn tie_even(product: Wide, exponent: i32, significand: u64, dropped: u6) bool {
    assert(product.high >> 62 != 0);
    assert(dropped >= 9);

    if (product.low > 1) return false;
    if (exponent < extended_even_min) return false;
    if (exponent > extended_even_max) return false;
    if (significand & 3 != 1) return false;

    return significand << dropped == product.high;
}

fn subnormal_of(significand: u64, biased: i32) f64 {
    assert(biased <= 0);
    assert(significand >> 54 == 0);

    if (1 - biased >= 64) return 0;

    const fraction_bits = std.math.floatFractionalBits(f64);
    const shifted = significand >> @intCast(1 - biased);
    const rounded = (shifted + (shifted & 1)) >> 1;
    const field: u64 = @intFromBool(rounded >= @as(u64, 1) << fraction_bits);
    const result: f64 = @bitCast(rounded | field << fraction_bits);

    assert(result >= 0);

    return result;
}

fn normal_of(significand: u64, biased: i32) ?f64 {
    assert(biased > 0);
    assert(significand >> 54 == 0);

    const fraction_bits = std.math.floatFractionalBits(f64);
    const hidden: u64 = @as(u64, 1) << fraction_bits;
    const rounded = (significand + (significand & 1)) >> 1;
    const carried = rounded >= 2 * hidden;
    const field = biased + @intFromBool(carried);
    if (field >= 2 * std.math.floatExponentMax(f64) + 1) return null;

    const fraction = if (carried) 0 else rounded & (hidden - 1);
    const result: f64 = @bitCast(fraction | @as(u64, @intCast(field)) << fraction_bits);

    assert(std.math.isFinite(result));

    return result;
}

fn power_five_truncated(comptime power: u2048) Wide {
    assert(power > 0);
    assert(power % 5 == 0 or power == 1);

    const length = 2048 - @clz(power);
    const value: u128 = if (length <= 128)
        @intCast(power << (128 - length))
    else
        @intCast(power >> (length - 128));

    return .{ .high = @truncate(value >> 64), .low = @truncate(value) };
}

fn power_five_reciprocal(comptime power: u2048, comptime count: u32) Wide {
    assert(count > 0);
    assert(power % 5 == 0);

    const length = 2048 - @clz(power);
    const shift = if (count <= -extended_exact_min) length + 127 else 2 * length + 128;
    const quotient = @divFloor(@as(u2048, 1) << shift, power) + 1;
    const quotient_length = 2048 - @clz(quotient);
    const value: u128 = if (quotient_length <= 128)
        @intCast(quotient)
    else
        @intCast(quotient >> (quotient_length - 128));

    return .{ .high = @truncate(value >> 64), .low = @truncate(value) };
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

fn spelling_is(text: []const u8) bool {
    assert(text.len > 0);
    assert(std.ascii.isAlphabetic(text[0]));

    for (spellings) |spelling| {
        if (std.ascii.eqlIgnoreCase(text, spelling)) return true;
    }

    return false;
}

fn finite_is(text: []const u8) bool {
    assert(text.len > 0);
    assert(!std.ascii.isAlphabetic(text[0]));

    var index: u32 = if (text[0] == '0') 1 else digits_end(text, 0);
    if (index == 0) return false;

    if (byte_is(text, index, '.')) {
        const end = digits_end(text, index + 1);
        if (end == index + 1) return false;

        index = end;
    }

    if (exponent_is(text, index)) {
        const start = index + 1 + @intFromBool(sign_is(text, index + 1));
        const end = digits_end(text, start);
        if (end == start) return false;

        index = end;
    }

    return index == text.len;
}

fn digits_end(text: []const u8, start: u32) u32 {
    assert(start <= text.len);
    assert(text.len < std.math.maxInt(u32));

    var result = start;

    for (text[start..]) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        result += 1;
    }

    assert(result <= text.len);

    return result;
}

fn byte_is(text: []const u8, index: u32, byte: u8) bool {
    assert(index <= text.len);
    assert(!std.ascii.isDigit(byte));

    if (index == text.len) return false;
    return text[index] == byte;
}

fn exponent_is(text: []const u8, index: u32) bool {
    assert(index <= text.len);
    assert(index > 0);

    if (index == text.len) return false;

    return switch (text[index]) {
        'E', 'e' => true,
        else => false,
    };
}

fn sign_is(text: []const u8, index: u32) bool {
    assert(index <= text.len);
    assert(index > 1);

    if (index == text.len) return false;

    return switch (text[index]) {
        '+', '-' => true,
        else => false,
    };
}

pub fn integer_format(value: u64, target: *[integer_bytes_max]u8) []const u8 {
    assert(std.math.log10_int(value | 1) < target.len);

    var remaining = value;
    var start: u32 = integer_bytes_max;

    for (0..@divExact(integer_bytes_max, 2)) |_| {
        if (remaining < 100) break;

        start -= 2;
        target[start..][0..2].* = std.fmt.digits2(@intCast(@rem(remaining, 100)));
        remaining = @divFloor(remaining, 100);
    }

    if (remaining < 10) {
        start -= 1;
        target[start] = '0' + @as(u8, @intCast(remaining));
    } else {
        start -= 2;
        target[start..][0..2].* = std.fmt.digits2(@intCast(remaining));
    }

    const result = target[start..];

    assert(result.len >= 1);
    if (result.len > 1) assert(result[0] != '0');

    return result;
}

pub fn float_format(comptime T: type, value: T, target: *[float_bytes_max]u8) []const u8 {
    comptime assert(@typeInfo(T) == .float);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(std.math.isFinite(value));

    if (comptime T == f64) return target[0..float64_write(target, value)];

    return form_format(T, value, target);
}

fn form_format(comptime T: type, value: T, target: *[float_bytes_max]u8) []const u8 {
    comptime assert(@typeInfo(T) == .float);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(std.math.isFinite(value));

    var digits: [integer_bytes_max]u8 = undefined;
    const form = form_of(T, value, &digits);
    const sign_length: u32 = @intFromBool(form.sign);
    const point = form_point(form);
    const point_is = point > -point_zeros_max and point <= point_digits_max;
    const length = if (point_is) form_decimal_length(form) else form_scientific_length(form);

    assert(sign_length + length <= float_unsigned_bytes_max + 1);
    assert(sign_length + length <= target.len);

    target[0] = '-';

    if (point_is) {
        form_decimal_write(form, target[sign_length..][0..length]);
    } else {
        form_scientific_write(form, target[sign_length..][0..length]);
    }

    return target[0 .. sign_length + length];
}

pub inline fn float_write(comptime T: type, target: *[float_bytes_max]u8, value: T) u32 {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));

    if (comptime T == f64) return float64_write(target, value);

    var buffer: [float_bytes_max]u8 = undefined;
    const text = form_format(T, value, &buffer);

    @memcpy(target[0..text.len], text);

    const result: u32 = @intCast(text.len);

    assert(result >= 1);
    assert(result <= float_bytes_max);

    return result;
}

pub inline fn unsigned_write(target: []u8, value: u64) u32 {
    assert(target.len >= integer_write_bytes_max);
    assert(digits_count(value) <= integer_bytes_max);

    const result = result: {
        if (value < four_digits_limit) break :result four_write(target, @intCast(value));
        if (value < eight_digits_limit) break :result short_write(target, @intCast(value));

        const count = digits_count(value);

        digits_long(target, count, value);

        break :result count;
    };

    assert(result >= 1);
    assert(result <= integer_bytes_max);

    return result;
}

const eight_digits_limit: u32 = 100_000_000;
const four_digits_limit: u32 = 10_000;

inline fn four_write(target: []u8, value: u32) u32 {
    assert(value < four_digits_limit);
    assert(target.len >= 4);

    const result: u32 = 1 + @as(u32, @intFromBool(value >= 10)) + @intFromBool(value >= 100) +
        @intFromBool(value >= 1000);
    const hundreds = (value * 5243) >> 19;
    const pairs = hundreds | (value - hundreds * 100) << 16;
    const tens = ((pairs * 103) >> 10) & 0x000f_000f;
    const raw = tens | (pairs - tens * 10) << 8;
    const zeros: u5 = @intCast(4 - result);
    const word = (raw + 0x3030_3030) >> (zeros * 8);

    target[0..4].* = @bitCast(word);

    assert(result == digits_count(value));

    return result;
}

inline fn short_write(target: []u8, value: u32) u32 {
    assert(value < eight_digits_limit);
    assert(target.len >= 8);

    const result = digits_count(value);
    const raw = eight_digits_raw(value);
    const zeros: u6 = @intCast(8 - result);
    const word = (raw + 0x3030_3030_3030_3030) >> (zeros * 8);

    target[0..8].* = @bitCast(word);

    assert(result >= 1);

    return result;
}

noinline fn digits_long(target: []u8, count: u32, value: u64) void {
    assert(count > 8);
    assert(target.len >= count + 8);
    assert(value >= powers_ten[count - 1]);

    const low: u32 = @intCast(value % powers_ten[8]);
    const rest = @divFloor(value, powers_ten[8]);

    if (count <= 16) {
        digits_short(target, count - 8, rest);
        target[count - 8 ..][0..8].* = @bitCast(eight_digits(low));

        return;
    }

    const middle: u32 = @intCast(rest % powers_ten[8]);
    const top = @divFloor(rest, powers_ten[8]);

    digits_short(target, count - 16, top);
    target[count - 16 ..][0..8].* = @bitCast(eight_digits(middle));
    target[count - 8 ..][0..8].* = @bitCast(eight_digits(low));
}

fn digits_short(target: []u8, count: u32, value: u64) void {
    assert(count >= 1);
    assert(count <= 8);
    assert(value < powers_ten[count]);
    assert(target.len >= 8);

    const shift: u6 = @intCast(8 * (8 - count));
    const word = eight_digits(@intCast(value)) >> shift;

    target[0..8].* = @bitCast(word);
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

pub inline fn float64_regular_write(target: *[float_bytes_max]u8, bits: u64) u32 {
    assert(shortest.regular_is(bits));
    assert(target.len == float_bytes_max);

    const start: u32 = @intCast(bits >> 63);
    const body = target[start..];

    target[0] = '-';

    const layout = layout_of(shortest.scaled_of(bits));
    const result = start + significand_write(body, layout.significand, layout.point);

    assert(result >= 1);
    assert(result <= float_bytes_max);

    return result;
}

pub inline fn float64_write(target: *[float_bytes_max]u8, value: f64) u32 {
    assert(std.math.isFinite(value));
    assert(target.len == float_bytes_max);

    const bits: u64 = @bitCast(value);

    if (shortest.regular_is(bits)) return float64_regular_write(target, bits);

    const start: u32 = @intCast(bits >> 63);
    const body = target[start..];

    target[0] = '-';

    const result = result: {
        if (bits << 1 == 0) {
            body[0] = '0';

            break :result start + 1;
        }

        break :result start + float_generic_write(body, value);
    };

    assert(result >= 1);
    assert(result <= float_bytes_max);

    return result;
}

noinline fn float_generic_write(target: []u8, value: f64) u32 {
    assert(std.math.isFinite(value));
    assert(value != 0);
    assert(target.len >= float_bytes_max - 1);

    const decimal = shortest.decimal_of(value);
    const count = digits_count(decimal.mantissa);
    const normalized = decimal.mantissa * powers_ten[significand_digits_max - count];
    const base = @divFloor(normalized, 10);
    const digits = sixteen_digits(groups_of(base));
    const significand = significand_of(digits, @intCast(normalized - base * 10));
    const point = decimal.exponent + @as(i32, @intCast(count));

    return significand_write(target, significand, point);
}

const Layout = struct {
    point: i32,
    significand: Significand,
};

const Significand = struct {
    count: u32,
    digits: Sixteen,
    extra: u8,
};

const Lanes = @Vector(8, u16);
const Quads = @Vector(4, u32);
const Sixteen = @Vector(16, u8);

const digits_shift_mask: [16]i32 = mask: {
    var mask: [16]i32 = undefined;

    for (mask[1..], 0..) |*entry, index| entry.* = @intCast(index);

    break :mask mask;
};

const powers_ten: [integer_bytes_max]u64 = powers: {
    var table: [integer_bytes_max]u64 = undefined;
    var power: u64 = 1;

    for (&table, 0..) |*entry, index| {
        entry.* = power;
        if (index + 1 < integer_bytes_max) power *= 10;
    }

    break :powers table;
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
        .significand = significand_of(digits, @intCast(scaled.digit & select)),
    };
}

inline fn significand_of(digits: Sixteen, extra: u8) Significand {
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
    assert(result.count <= significand_digits_max);

    return result;
}

inline fn significand_write(target: []u8, significand: Significand, point: i32) u32 {
    assert(significand.count >= 1);
    assert(target.len >= float_bytes_max - 1);
    assert(@abs(point - 1) <= exponent_magnitude_max);

    const result = result: {
        if (point > point_digits_max) break :result scientific_of(target, significand, point);
        if (point >= significand.count) break :result integral_write(target, significand, point);
        if (point > 0) break :result mixed_write(target, significand, @intCast(point));

        if (point > -point_zeros_max) {
            break :result fraction_write(target, significand, @intCast(-point));
        }

        break :result scientific_of(target, significand, point);
    };

    assert(result >= 1);
    assert(result <= float_bytes_max - 1);

    return result;
}

inline fn scientific_of(target: []u8, significand: Significand, point: i32) u32 {
    assert(significand.count >= 1);
    assert(target.len >= float_bytes_max - 1);
    assert(@abs(point - 1) <= exponent_magnitude_max);

    const digits = significand.digits;
    const count = significand.count;
    const result = scientific_write(target, digits, count, significand.extra, point - 1);

    assert(result >= 1);

    return result;
}

inline fn integral_write(target: []u8, significand: Significand, point: i32) u32 {
    assert(point >= significand.count);
    assert(point <= point_digits_max);
    assert(target.len >= float_bytes_max - 1);

    target[0..16].* = @bitCast(significand.digits);
    target[16] = significand.extra;
    target[17..][0..4].* = "0000".*;

    const result: u32 = @intCast(point);

    assert(result >= significand.count);

    return result;
}

inline fn mixed_write(target: []u8, significand: Significand, point: u32) u32 {
    assert(point >= 1);
    assert(point < significand.count);
    assert(target.len >= float_bytes_max - 1);

    const iota = std.simd.iota(i8, 16);
    const split: @Vector(16, i8) = @splat(@intCast(point));
    const shifted = @shuffle(u8, significand.digits, undefined, digits_shift_mask);

    target[16] = significand.digits[15];
    target[17] = significand.extra;
    target[0..16].* = @bitCast(@select(u8, iota < split, significand.digits, shifted));
    target[point] = '.';

    const result = significand.count + 1;

    assert(result > point);

    return result;
}

inline fn fraction_write(target: []u8, significand: Significand, zeros: u32) u32 {
    assert(zeros < point_zeros_max);
    assert(significand.count >= 1);
    assert(target.len >= float_bytes_max - 1);

    target[0..8].* = "0.000000".*;
    target[2 + zeros ..][0..16].* = @bitCast(significand.digits);
    target[18 + zeros] = significand.extra;

    const result = 2 + zeros + significand.count;

    assert(result > zeros);

    return result;
}

noinline fn scientific_write(
    target: []u8,
    digits: Sixteen,
    count: u32,
    extra: u8,
    exponent: i32,
) u32 {
    assert(count >= 1);
    assert(@abs(exponent) <= exponent_magnitude_max);
    assert(target.len >= float_bytes_max - 1);
    assert(digits[0] != '0');

    target[1..17].* = @bitCast(digits);
    target[17] = extra;
    target[0] = digits[0];
    target[1] = '.';

    const mantissa_length: u32 = if (count > 1) count + 1 else 1;
    const magnitude: u32 = @abs(exponent);
    const tail = target[mantissa_length..];

    tail[0..2].* = .{ 'e', if (exponent < 0) '-' else '+' };

    var length: u32 = 0;

    if (magnitude < 10) {
        tail[2] = '0' + @as(u8, @intCast(magnitude));
        length = 3;
    } else if (magnitude < 100) {
        tail[2..4].* = std.fmt.digits2(@intCast(magnitude));
        length = 4;
    } else {
        tail[2] = '0' + @as(u8, @intCast(@divFloor(magnitude, 100)));
        tail[3..5].* = std.fmt.digits2(@intCast(@rem(magnitude, 100)));
        length = 5;
    }

    const result = mantissa_length + length;

    assert(result >= 4);

    return result;
}

fn digits_count(value: u64) u32 {
    assert(@clz(value | 1) < 64);
    assert(powers_ten[integer_bytes_max - 1] == 10_000_000_000_000_000_000);

    const bits: u32 = 64 - @clz(value | 1);
    const guess = (bits * 1233) >> 12;
    const result = guess + @intFromBool(value | 1 >= powers_ten[guess]);

    assert(result >= 1);
    assert(result <= integer_bytes_max);

    return result;
}

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

inline fn high_of(values: Lanes, factor: u16) Lanes {
    assert(factor > 0);
    assert(@reduce(.Max, values) < 10_000);

    const product = @as(@Vector(8, u32), values) * @as(@Vector(8, u32), @splat(factor));

    return @intCast(product >> @splat(16));
}

pub fn float_decimal_format(
    comptime T: type,
    value: T,
    target: *[float_decimal_bytes_max]u8,
) []const u8 {
    comptime assert(@typeInfo(T) == .float);
    comptime assert(@bitSizeOf(T) <= 64);
    assert(std.math.isFinite(value));

    var digits: [integer_bytes_max]u8 = undefined;
    const form = form_of(T, value, &digits);
    const sign_length: u32 = @intFromBool(form.sign);
    const length = form_decimal_length(form);

    assert(sign_length + length <= target.len);

    target[0] = '-';

    form_decimal_write(form, target[sign_length..][0..length]);

    return target[0 .. sign_length + length];
}

fn form_of(comptime T: type, value: T, digits: *[integer_bytes_max]u8) Form {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));

    const Bits = @Int(.unsigned, @bitSizeOf(T));

    const decimal = std.fmt.float.binaryToDecimal(
        u64,
        @as(Bits, @bitCast(value)),
        std.math.floatMantissaBits(T),
        std.math.floatExponentBits(T),
        false,
        &std.fmt.float.Backend64_TablesFull,
    );

    const result: Form = .{
        .digits = integer_format(decimal.mantissa, digits),
        .exponent = decimal.exponent,
        .sign = decimal.sign,
    };

    assert(result.digits.len <= significand_digits_max);
    assert(result.sign == std.math.signbit(value));

    return result;
}

fn form_point(form: Form) i32 {
    assert(form.digits.len >= 1);
    assert(form.digits.len <= significand_digits_max);

    const result = @as(i32, @intCast(form.digits.len)) + form.exponent;

    assert(result > -@as(i32, exponent_magnitude_max));

    return result;
}

fn form_decimal_length(form: Form) u32 {
    assert(form.digits.len >= 1);
    assert(form.digits.len <= significand_digits_max);

    const count: i32 = @intCast(form.digits.len);
    const point = count + form.exponent;
    var result: i32 = count + 1;

    if (form.exponent >= 0) {
        result = point;
    } else if (point < 1) {
        result = 2 - point + count;
    } else {
        assert(point < count);
    }

    assert(result >= count);

    return @intCast(result);
}

fn form_scientific_length(form: Form) u32 {
    assert(form.digits.len >= 1);
    assert(form.digits.len <= significand_digits_max);

    const count: u32 = @intCast(form.digits.len);
    const exponent = form_point(form) - 1;

    var digits: [integer_bytes_max]u8 = undefined;
    const exponent_text = integer_format(@abs(exponent), &digits);
    const significand_length = if (count > 1) count + 1 else 1;
    const result = significand_length + 2 + exponent_text.len;

    assert(result >= count + 3);

    return @intCast(result);
}

fn form_decimal_write(form: Form, target: []u8) void {
    assert(target.len == form_decimal_length(form));
    assert(form.digits.len >= 1);

    const count: i32 = @intCast(form.digits.len);
    const point = count + form.exponent;

    if (form.exponent >= 0) {
        @memcpy(target[0..form.digits.len], form.digits);
        @memset(target[form.digits.len..], '0');
    } else if (point > 0) {
        const split: u32 = @intCast(point);

        @memcpy(target[0..split], form.digits[0..split]);
        target[split] = '.';

        @memcpy(target[split + 1 ..], form.digits[split..]);
    } else {
        const zeros: u32 = @intCast(-point);

        target[0..2].* = "0.".*;

        @memset(target[2..][0..zeros], '0');
        @memcpy(target[2 + zeros ..], form.digits);
    }
}

fn form_scientific_write(form: Form, target: []u8) void {
    assert(target.len == form_scientific_length(form));
    assert(form.digits.len >= 1);

    const count: u32 = @intCast(form.digits.len);

    target[0] = form.digits[0];

    if (count > 1) {
        target[1] = '.';

        @memcpy(target[2..][0 .. count - 1], form.digits[1..]);
    }

    const exponent = form_point(form) - 1;
    var index: u32 = if (count > 1) count + 1 else 1;

    target[index] = 'e';

    target[index + 1] = if (exponent < 0) '-' else '+';
    index += 2;

    var digits: [integer_bytes_max]u8 = undefined;
    const exponent_text = integer_format(@abs(exponent), &digits);

    @memcpy(target[index..], exponent_text);

    assert(index + exponent_text.len == target.len);
}

const testing = std.testing;

test "the fast double format agrees with the form path across bit patterns and magnitudes" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    var fast_buffer: [float_bytes_max]u8 = undefined;
    var form_buffer: [float_bytes_max]u8 = undefined;
    var spaced_buffer: [float_bytes_max]u8 = undefined;
    var regular_count: u32 = 0;

    for (0..1_000_000) |index| {
        const bits: u64 = switch (index % 4) {
            0 => random.int(u64),
            1 => random.int(u64) & ~((@as(u64, 1) << 52) - 1),
            2 => random.int(u64) >> random.uintLessThan(u6, 63),
            else => @bitCast(@as(f64, @floatFromInt(random.int(u32))) / 1000.0),
        };

        const value: f64 = @bitCast(bits);

        if (!std.math.isFinite(value)) continue;

        spaced_buffer = @splat('#');

        const fast = spaced_buffer[0..float64_write(&spaced_buffer, value)];
        const form = form_format(f64, value, &form_buffer);

        try testing.expectEqualStrings(form, fast);
        try testing.expectEqualStrings(form, float_format(f64, value, &fast_buffer));
        try testing.expectEqual(value, try std.fmt.parseFloat(f64, fast));

        regular_count += @intFromBool(shortest.regular_is(bits));
    }

    try testing.expect(regular_count > 500_000);
}

test "the fast double format covers every point position and exponent width" {
    var form_buffer: [float_bytes_max]u8 = undefined;
    var fast_buffer: [float_bytes_max]u8 = undefined;

    for ([_]f64{ 1.0, 1.5, 1.25, 9.87654321, 1.7976931348623157, 5.0e-324 / 5.0e-324 }) |base| {
        var exponent: i32 = -30;

        while (exponent <= 30) : (exponent += 1) {
            const value = base * std.math.pow(f64, 10, @floatFromInt(exponent));
            const form = form_format(f64, value, &form_buffer);

            try testing.expectEqualStrings(form, float_format(f64, value, &fast_buffer));
        }
    }

    const specials = [_]f64{
        0.0,
        -0.0,
        5e-324,
        1e-320,
        1e-300,
        1e100,
        1.7976931348623157e308,
        1e21,
        1e22,
    };

    for (specials) |value| {
        const form = form_format(f64, value, &form_buffer);

        try testing.expectEqualStrings(form, float_format(f64, value, &fast_buffer));
    }

    const quarters = [_]f64{ 1e15, 1e16, 1e17, 123456789012345678.0, 1234567890123456789012.0 };

    for (quarters) |value| {
        const form = form_format(f64, value, &form_buffer);

        try testing.expectEqualStrings(form, float_format(f64, value, &fast_buffer));
    }
}

fn test_float_expect(comptime T: type, value: T, expected: []const u8) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(expected.len > 0);

    var buffer: [float_bytes_max]u8 = undefined;

    try testing.expectEqualStrings(expected, float_format(T, value, &buffer));
}

fn test_number_reference(text: []const u8) bool {
    assert(text.len > 0);
    assert(std.mem.findAny(u8, text, " \t\n\r") == null);

    var tokenizer: Tokenizer = .init(text);
    const first = tokenizer.next() catch return false;
    if (first != .number) return false;

    const last = tokenizer.next() catch return false;
    return last == .end;
}

fn test_float_reference(comptime T: type, value: T) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));

    var scientific_buffer: [64]u8 = undefined;
    var expected_buffer: [float_decimal_bytes_max]u8 = undefined;
    var decimal_expected_buffer: [float_decimal_bytes_max]u8 = undefined;
    var buffer: [float_bytes_max]u8 = undefined;
    var decimal_buffer: [float_decimal_bytes_max]u8 = undefined;

    const scientific = try std.mem.print(&scientific_buffer, "{e}", .{value});
    const expected = try test_ecmascript_reference(scientific, &expected_buffer);
    const decimal_expected = try std.mem.print(&decimal_expected_buffer, "{d}", .{value});
    const text = float_format(T, value, &buffer);
    const decimal = float_decimal_format(T, value, &decimal_buffer);
    const Bits = @Int(.unsigned, @bitSizeOf(T));

    try testing.expectEqualStrings(expected, text);
    try testing.expectEqualStrings(decimal_expected, decimal);
    try testing.expect(test_number_reference(text));
    try testing.expect(test_number_reference(decimal));

    for ([_][]const u8{ text, decimal }) |written| {
        const parsed = try std.fmt.parseFloat(T, written);

        try testing.expectEqual(@as(Bits, @bitCast(value)), @as(Bits, @bitCast(parsed)));
    }
}

fn test_ecmascript_reference(scientific: []const u8, target: []u8) ![]const u8 {
    assert(scientific.len > 0);
    assert(target.len >= float_decimal_bytes_max);

    const negative = scientific[0] == '-';
    const unsigned = scientific[@intFromBool(negative)..];
    const marker = std.mem.findScalar(u8, unsigned, 'e') orelse return error.ReferenceInvalid;
    const exponent = try std.fmt.parseInt(i32, unsigned[marker + 1 ..], 10);

    var digits_buffer: [32]u8 = undefined;
    var digit_count: u32 = 0;

    for (unsigned[0..marker]) |byte| {
        if (byte == '.') continue;

        digits_buffer[digit_count] = byte;
        digit_count += 1;
    }

    const digits = digits_buffer[0..digit_count];
    const count: i32 = @intCast(digit_count);
    const point = exponent + 1;
    var writer: std.Io.Writer = .fixed(target);

    if (negative) try writer.writeByte('-');

    switch (point) {
        -5...0 => {
            try writer.writeAll("0.");
            try writer.splatByteAll('0', @intCast(-point));
            try writer.writeAll(digits);
        },
        1...21 => {
            if (count > point) {
                const split: u32 = @intCast(point);

                try writer.print("{s}.{s}", .{ digits[0..split], digits[split..] });
            } else {
                try writer.writeAll(digits);
                try writer.splatByteAll('0', @intCast(point - count));
            }
        },
        else => {
            const sign: u8 = if (point - 1 < 0) '-' else '+';

            try writer.writeByte(digits[0]);

            if (count > 1) try writer.print(".{s}", .{digits[1..]});

            try writer.print("e{c}{d}", .{ sign, @abs(point - 1) });
        },
    }

    return writer.buffered();
}

test "integers format as std.fmt does at every digit-count edge" {
    var buffer: [integer_bytes_max]u8 = undefined;
    var expected_buffer: [integer_bytes_max]u8 = undefined;
    var power: u64 = 1;

    for (0..integer_bytes_max) |_| {
        for ([_]u64{ power -| 1, power, power +| 1 }) |value| {
            const expected = try std.mem.print(&expected_buffer, "{d}", .{value});

            try testing.expectEqualStrings(expected, integer_format(value, &buffer));
        }

        power = std.math.mul(u64, power, 10) catch std.math.maxInt(u64);
    }

    try testing.expectEqualStrings("0", integer_format(0, &buffer));

    try testing.expectEqualStrings(
        "18446744073709551615",
        integer_format(std.math.maxInt(u64), &buffer),
    );
}

test "floats follow the ECMAScript Number::toString layout" {
    try test_float_expect(f64, 100, "100");
    try test_float_expect(f64, 1000, "1000");
    try test_float_expect(f64, 70000, "70000");
    try test_float_expect(f64, 0.25, "0.25");
    try test_float_expect(f64, 1e20, "100000000000000000000");
    try test_float_expect(f64, 9.999999999999999e20, "999999999999999900000");
    try test_float_expect(f64, 1e21, "1e+21");
    try test_float_expect(f64, 1.5e300, "1.5e+300");
    try test_float_expect(f64, 1e-6, "0.000001");
    try test_float_expect(f64, 9.999999999999997e-7, "9.999999999999997e-7");
    try test_float_expect(f64, 1e-7, "1e-7");
    try test_float_expect(f64, 1.5e-7, "1.5e-7");
    try test_float_expect(f64, 5e-324, "5e-324");
    try test_float_expect(f64, 123456789.125, "123456789.125");
    try test_float_expect(f64, -0.0, "-0");
    try test_float_expect(f64, 0, "0");
    try test_float_expect(f64, 1.7976931348623157e308, "1.7976931348623157e+308");
    try test_float_expect(f64, -2.5e-3, "-0.0025");
    try test_float_expect(f64, 0.000001234567890123456, "0.000001234567890123456");
    try test_float_expect(f32, 0.1, "0.1");
    try test_float_expect(f32, 3.4028235e38, "3.4028235e+38");
    try test_float_expect(f32, 1e-45, "1e-45");
    try test_float_expect(f32, 1e21, "1e+21");
    try test_float_expect(f32, 9.9999995e20, "999999950000000000000");
    try test_float_expect(f32, 9.999999e-7, "9.999999e-7");
}

test "decimal notation writes every magnitude without an exponent" {
    var buffer: [float_decimal_bytes_max]u8 = undefined;

    const large = float_decimal_format(f64, 1e21, &buffer);

    try testing.expectEqualStrings("1000000000000000000000", large);

    const small = float_decimal_format(f64, 1.5e-7, &buffer);

    try testing.expectEqualStrings("0.00000015", small);

    const zero = float_decimal_format(f64, -0.0, &buffer);

    try testing.expectEqualStrings("-0", zero);

    const smallest = float_decimal_format(f64, 5e-324, &buffer);

    try testing.expectEqual(@as(usize, 326), smallest.len);
    try testing.expect(std.mem.startsWith(u8, smallest, "0.000"));
    try testing.expect(std.mem.endsWith(u8, smallest, "0005"));

    const largest = float_decimal_format(f64, -1.7976931348623157e308, &buffer);

    try testing.expectEqual(@as(usize, 310), largest.len);
    try testing.expect(std.mem.startsWith(u8, largest, "-17976931348623157000"));
}

test "a float matches the ECMAScript reference and std decimal form and parses back" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    for (0..4096) |_| {
        const wide: f64 = @bitCast(random.int(u64));
        const narrow: f32 = @bitCast(random.int(u32));

        if (std.math.isFinite(wide)) try test_float_reference(f64, wide);
        if (std.math.isFinite(narrow)) try test_float_reference(f32, narrow);
    }

    const boundaries = [_]f64{
        1e-7,
        1e-6,
        9.999999999999997e-7,
        1e21,
        9.999999999999999e20,
        5e-324,
        1.7976931348623157e308,
        2.2250738585072014e-308,
        0,
        -0.0,
    };

    for (boundaries) |boundary| {
        try test_float_reference(f64, boundary);
        try test_float_reference(f64, -boundary);
    }
}

test "the grammar accepts exactly the texts the tokenizer reads as one number" {
    const alphabet = "-+.eE019";
    const radix: u32 = alphabet.len;
    var text: [5]u8 = undefined;
    var total: u32 = 1;

    for (1..text.len + 1) |length| {
        total *= radix;

        for (0..total) |code| {
            var rest: u32 = @intCast(code);

            for (text[0..length]) |*byte| {
                byte.* = alphabet[@rem(rest, radix)];
                rest = @divFloor(rest, radix);
            }

            const expected = test_number_reference(text[0..length]);

            try testing.expectEqual(expected, grammar_is(text[0..length]));
        }
    }
}

test "the grammar accepts nan, inf, and infinity in any case with an optional minus" {
    const accepted = [_][]const u8{
        "nan",
        "NaN",
        "NAN",
        "inf",
        "Inf",
        "INF",
        "infinity",
        "Infinity",
        "-nan",
        "-inf",
        "-Infinity",
        "-iNfInItY",
    };

    const refused = [_][]const u8{
        "",
        "-",
        "+inf",
        "--inf",
        "-+inf",
        "in",
        "na",
        "infin",
        "nan1",
        "1nan",
        "inf ",
        " inf",
        "Infinityy",
        "nul",
    };

    for (accepted) |text| {
        try testing.expect(grammar_is(text));
        try testing.expect(non_finite_is(text));
        try testing.expectEqual(@as(?i64, null), integer_of_text(text));
        try testing.expectEqual(@as(?u64, null), unsigned_of_text(text));
    }

    for (refused) |text| try testing.expect(!grammar_is(text));

    try testing.expect(!non_finite_is("-0.5"));
    try testing.expect(!non_finite_is("7"));
}

test "a non-finite float is spelled NaN, Infinity, or -Infinity and reads back" {
    try testing.expectEqualStrings("NaN", spelling_of(std.math.nan(f64)));
    try testing.expectEqualStrings("NaN", spelling_of(-std.math.nan(f64)));
    try testing.expectEqualStrings("Infinity", spelling_of(std.math.inf(f64)));
    try testing.expectEqualStrings("-Infinity", spelling_of(-std.math.inf(f64)));

    try testing.expect(std.math.isNan(float_of_text("NaN").?));
    try testing.expect(std.math.isNan(float_of_text("-nan").?));
    try testing.expectEqual(@as(?f64, std.math.inf(f64)), float_of_text("Infinity"));
    try testing.expectEqual(@as(?f64, -std.math.inf(f64)), float_of_text("-INF"));
    try testing.expectEqual(@as(?f64, null), float_of_text("1e400"));
    try testing.expectEqual(@as(?f64, null), float_of_text("-1e400"));
    try testing.expectEqual(@as(?f64, 1.5), float_of_text("1.5"));
    try testing.expectEqual(@as(?i64, -7), integer_of_text("-7"));
    try testing.expectEqual(@as(?u64, 0), unsigned_of_text("-0"));
    try testing.expectEqual(@as(?u64, null), unsigned_of_text("-1"));
}

test "the canonical spelling of a text agrees with the spelling of the float it reads as" {
    var buffer: [16]u8 = undefined;

    for (spellings) |spelling| {
        for (0..@as(u32, 1) << @intCast(spelling.len)) |variant| {
            for (spelling, 0..) |byte, position| {
                const upper = (variant >> @intCast(position)) & 1 == 1;

                buffer[position + 1] = if (upper) std.ascii.toUpper(byte) else byte;
            }

            buffer[0] = '-';

            const unsigned = buffer[1 .. spelling.len + 1];
            const signed = buffer[0 .. spelling.len + 1];

            for ([_][]const u8{ unsigned, signed }) |text| {
                const expected = spelling_of(float_of_text(text).?);

                try testing.expectEqualStrings(expected, spelling_of_text(text));
            }
        }
    }
}

fn test_decimal_text(random: std.Random, buffer: []u8) ![]const u8 {
    assert(buffer.len >= 96);
    assert(@sizeOf(std.Random) > 0);

    var writer: std.Io.Writer = .fixed(buffer);

    if (random.boolean()) try writer.writeByte('-');

    const integer_count = random.intRangeAtMost(u32, 1, 21);

    for (0..integer_count) |index| {
        const leading = index == 0;
        const lowest: u8 = if (leading) @intFromBool(integer_count > 1) else 0;
        const digit = random.intRangeAtMost(u8, lowest, 9);

        try writer.writeByte('0' + digit);
    }

    if (random.uintLessThan(u32, 4) != 0) {
        try writer.writeByte('.');

        for (0..random.intRangeAtMost(u32, 1, 21)) |_| {
            try writer.writeByte('0' + random.uintLessThan(u8, 10));
        }
    }

    if (random.uintLessThan(u32, 3) == 0) {
        const signs = [_][]const u8{ "e", "E", "e+", "e-", "E-" };

        try writer.writeAll(signs[random.uintLessThan(u32, signs.len)]);
        try writer.print("{d}", .{random.uintLessThan(u32, 340)});
    }

    return writer.buffered();
}

test "the quick parsers agree with the standard library on every number text" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    var buffer: [128]u8 = undefined;
    var padded: [256]u8 = undefined;
    var quick_count: u32 = 0;

    for (0..400_000) |_| {
        const text = try test_decimal_text(random, &buffer);
        const expected = try std.fmt.parseFloat(f64, text);
        const actual = float_parse(f64, text).?;

        try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));

        quick_count += @intFromBool(float_quick(text) != null);

        @memcpy(padded[0..text.len], text);
        @memset(padded[text.len..], ' ');

        const input = padded[0 .. text.len + 64];

        if (float_far(input, 0)) |far| {
            try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(far.value)));
            try testing.expectEqual(text.len, far.end);
        }
    }

    try testing.expect(quick_count > 100_000);
}

test "the integer parsers agree with the standard library at every width" {
    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    var buffer: [64]u8 = undefined;
    var padded: [128]u8 = undefined;

    for (0..200_000) |_| {
        const magnitude = random.int(u64) >> random.int(u6);
        const value: i128 = if (random.boolean()) magnitude else -@as(i128, magnitude);
        const text = try std.mem.print(&buffer, "{d}", .{value});

        @memcpy(padded[0..text.len], text);
        @memset(padded[text.len..], ' ');

        const input = padded[0 .. text.len + 32];

        inline for ([_]type{ u8, i8, u16, i16, u32, i32, u64, i64 }) |T| {
            const expected = std.fmt.parseInt(T, text, 10) catch null;

            try testing.expectEqual(expected, integer_parse(T, text));

            if (integer_far(T, input, 0)) |far| {
                try testing.expectEqual(expected.?, far.value);
                try testing.expectEqual(text.len, far.end);
            }
        }
    }
}

test "the far integer scan refuses what the grammar refuses and spans every digit count" {
    var padded: [64]u8 = @splat(' ');

    for ([_][]const u8{ "01", "00", "-", "-01", "1.5", "1e3", "12x", "\"1\"", "" }) |text| {
        @memcpy(padded[0..text.len], text);
        @memset(padded[text.len..], ' ');

        try testing.expect(integer_far(i64, &padded, 0) == null);
    }

    var power: u64 = 1;

    for (1..20) |digit_count| {
        const text = try std.mem.print(&padded, "{d}", .{power});

        try testing.expectEqual(digit_count, text.len);

        @memset(padded[text.len..], ' ');

        const far = integer_far(u64, &padded, 0).?;

        try testing.expectEqual(power, far.value);
        try testing.expectEqual(digit_count, far.end);

        if (digit_count < 19) power *= 10;
    }

    const twenty = try std.mem.print(&padded, "{d}", .{@as(u64, std.math.maxInt(u64))});

    @memset(padded[twenty.len..], ' ');

    try testing.expect(integer_far(u64, &padded, 0) == null);
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), integer_parse(u64, twenty));
}

const Agreement = enum {
    converted,
    declined,
    overflowed,
};

fn extended_agree(mantissa: u64, exponent: i32) !Agreement {
    assert(mantissa <= powers_integer[decimal_digits_max]);
    assert(exponent > @divTrunc(std.math.minInt(i32), 2));

    var buffer: [48]u8 = undefined;

    const text = try std.mem.print(&buffer, "{d}e{d}", .{ mantissa, exponent });
    const expected = try std.fmt.parseFloat(f64, text);

    const value = magnitude_extended(mantissa, exponent) orelse {
        if (std.math.isInf(expected)) return .overflowed;
        if (exponent >= extended_exact_min) try testing.expect(exponent > extended_exact_max);

        return .declined;
    };

    try testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(value)));

    return .converted;
}

fn mantissa_random(random: std.Random) u64 {
    const digit_count = random.intRangeAtMost(u32, 1, decimal_digits_max);
    const low = powers_integer[digit_count - 1];
    const high = if (digit_count == decimal_digits_max)
        powers_integer[decimal_digits_max] - 1
    else
        powers_integer[digit_count] - 1;

    const result = switch (random.uintLessThan(u32, 8)) {
        0 => powers_integer[random.uintLessThan(u32, decimal_digits_max)],
        1 => (@as(u64, 1) << 53) + random.uintLessThan(u64, 8) - 4,
        2 => @max(low, @divFloor(random.intRangeAtMost(u64, low, high), 1000) * 1000),
        else => random.intRangeAtMost(u64, low, high),
    };

    assert(result > 0);
    assert(result < powers_integer[decimal_digits_max]);

    return result;
}

test "the powers of five match the published Eisel-Lemire table" {
    const Entry = struct { exponent: i32, high: u64, low: u64 };
    const entries = [_]Entry{
        .{ .exponent = -342, .high = 0xeef453d6923bd65a, .low = 0x113faa2906a13b3f },
        .{ .exponent = -341, .high = 0x9558b4661b6565f8, .low = 0x4ac7ca59a424c507 },
        .{ .exponent = -300, .high = 0xab70fe17c79ac6ca, .low = 0x6dbd630a48aaf406 },
        .{ .exponent = -100, .high = 0xdff9772470297ebd, .low = 0x59787e2b93bc56f7 },
        .{ .exponent = -28, .high = 0xfd87b5f28300ca0d, .low = 0x8bca9d6e188853fc },
        .{ .exponent = -27, .high = 0x9e74d1b791e07e48, .low = 0x775ea264cf55347e },
        .{ .exponent = -26, .high = 0xc612062576589dda, .low = 0x95364afe032a819e },
        .{ .exponent = -1, .high = 0xcccccccccccccccc, .low = 0xcccccccccccccccd },
        .{ .exponent = 0, .high = 0x8000000000000000, .low = 0x0 },
        .{ .exponent = 1, .high = 0xa000000000000000, .low = 0x0 },
        .{ .exponent = 27, .high = 0xcecb8f27f4200f3a, .low = 0x0 },
        .{ .exponent = 28, .high = 0x813f3978f8940984, .low = 0x4000000000000000 },
        .{ .exponent = 55, .high = 0xd0cf4b50cfe20765, .low = 0xfff4b4e3f741cf6d },
        .{ .exponent = 56, .high = 0x82818f1281ed449f, .low = 0xbff8f10e7a8921a4 },
        .{ .exponent = 100, .high = 0x924d692ca61be758, .low = 0x593c2626705f9c56 },
        .{ .exponent = 307, .high = 0xe3d8f9e563a198e5, .low = 0x58180fddd97723a6 },
        .{ .exponent = 308, .high = 0x8e679c2f5e44ff8f, .low = 0x570f09eaa7ea7648 },
    };

    for (entries) |entry| {
        const power = powers_five[@intCast(entry.exponent - power_five_min)];

        try testing.expectEqual(entry.high, power.high);
        try testing.expectEqual(entry.low, power.low);
    }
}

test "the extended conversion agrees with the standard library at every exponent" {
    var prng: std.Random.DefaultPrng = .init(0x656c656d);
    const random = prng.random();

    var counts: std.EnumArray(Agreement, u32) = .initFill(0);

    for (0..200_000) |_| {
        const mantissa = mantissa_random(random);
        const exponent = random.intRangeAtMost(i32, power_five_min - 30, power_five_max + 30);
        const agreement = try extended_agree(mantissa, exponent);

        counts.set(agreement, counts.get(agreement) + 1);
    }

    try testing.expect(counts.get(.converted) > 180_000);
    try testing.expect(counts.get(.overflowed) > 0);
    try testing.expect(counts.get(.declined) < 50);

    const hard = [_]struct { mantissa: u64, exponent: i32 }{
        .{ .mantissa = 9007199254740993, .exponent = 0 },
        .{ .mantissa = 9007199254740995, .exponent = 0 },
        .{ .mantissa = 22250738585072011, .exponent = -324 },
        .{ .mantissa = 22250738585072012, .exponent = -324 },
        .{ .mantissa = 49406564584124654, .exponent = -340 },
        .{ .mantissa = 24703282292062327, .exponent = -340 },
        .{ .mantissa = 24703282292062328, .exponent = -340 },
        .{ .mantissa = 17976931348623157, .exponent = 292 },
        .{ .mantissa = 17976931348623158, .exponent = 292 },
        .{ .mantissa = 17976931348623159, .exponent = 292 },
        .{ .mantissa = 1, .exponent = -342 },
        .{ .mantissa = 9999999999999999999, .exponent = -343 },
        .{ .mantissa = 1, .exponent = 308 },
        .{ .mantissa = 7450580596923828125, .exponent = -27 },
    };

    for (hard) |case| _ = try extended_agree(case.mantissa, case.exponent);

    try testing.expectEqual(@as(?f64, 0), magnitude_extended(0, 5));
    try testing.expectEqual(@as(?f64, 0), magnitude_extended(1, power_five_min - 1));
    try testing.expectEqual(@as(?f64, null), magnitude_extended(1, power_five_max + 1));
}
