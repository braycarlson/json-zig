const std = @import("std");

const scalar = @import("scalar.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Batch = structural.Batch;
const Container = tokenizer_module.Container;
const Event = tokenizer_module.Event;
const Kind = tokenizer_module.Kind;
const State = tokenizer_module.State;
const Syntax = tokenizer_module.Syntax;
const Tokenizer = tokenizer_module.Tokenizer;

const Phase = enum {
    array_next,
    array_open,
    done,
    object_next,
    object_open,
    start,
    value_array,
    value_object,
    value_top,
};

const colon_after_quote: u16 = '"' | @as(u16, ':') << 8;
const depth_max = tokenizer_module.depth_max;
const direct = structural.walk_direct;
const entries_capacity = structural.entries_capacity;
const entry_sentinel = structural.entry_sentinel;
const event_capacity = tokenizer_module.event_capacity;
const events_member_max: u32 = 2;
const at_limit = if (direct) std.math.maxInt(u32) else entries_capacity;

comptime {
    assert(event_capacity > events_member_max);
    assert(depth_max <= std.math.maxInt(u8));
}

const cursor_empty: structural.Cursor = .{
    .count = 0,
    .exhausted = false,
    .failed = false,
    .indexer = undefined,
    .indices = undefined,
    .position = 0,
};

const IndexedState = struct {
    batch: Batch,
    indexer: structural.Indexer,
};

pub const Walk = struct {
    at: u32,
    handed_over: bool,
    indexed: if (direct) void else IndexedState,
    started: bool,

    pub fn reset(walk: *Walk, syntax: Syntax, input: []const u8) void {
        assert(input.len <= tokenizer_module.input_bytes_max);
        assert(structural.index_position_mask < structural.index_escaped);

        walk.at = 0;
        walk.handed_over = scanner_required(syntax, input);
        walk.started = false;
    }
};

pub inline fn walk_of(syntax: Syntax, input: []const u8) Walk {
    assert(input.len <= tokenizer_module.input_bytes_max);

    return .{
        .at = 0,
        .handed_over = scanner_required(syntax, input),
        .indexed = undefined,
        .started = false,
    };
}

fn scanner_required(syntax: Syntax, input: []const u8) bool {
    assert(input.len <= tokenizer_module.input_bytes_max);
    assert(structural.index_position_mask < structural.index_escaped);

    if (syntax != .strict) return true;
    if (input.len < structural.block_bytes) return true;
    return input.len >= structural.index_position_mask;
}

const Pass = struct {
    at: u32,
    batch: if (direct) void else *Batch,
    count: u32,
    depth: u32,
    events: *[event_capacity]Event,
    indent: u32,
    input: []const u8,
    limit: u32,
    stack: *[depth_max]Container,

    inline fn emit(pass: *Pass, event: Event) void {
        assert(pass.count < event_capacity);
        assert(event.end <= pass.input.len);

        pass.events[pass.count] = event;
        pass.count += 1;
    }

    inline fn peek(pass: *const Pass) u32 {
        assert(pass.at < at_limit);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        if (comptime direct) return entry_sentinel;

        return pass.batch.indices[pass.at];
    }

    inline fn take(pass: *Pass) ?u32 {
        assert(pass.at < at_limit);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        if (comptime direct) {
            return scalar.token_take(pass.input, .{
                .at = &pass.at,
                .indent = &pass.indent,
                .limit = pass.limit,
            });
        }

        const entry = pass.batch.indices[pass.at];

        pass.at += 1;

        if (entry < pass.input.len) return entry;

        return pass.take_cold(entry);
    }

    inline fn take_cold(pass: *Pass, entry: u32) ?u32 {
        @branchHint(.cold);
        assert(entry >= pass.input.len);

        if (entry != entry_sentinel) return null;
        if (!pass.batch.refill(pass.input)) return null;

        pass.at = 1;

        const first = pass.batch.indices[0];

        return if (first < pass.input.len) first else null;
    }

    inline fn string_emit(pass: *Pass, open: u32) bool {
        assert(open < pass.input.len);
        assert(pass.input[open] == '"');

        if (comptime direct) {
            const close = scalar.string_close(pass.input, .{ .limit = pass.limit, .open = open });
            if (close.position == 0) return false;

            const end = close.position + 1;

            pass.at = end;
            pass.emit(.{ .end = end, .kind = .string, .start = open });

            return true;
        }

        const entry = pass.batch.indices[pass.at];

        if (entry < pass.input.len) {
            if (pass.input[entry - 1] == '"') {
                pass.emit(.{ .end = entry, .kind = .string, .start = open });

                return true;
            }
        }

        const close = pass.batch.close_find(pass.input, .{ .at = pass.at, .open = open });
        if (close.position == 0) return false;

        if (close.refilled) pass.at = 0;

        pass.emit(.{ .end = close.position + 1, .kind = .string, .start = open });

        return true;
    }

    inline fn key_emit_direct(pass: *Pass, open: u32) bool {
        comptime assert(direct);
        assert(pass.input[open] == '"');

        const input = pass.input;
        const close = scalar.key_close(input, .{ .limit = pass.limit, .open = open });
        if (close.position == 0) return false;

        const end = close.position + 1;

        if (end < pass.limit) {
            @branchHint(.likely);

            if (input[end] == ':') {
                @branchHint(.likely);

                if (input[end + 1] == ' ') {
                    @branchHint(.likely);

                    pass.at = end + 2;
                } else {
                    pass.at = end + 1;
                }

                pass.emit(.{ .end = end, .kind = .key, .start = open + 1 });

                return true;
            }
        }

        pass.at = end;

        const colon = pass.take() orelse return false;
        if (input[colon] != ':') return false;

        pass.emit(.{ .end = end, .kind = .key, .start = open + 1 });

        return true;
    }

    inline fn key_emit(pass: *Pass, open: u32) bool {
        assert(open < pass.input.len);
        assert(pass.depth > 0);

        const input = pass.input;

        if (input[open] != '"') return false;

        if (comptime direct) return pass.key_emit_direct(open);

        const entry = pass.batch.indices[pass.at];

        if (entry < input.len) {
            const pair = std.mem.readInt(u16, input[entry - 1 ..][0..2], .little);

            if (pair == colon_after_quote) {
                pass.at += 1;
                pass.emit(.{ .end = entry, .kind = .key, .start = open + 1 });

                return true;
            }
        }

        const close = pass.batch.close_find(input, .{ .at = pass.at, .open = open });
        if (close.position == 0) return false;

        if (close.refilled) pass.at = 0;

        const colon = pass.batch.indices[pass.at];
        if (colon >= input.len) return false;
        if (input[colon] != ':') return false;

        pass.at += 1;
        pass.emit(.{ .end = close.position + 1, .kind = .key, .start = open + 1 });

        return true;
    }

    inline fn container_begin(pass: *Pass, comptime container: Container, position: u32) bool {
        assert(position < pass.input.len);
        assert(pass.depth <= depth_max);

        if (pass.depth == depth_max) return false;

        pass.stack[pass.depth] = container;
        pass.depth += 1;

        const kind: Kind = if (container == .object) .object_begin else .array_begin;

        pass.emit(.{ .end = position + 1, .kind = kind, .start = position });

        return true;
    }

    inline fn literal_emit(
        pass: *Pass,
        comptime literal: tokenizer_module.Literal,
        comptime kind: Kind,
        position: u32,
    ) bool {
        comptime assert(kind == .false_value or kind == .null_value or kind == .true_value);
        assert(position < pass.input.len);

        const text = comptime literal.text();
        const end = position + @as(u32, text.len);

        if (pass.peek() == end) {
            const word = std.mem.readInt(u32, pass.input[position..][0..4], .little);

            if (word != comptime std.mem.readInt(u32, text[0..4], .little)) return false;
            if (comptime text.len == 5) if (pass.input[position + 4] != text[4]) return false;
        } else {
            if (!tokenizer_module.literal_valid(pass.input, position, literal)) return false;
        }

        if (comptime direct) pass.at = end;

        pass.emit(.{ .end = end, .kind = kind, .start = position });

        return true;
    }

    inline fn number_emit(pass: *Pass, comptime negative: bool, position: u32) bool {
        assert(position < pass.input.len);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        const end = tokenizer_module.number_valid_end(pass.input, position, negative) orelse
            return false;

        if (comptime direct) pass.at = end;

        pass.emit(.{ .end = end, .kind = .number, .start = position });

        return true;
    }

    inline fn scalar_emit(pass: *Pass, lead: u8, position: u32) bool {
        assert(position < pass.input.len);
        assert(pass.input[position] == lead);

        return switch (lead) {
            '"' => pass.string_emit(position),
            '-' => pass.number_emit(true, position),
            '0'...'9' => pass.number_emit(false, position),
            'f' => pass.literal_emit(.false_value, .false_value, position),
            'n' => pass.literal_emit(.null_value, .null_value, position),
            't' => pass.literal_emit(.true_value, .true_value, position),
            else => false,
        };
    }

    inline fn container_end(pass: *Pass, comptime container: Container, position: u32) Phase {
        assert(position < pass.input.len);
        assert(pass.depth > 0);
        assert(pass.stack[pass.depth - 1] == container);

        const kind: Kind = if (container == .object) .object_end else .array_end;

        pass.depth -= 1;
        pass.emit(.{ .end = position + 1, .kind = kind, .start = position });

        if (pass.depth == 0) return .done;
        return if (pass.stack[pass.depth - 1] == .object) .object_next else .array_next;
    }

    fn end_emit(pass: *Pass) Exit {
        assert(pass.count <= event_capacity);
        assert(pass.depth == 0);

        if (pass.count == event_capacity) return .paused;
        if (!pass.end_reached()) return .handed_over;

        const length: u32 = @intCast(pass.input.len);

        pass.emit(.{ .end = length, .kind = .end, .start = length });

        return .finished;
    }

    fn end_reached(pass: *Pass) bool {
        assert(pass.at < at_limit);
        assert(pass.depth == 0);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        if (comptime direct) return scalar.blank_end(pass.input, pass.at) == pass.input.len;

        if (pass.batch.indices[pass.at] != entry_sentinel) return false;

        if (!pass.batch.cursor.exhausted) {
            if (!pass.batch.refill(pass.input)) return false;

            pass.at = 0;

            if (pass.batch.indices[0] != entry_sentinel) return false;
        }

        assert(pass.batch.cursor.exhausted);

        return true;
    }
};

const Exit = enum {
    finished,
    handed_over,
    paused,
};

pub const events_produce = if (structural.functions_aligned)
    events_produce_aligned
else
    events_produce_unaligned;

noinline fn events_produce_aligned(tokenizer: *Tokenizer) align(4096) void {
    assert(tokenizer.event_index == tokenizer.event_count);
    assert(!tokenizer.indexed.handed_over);

    events_produce_body(tokenizer);
}

noinline fn events_produce_unaligned(tokenizer: *Tokenizer) void {
    assert(tokenizer.event_index == tokenizer.event_count);
    assert(!tokenizer.indexed.handed_over);

    events_produce_body(tokenizer);
}

inline fn events_produce_body(tokenizer: *Tokenizer) void {
    assert(tokenizer.event_index == tokenizer.event_count);
    assert(!tokenizer.indexed.handed_over);

    const walk = &tokenizer.indexed;

    if (comptime !direct) {
        const state = &walk.indexed;

        if (!walk.started) {
            walk.started = true;
            state.batch.cursor = cursor_empty;
            state.batch.indices[0] = entry_sentinel;
            state.indexer = .empty;
        }

        state.batch.cursor.indexer = &state.indexer;
        state.batch.cursor.indices = state.batch.indices[0..structural.index_capacity];
    }

    var pass: Pass = .{
        .at = walk.at,
        .batch = if (direct) {} else &walk.indexed.batch,
        .count = 0,
        .depth = tokenizer.scan_depth,
        .events = &tokenizer.events,
        .indent = 0,
        .input = tokenizer.input,
        .limit = @intCast(tokenizer.input.len -| scalar.margin_bytes),
        .stack = &tokenizer.frames.stack,
    };

    const exit = pass_run(&pass, phase_of(tokenizer));

    tokenizer.event_count = pass.count;
    tokenizer.event_index = 0;

    walk.at = pass.at;
    walk.handed_over = exit != .paused;

    if (pass.count > 0) {
        const last = tokenizer.events[pass.count - 1];

        tokenizer.scan_depth = pass.depth;
        tokenizer.scan_index = last.end;
        tokenizer.scan_state = state_after(last.kind, pass.depth);
    }

    assert(pass.count <= event_capacity);
    if (exit == .paused) assert(pass.count > 0);
}

fn phase_of(tokenizer: *const Tokenizer) Phase {
    assert(tokenizer.scan_depth <= depth_max);
    assert(tokenizer.scan_index <= tokenizer.input.len);

    const depth = tokenizer.scan_depth;

    return switch (tokenizer.scan_state) {
        .colon, .key => unreachable,
        .comma_or_end => if (tokenizer.frames.stack[depth - 1] == .object)
            .object_next
        else
            .array_next,
        .done => .done,
        .key_or_end => .object_open,
        .value => .start,
        .value_or_end => .array_open,
    };
}

fn state_after(kind: Kind, depth: u32) State {
    assert(depth <= depth_max);
    if (kind == .key) assert(depth > 0);

    return switch (kind) {
        .array_begin => .value_or_end,
        .end => .done,
        .key => .colon,
        .object_begin => .key_or_end,
        .array_end, .false_value, .null_value, .number, .object_end, .string, .true_value => {
            return if (depth == 0) .done else .comma_or_end;
        },
    };
}

inline fn pass_run(pass: *Pass, phase_first: Phase) Exit {
    assert(pass.count == 0);
    assert(pass.depth <= depth_max);
    assert(pass.at < at_limit);

    var position: u32 = 0;

    parse: switch (phase_first) {
        .start => {
            position = pass.take() orelse return .handed_over;

            continue :parse .value_top;
        },
        .done => return pass.end_emit(),
        inline .array_next, .array_open, .object_next, .object_open => |member| {
            const object = member == .object_next or member == .object_open;
            const next = member == .array_next or member == .object_next;
            const closing: u8 = if (object) '}' else ']';
            const container: Container = if (object) .object else .array;

            if (pass.count > event_capacity - events_member_max) return .paused;

            const entry = pass.take() orelse return .handed_over;
            const byte = pass.input[entry];

            if (next) {
                if (byte != ',') {
                    if (byte != closing) return .handed_over;

                    continue :parse pass.container_end(container, entry);
                }

                position = pass.take() orelse return .handed_over;
            } else {
                if (byte == closing) continue :parse pass.container_end(container, entry);

                position = entry;
            }

            if (object) {
                if (!pass.key_emit(position)) return .handed_over;

                position = pass.take() orelse return .handed_over;

                continue :parse .value_object;
            }

            continue :parse .value_array;
        },
        inline .value_array, .value_object, .value_top => |value| {
            switch (pass.input[position]) {
                inline '[', '{' => |open| {
                    const container: Container = if (open == '{') .object else .array;

                    if (!pass.container_begin(container, position)) return .handed_over;

                    continue :parse if (open == '{') .object_open else .array_open;
                },
                else => |lead| if (!pass.scalar_emit(lead, position)) return .handed_over,
            }

            switch (value) {
                .value_array => continue :parse .array_next,
                .value_object => continue :parse .object_next,
                .value_top => continue :parse .done,
                else => comptime unreachable,
            }
        },
    }
}

const testing = std.testing;

pub fn paths_compare(input: []const u8) !void {
    assert(input.len <= tokenizer_module.input_bytes_max);

    errdefer std.debug.print("disagreement on {s}\n", .{input});

    var indexed: Tokenizer = .init(input);
    var scanned: Tokenizer = .init(input);

    scanned.indexed.handed_over = true;

    assert(indexed.index == scanned.index);

    for (0..input.len + 3) |_| {
        const expected = scanned.next();
        const actual = indexed.next();

        try testing.expectEqualDeep(expected, actual);
        try testing.expectEqual(scanned.depth, indexed.depth);
        try testing.expectEqual(scanned.index, indexed.index);
        try testing.expectEqual(scanned.key_start, indexed.key_start);
        try testing.expectEqual(scanned.value_start, indexed.value_start);

        const token = expected catch {
            try testing.expectEqualDeep(scanned.diagnostic(), indexed.diagnostic());

            return;
        };

        if (token == .end) {
            const scanned_again = scanned.next();
            const indexed_again = indexed.next();

            try testing.expectEqualDeep(scanned_again, indexed_again);

            return;
        }
    }

    return error.StreamUnfinished;
}

test "the indexed tokenizer yields the scanner's stream on small documents" {
    const long: [200]u8 = @splat('s');
    const spaces: [120]u8 = @splat(' ');
    const long_blanks = "   \n \n" ++ spaces;

    const inputs = [_][]const u8{
        "{}",
        "[]",
        "[1, -2.5e3, true, false, null, \"a\", {\"k\": [[], {}]}]",
        "{\"a\\u0041b\": \"x\\ny\", \"c\": \"\\\"\"}",
        "  \"lone\"  ",
        "\"\"",
        "0",
        "-1.5e+3 ",
        "true",
        "false",
        "null",
        "[\"" ++ long ++ "\", 1]",
        "{\"a\": 1, \"b\": [1, 2, {\"c\": null}], \"d\": \"e\"}",
        "[1 2]",
        "[1\n" ++ long_blanks,
        "[1,\n" ++ long_blanks,
        "{\"a\":\n" ++ long_blanks,
        "[1]\n" ++ long_blanks,
        "{\"a\" 1}",
        "{\"a\":1,}",
        "[1,]",
        "[,1]",
        "{,}",
        "[tru]",
        "[truex]",
        "[nul",
        "[\"a\\q\"]",
        "[\"a",
        "[\"a\\",
        "\"a\\\"",
        "\"a\\\"   ",
        "",
        "   ",
        "{\"a\": [1, 2}",
        "[01]",
        "[1]x",
        "[1] [2]",
        "1 2",
        "\"a\"\"b\"",
        "[\"a\"\"b\"]",
        "[\"a\" ,\n \"b\" \n]",
        "{\"a\" : 1 , \"b\" : \"c\" }",
        "{\"a\\n\" : 1}",
        "{\"a\\q\" : 1}",
        "{\"a\"",
        "{\"a\":",
        "{\"a\":1",
        "[\x01]",
        "[\"\x01\"]",
        "[\"\xc3\xa9\", \"\xff\"]",
        "[\"\xc3\"]",
        "\xef\xbb\xbf[]",
    };

    for (inputs) |input| try paths_compare(input);
}

test "the indexed tokenizer agrees on every prefix and every single byte change" {
    const document =
        \\{"name": "caf\u00e9", "list": [1, -2.50, 3e4, true, false, null, {}, []], "nested":
        \\ {"a\nb": "\"", "deep": [[[{"x": "y"}]]]}, "last": "é"}
    ;
    const alphabet = "{}[]:,\"\\ -+.eE0129tfnaulrsx\x00\x1f\xc3\xed\xa0\xff";

    var buffer: [document.len]u8 = undefined;

    for (0..document.len + 1) |length| try paths_compare(document[0..length]);

    for (0..document.len) |position| {
        @memcpy(&buffer, document);

        for (alphabet) |byte| {
            buffer[position] = byte;

            try paths_compare(&buffer);
        }
    }
}

test "the indexed tokenizer crosses every batch and event buffer boundary" {
    const line = "{\"Name\":\"x\\ty\",\"PrivatePort\":12,\"z\":\"\\\\\"," ++
        "\"e\":[1,2,[]],\"s\" : \"t\" }";

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    for (0..96) |shift| {
        builder.clearRetainingCapacity();

        try builder.appendNTimes(testing.allocator, ' ', shift);
        try builder.append(testing.allocator, '[');

        for (0..512) |index| {
            if (index > 0) try builder.append(testing.allocator, ',');

            try builder.appendSlice(testing.allocator, line);
        }

        try builder.append(testing.allocator, ']');

        try paths_compare(builder.items);
    }
}

test "the indexed tokenizer never exposes a string a later batch refuses" {
    const element = "\"abcdefgh\",";
    const element_count: u32 = 20_000;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    for ([_][]const u8{ "\"\xff\"", "\"\x01\"", "\"\\q\"", "\"\xc3\"", "\"", "x" }) |last| {
        builder.clearRetainingCapacity();

        try builder.append(testing.allocator, '[');

        for (0..element_count) |_| try builder.appendSlice(testing.allocator, element);

        try builder.appendSlice(testing.allocator, last);
        try builder.append(testing.allocator, ']');

        try paths_compare(builder.items);

        const middle = @divFloor(builder.items.len, 2);

        builder.items[middle - middle % element.len + 2] = 0xff;

        try paths_compare(builder.items);
    }
}

test "the indexed tokenizer agrees across a failed refill" {
    const tail_bytes: u32 = 70;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    try builder.append(testing.allocator, '[');
    try builder.appendNTimes(testing.allocator, ' ', structural.scan_bytes_max - 2);
    try builder.append(testing.allocator, '"');
    try builder.appendNTimes(testing.allocator, 'a', tail_bytes);
    try builder.appendSlice(testing.allocator, "\x01\"]");

    try paths_compare(builder.items);
}

test "the indexed tokenizer agrees at the nesting limit" {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    for ([_]u32{ depth_max - 1, depth_max, depth_max + 1 }) |depth| {
        builder.clearRetainingCapacity();

        try builder.appendNTimes(testing.allocator, '[', depth);
        try builder.appendNTimes(testing.allocator, ']', depth);

        try paths_compare(builder.items);

        builder.clearRetainingCapacity();

        for (0..depth) |_| try builder.appendSlice(testing.allocator, "{\"a\":");

        try builder.append(testing.allocator, '1');
        try builder.appendNTimes(testing.allocator, '}', depth);

        try paths_compare(builder.items);
    }
}

test "the indexed tokenizer survives being moved between refills" {
    const line = "[1,\"two\",{\"three\":3}],";

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    try builder.append(testing.allocator, '[');

    for (0..2_000) |_| try builder.appendSlice(testing.allocator, line);

    try builder.appendSlice(testing.allocator, "0]");

    var scanned: Tokenizer = .init(builder.items);
    var moved: Tokenizer = .init(builder.items);

    scanned.indexed.handed_over = true;

    const copy = try testing.allocator.create(Tokenizer);
    defer testing.allocator.destroy(copy);

    for (0..builder.items.len) |_| {
        const expected = try scanned.next();
        const actual = try moved.next();

        try testing.expectEqualDeep(expected, actual);

        if (expected == .end) return;

        if (moved.event_index == moved.event_count) {
            copy.* = moved;
            moved = copy.*;
        }
    }

    return error.StreamUnfinished;
}
