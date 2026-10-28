const std = @import("std");

const number = @import("number.zig");
const string_module = @import("string.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Tokenizer = tokenizer_module.Tokenizer;

const depth_max = tokenizer_module.depth_max;
const indent_max: u8 = 16;
const input_bytes_max = tokenizer_module.input_bytes_max;
const member_bytes_max: u32 = tokenizer_module.lane_count;
const outer_near_count: u32 = 64;

comptime {
    assert(depth_max <= std.math.maxInt(u8));
    assert(depth_max <= 2 * outer_near_count);
    assert(indent_max >= 1);
    assert(@sizeOf(Writer) <= 40);
    assert(@sizeOf(Writer.Options) <= 2);
}

pub const Writer = struct {
    depth: u32,
    done: bool,
    frame: Frame,
    options: Options,
    outer_far: u64,
    outer_near: u64,
    sink: *std.Io.Writer,
    string_open: bool,

    pub const CapacityError = error{DepthExceeded};
    pub const Error = CapacityError || ValueError || std.Io.Writer.Error;

    pub const Layout = enum(u1) {
        compact,
        pretty,
    };

    pub const NonFinite = enum(u2) {
        literal,
        null_value,
        refused,
    };

    pub const Notation = enum(u1) {
        decimal,
        ecmascript,
    };

    pub const Options = packed struct {
        indent: u8 = 4,
        layout: Layout = .compact,
        non_finite: NonFinite = .refused,
        notation: Notation = .ecmascript,
        utf8: UTF8 = .trusted,
    };

    pub const UTF8 = string_module.UTF8;

    pub const ValueError = error{
        EnumerationUnrecognized,
        FloatNonFinite,
        RawMalformed,
    };

    const container_open = if (structural.functions_aligned)
        container_open_aligned
    else
        container_open_unaligned;

    const container_close = if (structural.functions_aligned)
        container_close_aligned
    else
        container_close_unaligned;

    const scalar_write = if (structural.functions_aligned)
        scalar_write_aligned
    else
        scalar_write_unaligned;

    pub fn init(sink: *std.Io.Writer, options: Options) Writer {
        assert(options.indent >= 1);
        assert(options.indent <= indent_max);

        return .{
            .depth = 0,
            .done = false,
            .frame = .array_items,
            .options = options,
            .outer_far = 0,
            .outer_near = 0,
            .sink = sink,
            .string_open = false,
        };
    }

    pub fn finish(writer: *const Writer) void {
        assert(writer.depth == 0);
        assert(writer.done);
        assert(!writer.string_open);
    }

    pub fn array_begin(writer: *Writer) (CapacityError || std.Io.Writer.Error)!void {
        assert(!writer.string_open);
        assert(writer.depth <= depth_max);

        try writer.container_open(.array_empty);
    }

    pub fn array_end(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth > 0);

        const frame = writer.frame;

        assert(frame == .array_empty or frame == .array_items);

        try writer.container_close(']');
    }

    pub fn object_begin(writer: *Writer) (CapacityError || std.Io.Writer.Error)!void {
        assert(!writer.string_open);
        assert(writer.depth <= depth_max);

        try writer.container_open(.object_empty);
    }

    pub fn object_end(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth > 0);

        const frame = writer.frame;

        assert(frame == .object_empty or frame == .object_members);

        try writer.container_close('}');
    }

    pub fn key(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(text.len <= input_bytes_max);

        try writer.key_open();
        try writer.sink.writeByte('"');
        try string_module.escape_write(writer.sink, text, writer.options.utf8);
        try writer.sink.writeByte('"');
        try writer.key_close();
    }

    pub fn string(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(text.len <= input_bytes_max);

        try writer.value_open();
        try writer.sink.writeByte('"');
        try string_module.escape_write(writer.sink, text, writer.options.utf8);
        try writer.sink.writeByte('"');

        writer.value_close();
    }

    pub fn string_begin(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth <= depth_max);

        try writer.value_open();
        try writer.sink.writeByte('"');

        writer.string_open = true;
    }

    pub fn string_part(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
        assert(writer.string_open);
        assert(text.len <= input_bytes_max);

        try string_module.escape_write(writer.sink, text, writer.options.utf8);
    }

    pub fn string_end(writer: *Writer) std.Io.Writer.Error!void {
        assert(writer.string_open);
        assert(!writer.done);

        try writer.sink.writeByte('"');

        writer.string_open = false;

        writer.value_close();
    }

    pub fn integer(writer: *Writer, value: i64) std.Io.Writer.Error!void {
        var buffer: [number.integer_bytes_max + 1]u8 = undefined;

        assert(!writer.string_open);
        assert(std.math.log10_int(@abs(value) | 1) + 2 <= buffer.len);

        const digits = number.integer_format(@abs(value), buffer[1..]);
        const start = buffer.len - digits.len - @intFromBool(value < 0);

        if (value < 0) buffer[start] = '-';

        try writer.scalar_write(buffer[start..]);
    }

    pub fn unsigned(writer: *Writer, value: u64) std.Io.Writer.Error!void {
        var buffer: [number.integer_bytes_max]u8 = undefined;

        assert(!writer.string_open);
        assert(std.math.log10_int(value | 1) + 1 <= buffer.len);

        try writer.scalar_write(number.integer_format(value, &buffer));
    }

    pub fn float(writer: *Writer, value: f64) (error{FloatNonFinite} || std.Io.Writer.Error)!void {
        assert(!writer.string_open);

        assert(
            @intFromBool(std.math.signbit(value)) + number.float_unsigned_bytes_max <
                number.float_bytes_max,
        );

        if (!std.math.isFinite(value)) {
            switch (writer.options.non_finite) {
                .literal => return non_finite_literal_write(writer, value),
                .null_value => return writer.null_value(),
                .refused => return error.FloatNonFinite,
            }
        }

        try float_finite_write(writer, f64, value);
    }

    pub fn boolean(writer: *Writer, value: bool) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth <= depth_max);

        try writer.scalar_write(if (value) "true" else "false");
    }

    pub fn null_value(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth <= depth_max);

        try writer.scalar_write("null");
    }

    pub fn raw(
        writer: *Writer,
        text: []const u8,
    ) (error{ DepthExceeded, RawMalformed } || std.Io.Writer.Error)!void {
        assert(!writer.string_open);
        assert(text.len <= input_bytes_max);

        const span = try raw_span(text);
        if (writer.depth + span.depth > depth_max) return error.DepthExceeded;

        try writer.scalar_write(text[span.start..span.end]);
    }

    fn key_open(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth > 0);

        switch (writer.frame) {
            .object_empty => {},
            .object_members => try writer.sink.writeByte(','),
            .array_empty, .array_items, .object_value => unreachable,
        }

        try writer.newline_write(writer.depth);
    }

    inline fn key_close(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(writer.depth > 0);

        const frame = &writer.frame;

        assert(frame.* == .object_empty or frame.* == .object_members);

        switch (writer.options.layout) {
            .compact => try writer.sink.writeByte(':'),
            .pretty => try writer.sink.writeAll(": "),
        }

        frame.* = .object_value;
    }

    fn container_open_aligned(
        writer: *Writer,
        frame: Frame,
    ) align(64) (CapacityError || std.Io.Writer.Error)!void {
        assert(frame == .array_empty or frame == .object_empty);
        assert(writer.depth <= depth_max);

        return container_open_body(writer, frame);
    }

    fn container_open_unaligned(
        writer: *Writer,
        frame: Frame,
    ) (CapacityError || std.Io.Writer.Error)!void {
        assert(frame == .array_empty or frame == .object_empty);
        assert(writer.depth <= depth_max);

        return container_open_body(writer, frame);
    }

    inline fn container_open_body(
        writer: *Writer,
        frame: Frame,
    ) (CapacityError || std.Io.Writer.Error)!void {
        assert(frame == .array_empty or frame == .object_empty);
        assert(writer.depth <= depth_max);

        if (writer.depth == depth_max) return error.DepthExceeded;

        try writer.value_open();
        try writer.sink.writeByte(if (frame == .array_empty) '[' else '{');

        const outer: u1 = @truncate(@backingInt(writer.frame));

        if (writer.depth >= outer_near_count) {
            const carry = writer.outer_near >> outer_near_count - 1;
            writer.outer_far = (writer.outer_far << 1) | carry;
        }

        writer.outer_near = (writer.outer_near << 1) | outer;
        writer.frame = frame;
        writer.depth += 1;
    }

    fn container_close_aligned(writer: *Writer, closer: u8) align(64) std.Io.Writer.Error!void {
        assert(closer == ']' or closer == '}');
        assert(writer.depth > 0);

        return container_close_body(writer, closer);
    }

    fn container_close_unaligned(writer: *Writer, closer: u8) std.Io.Writer.Error!void {
        assert(closer == ']' or closer == '}');
        assert(writer.depth > 0);

        return container_close_body(writer, closer);
    }

    inline fn container_close_body(writer: *Writer, closer: u8) std.Io.Writer.Error!void {
        assert(closer == ']' or closer == '}');
        assert(writer.depth > 0);

        switch (writer.frame) {
            .array_empty, .object_empty => {},
            .array_items, .object_members => try writer.newline_write(writer.depth - 1),
            .object_value => unreachable,
        }

        try writer.sink.writeByte(closer);

        const outer: u1 = @truncate(writer.outer_near);
        writer.outer_near >>= 1;

        if (writer.depth > outer_near_count) {
            writer.outer_near |= (writer.outer_far & 1) << outer_near_count - 1;
            writer.outer_far >>= 1;
        }

        writer.depth -= 1;
        writer.frame = @fromBackingInt(outer);

        writer.value_close();
    }

    inline fn value_open(writer: *Writer) std.Io.Writer.Error!void {
        assert(!writer.string_open);
        assert(!writer.done);

        if (writer.depth == 0) return;

        const frame = &writer.frame;

        switch (frame.*) {
            .array_empty => {
                frame.* = .array_items;

                try writer.newline_write(writer.depth);
            },
            .array_items => {
                try writer.sink.writeByte(',');
                try writer.newline_write(writer.depth);
            },
            .object_value => frame.* = .object_members,
            .object_empty, .object_members => unreachable,
        }
    }

    fn value_close(writer: *Writer) void {
        assert(!writer.string_open);
        assert(!writer.done);

        if (writer.depth == 0) writer.done = true;
    }

    inline fn newline_write(writer: *Writer, level: u32) std.Io.Writer.Error!void {
        assert(level <= depth_max);
        assert(writer.options.indent <= indent_max);

        if (writer.options.layout == .compact) return;

        try writer.indent_write(level);
    }

    noinline fn indent_write(writer: *Writer, level: u32) std.Io.Writer.Error!void {
        assert(level <= depth_max);
        assert(writer.options.layout == .pretty);

        try writer.sink.writeByte('\n');
        try writer.sink.splatByteAll(' ', writer.options.indent * level);
    }

    fn scalar_write_aligned(writer: *Writer, text: []const u8) align(64) std.Io.Writer.Error!void {
        assert(text.len > 0);
        assert(text.len <= input_bytes_max);

        return scalar_write_body(writer, text);
    }

    fn scalar_write_unaligned(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len > 0);
        assert(text.len <= input_bytes_max);

        return scalar_write_body(writer, text);
    }

    inline fn scalar_write_body(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
        assert(text.len > 0);
        assert(text.len <= input_bytes_max);

        try writer.value_open();
        try writer.sink.writeAll(text);

        writer.value_close();
    }
};

