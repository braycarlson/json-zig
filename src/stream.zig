const std = @import("std");

const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Event = tokenizer_module.Event;
const Mode = tokenizer_module.Mode;
const Position = tokenizer_module.Position;
const Status = tokenizer_module.Status;
const Syntax = tokenizer_module.Syntax;
const Token = tokenizer_module.Token;
const Tokenizer = tokenizer_module.Tokenizer;
const TokenizerType = tokenizer_module.TokenizerType;

const bom = "\xef\xbb\xbf";
const depth_max = tokenizer_module.depth_max;
const input_bytes_max = tokenizer_module.input_bytes_max;
const lane_count = tokenizer_module.lane_count;
const pass_count_max: u64 = std.math.maxInt(u64);

const LaneMask = @Int(.unsigned, lane_count);
const Lanes = @Vector(lane_count, u8);

const StreamOptions = struct {
    values: Values = .single,

    pub const Values = tokenizer_module.Values;
};

comptime {
    assert(@sizeOf(StreamOptions) <= 16);
    assert(bom.len == 3);
}

pub const Stream = StreamType(.strict);

pub fn StreamType(comptime syntax: Syntax) type {
    comptime assert(@sizeOf(TokenizerType(syntax)) == @sizeOf(Tokenizer));

    return struct {
        base: Position,
        done: bool,
        options: Options,
        pin: ?u32,
        reader: *std.Io.Reader,
        status: Status,
        tokenizer: TokenizerType(syntax),

        pub const CapacityError = error{ BufferExhausted, DepthExceeded };
        pub const ReadError = error{ReadFailed};
        pub const SyntaxError = error{Malformed};
        pub const Error = CapacityError || ReadError || SyntaxError;
        pub const Options = StreamOptions;

        const complete_sequence_mode: Mode = .{
            .input = .complete,
            .syntax = syntax,
            .values = .sequence,
        };

        pub fn init(stream: *@This(), reader: *std.Io.Reader, options: Options) void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(reader.buffer.len <= input_bytes_max);
            assert(reader.seek <= reader.end);

            const done = fixed_is(reader);

            assert(done or reader.buffer.len > 0);

            stream.base = .{ .column = 1, .line = 1 };
            stream.done = done;
            stream.options = options;
            stream.pin = null;
            stream.reader = reader;
            stream.status = .ready;

            tokenizer_module.tokenizer_reset(syntax, &stream.tokenizer, reader.buffered());

            if (options.values == .sequence) stream.tokenizer.scan_state = .done;

            assert(stream.tokenizer.depth == 0);
        }

        pub inline fn next(stream: *@This()) Error!Token {
            assert(stream.pin == null);
            assert(stream.tokenizer.depth <= depth_max);

            const event = try stream.event_pop();
            const input = stream.tokenizer.input;

            return switch (event.kind) {
                .array_begin => .array_begin,
                .array_end => .array_end,
                .end => .end,
                .false_value => .{ .boolean = false },
                .key => .{ .key = input[event.start .. event.end - 1] },
                .null_value => .null_value,
                .number => .{ .number = input[event.start..event.end] },
                .object_begin => .object_begin,
                .object_end => .object_end,
                .string => .{ .string = input[event.start + 1 .. event.end - 1] },
                .true_value => .{ .boolean = true },
            };
        }

        pub fn value_next(stream: *@This()) Error![]const u8 {
            const tokenizer = &stream.tokenizer;

            assert(stream.pin == null);
            assert(tokenizer.event_index <= tokenizer.event_count);

            if (tokenizer.event_index == tokenizer.event_count) try stream.refill();

            const first = tokenizer.events[tokenizer.event_index];

            switch (first.kind) {
                .array_end, .end, .object_end => {
                    _ = tokenizer_module.event_advance(syntax, tokenizer);

                    return "";
                },
                .key => unreachable,
                .array_begin,
                .false_value,
                .null_value,
                .number,
                .object_begin,
                .string,
                .true_value,
                => {},
            }

            const depth = tokenizer.depth;

            assert(depth <= depth_max);

            stream.pin = first.start;
            defer stream.pin = null;

            for (0..stream.reader.buffer.len + 1) |_| {
                const event = try stream.event_pop();

                if (tokenizer.depth != depth) continue;

                const start = stream.pin.?;

                assert(start < event.end);
                assert(event.end <= tokenizer.input.len);

                return tokenizer.input[start..event.end];
            }

            unreachable;
        }

        pub fn diagnostic(stream: *const @This()) Position {
            const tokenizer = &stream.tokenizer;

            assert(tokenizer.failure_index <= tokenizer.input.len);
            assert(stream.base.line >= 1);

            const relative = tokenizer_module.position_of(tokenizer.input, tokenizer.failure_index);

            if (relative.line == 1) {
                return .{
                    .column = stream.base.column +| (relative.column - 1),
                    .line = stream.base.line,
                };
            }

            return .{ .column = relative.column, .line = stream.base.line +| (relative.line - 1) };
        }

        inline fn event_pop(stream: *@This()) Error!Event {
            const tokenizer = &stream.tokenizer;

            assert(tokenizer.event_index <= tokenizer.event_count);
            assert(tokenizer.depth <= depth_max);

            if (tokenizer.event_index == tokenizer.event_count) try stream.refill();

            return tokenizer_module.event_advance(syntax, tokenizer);
        }

        noinline fn refill(stream: *@This()) Error!void {
            const tokenizer = &stream.tokenizer;

            assert(tokenizer.event_index == tokenizer.event_count);
            assert(tokenizer.scan_depth <= depth_max);

            var pass: u64 = 0;

            while (pass < pass_count_max) : (pass += 1) {
                if (tokenizer.failure) |failure| {
                    tokenizer.index = tokenizer.failure_index;

                    return failure;
                }

                if (stream.status == .ready) {
                    stream.status = stream.scan();

                    if (tokenizer.event_count > 0) return;
                }

                if (stream.status == .underflow) {
                    try stream.window_advance();
                } else {
                    assert(tokenizer.failure != null);
                }
            }

            unreachable;
        }

        fn scan(stream: *@This()) Status {
            const tokenizer = &stream.tokenizer;

            tokenizer.input = stream.reader.buffered();

            assert(tokenizer.failure == null);
            assert(tokenizer.scan_index <= tokenizer.input.len);

            if (syntax == .relaxed) {
                if (stream.bom_skip() == .underflow) return .underflow;
            }

            if (stream.done) {
                if (stream.options.values == .single) return stream.complete_fill();
                return stream.complete_sequence_scan();
            }

            return switch (stream.options.values) {
                inline else => |values| stream.window_scan(values),
            };
        }

        noinline fn window_scan(stream: *@This(), comptime values: Options.Values) Status {
            assert(!stream.done);
            assert(stream.options.values == values);

            const mode: Mode = .{ .input = .window, .syntax = syntax, .values = values };
            return tokenizer_module.events_scan(mode, &stream.tokenizer);
        }

        noinline fn complete_sequence_scan(stream: *@This()) Status {
            const tokenizer = &stream.tokenizer;

            assert(stream.done);
            assert(stream.options.values == .sequence);

            const status = tokenizer_module.events_scan(complete_sequence_mode, tokenizer);

            assert(status == .ready);

            return status;
        }

        noinline fn complete_fill(stream: *@This()) Status {
            const tokenizer = &stream.tokenizer;

            assert(stream.done);
            assert(stream.options.values == .single);

            tokenizer.events_fill() catch |err| assert(tokenizer.failure.? == err);

            return .ready;
        }

        fn bom_skip(stream: *@This()) Status {
            comptime assert(syntax == .relaxed);

            const tokenizer = &stream.tokenizer;
            const window = tokenizer.input;
            const first = stream.base.line == 1 and stream.base.column == 1;

            assert(tokenizer.scan_index <= window.len);

            if (!first) return .ready;
            if (tokenizer.scan_index != 0) return .ready;

            if (std.mem.startsWith(u8, window, bom)) {
                tokenizer.index = bom.len;
                tokenizer.scan_index = bom.len;

                return .ready;
            }

            if (stream.done) return .ready;
            if (window.len >= bom.len) return .ready;
            if (!std.mem.startsWith(u8, bom, window)) return .ready;
            return .underflow;
        }

        fn window_advance(stream: *@This()) Error!void {
            const tokenizer = &stream.tokenizer;
            const reader = stream.reader;

            assert(stream.status == .underflow);
            assert(!stream.done);

            const commit = tokenizer.scan_index;
            const amount = if (stream.pin) |pin| @min(pin, commit) else commit;

            stream.base = position_after(stream.base, reader.buffered()[0..amount]);

            reader.toss(amount);
            stream.indices_shift(amount);
            tokenizer.input = reader.buffered();

            if (reader.bufferedLen() == reader.buffer.len) {
                tokenizer.failure_index = 0;

                return error.BufferExhausted;
            }

            const filled = reader.fill(reader.bufferedLen() + 1);

            tokenizer.input = reader.buffered();

            filled catch |err| switch (err) {
                error.EndOfStream => stream.done = true,
                error.ReadFailed => {
                    tokenizer.failure_index = tokenizer.scan_index;

                    return error.ReadFailed;
                },
            };

            stream.status = .ready;

            assert(tokenizer.scan_index <= tokenizer.input.len);
        }

        fn indices_shift(stream: *@This(), amount: u32) void {
            const tokenizer = &stream.tokenizer;

            assert(amount <= tokenizer.scan_index);
            assert(tokenizer.failure == null);

            tokenizer.failure_index -|= amount;
            tokenizer.index -|= amount;
            tokenizer.key_start -|= amount;
            tokenizer.scan_index -= amount;

            tokenizer.value_start -|= amount;

            if (stream.pin) |pin| {
                assert(pin >= amount);

                stream.pin = pin - amount;
            }
        }
    };
}

