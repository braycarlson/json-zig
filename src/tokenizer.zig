const std = @import("std");

const structural = @import("structural.zig");

const assert = std.debug.assert;

const bom = "\xef\xbb\xbf";
const continuation_any: Range = .{ 0x80, 0xbf };
pub const depth_max: u32 = 128;
pub const digit_lane_count: u32 = 16;
const event_capacity: u32 = 512;
const hex_digits = "0123456789abcdefABCDEF";
const indent_depth_count = 32;
const indent_state_count = 8;
pub const input_bytes_max: u32 = 1 << 31;
pub const lane_count: u32 = if (structural.lanes_narrow) 16 else 32;
const number_chunk_enabled = std.debug.runtime_safety and vector_bytes >= lane_count;
const non_finite_prefixes = [_][]const u8{ "infinity", "nan" };
const non_finite_spellings = [_][]const u8{ "infinity", "inf", "nan" };
const surrogate_low_template = [_][]const u8{ "\\", "u", "dD", "cdefCDEF", hex_digits, hex_digits };
const vector_bytes = std.simd.suggestVectorLength(u8) orelse 0;

comptime {
    assert(depth_max >= 16);
    assert(depth_max <= std.math.maxInt(u8));
    assert(input_bytes_max < std.math.maxInt(u32));
    assert(std.math.isPowerOfTwo(digit_lane_count));
    assert(event_capacity >= 2);
    assert(event_capacity <= std.math.maxInt(u16));
    assert(indent_depth_count <= depth_max);
    assert(indent_state_count >= @typeInfo(State).@"enum".field_names.len);
    assert(std.math.isPowerOfTwo(lane_count));
}

pub const Token = union(enum) {
    array_begin,
    array_end,
    boolean: bool,
    end,
    key: []const u8,
    null_value,
    number: []const u8,
    object_begin,
    object_end,
    string: []const u8,
};

pub const Position = struct {
    column: u32,
    line: u32,
};

pub const Syntax = enum {
    relaxed,
    strict,
};

const Chunk = @Vector(lane_count, u8);
const DigitMask = @Int(.unsigned, digit_lane_count);
const Digits = @Vector(digit_lane_count, u8);
const Indents = [indent_depth_count][indent_state_count]u8;
const Lanes = @Vector(lane_count, u1);
const Mask = @Int(.unsigned, lane_count);
const UTF8 = structural.UTF8Type(lane_count);

const Container = enum {
    array,
    object,
};

const Frames = struct {
    indents: Indents,
    stack: [depth_max]Container,
};

pub const Event = struct {
    end: u32,
    kind: Kind,
    start: u32,
};

pub const Input = enum {
    complete,
    window,
};

pub const Kind = enum {
    array_begin,
    array_end,
    end,
    false_value,
    key,
    null_value,
    number,
    object_begin,
    object_end,
    string,
    true_value,
};

const Literal = enum {
    false_value,
    null_value,
    true_value,

    fn text(literal: Literal) []const u8 {
        const result = switch (literal) {
            .false_value => "false",
            .null_value => "null",
            .true_value => "true",
        };

        assert(result.len >= 4);

        return result;
    }

    fn kind(literal: Literal) Kind {
        const result: Kind = switch (literal) {
            .false_value => .false_value,
            .null_value => .null_value,
            .true_value => .true_value,
        };

        assert(result != .end);

        return result;
    }
};

pub const Mode = struct {
    input: Input,
    syntax: Syntax,
    values: Values,
};

const Outcome = struct {
    index: u32,
    valid: bool,
};

pub const ScanError = error{ DepthExceeded, Malformed, Underflow };
const Range = struct { u8, u8 };

const Separator = enum(u8) {
    colon = ':',
    comma = ',',
};

const State = enum {
    colon,
    comma_or_end,
    done,
    key,
    key_or_end,
    value,
    value_or_end,
};

pub const Status = enum {
    ready,
    underflow,
};

const Step = union(enum) {
    kind: Kind,
    separated,
};

const Ending = enum {
    complete,
    malformed,
    truncated,
};

const Blank = struct {
    ending: Ending,
    index: u32,
};

const Comment = union(Ending) {
    complete: u32,
    malformed,
    truncated,
};

pub const Values = enum {
    sequence,
    single,
};

const Cause = enum {
    escape,
    utf8,
};

const Verdict = enum {
    invalid,
    truncated,
    valid,
};

const WindowOutcome = struct {
    index: u32,
    truncated: bool,
    valid: bool,
};

pub const Tokenizer = TokenizerType(.strict);