const Frame = enum(u8) {
    array_empty = 2,
    array_items = 0,
    object_empty = 3,
    object_members = 1,
    object_value = 4,
};

pub const KeyMember = struct {
    bytes: [member_bytes_max + 1]u8,
    length: u8,

    pub const length_max = member_bytes_max;

    pub fn of(comptime quoted: []const u8) KeyMember {
        comptime assert(quoted.len >= 2);
        comptime assert(quoted.len + 2 <= member_bytes_max);

        const text = "," ++ quoted ++ ":";
        var result: KeyMember = .{ .bytes = @splat(0), .length = text.len };
        result.bytes[0..text.len].* = text.*;

        return result;
    }
};

const Span = struct {
    depth: u32,
    end: u32,
    start: u32,
};

pub const key_member_write = if (structural.functions_aligned)
    key_member_write_aligned
else
    key_member_write_unaligned;

fn key_member_write_aligned(
    writer: *Writer,
    member: *const KeyMember,
) align(64) std.Io.Writer.Error!void {
    assert(member.length >= 4);
    assert(member.length <= member_bytes_max);

    return key_member_write_body(writer, member);
}

fn key_member_write_unaligned(
    writer: *Writer,
    member: *const KeyMember,
) std.Io.Writer.Error!void {
    assert(member.length >= 4);
    assert(member.length <= member_bytes_max);

    return key_member_write_body(writer, member);
}