fn fixed_is(reader: *const std.Io.Reader) bool {
    assert(reader.seek <= reader.end);
    assert(reader.end <= reader.buffer.len);

    return reader.vtable.readVec == std.Io.Reader.ending.vtable.readVec;
}

fn newline_last_find(bytes: []const u8) ?u32 {
    assert(bytes.len <= input_bytes_max);
    assert(lane_count == @bitSizeOf(LaneMask));

    var end: u32 = @intCast(bytes.len);

    const found: ?usize = for (0..@divFloor(bytes.len, lane_count) + 1) |_| {
        if (end < lane_count) break std.mem.findScalarLast(u8, bytes[0..end], '\n');

        const lanes: Lanes = bytes[end - lane_count ..][0..lane_count].*;
        const mask: LaneMask = @bitCast(lanes == @as(Lanes, @splat('\n')));
        if (mask != 0) break end - 1 - @clz(mask);

        end -= lane_count;
    } else unreachable;

    const result: u32 = @intCast(found orelse return null);

    assert(result < bytes.len);
    assert(bytes[result] == '\n');

    return result;
}

fn position_after(base: Position, bytes: []const u8) Position {
    assert(base.line >= 1);
    assert(bytes.len <= input_bytes_max);

    const length: u32 = @intCast(bytes.len);

    const newline_last = newline_last_find(bytes) orelse {
        return .{ .column = base.column +| length, .line = base.line };
    };

    const newline_count: u32 = @intCast(std.mem.countScalar(u8, bytes, '\n'));

    assert(newline_count > 0);

    return .{
        .column = @intCast(bytes.len - newline_last),
        .line = base.line +| newline_count,
    };
}