pub fn TokenizerType(comptime syntax: Syntax) type {
    return struct {
        depth: u32,
        event_count: u32,
        event_index: u32,
        events: [event_capacity]Event,
        failure: ?Error,
        failure_index: u32,
        frames: Frames,
        index: u32,
        input: []const u8,
        key_start: u32,
        scan_depth: u32,
        scan_index: u32,
        scan_state: State,
        value_start: u32,

        pub const CapacityError = error{DepthExceeded};
        pub const SyntaxError = error{Malformed};
        pub const Error = CapacityError || SyntaxError;
        const complete_mode: Mode = .{ .input = .complete, .syntax = syntax, .values = .single };

        pub const events_fill = if (structural.functions_aligned)
            events_fill_aligned
        else
            events_fill_unaligned;

        pub fn init(input: []const u8) @This() {
            assert(input.len <= input_bytes_max);

            const start = start_of(syntax, input);

            const result = TokenizerType(syntax){
                .depth = 0,
                .event_count = 0,
                .event_index = 0,
                .events = undefined,
                .failure = null,
                .failure_index = 0,
                .frames = .{ .indents = @splat(@splat(0)), .stack = undefined },
                .index = start,
                .input = input,
                .key_start = 0,
                .scan_depth = 0,
                .scan_index = start,
                .scan_state = .value,
                .value_start = 0,
            };

            assert(result.depth == 0);
            assert(result.event_count == result.event_index);

            return result;
        }

        pub inline fn next(tokenizer: *@This()) Error!Token {
            assert(tokenizer.index <= tokenizer.input.len);

            const event = try tokenizer.event_pop();
            const input = tokenizer.input;

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

        pub fn skip(tokenizer: *@This(), first: Token) Error!void {
            assert(first != .end);
            assert(tokenizer.depth <= depth_max);

            const depth_target = switch (first) {
                .array_begin, .object_begin => tokenizer.depth - 1,
                .array_end, .end, .key, .object_end => return error.Malformed,
                .boolean, .null_value, .number, .string => return,
            };

            var budget: u32 = @intCast(tokenizer.input.len + 1);

            while (budget > 0) : (budget -= 1) {
                const event = try tokenizer.event_pop();
                if (event.kind == .end) return error.Malformed;
                if (tokenizer.depth == depth_target) return;
            }

            return error.Malformed;
        }

        pub fn diagnostic(tokenizer: *const @This()) Position {
            assert(tokenizer.failure_index <= tokenizer.input.len);
            assert(tokenizer.input.len <= input_bytes_max);

            const result = position_of(tokenizer.input, tokenizer.failure_index);

            assert(result.line >= 1);

            return result;
        }

        inline fn event_pop(tokenizer: *@This()) Error!Event {
            assert(tokenizer.event_index <= tokenizer.event_count);
            assert(tokenizer.event_count <= event_capacity);

            if (tokenizer.event_index == tokenizer.event_count) try tokenizer.events_fill();

            return event_advance(syntax, tokenizer);
        }

        noinline fn events_fill_aligned(tokenizer: *@This()) align(64) Error!void {
            assert(tokenizer.event_index == tokenizer.event_count);
            assert(tokenizer.depth <= depth_max);
            assert(tokenizer.scan_depth <= depth_max);

            return events_fill_body(tokenizer);
        }

        noinline fn events_fill_unaligned(tokenizer: *@This()) Error!void {
            assert(tokenizer.event_index == tokenizer.event_count);
            assert(tokenizer.depth <= depth_max);
            assert(tokenizer.scan_depth <= depth_max);

            return events_fill_body(tokenizer);
        }

        inline fn events_fill_body(tokenizer: *@This()) Error!void {
            assert(tokenizer.event_index == tokenizer.event_count);
            assert(tokenizer.depth <= depth_max);
            assert(tokenizer.scan_depth <= depth_max);

            if (tokenizer.failure == null) _ = events_scan(complete_mode, tokenizer);

            if (tokenizer.failure) |failure| {
                if (tokenizer.event_index == tokenizer.event_count) {
                    tokenizer.index = tokenizer.failure_index;

                    return failure;
                }
            }

            assert(tokenizer.event_index < tokenizer.event_count);
        }
    };
}

pub fn events_take(
    comptime syntax: Syntax,
    tokenizer: *TokenizerType(syntax),
) Tokenizer.Error![]const Event {
    assert(tokenizer.event_index <= tokenizer.event_count);
    assert(tokenizer.event_count <= event_capacity);

    if (tokenizer.event_index == tokenizer.event_count) try tokenizer.events_fill();

    const result = tokenizer.events[tokenizer.event_index..tokenizer.event_count];

    tokenizer.event_index = tokenizer.event_count;

    assert(result.len > 0);
    assert(result.len <= event_capacity);

    return result;
}

pub fn tokenizer_reset(
    comptime syntax: Syntax,
    tokenizer: *TokenizerType(syntax),
    input: []const u8,
) void {
    assert(input.len <= input_bytes_max);

    tokenizer.depth = 0;
    tokenizer.event_count = 0;
    tokenizer.event_index = 0;
    tokenizer.failure = null;
    tokenizer.failure_index = 0;
    tokenizer.frames.indents = @splat(@splat(0));
    tokenizer.index = start_of(syntax, input);
    tokenizer.input = input;
    tokenizer.key_start = 0;
    tokenizer.scan_depth = 0;
    tokenizer.scan_index = tokenizer.index;
    tokenizer.scan_state = .value;
    tokenizer.value_start = 0;

    assert(tokenizer.event_count == tokenizer.event_index);
}

pub inline fn event_advance(comptime syntax: Syntax, tokenizer: *TokenizerType(syntax)) Event {
    const event = tokenizer.events[tokenizer.event_index];

    tokenizer.event_index += 1;
    tokenizer.index = event.end;

    switch (event.kind) {
        .array_begin, .object_begin => {
            tokenizer.depth += 1;
            tokenizer.value_start = event.start;

            assert(tokenizer.depth <= depth_max);
        },
        .array_end, .object_end => tokenizer.depth -= 1,
        .end => {},
        .key => tokenizer.key_start = event.start,
        .false_value, .null_value, .number, .string, .true_value => {
            tokenizer.value_start = event.start;
        },
    }

    return event;
}

pub fn events_scan(comptime mode: Mode, tokenizer: *TokenizerType(mode.syntax)) Status {
    comptime assert(@sizeOf(TokenizerType(mode.syntax)) == @sizeOf(Tokenizer));
    assert(tokenizer.failure == null);
    assert(tokenizer.event_index == tokenizer.event_count);
    assert(tokenizer.input.len <= input_bytes_max);

    var scanner: ScannerType(mode) = .{
        .commit = if (mode.input == .window) tokenizer.scan_index else {},
        .depth = tokenizer.scan_depth,
        .frames = &tokenizer.frames,
        .index = tokenizer.scan_index,
        .input = tokenizer.input,
        .start = 0,
        .state = tokenizer.scan_state,
    };

    var count: u32 = 0;
    var status: Status = .ready;

    for (0..event_capacity) |_| {
        const kind = scanner.kind_next() catch |failure| {
            switch (mode.input) {
                .complete => {
                    tokenizer.failure = failure;
                    tokenizer.failure_index = scanner.index;
                },
                .window => if (failure == error.Underflow) {
                    scanner.index = scanner.commit;
                    status = .underflow;
                } else {
                    tokenizer.failure = failure_narrowed(failure);
                    tokenizer.failure_index = scanner.index;
                },
            }

            break;
        };

        tokenizer.events[count] = .{
            .end = scanner.index,
            .kind = kind,
            .start = scanner.start,
        };

        count += 1;

        if (kind == .end) break;
    }

    tokenizer.event_count = count;
    tokenizer.event_index = 0;
    tokenizer.scan_depth = scanner.depth;
    tokenizer.scan_index = scanner.index;
    tokenizer.scan_state = scanner.state;

    assert(count <= event_capacity);
    if (status == .underflow) assert(tokenizer.failure == null);

    return status;
}

fn CommitType(comptime input_mode: Input) type {
    return switch (input_mode) {
        .complete => void,
        .window => u32,
    };
}

fn failure_narrowed(failure: ScanError) Tokenizer.Error {
    assert(failure != error.Underflow);

    return switch (failure) {
        error.DepthExceeded => error.DepthExceeded,
        error.Malformed => error.Malformed,
        error.Underflow => unreachable,
    };
}

inline fn start_of(comptime syntax: Syntax, input: []const u8) u32 {
    assert(input.len <= input_bytes_max);

    if (syntax == .strict) return 0;
    if (!std.mem.startsWith(u8, input, bom)) return 0;
    return bom.len;
}

fn ScannerType(comptime mode: Mode) type {
    comptime assert(@sizeOf(CommitType(mode.input)) <= @sizeOf(u32));

    return struct {
        commit: CommitType(mode.input),
        depth: u32,
        frames: *Frames,
        index: u32,
        input: []const u8,
        start: u32,
        state: State,

        const Error = switch (mode.input) {
            .complete => Tokenizer.Error,
            .window => ScanError,
        };

        const syntax = mode.syntax;
        const window = mode.input == .window;

        inline fn kind_next(scanner: *@This()) Error!Kind {
            assert(scanner.depth <= depth_max);
            assert(scanner.index <= scanner.input.len);

            if (syntax == .relaxed) return scanner.relaxed_kind_next();

            var step: u32 = 0;

            while (step < 3) : (step += 1) {
                scanner.whitespace_skip();

                if (window) try scanner.window_commit();

                switch (scanner.state) {
                    .colon => try scanner.separator_expect(.colon, .value),
                    .comma_or_end => {
                        if (scanner.peek() != ',') return scanner.container_end();

                        const after = comma_after(syntax, scanner.top());

                        try scanner.separator_expect(.comma, after);
                    },
                    .done => {
                        if (scanner.index < scanner.input.len) {
                            if (mode.values == .sequence) return scanner.value_read();
                            return error.Malformed;
                        }

                        return .end;
                    },
                    .key, .key_or_end => {
                        if (scanner.state == .key_or_end) {
                            if (scanner.peek() == '}') return scanner.container_end();
                        }

                        return scanner.key_read();
                    },
                    .value, .value_or_end => {
                        if (scanner.state == .value_or_end) {
                            if (scanner.peek() == ']') return scanner.container_end();
                        }

                        return scanner.value_read();
                    },
                }
            }

            unreachable;
        }

        inline fn relaxed_kind_next(scanner: *@This()) Error!Kind {
            comptime assert(syntax == .relaxed);
            assert(scanner.index <= scanner.input.len);

            var step: u32 = 0;

            while (step < 4) : (step += 1) {
                scanner.whitespace_skip();

                if (window) try scanner.window_commit();

                const before = scanner.index;

                const stepped = scanner.state_step() catch |err| {
                    if (scanner.index != before) return err;
                    if (scanner.peek() != '/') return err;

                    try scanner.blank_skip();

                    continue;
                };

                switch (stepped) {
                    .kind => |kind| return kind,
                    .separated => {},
                }
            }

            unreachable;
        }

        inline fn window_commit(scanner: *@This()) Error!void {
            comptime assert(window);
            assert(scanner.index <= scanner.input.len);

            scanner.commit = scanner.index;

            if (scanner.index == scanner.input.len) return error.Underflow;
        }

        inline fn state_step(scanner: *@This()) Error!Step {
            comptime assert(syntax == .relaxed);
            assert(scanner.depth <= depth_max);
            assert(scanner.index <= scanner.input.len);

            switch (scanner.state) {
                .colon => try scanner.separator_expect(.colon, .value),
                .comma_or_end => {
                    if (scanner.peek() != ',') return .{ .kind = try scanner.container_end() };

                    const after = comma_after(syntax, scanner.top());

                    try scanner.separator_expect(.comma, after);
                },
                .done => {
                    if (scanner.index < scanner.input.len) {
                        if (mode.values == .sequence) return .{ .kind = try scanner.value_read() };
                        return error.Malformed;
                    }

                    return .{ .kind = .end };
                },
                .key, .key_or_end => {
                    if (scanner.state == .key_or_end) {
                        if (scanner.peek() == '}') return .{ .kind = try scanner.container_end() };
                    }

                    return .{ .kind = try scanner.key_read() };
                },
                .value, .value_or_end => {
                    if (scanner.state == .value_or_end) {
                        if (scanner.peek() == ']') return .{ .kind = try scanner.container_end() };
                    }

                    return .{ .kind = try scanner.value_read() };
                },
            }

            return .separated;
        }

        inline fn key_read(scanner: *@This()) Error!Kind {
            assert(scanner.depth > 0);
            assert(scanner.top() == .object);

            if (scanner.peek() != '"') return error.Malformed;

            scanner.start = scanner.index + 1;

            try scanner.string_read();

            scanner.state = .colon;

            assert(scanner.index > scanner.start);

            return .key;
        }

        inline fn value_read(scanner: *@This()) Error!Kind {
            assert(scanner.depth <= depth_max);
            assert(scanner.index <= scanner.input.len);

            scanner.start = scanner.index;

            switch (scanner.peek()) {
                '{' => return scanner.container_begin(.object),
                '[' => return scanner.container_begin(.array),
                '"' => {
                    try scanner.string_read();

                    scanner.value_finish();

                    return .string;
                },
                't' => return scanner.literal_read(.true_value),
                'f' => return scanner.literal_read(.false_value),
                'n' => {
                    if (syntax == .strict) return scanner.literal_read(.null_value);

                    if (window) {
                        const null_kind = scanner.literal_read(.null_value);
                        return null_kind catch |err| scanner.non_finite_fallback(err);
                    }

                    return scanner.literal_read(.null_value) catch scanner.non_finite_read();
                },
                '-' => {
                    if (syntax == .strict) return scanner.number_finish(true);

                    if (window) {
                        const number_kind = scanner.number_finish(true);
                        return number_kind catch |err| scanner.non_finite_fallback(err);
                    }

                    return scanner.number_finish(true) catch scanner.non_finite_read();
                },
                '0'...'9' => return scanner.number_finish(false),
                else => {
                    if (syntax == .relaxed) {
                        if (scanner.non_finite_is()) return scanner.non_finite_read();
                    }

                    return error.Malformed;
                },
            }
        }

        inline fn container_begin(scanner: *@This(), container: Container) Error!Kind {
            assert(scanner.depth <= depth_max);

            if (scanner.depth == depth_max) return error.DepthExceeded;

            scanner.frames.stack[scanner.depth] = container;
            scanner.depth += 1;
            scanner.index += 1;

            assert(scanner.depth <= depth_max);

            switch (container) {
                .array => {
                    scanner.state = .value_or_end;

                    return .array_begin;
                },
                .object => {
                    scanner.state = .key_or_end;

                    return .object_begin;
                },
            }
        }

        inline fn container_end(scanner: *@This()) Error!Kind {
            assert(scanner.depth <= depth_max);

            if (scanner.depth == 0) return error.Malformed;

            const container = scanner.top();
            const closing: u8 = if (container == .object) '}' else ']';
            if (scanner.peek() != closing) return error.Malformed;

            scanner.depth -= 1;
            scanner.index += 1;

            scanner.value_finish();

            assert(scanner.depth < depth_max);

            return if (container == .object) .object_end else .array_end;
        }

        inline fn value_finish(scanner: *@This()) void {
            assert(scanner.depth <= depth_max);

            scanner.state = if (scanner.depth == 0) .done else .comma_or_end;

            if (scanner.state == .done) assert(scanner.depth == 0);
        }

        inline fn separator_expect(
            scanner: *@This(),
            separator: Separator,
            after: State,
        ) Tokenizer.Error!void {
            assert(scanner.depth > 0);
            assert(scanner.index <= scanner.input.len);

            if (separator == .colon) assert(scanner.state == .colon);
            if (separator == .comma) assert(scanner.state == .comma_or_end);

            if (scanner.peek() != @backingInt(separator)) return error.Malformed;

            scanner.index += 1;
            scanner.state = after;
        }

        inline fn literal_read(scanner: *@This(), comptime literal: Literal) Error!Kind {
            assert(scanner.index < scanner.input.len);

            const text = comptime literal.text();
            const rest = scanner.input[scanner.index..];

            if (rest.len < text.len) {
                if (window) {
                    if (std.mem.startsWith(u8, text, rest)) return error.Underflow;
                }

                return error.Malformed;
            }

            inline for (text, 0..) |byte, offset| {
                if (rest[offset] != byte) return error.Malformed;
            }

            scanner.index += @intCast(text.len);

            scanner.value_finish();

            assert(scanner.index <= scanner.input.len);

            return comptime literal.kind();
        }

        inline fn string_read(scanner: *@This()) Error!void {
            assert(scanner.peek() == '"');
            assert(scanner.index < scanner.input.len);

            const input = scanner.input;
            const quote = scanner.index;

            scanner.index += 1;

            const position = special_find(input, scanner.index);

            if (position == input.len) {
                if (window) return error.Underflow;

                scanner.index = quote;

                return error.Malformed;
            }

            if (input[position] == '"') {
                scanner.index = position + 1;

                return;
            }

            const outcome = string_rest_read(mode.input, input, position);

            scanner.index = outcome.index;

            if (window) {
                if (outcome.truncated) return error.Underflow;
            }

            if (!outcome.valid) {
                if (outcome.index == input.len) scanner.index = quote;

                return error.Malformed;
            }
        }

        inline fn number_finish(scanner: *@This(), comptime negative: bool) Error!Kind {
            assert(scanner.index < scanner.input.len);

            if (negative) assert(scanner.peek() == '-');

            try scanner.number_read(negative);

            scanner.value_finish();

            return .number;
        }

        inline fn number_read(scanner: *@This(), comptime negative: bool) Error!void {
            assert(scanner.index < scanner.input.len);

            if (number_chunk_enabled) {
                const length = number_length_chunk(scanner.input, scanner.index, negative);

                if (length > 0) {
                    scanner.index += length;

                    return;
                }
            }

            if (window) return scanner.number_read_window(negative);

            const input = scanner.input;
            const start = scanner.index;
            var index = start + @intFromBool(negative);
            if (index == input.len) return error.Malformed;

            switch (input[index]) {
                '0' => index += 1,
                '1'...'9' => index = digits_skip(input, index),
                else => return error.Malformed,
            }

            if (byte_is(input, index, '.')) index = try digits_required(input, index + 1);

            if (byte_is_folded(input, index, 'e')) index = try exponent_read(input, index + 1);

            scanner.index = index;

            assert(scanner.index > start);
        }

        fn number_read_window(scanner: *@This(), comptime negative: bool) Error!void {
            comptime assert(window);
            assert(scanner.index < scanner.input.len);

            const input = scanner.input;
            const start = scanner.index;
            var index = start + @intFromBool(negative);
            if (index == input.len) return error.Underflow;

            switch (input[index]) {
                '0' => index += 1,
                '1'...'9' => index = digits_skip(input, index),
                else => return error.Malformed,
            }

            if (byte_is(input, index, '.')) index = try digits_window(input, index + 1);

            if (byte_is_folded(input, index, 'e')) index = try exponent_window(input, index + 1);

            if (index == input.len) return error.Underflow;

            scanner.index = index;

            assert(scanner.index > start);
        }

        inline fn blank_skip(scanner: *@This()) Error!void {
            comptime assert(syntax == .relaxed);
            assert(scanner.peek() == '/');

            if (window) return scanner.blank_skip_window();

            const outcome = blank_end(scanner.input, scanner.index);

            scanner.index = outcome.index;

            if (!outcome.valid) return error.Malformed;
        }

        fn blank_skip_window(scanner: *@This()) Error!void {
            comptime assert(window);
            assert(scanner.peek() == '/');

            const blank = blank_end_window(scanner.input, scanner.index);

            scanner.index = blank.index;

            switch (blank.ending) {
                .complete => {},
                .malformed => return error.Malformed,
                .truncated => {
                    scanner.commit = blank.index;

                    return error.Underflow;
                },
            }

            assert(scanner.index <= scanner.input.len);
        }

        inline fn non_finite_fallback(scanner: *@This(), failure: Error) Error!Kind {
            comptime assert(window);
            assert(scanner.index < scanner.input.len);
            assert(failure != error.DepthExceeded);

            if (failure == error.Underflow) return error.Underflow;
            return scanner.non_finite_read();
        }

        inline fn non_finite_is(scanner: *const @This()) bool {
            comptime assert(syntax == .relaxed);
            assert(scanner.index <= scanner.input.len);

            return non_finite_starts(scanner.input, scanner.index);
        }

        inline fn non_finite_read(scanner: *@This()) Error!Kind {
            comptime assert(syntax == .relaxed);
            assert(scanner.index < scanner.input.len);

            if (window) {
                if (non_finite_truncated(scanner.input, scanner.index)) return error.Underflow;
            }

            const end = non_finite_end(scanner.input, scanner.index) orelse return error.Malformed;

            scanner.index = end;

            scanner.value_finish();

            assert(scanner.index <= scanner.input.len);

            return .number;
        }

        inline fn indent_skip(scanner: *@This()) void {
            assert(scanner.depth <= depth_max);
            assert(scanner.index <= scanner.input.len);

            if (scanner.index == scanner.input.len) return;
            if (scanner.input[scanner.index] != '\n') return;

            const depth = @min(scanner.depth, indent_depth_count - 1);
            const indent = &scanner.frames.indents[depth][@backingInt(scanner.state)];

            if (indent_matches(scanner.input, scanner.index, indent.*)) {
                scanner.index += indent.*;

                return;
            }

            scanner.index = indent_learn(scanner.input, scanner.index, indent);

            assert(scanner.index <= scanner.input.len);
        }

        inline fn whitespace_skip(scanner: *@This()) void {
            assert(scanner.depth <= depth_max);
            assert(scanner.index <= scanner.input.len);

            while (scanner.index < scanner.input.len) : (scanner.index += 1) {
                switch (scanner.input[scanner.index]) {
                    ' ', '\t', '\r' => {},
                    '\n' => {
                        @branchHint(.unlikely);

                        return scanner.indent_skip();
                    },
                    else => return,
                }
            }

            assert(scanner.index == scanner.input.len);
        }

        inline fn peek(scanner: *const @This()) u8 {
            assert(scanner.index <= scanner.input.len);

            if (scanner.index == scanner.input.len) return 0;

            const byte = scanner.input[scanner.index];
            return byte;
        }

        inline fn top(scanner: *const @This()) Container {
            assert(scanner.depth > 0);
            assert(scanner.depth <= depth_max);

            return scanner.frames.stack[scanner.depth - 1];
        }
    };
}

pub inline fn number_end(
    input: []const u8,
    start: u32,
    comptime negative: bool,
) Tokenizer.Error!u32 {
    assert(start < input.len);
    if (negative) assert(input[start] == '-');

    const length = if (number_chunk_enabled) number_length_chunk(input, start, negative) else 0;
    const end = if (length > 0) start + length else try number_end_scalar(input, start, negative);

    assert(end > start);

    return end;
}

inline fn number_end_scalar(
    input: []const u8,
    start: u32,
    comptime negative: bool,
) Tokenizer.Error!u32 {
    assert(start < input.len);
    if (negative) assert(input[start] == '-');

    var index = start + @intFromBool(negative);
    if (index == input.len) return error.Malformed;

    switch (input[index]) {
        '0' => index += 1,
        '1'...'9' => index = digits_skip(input, index),
        else => return error.Malformed,
    }

    if (byte_is(input, index, '.')) index = try digits_required(input, index + 1);

    if (byte_is_folded(input, index, 'e')) index = try exponent_read(input, index + 1);

    assert(index > start);

    return index;
}

const scalar_end_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (" \t\n\r,:[]{}") |byte| table[byte] = true;

    break :table table;
};