inline fn key_member_write_body(
    writer: *Writer,
    member: *const KeyMember,
) std.Io.Writer.Error!void {
    assert(member.length >= 4);
    assert(member.length <= member_bytes_max);

    const sink = writer.sink;
    const quoted = member.bytes[1 .. member.length - 1];
    if (writer.options.layout == .pretty) return key_escaped_write(writer, quoted, true);
    if (sink.unusedCapacityLen() < member_bytes_max) return key_escaped_write(writer, quoted, true);

    assert(!writer.string_open);
    assert(writer.depth > 0);

    const frame = &writer.frame;

    const skipped: u8 = switch (frame.*) {
        .object_empty => 1,
        .object_members => 0,
        .array_empty, .array_items, .object_value => unreachable,
    };

    sink.buffer[sink.end..][0..member_bytes_max].* = member.bytes[skipped..][0..member_bytes_max].*;

    sink.advance(member.length - skipped);
    frame.* = .object_value;
}

pub fn key_escaped_write(
    writer: *Writer,
    quoted: []const u8,
    comptime verbatim: bool,
) std.Io.Writer.Error!void {
    assert(quoted.len >= 2);
    assert(quoted[0] == '"');
    assert(quoted[quoted.len - 1] == '"');

    try writer.key_open();

    if (verbatim) {
        try writer.sink.writeAll(quoted);
    } else {
        try string_module.escaped_write(writer.sink, quoted, writer.options.utf8);
    }

    try writer.key_close();
}

