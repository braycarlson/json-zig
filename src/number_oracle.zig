const std = @import("std");

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const Order = std.math.Order;

const Binary = struct {
    exponent: i64,
    mantissa: u64,
};

const Decimal = struct {
    count: u32,
    digits: [digit_count_max]u8,
    exponent: i64,
    negative: bool,
};

const Interval = struct {
    inclusive: bool,
    lower: ?Binary,
    upper: ?Binary,
};

pub const Error = Allocator.Error || error{ DigitsTooMany, NumberInvalid };

pub const digit_count_max: u32 = 1 << 14;
const exponent_saturated: i64 = 1 << 40;
const point_decided_max: i64 = 400;

comptime {
    assert(point_decided_max > 330);
    assert(exponent_saturated > digit_count_max + point_decided_max);
}

pub fn float_check(comptime T: type, gpa: Allocator, text: []const u8, value: T) Error!bool {
    comptime assert(@typeInfo(T) == .float);
    assert(text.len > 0);
    assert(!std.math.isNan(value));

    var decimal: Decimal = undefined;

    try decimal_parse(text, &decimal);

    return decimal_rounds_to(T, gpa, &decimal, value);
}

pub fn format_check(comptime T: type, gpa: Allocator, text: []const u8, value: T) Error!bool {
    comptime assert(@typeInfo(T) == .float);
    assert(text.len > 0);
    assert(std.math.isFinite(value));

    var decimal: Decimal = undefined;

    try decimal_parse(text, &decimal);

    if (!try decimal_rounds_to(T, gpa, &decimal, value)) return false;
    if (decimal.count == 0) return true;
    if (try shorter_rounds_to(T, gpa, &decimal, value)) return false;

    var significand = try Managed.init(gpa);
    defer significand.deinit();

    try digits_set(&significand, decimal.digits[0..decimal.count]);

    return !try neighbour_closer(T, gpa, &significand, decimal.exponent, @abs(value));
}

pub fn integer_check(comptime T: type, gpa: Allocator, text: []const u8, value: ?T) Error!bool {
    comptime assert(@typeInfo(T) == .int);
    assert(text.len > 0);
    if (value) |known| assert(known >= 0 or text[0] == '-');

    var exact = try Managed.init(gpa);
    defer exact.deinit();

    exact.setString(10, text) catch |err| switch (err) {
        error.InvalidCharacter => return error.NumberInvalid,
        error.InvalidBase => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };

    const fitting = exact.toInt(T) catch |err| switch (err) {
        error.TargetTooSmall, error.NegativeIntoUnsigned => return value == null,
    };

    return value == fitting;
}

fn decimal_parse(text: []const u8, decimal: *Decimal) Error!void {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const negative = text[0] == '-';
    const unsigned = text[@intFromBool(negative)..];
    const marker = std.mem.findAny(u8, unsigned, "eE") orelse unsigned.len;

    decimal.count = 0;
    decimal.exponent = 0;
    decimal.negative = negative;

    if (marker < unsigned.len) decimal.exponent = try exponent_parse(unsigned[marker + 1 ..]);

    try significand_parse(unsigned[0..marker], decimal);

    for (0..decimal.count) |_| {
        if (decimal.count == 0) break;
        if (decimal.digits[decimal.count - 1] != '0') break;

        decimal.count -= 1;
        decimal.exponent += 1;
    }

    if (decimal.count > 0) assert(decimal.digits[0] != '0');
}

fn significand_parse(text: []const u8, decimal: *Decimal) Error!void {
    assert(text.len < std.math.maxInt(u32));
    assert(decimal.count == 0);
    assert(@abs(decimal.exponent) <= exponent_saturated);

    var point_seen = false;
    var digit_seen = false;

    for (text) |byte| {
        if (byte == '.') {
            if (point_seen) return error.NumberInvalid;

            point_seen = true;

            continue;
        }

        if (!std.ascii.isDigit(byte)) return error.NumberInvalid;

        digit_seen = true;

        if (point_seen) decimal.exponent -= 1;

        if (decimal.count == 0) {
            if (byte == '0') continue;
        }

        if (decimal.count == digit_count_max) return error.DigitsTooMany;

        decimal.digits[decimal.count] = byte;
        decimal.count += 1;
    }

    if (!digit_seen) return error.NumberInvalid;
}

fn exponent_parse(text: []const u8) Error!i64 {
    assert(text.len < std.math.maxInt(u32));

    if (text.len == 0) return error.NumberInvalid;

    const negative = text[0] == '-';
    const digits = text[@intFromBool(negative or text[0] == '+')..];
    if (digits.len == 0) return error.NumberInvalid;

    var magnitude: i64 = 0;

    for (digits) |byte| {
        if (!std.ascii.isDigit(byte)) return error.NumberInvalid;

        magnitude = @min(magnitude * 10 + (byte - '0'), exponent_saturated);
    }

    assert(magnitude >= 0);
    assert(magnitude <= exponent_saturated);

    return if (negative) -magnitude else magnitude;
}