pub inline fn scalar_ended(input: []const u8, end: u32) bool {
    assert(end <= input.len);
    assert(end > 0);

    if (end == input.len) return true;
    return scalar_end_table[input[end]];
}

fn comma_after(comptime syntax: Syntax, container: Container) State {
    return switch (syntax) {
        .relaxed => if (container == .object) .key_or_end else .value_or_end,
        .strict => if (container == .object) .key else .value,
    };
}

noinline fn blank_end(input: []const u8, start: u32) Outcome {
    assert(start < input.len);
    assert(input[start] == '/');

    var index = start;

    for (0..input.len - start + 1) |_| {
        const end = comment_end(input, index) orelse return .{ .index = index, .valid = false };

        index = whitespace_end(input, end);

        if (!byte_is(input, index, '/')) return .{ .index = index, .valid = true };
    }

    unreachable;
}

noinline fn blank_end_window(input: []const u8, start: u32) Blank {
    assert(start < input.len);
    assert(input[start] == '/');

    var index = start;

    for (0..input.len - start + 1) |_| {
        const end = switch (comment_end_window(input, index)) {
            .complete => |end| end,
            .malformed => return .{ .ending = .malformed, .index = index },
            .truncated => return .{ .ending = .truncated, .index = index },
        };

        index = whitespace_end(input, end);

        if (!byte_is(input, index, '/')) return .{ .ending = .complete, .index = index };
    }

    unreachable;
}

fn comment_end_window(input: []const u8, start: u32) Comment {
    assert(start < input.len);
    assert(input[start] == '/');

    if (start + 1 == input.len) return .truncated;

    const close = switch (input[start + 1]) {
        '*' => std.mem.findPos(u8, input, start + 2, "*/"),
        '/' => std.mem.findAnyPos(u8, input, start + 2, "\n\r"),
        else => return .malformed,
    };

    const found = close orelse return .truncated;
    const end: u32 = @intCast(if (input[start + 1] == '*') found + 2 else found);

    assert(end >= start + 2);
    assert(end <= input.len);

    return .{ .complete = end };
}

