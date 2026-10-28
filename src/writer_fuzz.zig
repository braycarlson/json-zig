const std = @import("std");

const string = @import("string.zig");
const tokenizer_module = @import("tokenizer.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Prng = std.Random.DefaultPrng;
const Token = tokenizer_module.Token;
const Tokenizer = tokenizer_module.Tokenizer;
const Writer = writer_module.Writer;

const codepoint_count_max: u32 = 12;
const depth_generate_max: u32 = 6;
const expected_count_max: u32 = 1024;
const expected_margin: u32 = 16;
const output_bytes_max: u32 = 1024 * 1024;
const part_count_max: u32 = 3;
const raw_bytes_max: u32 = 2048;
const raw_width_max: u32 = 4;
const string_bytes_max: u32 = 4 * codepoint_count_max;
const texts_bytes_max: u32 = 2 * string_bytes_max * expected_count_max;
const width_max: u32 = 6;

comptime {
    assert(depth_generate_max + 2 < tokenizer_module.depth_max);
    assert(expected_margin > raw_width_max + depth_generate_max);
    assert(2 * string_bytes_max <= 256);
}

const Expected = union(enum) {
    array_begin,
    array_end,
    boolean: bool,
    float: u64,
    integer: i64,
    key: []const u8,
    null_value,
    object_begin,
    object_end,
    string: []const u8,
    unsigned: u64,
};

const Frame = struct {
    object: bool,
    remaining: u32,
};

const Comparison = struct {
    escaped: []const u8,
    plain: []const u8,
};

const Cursor = struct {
    depth: u32,
    index: u32,
};

const Role = enum {
    key,
    value,
};

pub const State = struct {
    decoded: [2 * string_bytes_max]u8,
    expected: [expected_count_max]Expected,
    expected_count: u32,
    frames: [depth_generate_max]Frame,
    output: [output_bytes_max]u8,
    raw: [raw_bytes_max]u8,
    text: [string_bytes_max]u8,
    texts: [texts_bytes_max]u8,
    texts_count: u32,
};

pub fn event(state: *State, prng: *Prng, reference: []u8) !void {
    assert(reference.len >= output_bytes_max);
    assert(state.output.len == output_bytes_max);

    const options = options_random(prng);
    var sink: std.Io.Writer = .fixed(&state.output);
    var writer: Writer = .init(&sink, options);

    state.expected_count = 0;
    state.texts_count = 0;

    try document_generate(state, prng, &writer);

    writer.finish();

    const output = sink.buffered();
    var allocator: std.heap.FixedBufferAllocator = .init(reference);

    try policy_check(output, options.utf8);

    if (!try std.json.validate(allocator.allocator(), output)) return error.ReferenceRefused;

    try tokens_compare(state, output);
    try layout_check(output, &options);
}

fn policy_check(output: []const u8, utf8: Writer.UTF8) !void {
    assert(output.len <= output_bytes_max);
    assert(@backingInt(utf8) < std.enums.values(Writer.UTF8).len);

    switch (utf8) {
        .ascii => {
            for (output) |byte| if (byte >= 0x80) return error.PolicyBroken;
        },
        .bmp => {
            for (output) |byte| if (byte >= 0xf0) return error.PolicyBroken;
        },
        .checked => {
            if (!std.unicode.utf8ValidateSlice(output)) return error.PolicyBroken;
        },
        .trusted => {},
    }
}

fn options_random(prng: *Prng) Writer.Options {
    const random = prng.random();

    const result: Writer.Options = .{
        .indent = random.intRangeAtMost(u8, 1, 16),
        .layout = if (random.boolean()) .compact else .pretty,
        .non_finite = if (random.boolean()) .null_value else .refused,
        .notation = if (random.boolean()) .decimal else .ecmascript,
        .utf8 = random.enumValue(Writer.UTF8),
    };

    assert(result.indent >= 1);
    assert(result.indent <= 16);

    return result;
}

fn document_generate(state: *State, prng: *Prng, writer: *Writer) !void {
    assert(state.expected_count == 0);
    assert(writer.depth == 0);

    var depth: u32 = 0;

    try value_generate(state, prng, writer, &depth);

    for (0..2 * expected_count_max) |_| {
        if (depth == 0) break;

        const frame = &state.frames[depth - 1];

        if (state.expected_count + expected_margin > expected_count_max) frame.remaining = 0;

        if (frame.remaining == 0) {
            if (frame.object) try writer.object_end() else try writer.array_end();

            expected_push(state, if (frame.object) .object_end else .array_end);
            depth -= 1;

            continue;
        }

        frame.remaining -= 1;

        if (frame.object) try string_generate(state, prng, writer, .key);

        try value_generate(state, prng, writer, &depth);
    }

    assert(depth == 0);
    assert(writer.done);
}

fn value_generate(state: *State, prng: *Prng, writer: *Writer, depth: *u32) !void {
    assert(depth.* <= depth_generate_max);
    assert(state.expected_count + expected_margin <= expected_count_max);

    const random = prng.random();
    const choice_count: u32 = if (depth.* == depth_generate_max) 7 else 11;
    var choice = random.uintLessThan(u32, choice_count);

    if (depth.* == 0) {
        if (random.uintLessThan(u32, 4) > 0) choice = random.intRangeAtMost(u32, 7, 10);
    }

    switch (choice) {
        0...5 => try scalar_generate(state, prng, writer),
        6 => try raw_generate(state, prng, writer),
        7...10 => {
            const object = random.boolean();

            if (object) try writer.object_begin() else try writer.array_begin();

            expected_push(state, if (object) .object_begin else .array_begin);

            state.frames[depth.*] = .{
                .object = object,
                .remaining = random.uintAtMost(u32, width_max),
            };

            depth.* += 1;
        },
        else => unreachable,
    }
}

fn scalar_generate(state: *State, prng: *Prng, writer: *Writer) !void {
    assert(state.expected_count < expected_count_max);
    assert(!writer.string_open);

    const random = prng.random();

    switch (random.uintLessThan(u32, 6)) {
        0 => {
            const value = random.boolean();

            try writer.boolean(value);
            expected_push(state, .{ .boolean = value });
        },
        1 => {
            try writer.null_value();
            expected_push(state, .null_value);
        },
        2 => {
            const value = random.int(i64) >> random.int(u6);

            try writer.integer(value);
            expected_push(state, .{ .integer = value });
        },
        3 => {
            const value = random.int(u64) >> random.int(u6);

            try writer.unsigned(value);
            expected_push(state, .{ .unsigned = value });
        },
        4 => try float_generate(state, prng, writer),
        5 => try string_generate(state, prng, writer, .value),
        else => unreachable,
    }
}

fn float_generate(state: *State, prng: *Prng, writer: *Writer) !void {
    assert(state.expected_count < expected_count_max);
    assert(!writer.string_open);

    const random = prng.random();
    const specials = [_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), -0.0, 0 };

    const value: f64 = switch (random.uintLessThan(u32, 4)) {
        0 => @bitCast(random.int(u64)),
        1 => @as(f32, @bitCast(random.int(u32))),
        2 => specials[random.uintLessThan(u32, specials.len)],
        3 => @as(f64, @floatFromInt(random.int(i32))) / 64,
        else => unreachable,
    };

    if (std.math.isFinite(value)) {
        try writer.float(value);
        expected_push(state, .{ .float = @bitCast(value) });

        return;
    }

    if (writer.options.non_finite == .refused) {
        try std.testing.expectError(error.FloatNonFinite, writer.float(value));
        try writer.null_value();
    } else {
        try writer.float(value);
    }

    expected_push(state, .null_value);
}

