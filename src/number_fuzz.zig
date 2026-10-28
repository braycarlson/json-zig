const std = @import("std");

const codec = @import("codec.zig");
const number = @import("number.zig");
const oracle = @import("number_oracle.zig");
const region_module = @import("region.zig");

const assert = std.debug.assert;

const Managed = std.math.big.int.Managed;
const Prng = std.Random.DefaultPrng;
const Region = region_module.Region;

pub const Counter = enum {
    format_bottom,
    format_subnormal,
    overflow,
    subnormal,
    tie,
    tie_narrow,
    underflow,
};

const Kind = enum {
    decimal,
    format,
    format_narrow,
    midpoint,
    midpoint_narrow,
};

const Source = enum {
    decode,
    float_of_text,
};

const Shape = enum {
    any,
    bottom,
    subnormal,
};

const campaign_events_min: u32 = 4096;
const decimal_digit_count_max: u32 = 40;
const exponent_random_max: i32 = 360;
const region_buffer_bytes: u32 = 64;
const scratch_bytes: u32 = 64 * 1024;
const text_bytes_max: u32 = 2048;

comptime {
    assert(text_bytes_max < oracle.digit_count_max);
    assert(decimal_digit_count_max < text_bytes_max);
}

pub const State = struct {
    counts: std.EnumArray(Counter, u32),
    region_buffer: [region_buffer_bytes]u8,
    scratch: [scratch_bytes]u8,
    scratch_used_max: u32,
    text: [text_bytes_max]u8,
};

pub fn event(state: *State, prng: *Prng) !void {
    assert(state.scratch.len == scratch_bytes);
    assert(state.scratch_used_max <= scratch_bytes);

    const kind = prng.random().enumValue(Kind);

    switch (kind) {
        .decimal => try decimal_event(state, prng),
        .format => try format_event(f64, state, prng),
        .format_narrow => try format_event(f32, state, prng),
        .midpoint => try midpoint_event(f64, state, prng),
        .midpoint_narrow => try midpoint_event(f32, state, prng),
    }
}

pub fn counts_reset(state: *State) void {
    assert(@typeInfo(Counter).@"enum".field_names.len > 0);
    assert(state.scratch.len == scratch_bytes);

    state.counts = .initFill(0);
    state.scratch_used_max = 0;
}

pub fn summary_check(state: *const State, events_max: u32) !void {
    assert(events_max > 0);
    assert(state.scratch_used_max <= scratch_bytes);

    for (std.enums.values(Counter)) |counter| {
        std.debug.print("fuzz number: {t}={d}\n", .{ counter, state.counts.get(counter) });
    }

    std.debug.print("fuzz number: scratch_used_max={d}\n", .{state.scratch_used_max});

    if (events_max < campaign_events_min) return;

    for (std.enums.values(Counter)) |counter| {
        if (state.counts.get(counter) == 0) return error.CounterUnreached;
    }
}

fn decimal_event(state: *State, prng: *Prng) !void {
    assert(state.text.len == text_bytes_max);
    assert(decimal_digit_count_max > 1);

    const random = prng.random();
    const count = random.intRangeAtMost(u32, 1, decimal_digit_count_max);
    var digits: [decimal_digit_count_max]u8 = undefined;

    for (digits[0..count], 0..) |*digit, index| {
        const low: u8 = if (index == 0) '1' else '0';

        digit.* = random.intRangeAtMost(u8, low, '9');
    }

    const exponent = random.intRangeAtMost(i32, -exponent_random_max, exponent_random_max);
    const text = try text_build(state, prng, digits[0..count], exponent);

    try parse_check(f64, state, text);
    try parse_check(f32, state, text);
}

fn midpoint_event(comptime T: type, state: *State, prng: *Prng) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(state.text.len == text_bytes_max);

    const random = prng.random();
    const shape: Shape = if (random.uintLessThan(u32, 8) == 0) .subnormal else .any;
    const magnitude = magnitude_random(T, prng, shape);
    const delta = random.intRangeAtMost(i2, -1, 1);

    var allocator: std.heap.FixedBufferAllocator = .init(&state.scratch);
    const gpa = allocator.allocator();

    var midpoint = try Managed.initSet(gpa, 2 * mantissa_of(T, magnitude) + 1);
    var exponent: i32 = exponent_of(T, magnitude) - 1;

    if (exponent < 0) {
        var power = try Managed.initSet(gpa, 5);

        try power.pow(&power, @intCast(-exponent));
        try midpoint.mul(&midpoint, &power);
    } else {
        try midpoint.shiftLeft(&midpoint, @intCast(exponent));

        exponent = 0;
    }

    if (delta != 0) {
        var ten = try Managed.initSet(gpa, 10);

        try midpoint.mul(&midpoint, &ten);
        try midpoint.addScalar(&midpoint, delta);

        exponent -= 1;
    }

    const digits = try midpoint.toString(gpa, 10, .lower);
    const text = try text_build(state, prng, digits, exponent);

    scratch_record(state, &allocator);

    if (delta == 0) state.counts.getPtr(if (T == f64) .tie else .tie_narrow).* += 1;
    if (magnitude < std.math.floatMin(T)) state.counts.getPtr(.subnormal).* += 1;

    try parse_check(T, state, text);
}