inline fn comment_end(input: []const u8, start: u32) ?u32 {
    assert(start < input.len);
    assert(input[start] == '/');

    if (start + 1 == input.len) return null;

    const end: u32 = switch (input[start + 1]) {
        '*' => end: {
            const close = std.mem.findPos(u8, input, start + 2, "*/") orelse return null;

            break :end @intCast(close + 2);
        },
        '/' => end: {
            const line_end = std.mem.findAnyPos(u8, input, start + 2, "\n\r");

            break :end @intCast(line_end orelse input.len);
        },
        else => return null,
    };

    assert(end >= start + 2);
    assert(end <= input.len);

    return end;
}

noinline fn indent_learn(input: []const u8, start: u32, indent: *u8) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const end = whitespace_end(input, start);

    indent.* = @intCast(@min(end - start, lane_count));

    assert(end <= input.len);

    return end;
}

inline fn indent_matches(input: []const u8, start: u32, indent: u8) bool {
    assert(start <= input.len);
    assert(indent <= lane_count);

    if (indent == 0) return false;
    if (indent == lane_count) return false;
    if (input.len - start < lane_count) return false;

    const chunk: Chunk = input[start..][0..lane_count].*;
    const blank: u64 = chunk_blank_mask(&chunk);
    const run = (@as(u64, 1) << @intCast(indent)) - 1;

    return blank & (run << 1 | 1) == run;
}

fn chunk_blank_mask(chunk: *const Chunk) Mask {
    assert(lane_count == @typeInfo(Chunk).vector.len);
    assert(lane_count <= 64);

    const bytes = chunk.*;
    const space = bytes == @as(Chunk, @splat(' '));
    const tab = bytes == @as(Chunk, @splat('\t'));
    const line_feed = bytes == @as(Chunk, @splat('\n'));
    const carriage_return = bytes == @as(Chunk, @splat('\r'));

    const blank: Lanes = @intFromBool(space) | @intFromBool(tab) | @intFromBool(line_feed) |
        @intFromBool(carriage_return);

    return @bitCast(blank);
}

inline fn whitespace_end(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    var index = start;

    while (index < input.len) : (index += 1) {
        switch (input[index]) {
            ' ', '\t', '\n', '\r' => {},
            else => break,
        }
    }

    assert(index <= input.len);

    return index;
}

noinline fn non_finite_end(input: []const u8, index: u32) ?u32 {
    assert(index < input.len);
    assert(input.len <= input_bytes_max);

    const start = index + @intFromBool(input[index] == '-');
    const rest = input[start..];

    const length: u32 = for (non_finite_spellings) |spelling| {
        if (std.ascii.startsWithIgnoreCase(rest, spelling)) break @intCast(spelling.len);
    } else return null;

    const result = start + length;

    assert(result <= input.len);

    return result;
}

fn non_finite_truncated(input: []const u8, index: u32) bool {
    assert(index < input.len);
    assert(input.len <= input_bytes_max);

    const start = index + @intFromBool(input[index] == '-');
    const rest = input[start..];

    for (non_finite_prefixes) |spelling| {
        if (rest.len < spelling.len) {
            if (std.ascii.startsWithIgnoreCase(spelling, rest)) return true;
        }
    }

    return false;
}

inline fn non_finite_starts(input: []const u8, index: u32) bool {
    assert(index <= input.len);
    assert(input.len <= input_bytes_max);

    const signed = byte_is(input, index, '-');
    const letter = index + @intFromBool(signed);
    if (letter >= input.len) return false;

    return switch (input[letter]) {
        'I', 'N', 'i' => true,
        'n' => signed or byte_is_folded(input, letter + 1, 'a'),
        else => false,
    };
}

fn byte_is_folded(input: []const u8, index: u32, lower: u8) bool {
    assert(index <= input.len);
    assert(std.ascii.isLower(lower));

    if (index == input.len) return false;
    return std.ascii.toLower(input[index]) == lower;
}

pub fn position_of(input: []const u8, index: u32) Position {
    assert(input.len <= input_bytes_max);
    assert(index <= input.len);

    var result: Position = .{ .column = 1, .line = 1 };

    for (input[0..index]) |byte| {
        if (byte == '\n') {
            result.line += 1;
            result.column = 1;
        } else {
            result.column += 1;
        }
    }

    assert(result.line >= 1);

    return result;
}

inline fn special_find(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const scan = chunks_scan(input, start);
    const result = if (scan.found) scan.index else tail_scan(input, scan.index);

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

const Scan = struct {
    found: bool,
    index: u32,
};

inline fn chunks_scan(input: []const u8, start: u32) Scan {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    var result: Scan = .{ .found = false, .index = start };

    for (0..@divFloor(input.len, lane_count) + 1) |_| {
        if (input.len - result.index < lane_count) break;

        const chunk: Chunk = input[result.index..][0..lane_count].*;

        if (chunk_special_first(&chunk)) |offset| {
            result = .{ .found = true, .index = result.index + offset };

            break;
        }

        result.index += lane_count;
    }

    assert(result.index <= input.len);

    return result;
}

inline fn tail_scan(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len - start < lane_count);

    var result: u32 = @intCast(input.len);

    for (start..input.len) |position| {
        switch (input[position]) {
            0x00...0x1f, '"', '\\', 0x80...0xff => {
                result = @intCast(position);

                break;
            },
            else => {},
        }
    }

    assert(result <= input.len);

    return result;
}

fn chunk_special_first(chunk: *const Chunk) ?u32 {
    assert(lane_count == @typeInfo(Chunk).vector.len);
    assert(lane_count <= 64);

    const bytes = chunk.*;
    const printable_low: Chunk = @splat(0x20);
    const printable_span: Chunk = @splat(0x60);
    const outside = (bytes -% printable_low) >= printable_span;
    const quote = bytes == @as(Chunk, @splat('"'));
    const backslash = bytes == @as(Chunk, @splat('\\'));
    const special: Lanes = @intFromBool(outside) | @intFromBool(quote) | @intFromBool(backslash);
    const mask: Mask = @bitCast(special);
    if (mask == 0) return null;

    const offset: u32 = @ctz(mask);

    assert(offset < lane_count);

    return offset;
}

noinline fn string_rest_read(
    comptime input_mode: Input,
    input: []const u8,
    start: u32,
) OutcomeType(input_mode) {
    assert(start < input.len);
    assert(input[start] != '"');

    var index = start;
    var position = start;
    var wide_tried = false;

    for (0..input.len) |_| {
        switch (input[position]) {
            '"' => return string_ended(input_mode, input, position + 1, .valid),
            '\\' => {
                const length = escape_length(input[position..]) catch {
                    return string_refused(input_mode, input, position, .escape);
                };

                index = position + length;
            },
            0x00...0x1f => return string_ended(input_mode, input, position, .invalid),
            0x80...0xff => {
                if (!wide_tried) {
                    wide_tried = true;

                    if (string_end_find_wide(input, position)) |end| {
                        return string_ended(input_mode, input, end, .valid);
                    }
                }

                const length = utf8_length(input, position) catch {
                    return string_refused(input_mode, input, position, .utf8);
                };

                index = position + length;
            },
            else => unreachable,
        }

        position = special_find(input, index);

        if (position == input.len) {
            const end = if (input_mode == .complete) position else index;

            return string_ended(input_mode, input, end, .truncated);
        }
    }

    return string_ended(input_mode, input, index, .invalid);
}

fn OutcomeType(comptime input_mode: Input) type {
    return switch (input_mode) {
        .complete => Outcome,
        .window => WindowOutcome,
    };
}

inline fn string_ended(
    comptime input_mode: Input,
    input: []const u8,
    index: u32,
    verdict: Verdict,
) OutcomeType(input_mode) {
    if (input_mode == .window) assert(index <= input.len);

    const outcome = string_outcome(input, index, verdict == .valid);

    return switch (input_mode) {
        .complete => outcome,
        .window => .{
            .index = outcome.index,
            .truncated = verdict == .truncated,
            .valid = outcome.valid,
        },
    };
}

inline fn string_refused(
    comptime input_mode: Input,
    input: []const u8,
    position: u32,
    comptime cause: Cause,
) OutcomeType(input_mode) {
    assert(position < input.len);

    const truncated = switch (input_mode) {
        .complete => false,
        .window => switch (cause) {
            .escape => escape_truncated(input[position..]),
            .utf8 => utf8_truncated(input, position),
        },
    };

    return string_ended(input_mode, input, position, if (truncated) .truncated else .invalid);
}

fn escape_truncated(text: []const u8) bool {
    assert(text.len > 0);
    assert(text[0] == '\\');

    if (text.len < 2) return true;
    if (text[1] != 'u') return false;
    if (text.len >= 12) return false;

    const length: u32 = @intCast(@min(text.len, 6));

    for (text[2..length]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }

    if (text.len < 6) return true;

    const unit = code_unit_of(text) catch return false;
    if (unit < 0xd800) return false;
    if (unit > 0xdbff) return false;
    return surrogate_low_prefix_is(text[6..]);
}

fn surrogate_low_prefix_is(text: []const u8) bool {
    assert(text.len < 6);
    assert(surrogate_low_template.len == 6);

    for (text, surrogate_low_template[0..text.len]) |byte, allowed| {
        if (std.mem.findScalar(u8, allowed, byte) == null) return false;
    }

    return true;
}

fn utf8_truncated(input: []const u8, index: u32) bool {
    assert(index < input.len);
    assert(input[index] >= 0x80);

    const lead = input[index];
    const length = std.unicode.utf8ByteSequenceLength(lead) catch return false;
    const available: u32 = @intCast(input.len - index);
    if (length <= available) return false;
    if (lead < 0xc2) return false;
    if (lead > 0xf4) return false;

    for (input[index + 1 ..], 1..) |byte, offset| {
        const range = if (offset == 1) continuation_range(lead) else continuation_any;
        if (byte < range[0]) return false;
        if (byte > range[1]) return false;
    }

    return true;
}