pub fn float_finite_write(
    writer: *Writer,
    comptime T: type,
    value: T,
) std.Io.Writer.Error!void {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));

    switch (writer.options.notation) {
        .decimal => try float_decimal_write(writer, T, value),
        .ecmascript => {
            var buffer: [number.float_bytes_max]u8 = undefined;

            assert(number.float_unsigned_bytes_max < buffer.len);

            try writer.scalar_write(number.float_format(T, value, &buffer));
        },
    }
}

noinline fn float_decimal_write(
    writer: *Writer,
    comptime T: type,
    value: T,
) std.Io.Writer.Error!void {
    comptime assert(@typeInfo(T) == .float);
    assert(std.math.isFinite(value));

    var buffer: [number.float_decimal_bytes_max]u8 = undefined;

    try writer.scalar_write(number.float_decimal_format(T, value, &buffer));
}

pub fn number_text_write(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
    assert(text.len > 0);
    assert(text[0] == '-' or std.ascii.isAlphanumeric(text[0]));

    if (number.non_finite_is(text)) return non_finite_text_write(writer, text);

    try writer.scalar_write(text);
}

noinline fn non_finite_literal_write(writer: *Writer, value: f64) std.Io.Writer.Error!void {
    assert(!std.math.isFinite(value));
    assert(writer.options.non_finite == .literal);

    try writer.scalar_write(number.spelling_of(value));
}

noinline fn non_finite_text_write(writer: *Writer, text: []const u8) std.Io.Writer.Error!void {
    assert(text.len >= 3);
    assert(number.non_finite_is(text));

    switch (writer.options.non_finite) {
        .literal => try writer.scalar_write(number.spelling_of_text(text)),
        .null_value, .refused => try writer.null_value(),
    }
}

pub fn string_escaped_write(
    writer: *Writer,
    quoted: []const u8,
    comptime verbatim: bool,
) std.Io.Writer.Error!void {
    assert(quoted.len >= 2);
    assert(quoted[0] == '"');
    assert(quoted[quoted.len - 1] == '"');

    if (verbatim) return writer.scalar_write(quoted);

    try writer.value_open();
    try string_module.escaped_write(writer.sink, quoted, writer.options.utf8);

    writer.value_close();
}

fn raw_span(text: []const u8) error{ DepthExceeded, RawMalformed }!Span {
    assert(text.len <= input_bytes_max);

    var tokenizer: Tokenizer = .init(text);
    var span: Span = .{ .depth = 0, .end = 0, .start = 0 };

    for (0..text.len + 2) |position| {
        const token = tokenizer.next() catch |err| return switch (err) {
            error.DepthExceeded => error.DepthExceeded,
            error.Malformed => error.RawMalformed,
        };

        if (token == .end) break;

        if (position == 0) span.start = tokenizer.value_start;

        span.depth = @max(span.depth, tokenizer.depth);
        span.end = tokenizer.index;
    }

    assert(span.start < span.end);
    assert(span.depth <= depth_max);

    return span;
}

