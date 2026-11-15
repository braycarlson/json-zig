const std = @import("std");

const assert = std.debug.assert;

pub const Decimal = struct {
    exponent: i32,
    mantissa: u64,
};

const cache_index_minimum: i32 = -293;
const cache_index_maximum: i32 = 326;
const exact_maximum: i32 = 55;
const exponent_maximum: i32 = 971;
const exponent_minimum: i32 = -1074;
const extra_shift: u6 = 9;
const fraction_bits: u6 = 52;
const half_biased: u128 = (1 << 63) + 6;
const shorter_tie_exponent: i32 = -77;

const cache: [cache_index_maximum - cache_index_minimum + 1]u128 = cache: {
    @setEvalBranchQuota(10_000_000);

    var table: [cache_index_maximum - cache_index_minimum + 1]u128 = undefined;

    for (&table, 0..) |*entry, offset| {
        entry.* = power_normalized(cache_index_minimum + @as(i32, @intCast(offset)));
    }

    break :cache table;
};

const shifts: [exponent_maximum - exponent_minimum + 1]u6 = shifts: {
    @setEvalBranchQuota(100_000);

    var table: [exponent_maximum - exponent_minimum + 1]u6 = undefined;

    for (&table, 0..) |*entry, offset| {
        const exponent = exponent_minimum + @as(i32, @intCast(offset));
        const decimal_exponent = log10_power2(exponent);

        entry.* = @intCast(exponent + log2_power10(-decimal_exponent - 1) + 10);
    }

    break :shifts table;
};

comptime {
    assert(cache.len == 620);
    assert(shifts.len == 2046);
    assert(cache[@intCast(-cache_index_minimum)] == 1 << 127);
    assert(@as(u32, fraction_bits) + 1 + extra_shift < 64);
}

fn power_normalized(comptime exponent: i32) u128 {
    comptime assert(exponent >= cache_index_minimum);
    comptime assert(exponent <= cache_index_maximum);

    const Wide = u1408;
    const ten: Wide = 10;
    const magnitude: Wide = std.math.pow(Wide, ten, @abs(exponent));
    const bits: u32 = @bitSizeOf(Wide) - @clz(magnitude);

    const result: Wide = if (exponent >= 0)
        (magnitude >> (@as(u32, bits) -| 128)) << (128 -| bits)
    else
        @divFloor(@as(Wide, 1) << (127 + bits), magnitude);

    assert(result >> 127 == 1);
    assert(result >> 128 == 0);

    return @intCast(result);
}

fn log10_power2(exponent: i32) i32 {
    assert(exponent >= -1700);
    assert(exponent <= 1700);

    return @intCast((@as(i64, exponent) * 315_653) >> 20);
}

fn log10_power2_shorter(exponent: i32) i32 {
    assert(exponent >= -1700);
    assert(exponent <= 1700);

    return @intCast((@as(i64, exponent) * 631_305 - 261_663) >> 21);
}

fn log2_power10(exponent: i32) i32 {
    assert(exponent >= -1233);
    assert(exponent <= 1233);

    return @intCast((@as(i64, exponent) * 1_741_647) >> 19);
}

fn cache_of(minus_k: i32) u128 {
    assert(-minus_k >= cache_index_minimum);
    assert(-minus_k <= cache_index_maximum);

    const exponent = -minus_k;
    const inexact = @intFromBool(exponent < 0) | @intFromBool(exponent > exact_maximum);
    const result = cache[@intCast(exponent - cache_index_minimum)] + inexact;

    if (std.debug.runtime_safety) assert(result >> 127 == 1);

    return result;
}

inline fn high(value: u128) u64 {
    assert(value >> 64 <= std.math.maxInt(u64));

    const result: u64 = @truncate(value >> 64);

    assert(@as(u128, result) << 64 <= value);

    return result;
}

fn floor_of(exponent: i32) u128 {
    assert(exponent >= cache_index_minimum);
    assert(exponent <= cache_index_maximum);

    const result = cache[@intCast(exponent - cache_index_minimum)];

    assert(result >> 127 == 1);

    return result;
}