const testing = std.testing;

fn tokens_expect(comptime syntax: Syntax, text: []const u8, buffer_length: u32) !void {
    comptime assert(@sizeOf(TokenizerType(syntax)) == @sizeOf(Tokenizer));
    assert(text.len <= input_bytes_max);
    assert(buffer_length > 0);
    assert(buffer_length <= 64);

    var buffer: [64]u8 = undefined;
    var source: std.Io.Reader = .fixed(text);
    var limited = source.limited(.unlimited, buffer[0..buffer_length]);
    var stream: StreamType(syntax) = undefined;
    var tokenizer: TokenizerType(syntax) = .init(text);

    stream.init(&limited.interface, .{ .values = .single });

    for (0..text.len + 2) |_| {
        const expected = try tokenizer.next();
        const actual = try stream.next();

        try testing.expectEqualDeep(expected, actual);

        if (expected == .end) return;
    }

    unreachable;
}

test "a number needs the byte after it in the buffer" {
    try tokens_expect(.strict, "[12345]", 6);
    try testing.expectError(error.BufferExhausted, tokens_expect(.strict, "[12345]", 5));
}

test "a string needs only its own bytes in the buffer" {
    try tokens_expect(.strict, "[\"abcd\"]", 6);
    try testing.expectError(error.BufferExhausted, tokens_expect(.strict, "[\"abcd\"]", 5));
}