const testing = std.testing;

const test_options_compact: Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

fn test_document_write(writer: *Writer) !void {
    assert(writer.depth == 0);
    assert(!writer.done);

    try writer.object_begin();
    try writer.key("name");
    try writer.string("json");
    try writer.key("empty_array");
    try writer.array_begin();
    try writer.array_end();
    try writer.key("empty_object");
    try writer.object_begin();
    try writer.object_end();
    try writer.key("items");
    try writer.array_begin();
    try writer.integer(-7);
    try writer.unsigned(std.math.maxInt(u64));
    try writer.float(0.25);
    try writer.array_begin();
    try writer.boolean(true);
    try writer.null_value();
    try writer.array_end();
    try writer.object_begin();
    try writer.key("raw");
    try writer.raw(" {\"a\":[1]} ");
    try writer.object_end();
    try writer.array_end();
    try writer.object_end();

    writer.finish();
}

fn test_layout_expect(options: Writer.Options, expected: []const u8) !void {
    assert(options.indent >= 1);
    assert(expected.len > 0);

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, options);

    try test_document_write(&writer);
    try testing.expectEqualStrings(expected, sink.buffered());
}

test "compact and pretty output match serde byte for byte, with empty containers inline" {
    const compact = "{\"name\":\"json\",\"empty_array\":[],\"empty_object\":{},\"items\":" ++
        "[-7,18446744073709551615,0.25,[true,null],{\"raw\":{\"a\":[1]}}]}";

    const pretty_two =
        \\{
        \\  "name": "json",
        \\  "empty_array": [],
        \\  "empty_object": {},
        \\  "items": [
        \\    -7,
        \\    18446744073709551615,
        \\    0.25,
        \\    [
        \\      true,
        \\      null
        \\    ],
        \\    {
        \\      "raw": {"a":[1]}
        \\    }
        \\  ]
        \\}
    ;

    const pretty_four =
        \\{
        \\    "name": "json",
        \\    "empty_array": [],
        \\    "empty_object": {},
        \\    "items": [
        \\        -7,
        \\        18446744073709551615,
        \\        0.25,
        \\        [
        \\            true,
        \\            null
        \\        ],
        \\        {
        \\            "raw": {"a":[1]}
        \\        }
        \\    ]
        \\}
    ;

    var pretty = test_options_compact;

    pretty.layout = .pretty;

    try test_layout_expect(test_options_compact, compact);
    try test_layout_expect(pretty, pretty_two);

    pretty.indent = 4;

    try test_layout_expect(pretty, pretty_four);
}

test "integers keep their sign and extremes" {
    var buffer: [128]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);

    try writer.array_begin();
    try writer.integer(std.math.minInt(i64));
    try writer.integer(std.math.maxInt(i64));
    try writer.integer(0);
    try writer.integer(-1);
    try writer.unsigned(0);
    try writer.array_end();

    writer.finish();

    try testing.expectEqualStrings(
        "[-9223372036854775808,9223372036854775807,0,-1,0]",
        sink.buffered(),
    );
}

test "a container past depth_max is refused and the writer stays usable" {
    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);

    for (0..depth_max) |_| try writer.array_begin();

    const written = sink.buffered().len;

    try testing.expectError(error.DepthExceeded, writer.array_begin());
    try testing.expectError(error.DepthExceeded, writer.object_begin());
    try testing.expectEqual(written, sink.buffered().len);
    try testing.expectEqual(depth_max, writer.depth);

    try writer.null_value();

    for (0..depth_max) |_| try writer.array_end();

    writer.finish();

    var tokenizer: Tokenizer = .init(sink.buffered());

    for (0..2 * depth_max + 1) |_| _ = try tokenizer.next();

    const last = try tokenizer.next();

    try testing.expectEqualDeep(tokenizer_module.Token.end, last);
}

