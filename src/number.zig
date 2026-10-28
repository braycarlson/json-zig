const std = @import("std");

const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Form = struct {
    digits: []const u8,
    exponent: i32,
    sign: bool,
};

const exponent_magnitude_max: u32 = 324;
pub const float_bytes_max: u32 = 32;
pub const float_decimal_bytes_max: u32 = 352;
pub const float_unsigned_bytes_max: u32 = significand_digits_max + 7;
pub const integer_bytes_max: u32 = 20;
const point_digits_max: i32 = 21;
const point_zeros_max: i32 = 6;
const significand_digits_max: u32 = 17;
const spellings = [_][]const u8{ "inf", "infinity", "nan" };

comptime {
    assert(integer_bytes_max == std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 1);
    assert(float_bytes_max > float_unsigned_bytes_max);
    assert(float_decimal_bytes_max > 2 + exponent_magnitude_max + significand_digits_max);
    assert(@as(u32, point_digits_max) + 1 <= float_unsigned_bytes_max);
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

    const result = std.fmt.parseInt(i64, text, 10) catch return null;

    if (result < 0) assert(text[0] == '-');

    return result;
}

pub fn unsigned_of_text(text: []const u8) ?u64 {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const result = std.fmt.parseInt(u64, text, 10) catch return null;

    if (text[0] == '-') assert(result == 0);

    return result;
}

pub fn float_of_text(text: []const u8) ?f64 {
    assert(text.len > 0);
    assert(text.len < std.math.maxInt(u32));

    const result = std.fmt.parseFloat(f64, text) catch |err| switch (err) {
        error.InvalidCharacter => unreachable,
    };

    if (non_finite_is(text)) return result;
    if (!std.math.isFinite(result)) return null;

    assert(!std.math.isNan(result));

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

fn test_float_expect(comptime T: type, value: T, expected: []const u8) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(expected.len > 0);

    var buffer: [float_bytes_max]u8 = undefined;

    try testing.expectEqualStrings(expected, float_format(T, value, &buffer));
}

fn test_number_reference(text: []const u8) bool {
    assert(text.len > 0);
    assert(std.mem.findAny(u8, text, " \t\n\r") == null);

    var tokenizer: tokenizer_module.Tokenizer = .init(text);
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