fn continuation_range(lead: u8) Range {
    assert(lead >= 0xc2);
    assert(lead <= 0xf4);

    return switch (lead) {
        0xe0 => .{ 0xa0, 0xbf },
        0xed => .{ 0x80, 0x9f },
        0xf0 => .{ 0x90, 0xbf },
        0xf4 => .{ 0x80, 0x8f },
        else => continuation_any,
    };
}

fn string_outcome(input: []const u8, index: u32, valid: bool) Outcome {
    assert(index > 0);
    assert(index <= input.len);

    const result: Outcome = .{ .index = index, .valid = valid };

    if (result.valid) assert(input[result.index - 1] == '"');

    return result;
}

const string_end_find_wide = if (structural.functions_aligned)
    string_end_find_wide_aligned
else
    string_end_find_wide_unaligned;

noinline fn string_end_find_wide_aligned(input: []const u8, start: u32) align(64) ?u32 {
    assert(start < input.len);
    assert(input[start] >= 0x80);

    var index = start;
    var previous: Chunk = @splat(0);
    var high_previous: Mask = 0;

    for (0..input.len + 1) |_| {
        const chunk = chunk_padded(input, index);
        const stops = chunk_stop_mask(&chunk);
        const span: u32 = @ctz(stops);
        const through = lanes_through(span);
        const high = chunk_high_mask(&chunk);
        const pending = (high & through) | (high_previous >> (lane_count - 3));

        if (pending != 0) {
            const window: UTF8.Window = .{ .current = chunk, .previous = previous };
            const errors = UTF8.errors_compare(&window);
            if (errors & through != 0) return null;
        }

        if (stops == 0) {
            previous = chunk;
            high_previous = high;
            index += lane_count;

            continue;
        }

        const position = index + span;
        if (position >= input.len) return null;

        switch (input[position]) {
            '"' => {
                const end = position + 1;

                assert(end <= input.len);

                return end;
            },
            '\\' => {
                const length = escape_length(input[position..]) catch return null;

                index = position + length;
                previous = @splat(0);
                high_previous = 0;
            },
            else => return null,
        }
    }

    return null;
}

noinline fn string_end_find_wide_unaligned(input: []const u8, start: u32) ?u32 {
    assert(start < input.len);
    assert(input[start] >= 0x80);

    var index = start;
    var previous: Chunk = @splat(0);
    var high_previous: Mask = 0;

    for (0..input.len + 1) |_| {
        const chunk = chunk_padded(input, index);
        const stops = chunk_stop_mask(&chunk);
        const span: u32 = @ctz(stops);
        const through = lanes_through(span);
        const high = chunk_high_mask(&chunk);
        const pending = (high & through) | (high_previous >> (lane_count - 3));

        if (pending != 0) {
            const window: UTF8.Window = .{ .current = chunk, .previous = previous };
            const errors = UTF8.errors_compare(&window);
            if (errors & through != 0) return null;
        }

        if (stops == 0) {
            previous = chunk;
            high_previous = high;
            index += lane_count;

            continue;
        }

        const position = index + span;
        if (position >= input.len) return null;

        switch (input[position]) {
            '"' => {
                const end = position + 1;

                assert(end <= input.len);

                return end;
            },
            '\\' => {
                const length = escape_length(input[position..]) catch return null;

                index = position + length;
                previous = @splat(0);
                high_previous = 0;
            },
            else => return null,
        }
    }

    return null;
}

fn chunk_padded(input: []const u8, index: u32) Chunk {
    assert(index <= input.len);
    assert(input.len <= input_bytes_max);

    if (input.len - index >= lane_count) return input[index..][0..lane_count].*;

    var bytes: [lane_count]u8 = @splat(0);

    @memcpy(bytes[0 .. input.len - index], input[index..]);

    return bytes;
}

fn chunk_stop_mask(chunk: *const Chunk) Mask {
    assert(lane_count == @typeInfo(Chunk).vector.len);
    assert(lane_count <= 64);

    const bytes = chunk.*;
    const control = bytes < @as(Chunk, @splat(0x20));
    const quote = bytes == @as(Chunk, @splat('"'));
    const backslash = bytes == @as(Chunk, @splat('\\'));
    const stops: Lanes = @intFromBool(control) | @intFromBool(quote) | @intFromBool(backslash);

    return @bitCast(stops);
}

fn chunk_high_mask(chunk: *const Chunk) Mask {
    assert(lane_count == @typeInfo(Chunk).vector.len);
    assert(lane_count <= 64);

    const high: Lanes = @intFromBool(chunk.* >= @as(Chunk, @splat(0x80)));
    return @bitCast(high);
}

fn lanes_through(span: u32) Mask {
    assert(span <= lane_count);
    assert(lane_count <= 32);

    const lanes: u64 = (@as(u64, 2) << @intCast(span)) - 1;
    return @truncate(lanes);
}

fn byte_is(input: []const u8, index: u32, byte: u8) bool {
    assert(index <= input.len);
    assert(byte > ' ');

    if (index == input.len) return false;
    return input[index] == byte;
}

noinline fn number_length_chunk(input: []const u8, start: u32, comptime negative: bool) u32 {
    assert(start < input.len);
    if (negative) assert(input[start] == '-');

    if (input.len - start < lane_count) return 0;

    const bytes: Chunk = input[start..][0..lane_count].*;
    const dots: Chunk = @splat('.');
    const exponents: Chunk = @splat('e');
    const lowercase: Chunk = @splat(0x20);
    const tens: Chunk = @splat(10);
    const zeros: Chunk = @splat('0');
    const digit: Mask = @bitCast(@as(Lanes, @intFromBool(bytes -% zeros < tens)));
    const dot: Mask = @bitCast(@as(Lanes, @intFromBool(bytes == dots)));
    const exponent: Mask = @bitCast(@as(Lanes, @intFromBool(bytes | lowercase == exponents)));
    const first: u32 = @intFromBool(negative);
    if (digit >> first & 1 == 0) return 0;

    var end = if (input[start + first] == '0') first + 1 else run_end(digit, first);
    if (end >= lane_count) return 0;

    if (dot >> @intCast(end) & 1 != 0) {
        const fraction = end + 1;

        end = run_end(digit, fraction);

        if (end >= lane_count) return 0;
        if (end == fraction) return 0;
    }

    if (exponent >> @intCast(end) & 1 != 0) {
        if (end + 1 == lane_count) return 0;

        const minuses: Chunk = @splat('-');
        const pluses: Chunk = @splat('+');
        const minus: Mask = @bitCast(@as(Lanes, @intFromBool(bytes == minuses)));
        const plus: Mask = @bitCast(@as(Lanes, @intFromBool(bytes == pluses)));
        const sign = (plus | minus) >> @intCast(end + 1) & 1;
        const power = end + 1 + sign;

        end = run_end(digit, power);

        if (end >= lane_count) return 0;
        if (end == power) return 0;
    }

    assert(end > first);
    assert(end < lane_count);

    return end;
}

fn run_end(digit: Mask, start: u32) u32 {
    comptime assert(@bitSizeOf(@TypeOf(digit)) == lane_count);
    assert(start <= lane_count);

    const other = ~@as(u64, digit);
    const result: u32 = start + @ctz(other >> @intCast(start));

    assert(result <= lane_count);

    return result;
}

inline fn digits_skip(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    if (input.len - start >= digit_lane_count) {
        const chunk: Digits = input[start..][0..digit_lane_count].*;
        const offsets = chunk -% @as(Digits, @splat('0'));
        const mask: DigitMask = @bitCast(offsets >= @as(Digits, @splat(10)));

        if (mask != 0) {
            const end = start + @ctz(mask);

            assert(end < input.len);

            return end;
        }
    }

    return digits_skip_long(input, start);
}

inline fn digits_skip_long(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    var index = start;

    for (0..@divFloor(input.len, digit_lane_count) + 1) |_| {
        if (input.len - index < digit_lane_count) break;

        const chunk: Digits = input[index..][0..digit_lane_count].*;
        const offsets = chunk -% @as(Digits, @splat('0'));
        const outside = @intFromBool(offsets >= @as(Digits, @splat(10)));
        const mask: DigitMask = @bitCast(outside);

        if (mask != 0) {
            const end = index + @ctz(mask);

            assert(end < input.len);

            return end;
        }

        index += digit_lane_count;
    }

    while (index < input.len) : (index += 1) {
        if (!std.ascii.isDigit(input[index])) break;
    }

    assert(index >= start);

    return index;
}

inline fn digits_required(input: []const u8, start: u32) Tokenizer.Error!u32 {
    assert(start <= input.len);

    const end = digits_skip(input, start);
    if (end == start) return error.Malformed;
    return end;
}

fn digits_window(input: []const u8, start: u32) ScanError!u32 {
    assert(start <= input.len);
    assert(start > 0);

    if (start == input.len) return error.Underflow;

    const end = digits_skip(input, start);
    if (end == start) return error.Malformed;
    return end;
}

fn exponent_window(input: []const u8, start: u32) ScanError!u32 {
    assert(start <= input.len);
    assert(start > 0);

    var index = start;

    if (byte_is(input, index, '+')) index += 1;

    if (byte_is(input, index, '-')) {
        if (index == start) index += 1;
    }

    return digits_window(input, index);
}

inline fn exponent_read(input: []const u8, start: u32) Tokenizer.Error!u32 {
    assert(start <= input.len);
    assert(start > 0);

    var index = start;

    if (byte_is(input, index, '+')) index += 1;

    if (byte_is(input, index, '-')) {
        if (index == start) index += 1;
    }

    return digits_required(input, index);
}

fn utf8_length(input: []const u8, index: u32) Tokenizer.Error!u32 {
    assert(index < input.len);
    assert(input[index] >= 0x80);

    const length = std.unicode.utf8ByteSequenceLength(input[index]) catch return error.Malformed;
    if (length > input.len - index) return error.Malformed;

    _ = std.unicode.utf8Decode(input[index..][0..length]) catch return error.Malformed;

    return length;
}