test "objects and arrays mixed through every level to depth_max close as they opened" {
    var buffer: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);
    var expected_buffer: [2048]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buffer);

    for (0..depth_max) |level| {
        if (level % 3 == 1) {
            try writer.array_begin();
            try writer.integer(0);
            try expected.writeAll("[0,");
        } else {
            try writer.object_begin();
            try writer.key("k");
            try expected.writeAll("{\"k\":");
        }
    }

    try testing.expectError(error.DepthExceeded, writer.object_begin());
    try writer.null_value();
    try expected.writeAll("null");

    for (0..depth_max) |step| {
        const level = depth_max - 1 - step;

        if (level % 3 == 1) {
            try writer.integer(1);
            try writer.array_end();
            try expected.writeAll(",1]");
        } else {
            try writer.key("z");
            try writer.integer(1);
            try writer.object_end();
            try expected.writeAll(",\"z\":1}");
        }
    }

    writer.finish();

    try testing.expectEqualStrings(expected.buffered(), sink.buffered());

    var tokenizer: Tokenizer = .init(sink.buffered());
    var depth_seen: u32 = 0;

    for (0..sink.buffered().len) |_| {
        const token = try tokenizer.next();

        depth_seen = @max(depth_seen, tokenizer.depth);

        if (token == .end) break;
    }

    try testing.expectEqual(depth_max, depth_seen);
}

test "a non-finite float is refused or written as null by policy" {
    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);

    try writer.array_begin();
    try testing.expectError(error.FloatNonFinite, writer.float(std.math.nan(f64)));
    try testing.expectError(error.FloatNonFinite, writer.float(-std.math.inf(f64)));
    try writer.null_value();
    try writer.array_end();

    writer.finish();

    try testing.expectEqualStrings("[null]", sink.buffered());

    var nulled = test_options_compact;

    nulled.non_finite = .null_value;
    sink = .fixed(&buffer);
    writer = .init(&sink, nulled);

    try writer.array_begin();
    try writer.float(std.math.inf(f64));
    try writer.float(std.math.nan(f64));
    try writer.float(-0.0);
    try writer.array_end();

    writer.finish();

    try testing.expectEqualStrings("[null,null,-0]", sink.buffered());

    var literal = test_options_compact;

    literal.non_finite = .literal;
    sink = .fixed(&buffer);
    writer = .init(&sink, literal);

    try writer.array_begin();
    try writer.float(std.math.inf(f64));
    try writer.float(-std.math.inf(f64));
    try writer.float(-std.math.nan(f64));
    try writer.float(1.5);
    try writer.array_end();

    writer.finish();

    try testing.expectEqualStrings("[Infinity,-Infinity,NaN,1.5]", sink.buffered());
}

test "number text spelled with letters is written canonically under literal and null otherwise" {
    const texts = [_][]const u8{ "inf", "-INFINITY", "nan", "-NaN", "Infinity", "-0", "1e999" };

    const expected = [_][]const u8{
        "[Infinity,-Infinity,NaN,NaN,Infinity,-0,1e999]",
        "[null,null,null,null,null,-0,1e999]",
        "[null,null,null,null,null,-0,1e999]",
    };

    const policies = [_]Writer.NonFinite{ .literal, .null_value, .refused };
    var buffer: [64]u8 = undefined;

    for (policies, expected) |policy, output| {
        var options = test_options_compact;

        options.non_finite = policy;

        var sink: std.Io.Writer = .fixed(&buffer);
        var writer: Writer = .init(&sink, options);

        try writer.array_begin();

        for (texts) |text| try number_text_write(&writer, text);

        try writer.array_end();

        writer.finish();

        try testing.expectEqualStrings(output, sink.buffered());
    }
}

test "raw text must hold exactly one value and is copied without its outer whitespace" {
    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);
    const malformed = [_][]const u8{ "", " ", "[1,", "1 2", "{\"a\"}", "[1]]" };

    try writer.array_begin();

    for (malformed) |text| try testing.expectError(error.RawMalformed, writer.raw(text));

    try writer.raw("\n [ 1 , {\"b\" : null} ]\t");
    try writer.raw("\"text\"");

    for (0..depth_max - 3) |_| try writer.array_begin();

    try testing.expectError(error.DepthExceeded, writer.raw("[[[1]]]"));
    try writer.raw("[[1]]");

    for (0..depth_max - 3) |_| try writer.array_end();

    try writer.array_end();

    writer.finish();

    const text = sink.buffered();
    const closers: [depth_max]u8 = @splat(']');

    try testing.expect(std.mem.startsWith(u8, text, "[[ 1 , {\"b\" : null} ],\"text\",[["));
    try testing.expect(std.mem.endsWith(u8, text, "[[1" ++ closers));
}

