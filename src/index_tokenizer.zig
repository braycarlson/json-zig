const std = @import("std");

const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Token = tokenizer_module.Token;

const depth_max = tokenizer_module.depth_max;
const input_bytes_max = tokenizer_module.input_bytes_max;

const expect_value: u8 = 1;
const expect_key: u8 = 2;
const expect_colon: u8 = 4;
const expect_separator: u8 = 8;
const expect_close_array: u8 = 16;
const expect_close_object: u8 = 32;
const after_array: u8 = expect_separator | expect_close_array;
const after_object: u8 = expect_separator | expect_close_object;

comptime {
    assert(1 + (after_array >> 5) == expect_value);
    assert(1 + (after_object >> 5) == expect_key);
    assert(after_array & after_object == expect_separator);
}

pub const IndexTokenizer = struct {
    after_stack: [depth_max]u8,
    after_value: u8,
    cursor: structural.Cursor,
    depth: u32,
    expect: u8,
    index: u32,
    input: []const u8,
    value_start: u32,

    pub const Error = tokenizer_module.Tokenizer.Error;

    pub fn init(
        input: []const u8,
        indexer: *structural.Indexer,
        indices: *structural.Indices,
    ) IndexTokenizer {
        assert(input.len <= input_bytes_max);
        assert(indices.len == structural.index_capacity);

        indexer.* = .empty;

        return .{
            .after_stack = undefined,
            .after_value = 0,
            .cursor = .{
                .count = 0,
                .exhausted = false,
                .failed = false,
                .indexer = indexer,
                .indices = indices,
                .position = 0,
            },
            .depth = 0,
            .expect = expect_value,
            .index = 0,
            .input = input,
            .value_start = 0,
        };
    }

    pub inline fn next(tokenizer: *IndexTokenizer) Error!Token {
        assert(tokenizer.depth <= depth_max);
        assert(tokenizer.input.len <= input_bytes_max);

        for (0..tokenizer.input.len + 1) |_| {
            const input = tokenizer.input;
            const position = tokenizer.cursor.next(input) orelse return tokenizer.end_token();
            if (position >= input.len) return error.Malformed;

            switch (tokenizer.input[position]) {
                ',' => try tokenizer.comma_take(),
                ':' => try tokenizer.colon_take(),
                '{' => return tokenizer.open_token(position, .object_begin),
                '}' => return tokenizer.close_token(position, .object_end),
                '[' => return tokenizer.open_token(position, .array_begin),
                ']' => return tokenizer.close_token(position, .array_end),
                '"' => return tokenizer.string_token(position),
                't' => return tokenizer.literal_token(position, "true", .{ .boolean = true }),
                'f' => return tokenizer.literal_token(position, "false", .{ .boolean = false }),
                'n' => return tokenizer.literal_token(position, "null", .null_value),
                '-' => return tokenizer.number_token(position, true),
                '0'...'9' => return tokenizer.number_token(position, false),
                else => return error.Malformed,
            }
        }

        return error.Malformed;
    }

    pub fn skip(tokenizer: *IndexTokenizer, first: Token) Error!void {
        assert(first != .end);
        assert(tokenizer.depth <= depth_max);

        const depth_target = switch (first) {
            .array_begin, .object_begin => tokenizer.depth - 1,
            .array_end, .end, .key, .object_end => return error.Malformed,
            .boolean, .null_value, .number, .string => return,
        };

        for (0..tokenizer.input.len + 1) |_| {
            const input = tokenizer.input;
            const position = tokenizer.cursor.next(input) orelse return error.Malformed;
            if (position >= input.len) return error.Malformed;

            switch (input[position]) {
                ',' => try tokenizer.comma_take(),
                ':' => try tokenizer.colon_take(),
                '{' => _ = try tokenizer.open_token(position, .object_begin),
                '[' => _ = try tokenizer.open_token(position, .array_begin),
                '}' => _ = try tokenizer.close_token(position, .object_end),
                ']' => _ = try tokenizer.close_token(position, .array_end),
                '"' => _ = try tokenizer.string_token(position),
                't' => _ = try tokenizer.literal_token(position, "true", .{ .boolean = true }),
                'f' => _ = try tokenizer.literal_token(position, "false", .{ .boolean = false }),
                'n' => _ = try tokenizer.literal_token(position, "null", .null_value),
                '-' => _ = try tokenizer.number_token(position, true),
                '0'...'9' => _ = try tokenizer.number_token(position, false),
                else => return error.Malformed,
            }

            if (tokenizer.depth == depth_target) return;
        }

        return error.Malformed;
    }

    fn end_token(tokenizer: *const IndexTokenizer) Error!Token {
        assert(tokenizer.cursor.position == tokenizer.cursor.count);
        assert(tokenizer.depth <= depth_max);

        if (tokenizer.cursor.failed) return error.Malformed;
        if (tokenizer.depth != 0) return error.Malformed;
        if (tokenizer.expect != 0) return error.Malformed;
        return .end;
    }

    inline fn comma_take(tokenizer: *IndexTokenizer) Error!void {
        assert(tokenizer.depth <= depth_max);
        if (tokenizer.expect & expect_separator == 0) return error.Malformed;

        tokenizer.expect = 1 + (tokenizer.after_value >> 5);

        assert(tokenizer.expect == expect_value or tokenizer.expect == expect_key);
    }

    inline fn colon_take(tokenizer: *IndexTokenizer) Error!void {
        assert(tokenizer.depth <= depth_max);
        if (tokenizer.expect & expect_colon == 0) return error.Malformed;

        tokenizer.expect = expect_value;
    }

    inline fn open_token(
        tokenizer: *IndexTokenizer,
        position: u32,
        comptime token: Token,
    ) Error!Token {
        comptime assert(token == .array_begin or token == .object_begin);
        assert(position < tokenizer.input.len);

        if (tokenizer.expect & expect_value == 0) return error.Malformed;
        if (tokenizer.depth == depth_max) return error.DepthExceeded;

        tokenizer.after_stack[tokenizer.depth] = tokenizer.after_value;
        tokenizer.depth += 1;
        tokenizer.index = position + 1;
        tokenizer.value_start = position;

        if (token == .object_begin) {
            tokenizer.after_value = after_object;
            tokenizer.expect = expect_key | expect_close_object;
        } else {
            tokenizer.after_value = after_array;
            tokenizer.expect = expect_value | expect_close_array;
        }

        return token;
    }

    inline fn close_token(
        tokenizer: *IndexTokenizer,
        position: u32,
        comptime token: Token,
    ) Error!Token {
        comptime assert(token == .array_end or token == .object_end);
        assert(position < tokenizer.input.len);

        const bit = if (token == .object_end) expect_close_object else expect_close_array;
        if (tokenizer.expect & bit == 0) return error.Malformed;

        assert(tokenizer.depth > 0);

        tokenizer.depth -= 1;
        tokenizer.index = position + 1;
        tokenizer.after_value = tokenizer.after_stack[tokenizer.depth];
        tokenizer.expect = tokenizer.after_value;

        return token;
    }

    inline fn string_token(tokenizer: *IndexTokenizer, open: u32) Error!Token {
        assert(open < tokenizer.input.len);
        assert(tokenizer.input[open] == '"');

        const entry = tokenizer.cursor.peek_or_end(tokenizer.input);
        const before = entry & structural.index_position_mask;
        const close = structural.string_close_find(tokenizer.input, before);
        if (close <= open) return error.Malformed;

        const raw = tokenizer.input[open + 1 .. close];

        if (entry & structural.index_escaped != 0) {
            tokenizer.cursor.flag_clear();

            if (!escapes_valid(raw)) return error.Malformed;
        }

        tokenizer.index = close + 1;

        if (tokenizer.expect & expect_key != 0) {
            tokenizer.expect = expect_colon;

            return .{ .key = raw };
        }

        if (tokenizer.expect & expect_value == 0) return error.Malformed;

        tokenizer.expect = tokenizer.after_value;
        tokenizer.value_start = open;

        return .{ .string = raw };
    }

    inline fn literal_token(
        tokenizer: *IndexTokenizer,
        position: u32,
        comptime text: []const u8,
        comptime token: Token,
    ) Error!Token {
        comptime assert(text.len == 4 or text.len == 5);
        comptime assert(token == .null_value or token == .boolean);
        assert(position < tokenizer.input.len);

        if (tokenizer.expect & expect_value == 0) return error.Malformed;

        const rest = tokenizer.input[position..];
        if (rest.len < text.len) return error.Malformed;

        const word = std.mem.readInt(u32, rest[0..4], .little);
        if (word != comptime std.mem.readInt(u32, text[0..4], .little)) return error.Malformed;
        if (text.len == 5) if (rest[4] != text[4]) return error.Malformed;

        const end = position + @as(u32, text.len);
        if (!tokenizer_module.scalar_ended(tokenizer.input, end)) return error.Malformed;

        tokenizer.expect = tokenizer.after_value;
        tokenizer.index = end;
        tokenizer.value_start = position;

        return token;
    }

    inline fn number_token(
        tokenizer: *IndexTokenizer,
        position: u32,
        comptime negative: bool,
    ) Error!Token {
        assert(position < tokenizer.input.len);
        if (negative) assert(tokenizer.input[position] == '-');

        if (tokenizer.expect & expect_value == 0) return error.Malformed;

        const end = try tokenizer_module.number_end(tokenizer.input, position, negative);
        if (!tokenizer_module.scalar_ended(tokenizer.input, end)) return error.Malformed;

        tokenizer.expect = tokenizer.after_value;
        tokenizer.index = end;
        tokenizer.value_start = position;

        return .{ .number = tokenizer.input[position..end] };
    }
};