fn format_event(comptime T: type, state: *State, prng: *Prng) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(state.scratch.len == scratch_bytes);

    const shape = prng.random().enumValue(Shape);
    const magnitude = magnitude_random(T, prng, shape);
    const value = if (prng.random().boolean()) -magnitude else magnitude;

    var buffer: [number.float_bytes_max]u8 = undefined;
    var decimal_buffer: [number.float_decimal_bytes_max]u8 = undefined;

    const texts = [_][]const u8{
        number.float_format(T, value, &buffer),
        number.float_decimal_format(T, value, &decimal_buffer),
    };

    for (texts) |text| {
        var allocator: std.heap.FixedBufferAllocator = .init(&state.scratch);

        if (!number.grammar_is(text)) return error.ReferenceDisagreement;
        if (!try oracle.format_check(T, allocator.allocator(), text, value)) {
            std.debug.print("fuzz number: {s} is not the shortest closest form of {e}\n", .{
                text,
                value,
            });

            return error.ReferenceDisagreement;
        }

        scratch_record(state, &allocator);
    }

    if (shape == .bottom) state.counts.getPtr(.format_bottom).* += 1;
    if (magnitude < std.math.floatMin(T)) state.counts.getPtr(.format_subnormal).* += 1;
}

fn parse_check(comptime T: type, state: *State, text: []const u8) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(text.len > 0);

    if (!number.grammar_is(text)) return error.ReferenceDisagreement;

    const negative = text[0] == '-';
    const infinity = std.math.copysign(std.math.inf(T), @as(T, if (negative) -1 else 1));
    var region: Region = .init(&state.region_buffer);
    var decoded: T = undefined;

    codec.decode(T, &region, text, &decoded, .{ .diagnostic = null }) catch |err| switch (err) {
        error.Mismatch => decoded = infinity,
        else => return err,
    };

    try value_check(T, state, text, decoded, .decode);

    if (T == f64) {
        const value = number.float_of_text(text) orelse infinity;

        try value_check(T, state, text, value, .float_of_text);

        if (std.math.isInf(value)) state.counts.getPtr(.overflow).* += 1;
        if (value == 0) state.counts.getPtr(.underflow).* += 1;
    }
}

fn value_check(comptime T: type, state: *State, text: []const u8, value: T, source: Source) !void {
    comptime assert(@typeInfo(T) == .float);
    assert(text.len > 0);
    assert(!std.math.isNan(value));

    var allocator: std.heap.FixedBufferAllocator = .init(&state.scratch);

    if (!try oracle.float_check(T, allocator.allocator(), text, value)) {
        std.debug.print("fuzz number: {t} gave {e} for {s} as {s}\n", .{
            source,
            value,
            text,
            @typeName(T),
        });

        return error.ReferenceDisagreement;
    }

    scratch_record(state, &allocator);
}

fn scratch_record(state: *State, allocator: *const std.heap.FixedBufferAllocator) void {
    assert(allocator.end_index <= scratch_bytes);
    assert(state.scratch_used_max <= scratch_bytes);

    state.scratch_used_max = @max(state.scratch_used_max, @as(u32, @intCast(allocator.end_index)));
}

fn text_build(state: *State, prng: *Prng, digits: []const u8, exponent: i32) ![]const u8 {
    assert(digits.len > 0);
    assert(digits.len < text_bytes_max);
    assert(digits[0] != '0');
    assert(@abs(exponent) < 2 * text_bytes_max);

    const random = prng.random();
    const count: u32 = @intCast(digits.len);
    const point = random.intRangeAtMost(u32, 1, count);
    const shifted = exponent + @as(i32, @intCast(count - point));
    const sign = if (random.boolean()) "-" else "";
    const marker = if (random.boolean()) "e" else "E";
    const fraction = if (point < count) "." else "";
    const plus = if (shifted < 0) "" else if (random.boolean()) "+" else "";

    if (shifted == 0) {
        if (random.boolean()) {
            return std.mem.print(&state.text, "{s}{s}{s}{s}", .{
                sign,
                digits[0..point],
                fraction,
                digits[point..],
            }) catch error.Overflow;
        }
    }

    return std.mem.print(&state.text, "{s}{s}{s}{s}{s}{s}{d}", .{
        sign,
        digits[0..point],
        fraction,
        digits[point..],
        marker,
        plus,
        shifted,
    }) catch error.Overflow;
}

fn magnitude_random(comptime T: type, prng: *Prng, shape: Shape) T {
    comptime assert(@typeInfo(T) == .float);

    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const mantissa_bits = std.math.floatMantissaBits(T);
    const random = prng.random();

    for (0..64) |_| {
        const fraction_mask = (@as(Bits, 1) << mantissa_bits) - 1;

        var bits = random.int(Bits) >> 1;

        switch (shape) {
            .any => {},
            .bottom => bits &= ~fraction_mask,
            .subnormal => bits &= fraction_mask,
        }

        const result: T = @bitCast(bits);

        if (std.math.isFinite(result)) {
            if (result > 0) return result;
        }
    }

    return std.math.floatMin(T);
}

fn mantissa_of(comptime T: type, magnitude: T) u64 {
    assert(std.math.isFinite(magnitude));
    assert(magnitude > 0);

    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const mantissa_bits = std.math.floatMantissaBits(T);
    const bits: Bits = @bitCast(magnitude);
    const fraction: u64 = bits & ((@as(Bits, 1) << mantissa_bits) - 1);
    const hidden: u64 = if (magnitude < std.math.floatMin(T)) 0 else @as(u64, 1) << mantissa_bits;

    return fraction | hidden;
}

fn exponent_of(comptime T: type, magnitude: T) i32 {
    assert(std.math.isFinite(magnitude));
    assert(magnitude > 0);

    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const mantissa_bits = std.math.floatMantissaBits(T);
    const bias: i32 = (1 << (std.math.floatExponentBits(T) - 1)) - 1;
    const bits: Bits = @bitCast(magnitude);
    const field: i32 = @intCast(bits >> mantissa_bits);
    const result = @max(field, 1) - bias - mantissa_bits;

    assert(result >= 1 - bias - mantissa_bits);
    assert(result <= bias - mantissa_bits);

    return result;
}