fn decimal_rounds_to(comptime T: type, gpa: Allocator, decimal: *const Decimal, value: T) !bool {
    assert(decimal.count <= digit_count_max);
    assert(@abs(decimal.exponent) <= exponent_saturated + digit_count_max);

    if (std.math.signbit(value) != decimal.negative) return false;

    const magnitude = @abs(value);
    if (decimal.count == 0) return magnitude == 0;

    const point = decimal.count + decimal.exponent;
    if (point > point_decided_max) return std.math.isInf(magnitude);
    if (point < -point_decided_max) return magnitude == 0;

    var significand = try Managed.init(gpa);
    defer significand.deinit();

    try digits_set(&significand, decimal.digits[0..decimal.count]);

    return interval_contains(T, gpa, &significand, decimal.exponent, magnitude);
}

fn digits_set(target: *Managed, digits: []const u8) Allocator.Error!void {
    assert(digits.len > 0);
    assert(digits.len <= digit_count_max);

    target.setString(10, digits) catch |err| switch (err) {
        error.InvalidBase, error.InvalidCharacter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn interval_contains(
    comptime T: type,
    gpa: Allocator,
    significand: *const Managed,
    exponent: i64,
    magnitude: T,
) !bool {
    assert(!std.math.signbit(magnitude));
    assert(significand.isPositive() or significand.eqlZero());
    assert(@abs(exponent) <= point_decided_max + digit_count_max + 1);

    if (significand.eqlZero()) return magnitude == 0;

    const interval = interval_of(T, magnitude);

    if (interval.lower) |lower| {
        switch (try order_of(gpa, significand, exponent, lower)) {
            .lt => return false,
            .eq => if (!interval.inclusive) return false,
            .gt => {},
        }
    }

    if (interval.upper) |upper| {
        switch (try order_of(gpa, significand, exponent, upper)) {
            .lt => {},
            .eq => if (!interval.inclusive) return false,
            .gt => return false,
        }
    }

    return true;
}

fn interval_of(comptime T: type, magnitude: T) Interval {
    assert(!std.math.isNan(magnitude));
    assert(!std.math.signbit(magnitude));

    if (std.math.isInf(magnitude)) {
        const largest = binary_of(T, std.math.floatMax(T));
        const threshold: Binary = .{
            .exponent = largest.exponent - 1,
            .mantissa = 2 * largest.mantissa + 1,
        };

        return .{ .inclusive = true, .lower = threshold, .upper = null };
    }

    if (magnitude == 0) {
        const smallest = binary_of(T, std.math.floatTrueMin(T));
        const half: Binary = .{ .exponent = smallest.exponent - 1, .mantissa = 1 };

        return .{ .inclusive = true, .lower = null, .upper = half };
    }

    const binary = binary_of(T, magnitude);
    const hidden = @as(u64, 1) << std.math.floatMantissaBits(T);
    const smallest = binary_of(T, std.math.floatTrueMin(T));
    const bottom = binary.mantissa == hidden and binary.exponent > smallest.exponent;
    const upper: Binary = .{ .exponent = binary.exponent - 1, .mantissa = 2 * binary.mantissa + 1 };

    const lower: Binary = if (bottom)
        .{ .exponent = binary.exponent - 2, .mantissa = 4 * binary.mantissa - 1 }
    else
        .{ .exponent = binary.exponent - 1, .mantissa = 2 * binary.mantissa - 1 };

    return .{ .inclusive = binary.mantissa % 2 == 0, .lower = lower, .upper = upper };
}

fn binary_of(comptime T: type, magnitude: T) Binary {
    comptime assert(@bitSizeOf(T) <= 64);
    assert(std.math.isFinite(magnitude));
    assert(magnitude > 0);

    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const mantissa_bits = std.math.floatMantissaBits(T);
    const bias: i64 = (1 << (std.math.floatExponentBits(T) - 1)) - 1;
    const bits: Bits = @bitCast(magnitude);
    const fraction: u64 = bits & ((@as(Bits, 1) << mantissa_bits) - 1);
    const field: i64 = @intCast(bits >> mantissa_bits);

    if (field == 0) return .{ .exponent = 1 - bias - mantissa_bits, .mantissa = fraction };

    return .{
        .exponent = field - bias - mantissa_bits,
        .mantissa = fraction | (@as(u64, 1) << mantissa_bits),
    };
}

fn order_of(gpa: Allocator, significand: *const Managed, exponent: i64, binary: Binary) !Order {
    assert(@abs(exponent) <= point_decided_max + digit_count_max);
    assert(@abs(binary.exponent) < 2048);

    var left = try significand.clone();
    defer left.deinit();

    var right = try Managed.initSet(gpa, binary.mantissa);
    defer right.deinit();

    var five = try Managed.initSet(gpa, 5);
    defer five.deinit();

    var power = try Managed.init(gpa);
    defer power.deinit();

    try power.pow(&five, @intCast(@abs(exponent)));

    if (exponent >= 0) {
        try left.mul(&left, &power);
    } else {
        try right.mul(&right, &power);
    }

    const shift = exponent - binary.exponent;

    if (shift >= 0) {
        try left.shiftLeft(&left, @intCast(shift));
    } else {
        try right.shiftLeft(&right, @intCast(-shift));
    }

    return left.order(right);
}

fn shorter_rounds_to(comptime T: type, gpa: Allocator, decimal: *const Decimal, value: T) !bool {
    assert(decimal.count > 0);
    assert(std.math.isFinite(value));

    if (decimal.count == 1) return false;

    var floor = try Managed.init(gpa);
    defer floor.deinit();

    try digits_set(&floor, decimal.digits[0 .. decimal.count - 1]);

    var ceiling = try Managed.init(gpa);
    defer ceiling.deinit();

    try ceiling.addScalar(&floor, 1);

    const magnitude = @abs(value);

    if (try interval_contains(T, gpa, &floor, decimal.exponent + 1, magnitude)) return true;
    return interval_contains(T, gpa, &ceiling, decimal.exponent + 1, magnitude);
}

fn neighbour_closer(
    comptime T: type,
    gpa: Allocator,
    significand: *const Managed,
    exponent: i64,
    magnitude: T,
) !bool {
    assert(significand.isPositive());
    assert(std.math.isFinite(magnitude));
    assert(@abs(exponent) <= point_decided_max + digit_count_max);

    const binary = binary_of(T, magnitude);
    const doubled: Binary = .{ .exponent = binary.exponent + 1, .mantissa = binary.mantissa };
    const odd = !significand.isEven();

    var midpoint = try Managed.init(gpa);
    defer midpoint.deinit();

    var neighbour = try Managed.init(gpa);
    defer neighbour.deinit();

    for ([_]i2{ -1, 1 }) |direction| {
        try midpoint.shiftLeft(significand, 1);
        try midpoint.addScalar(&midpoint, direction);
        try neighbour.addScalar(significand, direction);

        const order = try order_of(gpa, &midpoint, exponent, doubled);
        const beyond: Order = if (direction > 0) .lt else .gt;
        const nearer = order == beyond or (order == .eq and odd);
        if (!nearer) continue;

        if (try interval_contains(T, gpa, &neighbour, exponent, magnitude)) return true;
    }

    return false;
}

const testing = std.testing;

fn test_float_expect(comptime T: type, text: []const u8, bits: u64) !void {
    const Bits = @Int(.unsigned, @bitSizeOf(T));

    assert(bits <= std.math.maxInt(Bits));

    const value: T = @bitCast(@as(Bits, @intCast(bits)));

    try testing.expect(try float_check(T, testing.allocator, text, value));

    if (std.math.isInf(value)) {
        const largest = std.math.floatMax(T);

        const finite = std.math.copysign(largest, value);

        try testing.expect(!try float_check(T, testing.allocator, text, finite));

        return;
    }

    const above = std.math.nextAfter(T, value, std.math.inf(T));
    const below = std.math.nextAfter(T, value, -std.math.inf(T));

    try testing.expect(!try float_check(T, testing.allocator, text, above));
    try testing.expect(!try float_check(T, testing.allocator, text, below));
}

test "the oracle accepts exactly the published correctly rounded doubles" {
    try test_float_expect(f64, "0.1", 0x3FB999999999999A);
    try test_float_expect(f64, "1", 0x3FF0000000000000);
    try test_float_expect(f64, "-2.5e-3", 0xBF647AE147AE147B);
    try test_float_expect(f64, "9007199254740993", 0x4340000000000000);
    try test_float_expect(f64, "9007199254740995", 0x4340000000000002);
    try test_float_expect(f64, "9007199254740993.0000000000000000001", 0x4340000000000001);
    try test_float_expect(f64, "2.2250738585072011e-308", 0x000FFFFFFFFFFFFF);
    try test_float_expect(f64, "2.2250738585072012e-308", 0x0010000000000000);
    try test_float_expect(f64, "2.4703282292062328e-324", 0x0000000000000001);
    try test_float_expect(f64, "4.9406564584124654e-324", 0x0000000000000001);
    try test_float_expect(f64, "1.7976931348623157e308", 0x7FEFFFFFFFFFFFFF);
    try test_float_expect(f64, "1.7976931348623158e308", 0x7FEFFFFFFFFFFFFF);
    try test_float_expect(f64, "1.7976931348623159e308", 0x7FF0000000000000);
    try test_float_expect(f64, "-1e400", 0xFFF0000000000000);
    try test_float_expect(f64, "1e23", 0x44B52D02C7E14AF6);
    try test_float_expect(f64, "8.98846567431158e307", 0x7FE0000000000000);
    try test_float_expect(f32, "0.1", 0x3DCCCCCD);
    try test_float_expect(f32, "16777217", 0x4B800000);
    try test_float_expect(f32, "3.4028235e38", 0x7F7FFFFF);
    try test_float_expect(f32, "3.40282356e38", 0x7F7FFFFF);
    try test_float_expect(f32, "3.4028236e38", 0x7F800000);
    try test_float_expect(f32, "3.40282357e38", 0x7F800000);
    try test_float_expect(f32, "1e-45", 0x00000001);
    try test_float_expect(f32, "1.17549435e-38", 0x00800000);
}

test "the oracle rounds ties to even and the halfway point of the smallest subnormal to zero" {
    const half_smallest = "2.4703282292062327208828439643411068618252990130716238221279284125" ++
        "033775363510437593264991818081799618989828234772285886546332835517796989819938739800" ++
        "539093906315035659515570226392290858392449105184435931802849936536152500319370457678" ++
        "249219365623669863658480757001585769269903706311928279558551332927834338409351978015" ++
        "531246597263579574622766465272827220056374006485499977096599470454020828166226237857" ++
        "393450736339007967761930577506740176324673600968951340535537458516661134223766678604" ++
        "162159680461914467291840300530057530849048765391711386591646239524912623653881879636" ++
        "239373280423891018672348497668235089863388587925628302755995657524455507255189313690" ++
        "836254779186948667994968324049705821028513185451396213837722826145437693412532098591" ++
        "327667236328125e-324";

    try testing.expect(try float_check(f64, testing.allocator, half_smallest, 0.0));
    try testing.expect(!try float_check(f64, testing.allocator, half_smallest, 5e-324));
    try testing.expect(try float_check(f64, testing.allocator, "-0", -0.0));
    try testing.expect(!try float_check(f64, testing.allocator, "-0", 0.0));
    try testing.expect(!try float_check(f64, testing.allocator, "0", -0.0));
    try testing.expect(try float_check(f64, testing.allocator, "-1e-999999999999", -0.0));
    try testing.expect(try float_check(f64, testing.allocator, "0e999999999999", 0.0));
}

test "the oracle refuses texts that are not decimal numbers" {
    const refused = [_][]const u8{ "-", ".", "1e", "1e+", "1.2.3", "0x10", "nan", "1 " };

    for (refused) |text| {
        try testing.expectError(error.NumberInvalid, float_check(f64, testing.allocator, text, 1));
    }
}

test "the format oracle accepts only the shortest and closest digits" {
    const gpa = testing.allocator;

    try testing.expect(try format_check(f64, gpa, "0.1", 0.1));
    try testing.expect(!try format_check(f64, gpa, "0.10000000000000001", 0.1));
    try testing.expect(!try format_check(f64, gpa, "0.1000000000000000055511", 0.1));
    try testing.expect(try format_check(f64, gpa, "5e-324", 5e-324));
    try testing.expect(!try format_check(f64, gpa, "4.9e-324", 5e-324));
    try testing.expect(try format_check(f64, gpa, "1e+23", 1e23));
    try testing.expect(try format_check(f64, gpa, "9007199254740992", 9007199254740992));
    try testing.expect(try format_check(f64, gpa, "-0", -0.0));

    const largest = std.math.floatMax(f64);

    try testing.expect(try format_check(f64, gpa, "1.7976931348623157e308", largest));
    try testing.expect(!try format_check(f64, gpa, "1.7976931348623158e308", largest));
    try testing.expect(try format_check(f32, gpa, "0.1", 0.1));
    try testing.expect(!try format_check(f32, gpa, "0.100000001", 0.1));
    try testing.expect(!try format_check(f64, gpa, "0.2", 0.1));
}

test "the integer oracle reads the exact value or reports that it does not fit" {
    const gpa = testing.allocator;

    try testing.expect(try integer_check(i64, gpa, "-9223372036854775808", std.math.minInt(i64)));
    try testing.expect(try integer_check(i64, gpa, "9223372036854775808", null));
    try testing.expect(try integer_check(u64, gpa, "18446744073709551615", std.math.maxInt(u64)));
    try testing.expect(try integer_check(u64, gpa, "18446744073709551616", null));
    try testing.expect(try integer_check(u64, gpa, "-1", null));
    try testing.expect(try integer_check(u64, gpa, "-0", 0));
    try testing.expect(!try integer_check(i64, gpa, "7", 8));
}