fn string_generate(state: *State, prng: *Prng, writer: *Writer, role: Role) !void {
    assert(state.expected_count < expected_count_max);
    assert(state.texts_count + 2 * string_bytes_max <= texts_bytes_max);

    const text = try text_generate(prng, &state.text, &writer.options);
    const random = prng.random();
    var splits: [part_count_max + 1]u32 = undefined;
    const split_count = if (role == .key) 0 else random.uintAtMost(u32, part_count_max);

    for (splits[0..split_count]) |*split| split.* = random.uintAtMost(u32, @intCast(text.len));

    splits[split_count] = @intCast(text.len);

    std.sort.pdq(u32, splits[0..split_count], {}, std.sort.asc(u32));

    const expected_start = state.texts_count;
    var part_start: u32 = 0;

    for (splits[0 .. split_count + 1]) |split| {
        expected_append(state, text[part_start..split], &writer.options);
        part_start = split;
    }

    const expected = state.texts[expected_start..state.texts_count];

    switch (role) {
        .key => {
            try writer.key(text);
            expected_push(state, .{ .key = expected });
        },
        .value => {
            if (split_count == 0) {
                try writer.string(text);
            } else {
                try parts_write(writer, text, splits[0 .. split_count + 1]);
            }

            expected_push(state, .{ .string = expected });
        },
    }
}