fn escapes_valid(raw: []const u8) bool {
    assert(raw.len <= input_bytes_max);
    assert(raw.len > 0);

    var index: u32 = 0;

    for (0..raw.len) |_| {
        const found = std.mem.findScalarPos(u8, raw, index, '\\') orelse return true;
        const length = tokenizer_module.escape_length(raw[found..]) catch return false;

        index = @intCast(found + length);

        if (index >= raw.len) return true;
    }

    return true;
}

const testing = std.testing;

fn test_streams_agree(input: []const u8) !void {
    assert(input.len <= 4096);

    errdefer std.debug.print("disagreement on {s}\n", .{input});

    var indexer: structural.Indexer = .empty;
    var indices: structural.Indices = undefined;
    var fast = IndexTokenizer.init(input, &indexer, &indices);
    var exact = tokenizer_module.Tokenizer.init(input);

    for (0..input.len + 2) |_| {
        const expected = exact.next() catch return test_errors_too(&fast);
        const actual = fast.next() catch return test_errors_too(&exact);

        try testing.expectEqualDeep(expected, actual);

        if (expected == .end) return;
    }

    return error.StreamUnfinished;
}

fn test_errors_too(tokenizer: anytype) !void {
    assert(tokenizer.input.len <= 4096);

    for (0..tokenizer.input.len + 2) |_| {
        const token = tokenizer.next() catch return;
        if (token == .end) return error.ErrorMissing;
    }

    return error.StreamUnfinished;
}

test "the index tokenizer yields the exact tokenizer's stream" {
    const long: [200]u8 = @splat('s');

    const inputs = [_][]const u8{
        "{}",
        "[]",
        "[1, -2.5e3, true, false, null, \"a\", {\"k\": [[], {}]}]",
        "{\"a\\u0041b\": \"x\\ny\", \"c\": \"\\\"\"}",
        "  \"lone\"  ",
        "[\"" ++ long ++ "\", 1]",
        "{\"a\": 1, \"b\": [1, 2, {\"c\": null}], \"d\": \"e\"}",
        "[1 2]",
        "{\"a\" 1}",
        "[tru]",
        "[\"a\\q\"]",
        "[\"a",
        "",
        "{\"a\": [1, 2}",
        "[01]",
    };

    for (inputs) |input| try test_streams_agree(input);
}
