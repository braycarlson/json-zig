const std = @import("std");

const stream_module = @import("stream.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Prng = std.Random.DefaultPrng;
const StreamType = stream_module.StreamType;
const Syntax = tokenizer_module.Syntax;
const Token = tokenizer_module.Token;
const TokenizerType = tokenizer_module.TokenizerType;
const Values = tokenizer_module.Values;

const bom = "\xef\xbb\xbf";
const campaign_events_min: u32 = 4096;
const chunk_bytes_max: u32 = 96;
const depth_generate_max: u32 = 5;
const digits_long_max: u32 = 100;
const gap_bytes_max: u32 = 600;
const infinity = "infinity";
const input_bytes_max: u32 = 16 * 1024;
const item_count_max: u32 = unit_count_max;

const mutation_alphabet = "{}[]:,\"\\ -+.eE0123456789tfnaulrsx\x00\x1f\xc3\xed\xa0\xff" ++
    "/*\n\rINi\xef\xbb\xbf";

const mutation_count_max: u32 = 4;
const run_bytes_max: u32 = 200;
const span_count_max: u32 = 256;
const string_pieces_long_max: u32 = 50;
const unit_count_max: u32 = input_bytes_max + 4;
const value_count_max: u32 = 6;
const width_max: u32 = 5;
const width_root_max: u32 = 24;

comptime {
    assert(depth_generate_max + mutation_count_max < tokenizer_module.depth_max);
    assert(width_root_max < span_count_max);
    assert(value_count_max < span_count_max);
    assert(run_bytes_max < input_bytes_max);
    assert(digits_long_max <= run_bytes_max);
    assert(string_pieces_long_max * 4 <= run_bytes_max);
}

pub const Counter = enum {
    buffer_exhausted,
    exact,
    fixed,
    gap_long,
    malformed,
    read_failed,
    sequence,
    value,
    verdict_exhausted,
};

const Call = enum {
    empty,
    gap,
    token,
    value,
};

const Frame = struct {
    first: bool,
    object: bool,
    remaining: u32,
};

const Item = struct {
    call: Call,
    needed: u32,
    span: Span,
    token: Token,
};

const Reason = enum {
    empty_expected,
    error_unexpected,
    exhaustion_late,
    exhaustion_missing,
    exhaustion_unexplained,
    position_differs,
    read_failure,
    value_differs,
    verdict_differs,
    verdict_missing,
};

const Run = struct {
    buffer_length: u32,
    failure_index: ?u32,
    fixed: bool,
    mutated: bool,
    values: Values,
};

const Span = struct {
    end: u32,
    start: u32,
};

const Unit = struct {
    kind: UnitKind,
    needed: u32,
    span: Span,
    token: Token,
};

const UnitKind = enum {
    bom,
    comment,
    token,
};

const Verdict = union(enum) {
    end,
    failure: Failure,

    const Failure = struct {
        err: tokenizer_module.Tokenizer.Error,
        index: u32,
    };
};

pub const ChunkReader = struct {
    chunk_bytes_max: u32,
    failure_index: ?u32,
    interface: std.Io.Reader,
    prng: Prng,
    source: []const u8,
    source_index: u32,

    pub const Options = struct {
        chunk_bytes_max: u32,
        failure_index: ?u32,
        seed: u64,
    };

    pub fn init(chunk: *ChunkReader, source: []const u8, buffer: []u8, options: Options) void {
        assert(options.chunk_bytes_max > 0);
        assert(source.len <= input_bytes_max);
        assert(buffer.len > 0);

        if (options.failure_index) |index| assert(index <= source.len);

        chunk.* = .{
            .chunk_bytes_max = options.chunk_bytes_max,
            .failure_index = options.failure_index,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .prng = .init(options.seed),
            .source = source,
            .source_index = 0,
        };
    }

    fn stream(
        io_reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const chunk: *ChunkReader = @alignCast(@fieldParentPtr("interface", io_reader));

        assert(limit != .nothing);
        assert(chunk.source_index <= chunk.source.len);
        assert(chunk.chunk_bytes_max > 0);

        const stop: u32 = chunk.failure_index orelse @intCast(chunk.source.len);

        if (chunk.source_index == stop) {
            if (chunk.failure_index != null) return error.ReadFailed;
            return error.EndOfStream;
        }

        const size_random = chunk.prng.random().intRangeAtMost(u32, 1, chunk.chunk_bytes_max);
        const size = @min(size_random, stop - chunk.source_index);
        const bytes = limit.sliceConst(chunk.source[chunk.source_index..][0..size]);
        const written = try writer.write(bytes);

        chunk.source_index += @intCast(written);

        assert(chunk.source_index <= stop);

        return written;
    }
};

pub const State = struct {
    buffer: [input_bytes_max + 1]u8,
    chunk: ChunkReader,
    counts: std.EnumArray(Counter, u32),
    fixed: std.Io.Reader,
    input: [input_bytes_max]u8,
    input_length: u32,
    item_count: u32,
    items: [item_count_max]Item,
    span_count: u32,
    spans: [span_count_max]Span,
    stream_relaxed: StreamType(.relaxed),
    stream_strict: StreamType(.strict),
    unit_count: u32,
    units: [unit_count_max]Unit,
    verdict: Verdict,
    whitespace_run_max: u32,
};

pub fn event(state: *State, prng: *Prng) !void {
    assert(state.buffer.len == input_bytes_max + 1);
    assert(state.units.len == unit_count_max);

    const random = prng.random();
    const syntax: Syntax = if (random.boolean()) .relaxed else .strict;
    const values: Values = if (random.uintLessThan(u32, 3) == 0) .sequence else .single;

    input_generate(state, prng, syntax, values) catch |err| switch (err) {
        error.WriteFailed => return,
    };

    const mutated = values == .single and random.uintLessThan(u32, 4) == 0;

    if (mutated) input_mutate(state, prng);

    switch (syntax) {
        inline else => |syntax_known| try syntax_event(syntax_known, state, prng, values, mutated),
    }
}

pub fn counts_reset(state: *State) void {
    assert(state.units.len == unit_count_max);
    assert(@typeInfo(Counter).@"enum".field_names.len > 0);

    state.counts = .initFill(0);
}

pub fn summary_check(state: *const State, events_max: u32) !void {
    assert(events_max > 0);
    assert(campaign_events_min > 0);

    for (std.enums.values(Counter)) |counter| {
        std.debug.print("fuzz stream: {t}={d}\n", .{ counter, state.counts.get(counter) });
    }

    if (events_max < campaign_events_min) return;

    for (std.enums.values(Counter)) |counter| {
        if (state.counts.get(counter) == 0) return error.CounterUnreached;
    }
}

fn syntax_event(
    comptime syntax: Syntax,
    state: *State,
    prng: *Prng,
    values: Values,
    mutated: bool,
) !void {
    comptime assert(@sizeOf(TokenizerType(syntax)) > 0);
    assert(state.input_length <= input_bytes_max);
    if (mutated) assert(values == .single);

    const input = state.input[0..state.input_length];

    try units_build(syntax, state, input, values);

    if (values == .single) {
        if (!mutated) elements_find(state);
    }

    const random = prng.random();
    const failing = random.uintLessThan(u32, 8) == 0 and input.len > 0;
    const fixed = !failing and random.uintLessThan(u32, 8) == 0;
    const whole = failing or fixed;
    const by_value = state.span_count > 0 and !mutated and random.boolean();

    items_build(state, values, by_value);

    if (fixed) state.counts.getPtr(.fixed).* += 1;
    if (values == .sequence) state.counts.getPtr(.sequence).* += 1;
    if (by_value) state.counts.getPtr(.value).* += 1;
    if (state.verdict == .failure) state.counts.getPtr(.malformed).* += 1;

    const run: Run = .{
        .buffer_length = if (whole) @intCast(input.len + 1) else buffer_length_pick(state, prng),
        .failure_index = if (failing) random.uintLessThan(u32, @intCast(input.len)) else null,
        .fixed = fixed,
        .mutated = mutated,
        .values = values,
    };

    const stream = switch (syntax) {
        .relaxed => &state.stream_relaxed,
        .strict => &state.stream_strict,
    };

    try stream_check(syntax, state, stream, prng, &run);
}

fn buffer_length_pick(state: *const State, prng: *Prng) u32 {
    assert(state.input_length <= input_bytes_max);
    assert(state.unit_count <= unit_count_max);

    const random = prng.random();
    const needed_max = needed_max_of(state);

    const result: u32 = switch (random.uintLessThan(u32, 6)) {
        0 => state.input_length + 1,
        1 => needed_max,
        2 => @max(needed_max - 1, 1),
        else => random.intRangeAtMost(u32, 1, @min(needed_max * 2, state.buffer.len)),
    };

    assert(result > 0);
    assert(result <= state.buffer.len);

    return result;
}

fn stream_check(
    comptime syntax: Syntax,
    state: *State,
    stream: *StreamType(syntax),
    prng: *Prng,
    run: *const Run,
) !void {
    comptime assert(@sizeOf(StreamType(syntax)) > 0);
    assert(run.buffer_length > 0);
    assert(run.buffer_length <= state.buffer.len);

    const input = state.input[0..state.input_length];
    const random = prng.random();

    state.chunk.init(input, state.buffer[0..run.buffer_length], .{
        .chunk_bytes_max = random.intRangeAtMost(u32, 1, chunk_bytes_max),
        .failure_index = run.failure_index,
        .seed = random.int(u64),
    });

    state.fixed = .fixed(input);

    const reader = if (run.fixed) &state.fixed else &state.chunk.interface;

    stream.init(reader, .{ .values = run.values });

    var pending: ?u32 = null;

    for (state.items[0..state.item_count]) |*item| {
        const over = item.needed > run.buffer_length;

        if (item.call == .gap) {
            if (over) {
                if (pending == null) pending = item.span.start;
            }

            continue;
        }

        const exhausted_here: ?u32 = if (over) item.span.start else null;
        const exhausted_at: ?u32 = pending orelse exhausted_here;
        const outcome = try call_check(syntax, state, stream, item, run, exhausted_at);
        if (outcome == .stopped) return;

        pending = null;
    }

    try verdict_check(syntax, state, stream, run, pending);
}

const Outcome = enum {
    passed,
    stopped,
};

fn call_check(
    comptime syntax: Syntax,
    state: *State,
    stream: *StreamType(syntax),
    item: *const Item,
    run: *const Run,
    exhausted_at: ?u32,
) !Outcome {
    comptime assert(@sizeOf(StreamType(syntax)) > 0);
    assert(item.call != .gap);
    assert(item.span.start <= state.input_length);
    if (exhausted_at) |start| assert(start <= item.span.start);

    const input = state.input[0..state.input_length];
    const result = call_make(syntax, stream, item.call);

    if (run.failure_index) |failure| {
        const determined = item.span.start + item.needed <= failure;
        const reached = if (result) |_| true else |err| err != error.ReadFailed;
        if (determined != reached) return failed(.read_failure, input, item.span.start);

        if (!reached) {
            state.counts.getPtr(.read_failed).* += 1;

            return .stopped;
        }
    }

    if (exhausted_at) |start| {
        _ = result catch |err| {
            if (err != error.BufferExhausted) return failed(.exhaustion_missing, input, start);

            try position_expect(input, start, stream.diagnostic());

            state.counts.getPtr(.buffer_exhausted).* += 1;

            return .stopped;
        };

        return failed(.exhaustion_missing, input, start);
    }

    const made = result catch |err| {
        std.debug.print("unexpected {t}\n", .{err});

        return failed(.error_unexpected, input, item.span.start);
    };

    try made_expect(item, made, input);

    return .passed;
}

const Made = union(enum) {
    text: []const u8,
    token: Token,
};

fn call_make(
    comptime syntax: Syntax,
    stream: *StreamType(syntax),
    call: Call,
) StreamType(syntax).Error!Made {
    comptime assert(@sizeOf(StreamType(syntax)) > 0);
    assert(call != .gap);
    assert(stream.pin == null);

    return switch (call) {
        .empty, .value => .{ .text = try stream.value_next() },
        .gap => unreachable,
        .token => .{ .token = try stream.next() },
    };
}

fn made_expect(item: *const Item, made: Made, input: []const u8) !void {
    assert(item.call != .gap);
    assert(item.span.end <= input.len);
    assert((made == .token) == (item.call == .token));

    switch (item.call) {
        .empty => if (made.text.len != 0) return failed(.empty_expected, input, item.span.start),
        .gap => unreachable,
        .token => try std.testing.expectEqualDeep(item.token, made.token),
        .value => {
            const expected = input[item.span.start..item.span.end];

            if (!std.mem.eql(u8, expected, made.text)) {
                return failed(.value_differs, input, item.span.start);
            }
        },
    }
}

fn verdict_check(
    comptime syntax: Syntax,
    state: *State,
    stream: *StreamType(syntax),
    run: *const Run,
    pending: ?u32,
) !void {
    comptime assert(@sizeOf(StreamType(syntax)) > 0);
    assert(state.item_count > 0 or state.verdict == .failure);
    assert(run.buffer_length > 0);
    if (pending) |start| assert(start <= state.input_length);

    const input = state.input[0..state.input_length];

    const failure = switch (state.verdict) {
        .end => {
            finished(state, run);

            return;
        },
        .failure => |failure| failure,
    };

    const result = stream.next();

    const err = if (result) |_| {
        return failed(.verdict_missing, input, failure.index);
    } else |err| err;

    if (err == error.ReadFailed) {
        if (run.failure_index == null) return failed(.read_failure, input, failure.index);

        state.counts.getPtr(.read_failed).* += 1;

        return;
    }

    if (err == error.BufferExhausted) {
        const position = stream.diagnostic();
        const reference = tokenizer_module.position_of(input, failure.index);

        const before = position.line < reference.line or
            (position.line == reference.line and position.column <= reference.column);

        const explained = pending != null or run.mutated;
        if (!explained) return failed(.exhaustion_unexplained, input, failure.index);
        if (!before) return failed(.exhaustion_late, input, failure.index);

        state.counts.getPtr(.verdict_exhausted).* += 1;

        return;
    }

    if (err != failure.err) return failed(.verdict_differs, input, failure.index);

    try position_expect(input, failure.index, stream.diagnostic());

    finished(state, run);
}

fn finished(state: *State, run: *const Run) void {
    assert(run.buffer_length > 0);
    assert(state.input_length <= input_bytes_max);

    state.counts.getPtr(.exact).* += 1;

    if (state.whitespace_run_max > run.buffer_length) state.counts.getPtr(.gap_long).* += 1;
}

fn position_expect(input: []const u8, index: u32, position: tokenizer_module.Position) !void {
    assert(index <= input.len);
    assert(position.line >= 1);

    const expected = tokenizer_module.position_of(input, index);
    const equal = expected.line == position.line and expected.column == position.column;

    if (!equal) {
        std.debug.print("position {d}:{d}, expected {d}:{d}\n", .{
            position.line,
            position.column,
            expected.line,
            expected.column,
        });

        return failed(.position_differs, input, index);
    }
}

fn failed(reason: Reason, input: []const u8, index: u32) error{StreamDisagreement} {
    assert(@backingInt(reason) < @typeInfo(Reason).@"enum".field_names.len);
    assert(index <= input.len);

    std.debug.print("stream {t} at {d} of {d} bytes\n{any}\n", .{
        reason,
        index,
        input.len,
        input,
    });

    return error.StreamDisagreement;
}

fn units_build(comptime syntax: Syntax, state: *State, input: []const u8, values: Values) !void {
    comptime assert(@sizeOf(TokenizerType(syntax)) > 0);
    assert(input.len <= input_bytes_max);
    assert(state.span_count <= span_count_max);
    if (values == .sequence) assert(state.span_count <= value_count_max);

    state.unit_count = 0;

    var previous: u32 = 0;

    if (syntax == .relaxed) {
        if (std.mem.startsWith(u8, input, bom)) {
            const span: Span = .{ .end = bom.len, .start = 0 };

            unit_push(state, .{ .kind = .bom, .needed = bom.len, .span = span, .token = .end });

            previous = bom.len;
        }
    }

    switch (values) {
        .sequence => {
            for (state.spans[0..state.span_count]) |span| {
                previous = try value_units_build(syntax, state, input, span, previous);
            }

            state.verdict = .end;
        },
        .single => {
            const whole: Span = .{ .end = @intCast(input.len), .start = 0 };

            previous = try value_units_build(syntax, state, input, whole, previous);
        },
    }

    if (state.verdict == .failure) return;

    gap_units_build(syntax, state, input, .{ .end = @intCast(input.len), .start = previous });

    unit_push(state, .{
        .kind = .token,
        .needed = 1,
        .span = .{ .end = @intCast(input.len), .start = @intCast(input.len) },
        .token = .end,
    });
}

fn value_units_build(
    comptime syntax: Syntax,
    state: *State,
    input: []const u8,
    span: Span,
    gap_start: u32,
) !u32 {
    comptime assert(@sizeOf(TokenizerType(syntax)) > 0);
    assert(span.start <= span.end);
    assert(span.end <= input.len);
    assert(gap_start <= span.end);

    const text = input[span.start..span.end];
    var tokenizer: TokenizerType(syntax) = .init(text);
    var previous = gap_start;

    for (0..text.len + 2) |_| {
        const token = tokenizer.next() catch |err| {
            state.verdict = .{ .failure = .{ .err = err, .index = span.start + tokenizer.index } };

            return previous;
        };

        if (token == .end) {
            state.verdict = .end;

            return previous;
        }

        const local = token_span_of(syntax, &tokenizer, token);

        const absolute: Span = .{
            .end = span.start + local.end,
            .start = span.start + local.start,
        };

        gap_units_build(syntax, state, input, .{ .end = absolute.start, .start = previous });

        unit_push(state, .{
            .kind = .token,
            .needed = token_needed(input, absolute, token),
            .span = absolute,
            .token = token,
        });

        previous = absolute.end;
    }

    unreachable;
}

fn token_span_of(
    comptime syntax: Syntax,
    tokenizer: *const TokenizerType(syntax),
    token: Token,
) Span {
    comptime assert(@sizeOf(TokenizerType(syntax)) > 0);
    assert(tokenizer.index <= tokenizer.input.len);
    assert(token != .end);

    const end = tokenizer.index;

    const start = switch (token) {
        .array_begin, .array_end, .object_begin, .object_end => end - 1,
        .boolean, .null_value, .number, .string => tokenizer.value_start,
        .end => unreachable,
        .key => tokenizer.key_start - 1,
    };

    assert(start < end);

    return .{ .end = end, .start = start };
}

fn token_needed(input: []const u8, span: Span, token: Token) u32 {
    assert(span.start < span.end);
    assert(span.end <= input.len);
    assert(token != .end);

    const length = span.end - span.start;

    return switch (token) {
        .array_begin, .array_end, .object_begin, .object_end => 1,
        .boolean, .key, .null_value, .string => length,
        .end => 1,
        .number => number_needed(input, span),
    };
}

fn number_needed(input: []const u8, span: Span) u32 {
    assert(span.start < span.end);
    assert(span.end <= input.len);

    const length = span.end - span.start;
    const sign: u32 = @intFromBool(input[span.start] == '-');
    const lead = input[span.start + sign];
    const letter = length > sign and std.ascii.isAlphabetic(lead);
    const inf = letter and length == sign + 3 and std.ascii.toLower(lead) == 'i';

    const result = if (inf)
        sign + infinity_prefix_length(input[span.start + sign ..]) + 1
    else if (letter)
        length
    else
        length + 1;

    assert(result >= length);
    assert(result <= length + infinity.len - 2);

    return result;
}

fn infinity_prefix_length(rest: []const u8) u32 {
    assert(rest.len >= 3);
    assert(std.ascii.toLower(rest[0]) == 'i');

    var common: u32 = 0;

    for (rest, 0..) |byte, position| {
        if (position == infinity.len) break;
        if (std.ascii.toLower(byte) != infinity[position]) break;

        common += 1;
    }

    assert(common >= 3);
    assert(common < infinity.len);

    return common;
}

fn gap_units_build(comptime syntax: Syntax, state: *State, input: []const u8, gap: Span) void {
    comptime assert(@sizeOf(TokenizerType(syntax)) > 0);
    assert(gap.start <= gap.end);
    assert(gap.end <= input.len);

    if (syntax == .strict) return;

    var index = gap.start;

    for (0..gap.end - gap.start + 1) |_| {
        const slash = std.mem.findScalarPos(u8, input[0..gap.end], index, '/') orelse return;
        const block = input[slash + 1] == '*';

        const close = if (block)
            std.mem.findPos(u8, input, slash + 2, "*/").? + 2
        else
            std.mem.findAnyPos(u8, input, slash + 2, "\n\r") orelse input.len;

        const span: Span = .{ .end = @intCast(close), .start = @intCast(slash) };
        const length = span.end - span.start;

        unit_push(state, .{
            .kind = .comment,
            .needed = if (block) length else length + 1,
            .span = span,
            .token = .end,
        });

        index = span.end;
    }

    unreachable;
}

fn unit_push(state: *State, unit: Unit) void {
    assert(state.unit_count < unit_count_max);
    assert(unit.needed > 0);

    state.units[state.unit_count] = unit;
    state.unit_count += 1;
}

fn needed_max_of(state: *const State) u32 {
    assert(state.unit_count <= unit_count_max);
    assert(state.input_length <= input_bytes_max);

    var result: u32 = 1;

    for (state.units[0..state.unit_count]) |unit| result = @max(result, unit.needed);

    return result;
}

fn elements_find(state: *State) void {
    assert(state.unit_count <= unit_count_max);
    assert(state.input_length <= input_bytes_max);

    state.span_count = 0;

    if (state.verdict != .end) return;

    var depth: u32 = 0;
    var start: u32 = 0;

    for (state.units[0..state.unit_count]) |unit| {
        if (unit.kind != .token) continue;
        if (unit.token == .end) break;

        const root = depth == 0;
        const element_first = depth == 1;

        if (root) {
            if (unit.token != .array_begin) return;
        }

        switch (unit.token) {
            .array_begin, .object_begin => depth += 1,
            .array_end, .object_end => depth -= 1,
            .boolean, .end, .key, .null_value, .number, .string => {},
        }

        if (depth == 0) return;

        if (element_first) start = unit.span.start;

        if (root) continue;

        if (depth == 1) {
            if (state.span_count == span_count_max) return;

            state.spans[state.span_count] = .{ .end = unit.span.end, .start = start };
            state.span_count += 1;
        }
    }
}

fn items_build(state: *State, values: Values, by_value: bool) void {
    assert(state.unit_count <= unit_count_max);
    assert(state.span_count <= span_count_max);
    if (values == .sequence) assert(state.span_count <= value_count_max);

    state.item_count = 0;

    var span_index: u32 = 0;
    var index: u32 = 0;

    for (0..state.unit_count + 1) |_| {
        if (index == state.unit_count) return;

        const unit = state.units[index];

        if (unit.kind != .token) {
            item_push(state, .{
                .call = .gap,
                .needed = unit.needed,
                .span = unit.span,
                .token = .end,
            });

            index += 1;

            continue;
        }

        const spanned = by_value and span_index < state.span_count;
        const value_first = spanned and unit.span.start == state.spans[span_index].start;

        if (value_first) {
            const span = state.spans[span_index];
            var needed: u32 = 0;

            for (state.units[index..state.unit_count]) |inner| {
                if (inner.span.start >= span.end) break;

                needed = @max(needed, inner.span.start + inner.needed - span.start);
                index += 1;
            }

            item_push(state, .{ .call = .value, .needed = needed, .span = span, .token = .end });
            span_index += 1;

            continue;
        }

        const closing = switch (values) {
            .sequence => unit.token == .end,
            .single => unit.token == .array_end and span_index == state.span_count,
        };

        const empty = by_value and closing;

        item_push(state, .{
            .call = if (empty) .empty else .token,
            .needed = unit.needed,
            .span = unit.span,
            .token = unit.token,
        });

        index += 1;
    }

    unreachable;
}

fn item_push(state: *State, item: Item) void {
    assert(state.item_count < item_count_max);
    assert(item.needed > 0);

    state.items[state.item_count] = item;
    state.item_count += 1;
}

const Generator = struct {
    long: bool,
    prng: *Prng,
    relaxed: bool,
    sink: *std.Io.Writer,
    whitespace_run_max: u32,

    fn value_write(generator: *Generator, root: bool) error{WriteFailed}!void {
        assert(generator.sink.end <= generator.sink.buffer.len);
        assert(depth_generate_max > 0);

        var frames: [depth_generate_max]Frame = undefined;
        var depth: u32 = 0;

        try generator.item_write(&frames, &depth, root);

        for (0..input_bytes_max) |_| {
            if (depth == 0) return;

            const frame = &frames[depth - 1];

            if (frame.remaining == 0) {
                try generator.container_close(frame);

                depth -= 1;

                continue;
            }

            if (!frame.first) {
                try generator.gap_write(false);
                try generator.sink.writeByte(',');
            }

            frame.first = false;
            frame.remaining -= 1;

            try generator.gap_write(false);

            if (frame.object) {
                try generator.string_write();
                try generator.gap_write(false);
                try generator.sink.writeByte(':');
                try generator.gap_write(false);
            }

            try generator.item_write(&frames, &depth, false);
        }

        return error.WriteFailed;
    }

    fn container_close(generator: *Generator, frame: *const Frame) error{WriteFailed}!void {
        assert(frame.remaining == 0);
        assert(generator.sink.end <= generator.sink.buffer.len);

        const random = generator.prng.random();
        const trailing = generator.relaxed and !frame.first and random.uintLessThan(u32, 3) == 0;

        if (trailing) {
            try generator.gap_write(false);
            try generator.sink.writeByte(',');
        }

        try generator.gap_write(false);
        try generator.sink.writeByte(if (frame.object) '}' else ']');
    }

    fn item_write(
        generator: *Generator,
        frames: *[depth_generate_max]Frame,
        depth: *u32,
        root: bool,
    ) error{WriteFailed}!void {
        assert(depth.* <= depth_generate_max);
        assert(generator.sink.end <= generator.sink.buffer.len);

        const random = generator.prng.random();
        const nested = depth.* < depth_generate_max;
        var choice = random.uintLessThan(u32, if (nested) 8 else 6);

        if (root) {
            if (random.boolean()) choice = 6;
        }

        switch (choice) {
            0 => try generator.sink.writeAll(if (random.boolean()) "true" else "false"),
            1 => try generator.sink.writeAll("null"),
            2, 3 => try generator.number_write(),
            4 => try generator.string_write(),
            5 => {
                const spelled = generator.relaxed and random.boolean();
                if (spelled) return generator.spelling_write();

                try generator.string_write();
            },
            6, 7 => {
                const object = choice == 7;
                const width = if (root) width_root_max else width_max;

                frames[depth.*] = .{
                    .first = true,
                    .object = object,
                    .remaining = random.uintAtMost(u32, width),
                };

                depth.* += 1;

                try generator.sink.writeByte(if (object) '{' else '[');
            },
            else => unreachable,
        }
    }

    fn string_write(generator: *Generator) error{WriteFailed}!void {
        assert(generator.sink.end <= generator.sink.buffer.len);
        assert(run_bytes_max >= 8);

        const random = generator.prng.random();
        const escapes = [_][]const u8{ "\\n", "\\\"", "\\\\", "\\u00e9", "\\ud83d\\ude00", "\\/" };
        const wide = [_][]const u8{ "\u{e9}", "\u{20ac}", "\u{1f600}" };
        const long = generator.long and random.uintLessThan(u32, 3) == 0;
        const count = random.uintAtMost(u32, if (long) string_pieces_long_max else 6);

        try generator.sink.writeByte('"');

        for (0..count) |_| {
            switch (random.uintLessThan(u32, 8)) {
                0 => try generator.sink.writeAll(escapes[random.uintLessThan(u32, escapes.len)]),
                1 => try generator.sink.writeAll(wide[random.uintLessThan(u32, wide.len)]),
                else => try generator.sink.writeAll("abc"[0..random.intRangeAtMost(u32, 1, 3)]),
            }
        }

        try generator.sink.writeByte('"');
    }

    fn number_write(generator: *Generator) error{WriteFailed}!void {
        assert(generator.sink.end <= generator.sink.buffer.len);
        assert(run_bytes_max >= 8);

        const random = generator.prng.random();
        const long = generator.long and random.uintLessThan(u32, 3) == 0;

        if (random.boolean()) try generator.sink.writeByte('-');

        if (random.uintLessThan(u32, 6) == 0) {
            try generator.sink.writeByte('0');
        } else {
            try generator.sink.writeByte('1' + @as(u8, @intCast(random.uintLessThan(u32, 9))));
            try generator.digits_write(random.uintAtMost(u32, if (long) digits_long_max else 4));
        }

        if (random.uintLessThan(u32, 3) == 0) {
            try generator.sink.writeByte('.');
            const fraction_max = if (long) digits_long_max else 3;

            try generator.digits_write(random.intRangeAtMost(u32, 1, fraction_max));
        }

        if (random.uintLessThan(u32, 4) == 0) {
            try generator.sink.writeByte(if (random.boolean()) 'e' else 'E');

            if (random.boolean()) try generator.sink.writeByte(if (random.boolean()) '+' else '-');

            try generator.digits_write(random.intRangeAtMost(u32, 1, 3));
        }
    }

    fn digits_write(generator: *Generator, count: u32) error{WriteFailed}!void {
        assert(count <= run_bytes_max);
        assert(generator.sink.end <= generator.sink.buffer.len);

        const random = generator.prng.random();

        for (0..count) |_| {
            try generator.sink.writeByte('0' + @as(u8, @intCast(random.uintLessThan(u32, 10))));
        }
    }

    fn spelling_write(generator: *Generator) error{WriteFailed}!void {
        assert(generator.relaxed);
        assert(generator.sink.end <= generator.sink.buffer.len);

        const random = generator.prng.random();
        const spellings = [_][]const u8{ "nan", "inf", "infinity" };
        const spelling = spellings[random.uintLessThan(u32, spellings.len)];

        if (random.boolean()) try generator.sink.writeByte('-');

        for (spelling) |byte| {
            try generator.sink.writeByte(if (random.boolean()) std.ascii.toUpper(byte) else byte);
        }
    }

    fn gap_write(generator: *Generator, last: bool) error{WriteFailed}!void {
        assert(generator.sink.end <= generator.sink.buffer.len);
        assert(gap_bytes_max > 0);

        const random = generator.prng.random();
        const piece_count = random.uintAtMost(u32, 3);

        for (0..piece_count) |piece| {
            const comment = generator.relaxed and random.uintLessThan(u32, 3) == 0;

            if (comment) {
                try generator.comment_write(last and piece + 1 == piece_count);
            } else {
                try generator.whitespace_write();
            }
        }
    }

    fn separator_write(generator: *Generator) error{WriteFailed}!void {
        assert(generator.sink.end <= generator.sink.buffer.len);
        assert(gap_bytes_max > 0);

        const random = generator.prng.random();

        try generator.sink.writeAll(if (random.boolean()) "\n" else "\r\n");
        try generator.gap_write(false);
    }

    fn whitespace_write(generator: *Generator) error{WriteFailed}!void {
        assert(generator.sink.end <= generator.sink.buffer.len);
        assert(gap_bytes_max > 0);

        const random = generator.prng.random();
        const long = random.uintLessThan(u32, 16) == 0;
        const count_max = if (long) gap_bytes_max else 3;
        const count = random.intRangeAtMost(u32, 1, count_max);

        for (0..count) |_| {
            try generator.sink.writeByte(" \t\n\r"[random.uintLessThan(u32, 4)]);
        }

        generator.whitespace_run_max = @max(generator.whitespace_run_max, count);
    }

    fn comment_write(generator: *Generator, final: bool) error{WriteFailed}!void {
        assert(generator.relaxed);
        assert(generator.sink.end <= generator.sink.buffer.len);

        const random = generator.prng.random();
        const alphabet = "ab */\"\\\x00\xc3\xff{";
        const long = generator.long and random.uintLessThan(u32, 3) == 0;
        const count = random.uintAtMost(u32, if (long) run_bytes_max else 8);
        const block = random.boolean();

        try generator.sink.writeAll(if (block) "/*" else "//");

        var previous: u8 = 0;

        for (0..count) |_| {
            var byte = alphabet[random.uintLessThan(u32, alphabet.len)];

            const closing = block and previous == '*' and byte == '/';

            if (closing) byte = 'b';

            try generator.sink.writeByte(byte);

            previous = byte;
        }

        if (block) {
            try generator.sink.writeAll("*/");

            return;
        }

        if (final) {
            if (random.boolean()) return;
        }

        try generator.sink.writeByte(if (random.boolean()) '\n' else '\r');
    }
};

fn input_generate(
    state: *State,
    prng: *Prng,
    syntax: Syntax,
    values: Values,
) error{WriteFailed}!void {
    assert(state.input.len == input_bytes_max);
    assert(value_count_max < span_count_max);
    assert(@backingInt(syntax) <= 1);
    assert(@backingInt(values) <= 1);

    const random = prng.random();
    var sink: std.Io.Writer = .fixed(&state.input);

    var generator: Generator = .{
        .long = random.uintLessThan(u32, 4) == 0,
        .prng = prng,
        .relaxed = syntax == .relaxed,
        .sink = &sink,
        .whitespace_run_max = 0,
    };

    state.span_count = 0;
    state.input_length = 0;

    if (generator.relaxed) {
        if (random.uintLessThan(u32, 8) == 0) try sink.writeAll(bom);
    }

    try generator.gap_write(false);

    switch (values) {
        .sequence => {
            const count = random.uintAtMost(u32, value_count_max);

            for (0..count) |index| {
                if (index > 0) try generator.separator_write();

                const start: u32 = @intCast(sink.end);

                try generator.value_write(false);

                state.spans[state.span_count] = .{ .end = @intCast(sink.end), .start = start };
                state.span_count += 1;
            }
        },
        .single => try generator.value_write(true),
    }

    try generator.gap_write(true);

    state.input_length = @intCast(sink.end);
    state.whitespace_run_max = generator.whitespace_run_max;
}

fn input_mutate(state: *State, prng: *Prng) void {
    assert(state.input_length <= input_bytes_max);
    assert(mutation_alphabet.len > 0);

    const random = prng.random();
    const count = random.intRangeAtMost(u32, 1, mutation_count_max);

    for (0..count) |_| {
        const length = state.input_length;
        const byte = mutation_alphabet[random.uintLessThan(u32, mutation_alphabet.len)];
        const position = random.uintAtMost(u32, length);

        switch (random.uintLessThan(u32, 3)) {
            0 => if (position < length) {
                state.input[position] = byte;
            },
            1 => if (length < input_bytes_max) {
                const tail = state.input[position..length];

                std.mem.copyBackwards(u8, state.input[position + 1 .. length + 1], tail);

                state.input[position] = byte;
                state.input_length += 1;
            },
            2 => if (position < length) {
                const tail = state.input[position + 1 .. length];

                std.mem.copyForwards(u8, state.input[position .. length - 1], tail);

                state.input_length -= 1;
            },
            else => unreachable,
        }
    }

    if (random.uintLessThan(u32, 4) == 0) {
        state.input_length = random.uintAtMost(u32, state.input_length);
    }
}