fn parts_write(writer: *Writer, text: []const u8, splits: []const u32) !void {
    assert(splits.len >= 2);
    assert(splits[splits.len - 1] == text.len);

    var part_start: u32 = 0;

    try writer.string_begin();

    for (splits) |split| {
        try writer.string_part(text[part_start..split]);
        part_start = split;
    }

    try writer.string_end();
}

fn text_generate(
    prng: *Prng,
    target: *[string_bytes_max]u8,
    options: *const Writer.Options,
) ![]const u8 {
    assert(target.len == string_bytes_max);
    assert(codepoint_count_max * 4 <= target.len);

    const random = prng.random();
    var length: u32 = 0;

    for (0..random.uintAtMost(u32, codepoint_count_max)) |_| {
        if (options.utf8 != .trusted) {
            if (random.uintLessThan(u32, 6) == 0) {
                target[length] = random.int(u8) | 0x80;
                length += 1;

                continue;
            }
        }

        length += try std.unicode.utf8Encode(codepoint_random(prng), target[length..]);
    }

    if (options.utf8 == .trusted) assert(std.unicode.utf8ValidateSlice(target[0..length]));

    return target[0..length];
}

fn codepoint_random(prng: *Prng) u21 {
    assert(std.unicode.utf8ValidCodepoint(0x10ffff));
    assert(!std.unicode.utf8ValidCodepoint(0xd800));

    const random = prng.random();
    const specials = "\"\\/\x7f\x08\x0c\n\r\t\x00\x1f";

    const result: u21 = switch (random.uintLessThan(u32, 6)) {
        0 => random.intRangeAtMost(u21, 0x20, 0x7e),
        1 => specials[random.uintLessThan(u32, specials.len)],
        2 => random.intRangeAtMost(u21, 0x80, 0x7ff),
        3 => random.intRangeAtMost(u21, 0xe000, 0xffff),
        4 => random.intRangeAtMost(u21, 0x10000, 0x10ffff),
        5 => random.uintLessThan(u21, 0x20),
        else => unreachable,
    };

    assert(std.unicode.utf8ValidCodepoint(result));

    return result;
}

fn raw_generate(state: *State, prng: *Prng, writer: *Writer) !void {
    assert(state.expected_count + raw_width_max + 2 <= expected_count_max);
    assert(!writer.string_open);

    const random = prng.random();
    const malformed = [_][]const u8{ "", " ", "[1,", "1 2", "{\"a\"}", "nul", "[", "]" };

    if (random.uintLessThan(u32, 4) == 0) {
        const text = malformed[random.uintLessThan(u32, malformed.len)];

        try std.testing.expectError(error.RawMalformed, writer.raw(text));
    }

    var nested_sink: std.Io.Writer = .fixed(state.raw[2 .. state.raw.len - 2]);

    var nested: Writer = .init(&nested_sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .null_value,
        .notation = .ecmascript,
        .utf8 = writer.options.utf8,
    });

    const object = random.boolean();

    if (object) try nested.object_begin() else try nested.array_begin();

    expected_push(state, if (object) .object_begin else .array_begin);

    for (0..random.uintAtMost(u32, raw_width_max)) |_| {
        if (object) try string_generate(state, prng, &nested, .key);

        try scalar_generate(state, prng, &nested);
    }

    if (object) try nested.object_end() else try nested.array_end();

    expected_push(state, if (object) .object_end else .array_end);
    nested.finish();

    const length: u32 = @intCast(nested_sink.buffered().len);

    state.raw[0..2].* = " \n".*;

    state.raw[2 + length ..][0..2].* = "\t ".*;

    try writer.raw(state.raw[0 .. length + 4]);
}

fn expected_append(state: *State, part: []const u8, options: *const Writer.Options) void {
    assert(part.len <= string_bytes_max);
    assert(state.texts_count + 2 * part.len <= texts_bytes_max);

    const target = state.texts[state.texts_count..];

    const appended = switch (options.utf8) {
        .ascii, .bmp, .checked => string.checked_transform(part, target[0 .. 2 * part.len]),
        .trusted => blk: {
            @memcpy(target[0..part.len], part);

            break :blk target[0..part.len];
        },
    };

    state.texts_count += @intCast(appended.len);
}