test "string parts produce the same bytes as one string call" {
    const tail: [40]u8 = @splat('x');
    const text = "plain \"quoted\" \\ back\x01slash \u{e9}\u{1f600} tail" ++ tail;

    for ([_]Writer.UTF8{ .checked, .trusted }) |utf8| {
        var options = test_options_compact;

        options.utf8 = utf8;

        var whole_buffer: [256]u8 = undefined;
        var whole_sink: std.Io.Writer = .fixed(&whole_buffer);
        var whole: Writer = .init(&whole_sink, options);

        try whole.string(text);

        whole.finish();

        for (0..text.len + 1) |split| {
            if (split < text.len) {
                if (text[split] & 0xc0 == 0x80) continue;
            }

            var parts_buffer: [256]u8 = undefined;
            var parts_sink: std.Io.Writer = .fixed(&parts_buffer);
            var parts: Writer = .init(&parts_sink, options);

            try parts.string_begin();
            try parts.string_part(text[0..split]);
            try parts.string_part("");
            try parts.string_part(text[split..]);
            try parts.string_end();

            parts.finish();

            try testing.expectEqualStrings(whole_sink.buffered(), parts_sink.buffered());
        }
    }
}

test "a checked string part escapes a sequence split across parts byte by byte" {
    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var options = test_options_compact;

    options.utf8 = .checked;

    var writer: Writer = .init(&sink, options);

    try writer.string_begin();
    try writer.string_part("\xc3");
    try writer.string_part("\xa9");
    try writer.string_end();

    writer.finish();

    try testing.expectEqualStrings("\"\\u00c3\\u00a9\"", sink.buffered());
}

test "escapes match serde: short forms, lowercase hex, and raw DEL and solidus" {
    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);

    try writer.string("\x08\x0c\n\r\t\x1f\x7f/\"\\");

    writer.finish();

    try testing.expectEqualStrings("\"\\b\\f\\n\\r\\t\\u001f\x7f/\\\"\\\\\"", sink.buffered());
}

const TestCall = enum {
    array_begin,
    array_end,
    boolean,
    float,
    integer,
    key,
    null_value,
    object_begin,
    object_end,
    raw,
    string,
    string_begin,
    string_end,
    string_part,
    unsigned,
};

fn test_call_prepare(writer: *Writer, call: TestCall) !void {
    assert(writer.depth == 0);
    assert(!writer.done);

    switch (call) {
        .array_end => try writer.array_begin(),
        .key, .object_end => try writer.object_begin(),
        .string_end, .string_part => try writer.string_begin(),
        .array_begin, .boolean, .float, .integer, .null_value => {},
        .object_begin, .raw, .string, .string_begin, .unsigned => {},
    }
}

fn test_call_make(writer: *Writer, call: TestCall) !void {
    assert(writer.depth <= 1);
    assert(!writer.done);

    switch (call) {
        .array_begin => try writer.array_begin(),
        .array_end => try writer.array_end(),
        .boolean => try writer.boolean(false),
        .float => try writer.float(1.5),
        .integer => try writer.integer(-12),
        .key => try writer.key("member"),
        .null_value => try writer.null_value(),
        .object_begin => try writer.object_begin(),
        .object_end => try writer.object_end(),
        .raw => try writer.raw("[1]"),
        .string => try writer.string("text"),
        .string_begin => try writer.string_begin(),
        .string_end => try writer.string_end(),
        .string_part => try writer.string_part("part"),
        .unsigned => try writer.unsigned(12),
    }
}

test "every call reports WriteFailed when the fixed sink is full" {
    for (std.enums.values(TestCall)) |call| {
        var buffer: [1]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&buffer);
        var writer: Writer = .init(&sink, test_options_compact);

        try test_call_prepare(&writer, call);

        sink.end = buffer.len;

        try testing.expectError(error.WriteFailed, test_call_make(&writer, call));
    }
}

test Writer {
    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    var writer: Writer = .init(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .null_value,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    try writer.object_begin();
    try writer.key("name");
    try writer.string("json");
    try writer.key("ratio");
    try writer.float(std.math.inf(f64));
    try writer.key("tags");
    try writer.array_begin();
    try writer.integer(-1);
    try writer.boolean(true);
    try writer.array_end();
    try writer.object_end();

    writer.finish();

    try testing.expectEqualStrings(
        "{\"name\":\"json\",\"ratio\":null,\"tags\":[-1,true]}",
        sink.buffered(),
    );
}