test "whitespace and comments longer than the buffer" {
    const spaces: [40]u8 = @splat(' ');

    try tokens_expect(.strict, &spaces ++ "[1," ++ spaces ++ "2]" ++ spaces, 3);
    try tokens_expect(.relaxed, "[1, /* abc */ 2] // xyz", 9);
    try testing.expectError(error.BufferExhausted, tokens_expect(.relaxed, "[1, /* abc */ 2]", 8));
}

test "a stream over a fixed reader agrees with the slice tokenizer" {
    const text = "{\"a\": [1, 2.5e3, true, null], \"b\": \"\\u00e9\"}";
    var source: std.Io.Reader = .fixed(text);
    var stream: Stream = undefined;
    var tokenizer: Tokenizer = .init(text);

    stream.init(&source, .{ .values = .single });

    for (0..text.len + 2) |_| {
        const expected = try tokenizer.next();
        const actual = try stream.next();

        try testing.expectEqualDeep(expected, actual);

        if (expected == .end) return;
    }

    unreachable;
}

test "value_next returns each value of a sequence" {
    const text = "{\"a\":1}\n[2, 3]\r\n\"four\"\n5\n";
    const values = [_][]const u8{ "{\"a\":1}", "[2, 3]", "\"four\"", "5" };
    var buffer: [8]u8 = undefined;
    var source: std.Io.Reader = .fixed(text);
    var limited = source.limited(.unlimited, &buffer);
    var stream: Stream = undefined;

    stream.init(&limited.interface, .{ .values = .sequence });

    for (values) |value| try testing.expectEqualStrings(value, try stream.value_next());

    try testing.expectEqual(@as(usize, 0), (try stream.value_next()).len);
}

test "a malformed byte reports its position across refills" {
    const text = "[1,\n 2,\n    3 4]";
    var buffer: [4]u8 = undefined;
    var source: std.Io.Reader = .fixed(text);
    var limited = source.limited(.unlimited, &buffer);
    var stream: Stream = undefined;

    stream.init(&limited.interface, .{ .values = .single });

    for (0..8) |_| {
        _ = stream.next() catch |err| {
            try testing.expectEqual(error.Malformed, err);
            try testing.expectEqual(Position{ .column = 7, .line = 3 }, stream.diagnostic());

            return;
        };
    }

    return error.TestUnexpectedResult;
}

test newline_last_find {
    var bytes: [100]u8 = @splat('a');

    try testing.expectEqual(@as(?u32, null), newline_last_find(&bytes));

    for (0..bytes.len) |position| {
        bytes[position] = '\n';

        const expected: ?u32 = @intCast(std.mem.findScalarLast(u8, &bytes, '\n').?);

        try testing.expectEqual(expected, newline_last_find(&bytes));
        try testing.expectEqual(expected, newline_last_find(bytes[0 .. position + 1]));

        bytes[position] = 'a';
    }

    bytes[3] = '\n';
    bytes[70] = '\n';

    try testing.expectEqual(@as(?u32, 70), newline_last_find(&bytes));
    try testing.expectEqual(@as(?u32, 3), newline_last_find(bytes[0..70]));
}

test position_after {
    const base: Position = .{ .column = 5, .line = 2 };

    try testing.expectEqual(Position{ .column = 8, .line = 2 }, position_after(base, "abc"));
    try testing.expectEqual(Position{ .column = 3, .line = 4 }, position_after(base, "a\nb\nxy"));
    try testing.expectEqual(Position{ .column = 1, .line = 3 }, position_after(base, "\n"));
}