pub fn escape_length(text: []const u8) error{Malformed}!u32 {
    assert(text.len > 0);
    assert(text[0] == '\\');

    if (text.len < 2) return error.Malformed;

    switch (text[1]) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => return 2,
        'u' => {
            const unit = try code_unit_of(text);

            switch (unit) {
                0xd800...0xdbff => {},
                0xdc00...0xdfff => return error.Malformed,
                else => return 6,
            }

            if (text.len < 12) return error.Malformed;
            if (text[6] != '\\') return error.Malformed;

            const low = try code_unit_of(text[6..]);
            if (low < 0xdc00) return error.Malformed;
            if (low > 0xdfff) return error.Malformed;
            return 12;
        },
        else => return error.Malformed,
    }
}

const hex_invalid: u8 = 0xff;

const hex_table: [256]u8 = table: {
    var table: [256]u8 = @splat(hex_invalid);

    for ("0123456789abcdef", 0..) |byte, value| table[byte] = value;
    for ("ABCDEF", 10..) |byte, value| table[byte] = value;

    break :table table;
};

pub fn code_unit_of(text: []const u8) error{Malformed}!u16 {
    assert(text.len >= 2);
    assert(text[0] == '\\');

    if (text[1] != 'u') return error.Malformed;
    if (text.len < 6) return error.Malformed;

    const first = hex_table[text[2]];
    const second = hex_table[text[3]];
    const third = hex_table[text[4]];
    const fourth = hex_table[text[5]];
    if ((first | second | third | fourth) > 0x0f) return error.Malformed;

    const result = @as(u16, first) << 12 | @as(u16, second) << 8 | @as(u16, third) << 4 | fourth;

    assert(result >> 12 == first);
    assert(result & 0x0f == fourth);

    return result;
}

const testing = std.testing;
const strict_mode: Mode = .{ .input = .complete, .syntax = .strict, .values = .single };

fn expect_tokens(input: []const u8, expected: []const Token) !void {
    assert(input.len > 0);
    assert(expected.len > 0);

    var tokenizer: Tokenizer = .init(input);

    for (expected) |token_expected| {
        const token = try tokenizer.next();

        try testing.expectEqualDeep(token_expected, token);
    }

    const last = try tokenizer.next();

    try testing.expectEqualDeep(Token.end, last);
}

fn refused(input: []const u8) bool {
    assert(input.len <= input_bytes_max);

    var tokenizer: Tokenizer = .init(input);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch return true;
        if (token == .end) return false;
    }

    unreachable;
}

test "objects, arrays, and scalars tokenize in order" {
    try expect_tokens(
        \\{"name": "seed", "private": false, "parameters": [1, -2.5e3, null], "doc": "a \"b\""}
    , &.{
        .object_begin,
        .{ .key = "name" },
        .{ .string = "seed" },
        .{ .key = "private" },
        .{ .boolean = false },
        .{ .key = "parameters" },
        .array_begin,
        .{ .number = "1" },
        .{ .number = "-2.5e3" },
        .null_value,
        .array_end,
        .{ .key = "doc" },
        .{ .string = "a \\\"b\\\"" },
        .object_end,
    });
}

test "empty containers and a bare scalar tokenize" {
    try expect_tokens("[]", &.{ .array_begin, .array_end });
    try expect_tokens("{ }", &.{ .object_begin, .object_end });
    try expect_tokens(" true ", &.{.{ .boolean = true }});
}

test "a long string is scanned in chunks and stops at the first special byte" {
    const run_a: [70]u8 = @splat('a');
    const run_b: [40]u8 = @splat('b');
    const run_c: [33]u8 = @splat('c');
    const text = "\"" ++ run_a ++ "\\n" ++ run_b ++ "\u{e9}" ++ run_c ++ "\"";

    try expect_tokens(text, &.{.{ .string = text[1 .. text.len - 1] }});
    try testing.expect(refused("\"" ++ run_b ++ "\x01" ++ run_b ++ "\""));
    try testing.expect(refused("\"" ++ run_a ++ "\xc3"));
    try testing.expect(refused("\"" ++ run_a ++ run_b));
}

test "malformed documents are refused" {
    const inputs = [_][]const u8{
        "{\"a\" 1}",
        "{\"a\": 1,}",
        "[1 2]",
        "[1,]",
        "{1: 2}",
        "\"unterminated",
        "\"bad \\x escape\"",
        "[}",
        "nul",
        "[1] [2]",
        "01",
        "-",
        "1.",
        "1e",
        "1e+",
        "1-2",
        "81e05E+4",
        "\"\\ud83d\\ud000\"",
        "\"\\udc00\"",
        "1.5e3e3",
        ".5",
        "\"\xff\"",
        "\"\xed\xa0\x80\"",
        "\"\xc0\xaf\"",
        "",
        " ",
    };

    for (inputs) |input| try testing.expect(refused(input));
}

test "nesting deeper than depth_max is refused" {
    const deep: [depth_max + 1]u8 = @splat('[');
    var tokenizer: Tokenizer = .init(&deep);

    for (0..depth_max) |_| {
        const token = try tokenizer.next();

        try testing.expectEqualDeep(Token.array_begin, token);
    }

    const result = tokenizer.next();

    try testing.expectError(error.DepthExceeded, result);
}

fn zeros_build(buffer: []u8, count: u32) u32 {
    assert(buffer.len >= 2 * count + 1);
    assert(count > 0);

    buffer[0] = '[';

    var length: u32 = 1;

    for (0..count) |_| {
        buffer[length] = '0';

        buffer[length + 1] = ',';
        length += 2;
    }

    assert(length == 2 * count + 1);

    return length;
}

test "events refill across batches and a later failure keeps its position" {
    const count = 2 * event_capacity + 3;
    var buffer: [2 * count + 2]u8 = undefined;
    const length = zeros_build(&buffer, count);

    buffer[length] = 'x';

    var tokenizer: Tokenizer = .init(buffer[0 .. length + 1]);
    const begin = try tokenizer.next();

    try testing.expectEqualDeep(Token.array_begin, begin);

    for (0..count) |position| {
        const token = try tokenizer.next();

        try testing.expectEqualDeep(Token{ .number = "0" }, token);
        try testing.expectEqual(@as(u32, @intCast(2 * position + 2)), tokenizer.index);
    }

    for (0..2) |_| {
        const failed = tokenizer.next();

        try testing.expectError(error.Malformed, failed);
        try testing.expectEqual(length, tokenizer.index);
    }
}

test "the end token repeats once the document is exhausted" {
    var tokenizer: Tokenizer = .init(" [ ] ");
    const begin = try tokenizer.next();
    const end = try tokenizer.next();

    try testing.expectEqualDeep(Token.array_begin, begin);
    try testing.expectEqualDeep(Token.array_end, end);

    for (0..3) |_| {
        const token = try tokenizer.next();

        try testing.expectEqualDeep(Token.end, token);
        try testing.expectEqual(@as(u32, 5), tokenizer.index);
        try testing.expectEqual(@as(u32, 0), tokenizer.depth);
    }
}

test "skip crosses batches and leaves the span of the skipped value" {
    const count = event_capacity + 7;
    const head = "{\"a\": ";
    const tail = "0], \"b\": 1}";
    var buffer: [head.len + 2 * count + 1 + tail.len]u8 = undefined;

    @memcpy(buffer[0..head.len], head);

    const length = zeros_build(buffer[head.len..], count);

    @memcpy(buffer[head.len + length ..][0..tail.len], tail);

    var tokenizer: Tokenizer = .init(buffer[0 .. head.len + length + tail.len]);
    const begin = try tokenizer.next();
    const key = try tokenizer.next();
    const array = try tokenizer.next();

    try testing.expectEqualDeep(Token.object_begin, begin);
    try testing.expectEqualDeep(Token{ .key = "a" }, key);
    try testing.expectEqualDeep(Token.array_begin, array);
    try testing.expectEqual(@as(u32, head.len), tokenizer.value_start);
    try testing.expectEqual(@as(u32, 2), tokenizer.depth);

    try tokenizer.skip(array);

    const close: u32 = @intCast(head.len + length + 2);

    try testing.expectEqual(close, tokenizer.index);
    try testing.expectEqual(@as(u32, 1), tokenizer.depth);

    const name = try tokenizer.next();
    const value = try tokenizer.next();
    const object_end = try tokenizer.next();
    const last = try tokenizer.next();

    try testing.expectEqualDeep(Token{ .key = "b" }, name);
    try testing.expectEqualDeep(Token{ .number = "1" }, value);
    try testing.expectEqualDeep(Token.object_end, object_end);
    try testing.expectEqualDeep(Token.end, last);
}

test "skip passes over a nested member and stops at the next key" {
    var tokenizer: Tokenizer = .init(
        \\{"owner": {"login": "x", "list": [1, {"y": []}]}, "name": "toolchain"}
    );

    const begin = try tokenizer.next();
    const owner = try tokenizer.next();
    const owner_value = try tokenizer.next();

    try tokenizer.skip(owner_value);

    const name = try tokenizer.next();
    const name_value = try tokenizer.next();

    try testing.expectEqualDeep(Token.object_begin, begin);
    try testing.expectEqualDeep(Token{ .key = "owner" }, owner);
    try testing.expectEqualDeep(Token{ .key = "name" }, name);
    try testing.expectEqualDeep(Token{ .string = "toolchain" }, name_value);
}

test "a failure position converts to a line and a column" {
    const input = "{\n  \"a\": 1,\n  \"b\": tru\n}";
    var tokenizer: Tokenizer = .init(input);

    for (0..4) |_| _ = try tokenizer.next();

    const failed = tokenizer.next();

    try testing.expectError(error.Malformed, failed);

    const location = position_of(input, tokenizer.index);

    try testing.expectEqual(@as(u32, 3), location.line);
    try testing.expectEqual(@as(u32, 8), location.column);
}