pub inline fn decimal_of(value: f64) Decimal {
    assert(std.math.isFinite(value));
    assert(value != 0);

    const bits: u64 = @bitCast(value);
    const fraction = bits & ((@as(u64, 1) << fraction_bits) - 1);
    const biased: i32 = @intCast((bits >> fraction_bits) & 0x7ff);

    if (biased == 0) return decimal_scaled(exponent_minimum, fraction);

    if (fraction == 0) {
        if (biased > 1) return decimal_shorter(biased - 1075);
    }

    return decimal_scaled(biased - 1075, fraction | @as(u64, 1) << fraction_bits);
}

pub const Scaled = struct {
    digit: u64,
    exponent: i32,
    nearest: u64,
    shorter: u64,
};

pub fn regular_is(bits: u64) bool {
    assert(@sizeOf(u64) == 8);
    assert(fraction_bits == 52);

    const biased_low: u64 = @as(u64, 1) << (fraction_bits + 1);
    const biased_span: u64 = @as(u64, 0x7fe) << (fraction_bits + 1);

    if ((bits << 1) -% biased_low >= biased_span) return false;
    return bits << 12 != 0;
}

pub inline fn scaled_of(bits: u64) Scaled {
    assert(regular_is(bits));
    assert(bits & 0x7ff0_0000_0000_0000 != 0x7ff0_0000_0000_0000);

    const fraction = bits & ((@as(u64, 1) << fraction_bits) - 1);
    const biased: i32 = @intCast((bits >> fraction_bits) & 0x7ff);

    return scaled_core(biased - 1075, fraction | @as(u64, 1) << fraction_bits);
}

inline fn scaled_core(exponent: i32, significand: u64) Scaled {
    assert(significand > 0);
    assert(significand < @as(u64, 1) << (fraction_bits + 1));
    if (std.debug.runtime_safety) assert(exponent >= exponent_minimum);

    const decimal_exponent = log10_power2(exponent);
    const power = floor_of(-decimal_exponent - 1);
    const shift = shifts[@intCast(exponent - exponent_minimum)];
    const power_high = high(power);
    const scaled = significand << shift;
    const product = std.math.mulWide(u64, power_high, scaled) +
        (std.math.mulWide(u64, @as(u64, @truncate(power)), scaled) >> 64);

    const product_high = high(product);
    const integral = product_high >> extra_shift;
    const fractional_high = product_high << (63 - extra_shift + 1);
    const fractional_low = @as(u64, @truncate(product)) >> extra_shift;
    const fractional = fractional_high | fractional_low;
    const half = (power_high >> (extra_shift + 1 - shift)) + @intFromBool(significand & 1 == 0);
    const round_up: u64 = @intFromBool(fractional +% half < fractional);
    const round_down: u64 = @intFromBool(half > fractional);
    const tie: u64 = @intFromBool(fractional == 1 << 62);
    const tenth: u64 = @intCast((std.math.mulWide(u64, fractional, 10) + half_biased) >> 64);
    const shorter = round_up | round_down;

    const result: Scaled = .{
        .digit = (tenth - tie) & (shorter -% 1),
        .exponent = decimal_exponent,
        .nearest = integral + round_up,
        .shorter = shorter,
    };

    assert(result.digit <= 9);
    assert(result.nearest < 10_000_000_000_000_000);

    return result;
}

inline fn decimal_scaled(exponent: i32, significand: u64) Decimal {
    assert(significand > 0);
    assert(significand < @as(u64, 1) << (fraction_bits + 1));
    if (std.debug.runtime_safety) assert(exponent >= exponent_minimum);

    const scaled = scaled_core(exponent, significand);
    const select = 0 -% scaled.shorter;
    const longer = scaled.nearest * 10 + scaled.digit;

    const result: Decimal = .{
        .exponent = scaled.exponent + @as(i32, @intCast(scaled.shorter)),
        .mantissa = (scaled.nearest & select) | (longer & ~select),
    };

    assert(result.mantissa > 0);
    assert(result.mantissa < 100_000_000_000_000_000);

    return result;
}