fn expected_push(state: *State, expected: Expected) void {
    assert(state.expected_count < expected_count_max);
    assert(state.expected.len == expected_count_max);

    state.expected[state.expected_count] = expected;
    state.expected_count += 1;
}

fn tokens_compare(state: *State, output: []const u8) !void {
    assert(output.len <= output_bytes_max);
    assert(state.expected_count <= expected_count_max);

    var tokenizer: Tokenizer = .init(output);

    for (state.expected[0..state.expected_count]) |*expected| {
        const token = try tokenizer.next();

        if (!try token_matches(state, expected, token)) {
            std.debug.print("writer disagreement: expected {any}, found {any}\n{s}\n", .{
                expected.*,
                token,
                output,
            });

            return error.ModelDisagreement;
        }
    }

    const last = try tokenizer.next();
    if (last != .end) return error.ModelDisagreement;
}

fn token_matches(state: *State, expected: *const Expected, token: Token) !bool {
    assert(token != .end);
    assert(state.decoded.len == 2 * string_bytes_max);

    return switch (expected.*) {
        .array_begin => token == .array_begin,
        .array_end => token == .array_end,
        .boolean => |value| if (token == .boolean) token.boolean == value else false,
        .float, .integer, .unsigned => number_matches(expected, token),
        .key => |text| if (token == .key) decoded_equal(state, .{
            .escaped = token.key,
            .plain = text,
        }) else false,
        .null_value => token == .null_value,
        .object_begin => token == .object_begin,
        .object_end => token == .object_end,
        .string => |text| if (token == .string) decoded_equal(state, .{
            .escaped = token.string,
            .plain = text,
        }) else false,
    };
}

fn number_matches(expected: *const Expected, token: Token) !bool {
    assert(token != .end);
    assert(token != .key);

    const text = switch (token) {
        .number => |text| text,
        else => return false,
    };

    return switch (expected.*) {
        .float => |bits| @as(u64, @bitCast(try std.fmt.parseFloat(f64, text))) == bits,
        .integer => |value| try std.fmt.parseInt(i64, text, 10) == value,
        .unsigned => |value| try std.fmt.parseInt(u64, text, 10) == value,
        .array_begin, .array_end, .boolean, .key, .null_value => unreachable,
        .object_begin, .object_end, .string => unreachable,
    };
}

fn decoded_equal(state: *State, comparison: Comparison) !bool {
    assert(comparison.plain.len <= state.decoded.len);
    assert(comparison.escaped.len <= 12 * string_bytes_max);

    const decoded = try string.unescape(comparison.escaped, &state.decoded);
    return std.mem.eql(u8, decoded, comparison.plain);
}

fn layout_check(output: []const u8, options: *const Writer.Options) !void {
    assert(output.len <= output_bytes_max);
    assert(options.indent >= 1);

    var depth: u32 = 0;
    var escaped = false;
    var quoted = false;

    for (output, 0..) |byte, index| {
        if (quoted) {
            quoted = escaped or byte != '"';
            escaped = !escaped and byte == '\\';

            continue;
        }

        switch (byte) {
            '"' => quoted = true,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            ' ', '\n', '\t', '\r' => {
                const cursor: Cursor = .{ .depth = depth, .index = @intCast(index) };

                try whitespace_check(output, cursor, options);
            },
            else => {},
        }
    }

    assert(depth == 0);
    assert(!quoted);
}

fn whitespace_check(output: []const u8, cursor: Cursor, options: *const Writer.Options) !void {
    assert(cursor.index < output.len);
    assert(cursor.depth <= tokenizer_module.depth_max);

    if (options.layout == .compact) return error.CompactWhitespace;

    if (output[cursor.index] == ' ') {
        const before = output[cursor.index - 1];
        if (before == ':') return;
        if (before == ' ') return;
        if (before == '\n') return;
        return error.PrettySpacing;
    }

    if (output[cursor.index] != '\n') return error.PrettySpacing;

    const rest = output[cursor.index + 1 ..];
    const spaces = std.mem.findNone(u8, rest, " ") orelse return error.PrettyIndentation;
    const closing = std.mem.findScalar(u8, "]}", rest[spaces]) != null;
    const level = if (closing) cursor.depth - 1 else cursor.depth;
    if (spaces != options.indent * level) return error.PrettyIndentation;
}