test "a string cut short is refused at its quote, or at an escape or character the cut splits" {
    const source = "{\"k\\u00e9y\": [\"a\\nb\", \"\u{65e5}\u{672c}\", " ++
        "\"x\\ud83d\\ude00y\"], \"\": \"\"}";
    var quote: ?u32 = null;
    var index: u32 = 0;
    var cut_count: u32 = 0;

    for (0..source.len) |_| {
        if (index == source.len) break;

        const byte = source[index];
        const length: u32 = if (quote == null) 1 else try test_piece_length(source[index..]);

        if (quote) |start| {
            try test_cut_refused_at(source[0..index], start);

            for (index + 1..index + length) |cut| {
                try test_cut_refused_at(source[0..cut], index);
            }

            cut_count += length;

            if (byte == '"') quote = null;
        } else if (byte == '"') {
            quote = index;
        } else {
            assert(quote == null);
        }

        index += length;
    }

    try testing.expectEqual(@as(?u32, null), quote);
    try testing.expectEqual(@as(u32, 38), cut_count);
}

fn test_piece_length(text: []const u8) !u32 {
    assert(text.len > 0);
    assert(text.len < input_bytes_max);

    if (text[0] != '\\') return try std.unicode.utf8ByteSequenceLength(text[0]);
    if (text[1] != 'u') return 2;

    const unit = try std.fmt.parseInt(u16, text[2..6], 16);
    if (unit < 0xd800) return 6;
    if (unit > 0xdbff) return 6;
    return 12;
}

fn test_cut_refused_at(input: []const u8, expected: u32) !void {
    assert(input.len > 0);
    assert(expected < input.len);

    var strict: Tokenizer = .init(input);
    var relaxed: TokenizerType(.relaxed) = .init(input);

    const strict_failure = for (0..input.len + 2) |_| {
        _ = strict.next() catch |err| break err;
    } else unreachable;

    const relaxed_failure = for (0..input.len + 2) |_| {
        _ = relaxed.next() catch |err| break err;
    } else unreachable;

    try testing.expectEqual(error.Malformed, strict_failure);
    try testing.expectEqual(error.Malformed, relaxed_failure);
    try testing.expectEqual(expected, strict.index);
    try testing.expectEqual(expected, relaxed.index);
}

test "a digit run ends at the first non-digit for every run length, offset, and input length" {
    const stops = [_]u8{ 0x00, ' ', ',', '.', '/', ':', 'E', 'e', 0x7f, 0x80, 0xb0, 0xff };
    var buffer: [80]u8 = undefined;

    for (0..48) |run| {
        for (stops) |stop| {
            @memset(&buffer, '0' + @as(u8, @intCast(run % 10)));
            buffer[run] = stop;

            for (0..run + 1) |start| {
                for ([_]usize{ run + 1, run + 17, buffer.len }) |length| {
                    const end = digits_skip(buffer[0..length], @intCast(start));

                    try testing.expectEqual(@as(u32, @intCast(run)), end);
                }

                const unstopped = digits_skip(buffer[0..run], @intCast(start));

                try testing.expectEqual(@as(u32, @intCast(run)), unstopped);
            }
        }
    }
}

fn string_end_reference(input: []const u8) ?u32 {
    assert(input.len >= 1);
    assert(input[0] == '"');

    var index: u32 = 1;

    for (0..input.len) |_| {
        if (index >= input.len) return null;

        const byte = input[index];

        switch (byte) {
            '"' => {
                const end = index + 1;

                assert(end <= input.len);

                return end;
            },
            '\\' => index += escape_length(input[index..]) catch return null,
            0x00...0x1f => return null,
            0x80...0xff => {
                const length = std.unicode.utf8ByteSequenceLength(byte) catch return null;
                if (length > input.len - index) return null;

                _ = std.unicode.utf8Decode(input[index..][0..length]) catch return null;

                index += length;
            },
            else => index += 1,
        }
    }

    return null;
}

fn string_paths_agree(input: []const u8) !void {
    assert(input.len >= 1);
    assert(input[0] == '"');

    const expected = string_end_reference(input);
    var frames: Frames = .{ .indents = @splat(@splat(0)), .stack = undefined };

    var scanner: ScannerType(strict_mode) = .{
        .commit = {},
        .depth = 0,
        .frames = &frames,
        .index = 0,
        .input = input,
        .start = 0,
        .state = .value,
    };

    if (scanner.string_read()) |_| {
        try testing.expectEqual(expected, @as(?u32, scanner.index));
    } else |_| {
        try testing.expectEqual(@as(?u32, null), expected);
    }

    const end = expected orelse return;
    const high = std.mem.findScalarPos(u8, input, 0, 0xc3) orelse return;

    try testing.expectEqual(@as(?u32, end), string_end_find_wide(input, @intCast(high)));
}

fn utf8_string_expect(content: []const u8, buffer: []u8) !void {
    assert(content.len + 2 <= buffer.len);
    assert(buffer.len > 0);

    buffer[0] = '"';

    @memcpy(buffer[1..][0..content.len], content);
    buffer[content.len + 1] = '"';

    const input = buffer[0 .. content.len + 2];
    const valid = std.unicode.utf8ValidateSlice(content);

    try testing.expectEqual(valid, string_end_reference(input) != null);
    try string_paths_agree(input);
    try string_paths_agree(input[0 .. content.len + 1]);
}

const utf8_probes = [_]u8{
    0x20, 0x41, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xe1,
    0xec, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf3, 0xf4, 0xf5, 0xf8, 0xff,
};

fn utf8_content_build(offset: u32, sequence: []const u8, content: []u8) []const u8 {
    assert(offset + sequence.len + 5 <= content.len);
    assert(sequence.len <= 4);

    content[0] = 0xc3;
    content[1] = 0xa9;

    @memset(content[2..][0..offset], 'a');
    @memcpy(content[2 + offset ..][0..sequence.len], sequence);
    @memset(content[2 + offset + sequence.len ..][0..3], 'b');

    return content[0 .. 2 + offset + sequence.len + 3];
}

test "the string fast path agrees with std.unicode and the scalar path on every two-byte pair" {
    var content: [48]u8 = undefined;
    var buffer: [64]u8 = undefined;

    for ([_]u32{ 0, 27, 28, 29, 30 }) |offset| {
        for (0x20..0x100) |first| {
            for (0x20..0x100) |second| {
                const pair = [_]u8{ @intCast(first), @intCast(second) };
                if (std.mem.findAny(u8, &pair, "\"\\") != null) continue;

                try utf8_string_expect(utf8_content_build(offset, &pair, &content), &buffer);
            }
        }
    }
}

fn utf8_lead_expect(offset: u32, lead: u8) !void {
    assert(offset <= 30);
    assert(lead >= 0xe0);

    var content: [48]u8 = undefined;
    var buffer: [64]u8 = undefined;

    for (0x80..0xc0) |second| {
        for (utf8_probes) |third| {
            for (utf8_probes) |fourth| {
                const sequence = [_]u8{ lead, @intCast(second), third, fourth };
                const built = utf8_content_build(offset, &sequence, &content);

                try utf8_string_expect(built, &buffer);
            }
        }
    }
}

test "the string fast path agrees on three- and four-byte sequences at chunk edges" {
    for ([_]u32{ 0, 27, 28, 29 }) |offset| {
        for (0xe0..0xf8) |lead| try utf8_lead_expect(offset, @intCast(lead));
    }
}

test "the string fast path falls back exactly on escapes, control bytes, and truncation" {
    const run: [40]u8 = @splat('a');

    const cases = [_][]const u8{
        "\"plain\"",
        "\"\\n\\u00e9\\ud83d\\ude00\"",
        "\"\\ud83d\\ud000\"",
        "\"\\x\"",
        "\"tab\there\"",
        "\"unterminated",
        "\"\xc3",
        "\"\xe2\x82",
        "\"\xe2\x82\xac\"",
        "\"\xc3\xa9" ++ run ++ "\xf0\x9f\x98\x80" ++ "\\\"" ++ "\xc3\xa9\"",
        "\"\xc3\xa9" ++ run ++ "\\u00e9\xe2\x82\xac\x01\"",
        "\"\xc3\xa9" ++ run ++ "\\q\xe2\x82\xac\"",
        "\"\xc3\xa9\\n" ++ run ++ "\xe2\x82\"",
        "\"\xc3\xa9" ++ run ++ "\xe2\x82\xac",
    };

    for (cases) |input| try string_paths_agree(input);
}

test "taken batches concatenate to the popped stream and keep the index of a late failure" {
    const count = 2 * event_capacity + 3;
    var buffer: [2 * count + 2]u8 = undefined;
    const length = zeros_build(&buffer, count);

    buffer[length] = 'x';

    const input = buffer[0 .. length + 1];
    var taken: Tokenizer = .init(input);
    var popped: Tokenizer = .init(input);
    var batch_count: u32 = 0;
    var event_count: u32 = 0;

    for (0..count + 2) |_| {
        const batch = events_take(.strict, &taken) catch |err| {
            try testing.expectEqual(error.Malformed, err);

            break;
        };

        batch_count += 1;

        for (batch) |event| {
            const expected = try popped.event_pop();

            try testing.expectEqualDeep(expected, event);

            event_count += 1;
        }
    }

    try testing.expectEqual(@as(u32, 3), batch_count);
    try testing.expectEqual(count + 1, event_count);
    try testing.expectError(error.Malformed, popped.event_pop());
    try testing.expectEqual(popped.index, taken.index);
    try testing.expectEqual(length, taken.index);
    try testing.expectError(error.Malformed, events_take(.strict, &taken));
}

test "a reset tokenizer produces the same stream as a fresh one, even after a failure" {
    const failing = "[1, {\"a\": [true, null]}, }";
    const input = "{\"b\": [false, -2.5e3, \"y\\n\"], \"c\": {}}";
    var reset: Tokenizer = .init(failing);

    for (0..failing.len) |_| {
        _ = reset.next() catch break;
    } else return error.FailureMissing;

    tokenizer_reset(.strict, &reset, input);

    var fresh: Tokenizer = .init(input);

    for (0..input.len + 2) |_| {
        const expected = try fresh.next();
        const token = try reset.next();

        try testing.expectEqualDeep(expected, token);
        try testing.expectEqual(fresh.index, reset.index);
        try testing.expectEqual(fresh.depth, reset.depth);

        if (expected == .end) break;
    } else return error.EndMissing;
}