fn decimal_shorter(exponent: i32) Decimal {
    assert(exponent >= exponent_minimum);
    assert(exponent <= 971);

    const minus_k = log10_power2_shorter(exponent);
    const beta: u6 = @intCast(exponent + log2_power10(-minus_k));
    const upper = high(cache_of(minus_k));
    const shift: u6 = @intCast(64 - @as(u7, fraction_bits) - 1 - beta);
    const left_integer = exponent >= 2 and exponent <= 3;
    const left_base = (upper - (upper >> (fraction_bits + 2))) >> shift;
    const left = if (left_integer) left_base else left_base + 1;
    const right = (upper + (upper >> (fraction_bits + 1))) >> shift;
    const larger = @divFloor(right, 10);

    if (larger * 10 >= left) return .{ .exponent = minus_k + 1, .mantissa = larger };

    const round_shift: u6 = @intCast(64 - @as(u7, fraction_bits) - 2 - beta);
    const rounded = @divFloor((upper >> round_shift) + 1, 2);
    const tie = rounded % 2 != 0 and exponent == shorter_tie_exponent;

    const mantissa = if (tie)
        rounded - 1
    else if (rounded < left)
        rounded + 1
    else
        rounded;

    assert(mantissa > 0);

    return .{ .exponent = minus_k, .mantissa = mantissa };
}

test "floor powers match the exact quotient" {
    for (0..cache.len) |offset| {
        const exponent = cache_index_minimum + @as(i32, @intCast(offset));
        const expected = power_floor_exact(exponent);

        try std.testing.expectEqual(expected, floor_of(exponent));
    }
}

fn power_floor_exact(exponent: i32) u128 {
    assert(exponent >= cache_index_minimum);
    assert(exponent <= cache_index_maximum);

    const Wide = u1408;
    const magnitude = std.math.pow(Wide, 10, @abs(exponent));
    const bits: u32 = @bitSizeOf(Wide) - @clz(magnitude);

    const result: Wide = if (exponent >= 0)
        (if (bits > 128) magnitude >> @intCast(bits - 128) else magnitude << @intCast(128 - bits))
    else
        @divFloor(@as(Wide, 1) << @intCast(127 + bits), magnitude);

    assert(result >> 127 == 1);
    assert(result >> 128 == 0);

    return @intCast(result);
}

test "decimals agree with the standard library shortest digits" {
    var prng: std.Random.DefaultPrng = .init(0x73686f72);
    const random = prng.random();
    const tables = &std.fmt.float.Backend64_TablesFull;

    for (0..2_000_000) |index| {
        const bits = switch (index % 4) {
            0 => random.int(u64) >> random.uintLessThan(u6, 63),
            1 => random.int(u64) & ~((@as(u64, 1) << 52) - 1),
            else => random.int(u64),
        };

        const value: f64 = @bitCast(bits);

        if (!std.math.isFinite(value)) continue;
        if (value == 0) continue;

        const expected = std.fmt.float.binaryToDecimal(u64, bits, 52, 11, false, tables);
        const actual = decimal_of(value);
        const left = normalized(expected.mantissa, expected.exponent);
        const right = normalized(actual.mantissa, actual.exponent);

        try std.testing.expectEqual(left, right);
    }
}

fn normalized(mantissa: u64, exponent: i32) Decimal {
    assert(mantissa > 0);
    assert(exponent > -400);

    var result: Decimal = .{ .exponent = exponent, .mantissa = mantissa };

    for (0..20) |_| {
        if (result.mantissa % 10 != 0) break;

        result.mantissa = @divExact(result.mantissa, 10);
        result.exponent += 1;
    }

    return result;
}

test "every power of two agrees with the standard library shortest digits" {
    const tables = &std.fmt.float.Backend64_TablesFull;

    for (1..2047) |biased| {
        const bits = @as(u64, biased) << 52;
        const value: f64 = @bitCast(bits);
        const expected = std.fmt.float.binaryToDecimal(u64, bits, 52, 11, false, tables);
        const actual = decimal_of(value);

        const left = normalized(expected.mantissa, expected.exponent);
        const right = normalized(actual.mantissa, actual.exponent);

        try std.testing.expectEqual(left, right);
    }
}