const Pair = struct {
    blanked: []const u8,
    relaxed: []const u8,
};

fn relaxed_blanked_expect(pair: Pair) !void {
    assert(pair.relaxed.len == pair.blanked.len);
    assert(pair.relaxed.len > 0);

    var left: TokenizerType(.relaxed) = .init(pair.relaxed);
    var right: Tokenizer = .init(pair.blanked);

    for (0..pair.relaxed.len + 2) |_| {
        const expected = try right.next();
        const token = try left.next();

        try testing.expectEqualDeep(expected, token);
        try testing.expectEqual(right.index, left.index);
        try testing.expectEqual(right.value_start, left.value_start);

        if (expected == .end) return;
    }

    unreachable;
}

fn relaxed_refused_at(input: []const u8, index: u32) !void {
    assert(input.len > 0);
    assert(index <= input.len);

    var tokenizer: TokenizerType(.relaxed) = .init(input);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch |err| {
            try testing.expectEqual(error.Malformed, err);
            try testing.expectEqual(index, tokenizer.index);

            return;
        };

        if (token == .end) return error.AcceptedUnexpectedly;
    }

    unreachable;
}

fn boundary_is(base: []const u8, index: usize) bool {
    assert(index <= base.len);
    assert(base.len > 0);

    if (index == 0) return true;
    if (index == base.len) return true;
    if (std.mem.findScalar(u8, "{}[],:", base[index - 1]) != null) return true;
    return std.mem.findScalar(u8, "{}[],:", base[index]) != null;
}

test "a comment at every token boundary tokenizes like the same span of spaces" {
    const base = "{\"a\":[1,true,{}],\"b\":{\"c\":null},\"d\":[]}";
    const comments = [_][]const u8{ "/* c */", "//c\n", "//c\r", "/**/", "// x\r\n" };
    var relaxed: [base.len + 8]u8 = undefined;
    var blanked: [base.len + 8]u8 = undefined;
    var boundary_count: u32 = 0;

    for (0..base.len + 1) |index| {
        if (!boundary_is(base, index)) continue;

        boundary_count += 1;

        for (comments) |comment| {
            const length = base.len + comment.len;

            @memcpy(relaxed[0..index], base[0..index]);
            @memcpy(relaxed[index..][0..comment.len], comment);
            @memcpy(relaxed[index + comment.len ..][0 .. base.len - index], base[index..]);
            @memcpy(blanked[0..length], relaxed[0..length]);
            @memset(blanked[index..][0..comment.len], ' ');

            try relaxed_blanked_expect(.{
                .blanked = blanked[0..length],
                .relaxed = relaxed[0..length],
            });
        }
    }

    try testing.expectEqual(@as(u32, 26), boundary_count);
}

test "a trailing comma before each closer tokenizes like a space" {
    const base = "{\"a\":[1,[true],{\"b\":2}],\"c\":{\"d\":[null]}}";
    var relaxed: [base.len + 1]u8 = undefined;
    var blanked: [base.len + 1]u8 = undefined;
    var closer_count: u32 = 0;

    for (0..base.len) |index| {
        const closer = base[index] == ']' or base[index] == '}';
        if (!closer) continue;

        closer_count += 1;

        @memcpy(relaxed[0..index], base[0..index]);
        relaxed[index] = ',';

        @memcpy(relaxed[index + 1 ..], base[index..]);
        @memcpy(&blanked, &relaxed);
        blanked[index] = ' ';

        try relaxed_blanked_expect(.{ .blanked = &blanked, .relaxed = &relaxed });
    }

    try testing.expectEqual(@as(u32, 6), closer_count);
}

test "a byte order mark at the start is skipped, and the strict tokenizer refuses it" {
    const commented = "\xef\xbb\xbf/* c */ {}";

    try relaxed_blanked_expect(.{ .blanked = "   [1, 2]", .relaxed = "\xef\xbb\xbf[1, 2]" });
    try relaxed_blanked_expect(.{ .blanked = "           {}", .relaxed = commented });
    try testing.expect(refused("\xef\xbb\xbf[1, 2]"));

    var tokenizer: TokenizerType(.relaxed) = .init("\xef\xbb\xbf");

    try testing.expectEqual(@as(u32, 3), tokenizer.index);

    const refusal = tokenizer.next();

    try testing.expectError(error.Malformed, refusal);
    try testing.expectEqual(@as(u32, 3), tokenizer.index);

    tokenizer_reset(.relaxed, &tokenizer, "\xef\xbb\xbftrue");

    try testing.expectEqual(@as(u32, 3), tokenizer.index);

    const token = try tokenizer.next();

    try testing.expectEqualDeep(Token{ .boolean = true }, token);
}

test "every letter case of nan, inf, and infinity is a number token holding its spelling" {
    const spellings = [_][]const u8{ "nan", "inf", "infinity" };
    var buffer: [16]u8 = undefined;

    for (spellings) |spelling| {
        const variant_count = @as(u32, 1) << @intCast(spelling.len);

        for (0..variant_count) |variant| {
            for (spelling, 0..) |byte, position| {
                const upper = (variant >> @intCast(position)) & 1 == 1;

                buffer[position + 1] = if (upper) std.ascii.toUpper(byte) else byte;
            }

            buffer[0] = '-';

            const unsigned = buffer[1 .. spelling.len + 1];
            const signed = buffer[0 .. spelling.len + 1];

            for ([_][]const u8{ unsigned, signed }) |text| {
                var tokenizer: TokenizerType(.relaxed) = .init(text);

                const number = try tokenizer.next();
                const end = try tokenizer.next();

                try testing.expectEqualDeep(Token{ .number = text }, number);
                try testing.expectEqualDeep(Token.end, end);
            }

            try testing.expect(refused(unsigned));
            try testing.expect(refused(signed));
        }
    }
}

test "non-finite spellings stand anywhere a value does and null still reads as null" {
    const input = "{\"a\": [NaN, -Infinity, nan, null], \"b\": INF}";
    var tokenizer: TokenizerType(.relaxed) = .init(input);

    const expected = [_]Token{
        .object_begin,
        .{ .key = "a" },
        .array_begin,
        .{ .number = "NaN" },
        .{ .number = "-Infinity" },
        .{ .number = "nan" },
        .null_value,
        .array_end,
        .{ .key = "b" },
        .{ .number = "INF" },
        .object_end,
        .end,
    };

    for (expected) |token_expected| {
        const token = try tokenizer.next();

        try testing.expectEqualDeep(token_expected, token);
    }
}

test "relaxed input refuses what no relaxation covers, at the offending byte" {
    try relaxed_refused_at("[,]", 1);
    try relaxed_refused_at("[1,,]", 3);
    try relaxed_refused_at("{,}", 1);
    try relaxed_refused_at("{\"a\":1,,}", 7);
    try relaxed_refused_at("/", 0);
    try relaxed_refused_at("[1 /]", 3);
    try relaxed_refused_at("[1 /x]", 3);
    try relaxed_refused_at("/* open", 0);
    try relaxed_refused_at("[1, /* open ]", 4);
    try relaxed_refused_at("true /* open", 5);
    try relaxed_refused_at("+inf", 0);
    try relaxed_refused_at("infx", 3);
    try relaxed_refused_at("[infinit]", 4);
    try relaxed_refused_at("-+inf", 0);
    try relaxed_refused_at("-null", 0);
    try relaxed_refused_at("Null", 0);
    try relaxed_refused_at("[1]\xef\xbb\xbf", 3);
    try relaxed_refused_at("[\xef\xbb\xbf1]", 1);
    try relaxed_refused_at("'a'", 0);
    try relaxed_refused_at("{a: 1}", 1);
    try relaxed_refused_at("[1, // open ]", 13);
}

test "the strict tokenizer refuses every relaxation" {
    const inputs = [_][]const u8{
        "/* c */ 1",
        "1 // c",
        "[1,]",
        "{\"a\": 1,}",
        "NaN",
        "-Infinity",
        "inf",
        "\xef\xbb\xbf1",
    };

    for (inputs) |input| try testing.expect(refused(input));
}

test "a comment longer than a batch and a long run of comments refill like whitespace" {
    const count = 2 * event_capacity + 3;
    const item = "0,/*c*/";
    var relaxed: [1 + count * item.len + 1]u8 = undefined;
    var blanked: [relaxed.len]u8 = undefined;

    relaxed[0] = '[';

    for (0..count) |position| {
        @memcpy(relaxed[1 + position * item.len ..][0..item.len], item);
    }

    relaxed[relaxed.len - 1] = ']';

    @memcpy(&blanked, &relaxed);

    for (0..count) |position| {
        @memset(blanked[1 + position * item.len + 2 ..][0 .. item.len - 2], ' ');
    }

    blanked[1 + (count - 1) * item.len + 1] = ' ';

    try relaxed_blanked_expect(.{ .blanked = &blanked, .relaxed = &relaxed });
}

test "a code unit reads every four hex digits in either case and refuses any other byte" {
    for (0..std.math.maxInt(u16) + 1) |value| {
        var lower: [6]u8 = undefined;
        var upper: [6]u8 = undefined;

        _ = try std.mem.print(&lower, "\\u{x:0>4}", .{value});
        _ = try std.mem.print(&upper, "\\u{X:0>4}", .{value});

        try testing.expectEqual(value, try code_unit_of(&lower));
        try testing.expectEqual(value, try code_unit_of(&upper));
    }

    for (0..256) |byte| {
        const hex = std.ascii.isHex(@intCast(byte));

        for (2..6) |position| {
            var text = "\\u0000".*;

            text[position] = @intCast(byte);

            const parsed = code_unit_of(&text);

            if (hex) {
                const expected = try std.fmt.parseUnsigned(u16, text[2..6], 16);

                try testing.expectEqual(expected, try parsed);
            } else {
                try testing.expectError(error.Malformed, parsed);
            }
        }
    }
}
