const std = @import("std");
const builtin = @import("builtin");

const storage_module = @import("storage.zig");
const string = @import("string.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Record = storage_module.Record;

const byte_highs: u64 = 0x8080808080808080;
const byte_lows: u64 = 0x0101010101010101;
const byte_sevens: u64 = 0x7f7f7f7f7f7f7f7f;
const container_object: u32 = 1 << 31;
const container_index_mask: u32 = container_object - 1;
const container_root: u32 = std.math.maxInt(u32);
const depth_max = tokenizer_module.depth_max;
const digits_overrun: u64 = std.math.maxInt(u64) - 1;
const escaped_bit: u64 = 1 << 62;
const input_bytes_max = tokenizer_module.input_bytes_max;
const link_of = storage_module.link_of;
const newline_space: u16 = '\n' | @as(u16, ' ') << 8;
pub const margin_bytes: u32 = 64;
const padded_bytes_max: u32 = 256;
const position_failed: u64 = std.math.maxInt(u64);
const reach_bytes: u64 = 1 + indent_words * word_bytes;
const indent_words: u64 = 4;
const Lane = @Vector(lane_bytes, u8);
const LaneBits = @Vector(lane_bytes, u1);
const lane_bytes: u32 = 16;
const lanes_enabled = std.simd.suggestVectorLength(u8) != null and
    (builtin.target.cpu.arch == .x86_64 or builtin.target.cpu.arch.isWasm());
const run_mask_shift: u6 = if (lanes_enabled) 0 else 3;
const run_stride: u32 = if (lanes_enabled) lane_bytes else word_bytes;
const triple_lane_bytes: u64 = 3 * @divFloor(lane_bytes, 3);
const triple_lane_mask: Lane = triple_lane_of(.{ .follow = 0xc0, .lead = 0xf0 });
const triple_lane_want: Lane = triple_lane_of(.{ .follow = 0x80, .lead = 0xe0 });
const word_bytes: u64 = @sizeOf(u64);

comptime {
    assert(input_bytes_max < position_failed);
    assert(input_bytes_max < escaped_bit);
    assert(position_failed & escaped_bit != 0);
    assert(container_index_mask >= storage_module.node_count_limit);
    assert(container_root & container_object != 0);
    assert(word_bytes == 8);
    assert(margin_bytes >= reach_bytes + 2 * word_bytes + "false".len);
    assert(triple_lane_bytes < lane_bytes);
    assert(run_stride % word_bytes == 0);
}

pub const Built = packed struct(u96) {
    depth_seen: u32,
    node_count: u32,
    text_count: u32,

    const failed: Built = .{ .depth_seen = 0, .node_count = 0, .text_count = 0 };
};

pub fn build(input: []const u8, records: []Record, text: []u8) ?Built {
    assert(input.len <= input_bytes_max);
    assert(records.len > 0);
    assert(text.len <= storage_module.text_bytes_limit);

    if (input.len == 0) return null;

    const built = if (input.len <= padded_bytes_max)
        build_padded(input, records, text)
    else if (!utf8_accepted(input))
        Built.failed
    else if (records.len >= input.len)
        @call(.never_inline, document_parse, .{ .unchecked, .bare, input, records, text })
    else
        @call(.never_inline, document_parse, .{ .checked, .bare, input, records, text });

    if (built.node_count == 0) return null;
    return built;
}

inline fn build_padded(input: []const u8, records: []Record, text: []u8) Built {
    assert(input.len > 0);
    assert(input.len <= padded_bytes_max);
    assert(records.len > 0);
    assert(text.len <= storage_module.text_bytes_limit);

    var buffer: [padded_bytes_max + margin_bytes]u8 = undefined;
    const padded = buffer[0 .. input.len + margin_bytes];

    const high = padded_copy(padded, input);

    padded[input.len..][0..margin_bytes].* = @splat(' ');

    if (high) {
        if (!structural.utf8_valid(input)) return Built.failed;
    }

    return if (records.len >= input.len)
        @call(.always_inline, document_parse, .{ .unchecked, .padded, padded, records, text })
    else
        @call(.always_inline, document_parse, .{ .checked, .padded, padded, records, text });
}

fn utf8_accepted(input: []const u8) bool {
    assert(input.len > padded_bytes_max);
    assert(input.len <= input_bytes_max);

    if (!high_present(input)) return true;
    return structural.utf8_valid(input);
}

fn high_present(input: []const u8) bool {
    assert(input.len >= lane_bytes);
    assert(input.len <= input_bytes_max);

    var seen: Lane = @splat(0);
    var index: u64 = 0;

    while (input.len - index > lane_bytes) : (index += lane_bytes) {
        seen |= input[@intCast(index)..][0..lane_bytes].*;
    }

    seen |= input[input.len - lane_bytes ..][0..lane_bytes].*;

    const signed: @Vector(lane_bytes, i8) = @bitCast(seen);

    return @reduce(.Or, signed < @as(@Vector(lane_bytes, i8), @splat(0)));
}

const Padding = enum {
    bare,
    padded,
};

pub const Close = struct {
    escaped: bool,
    position: u32,

    pub const failed: Close = .{ .escaped = false, .position = 0 };
};

pub inline fn blank_end(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    return @intCast(blank_skip(input, start));
}

pub const Reach = struct {
    limit: u32,
    open: u32,
};

pub const Take = struct {
    at: *u32,
    indent: *u32,
    limit: u32,
};

pub inline fn token_take(input: []const u8, take: Take) ?u32 {
    assert(take.at.* <= input.len);
    assert(take.limit <= input.len);

    const at = take.at.*;

    if (at < take.limit) {
        @branchHint(.likely);

        const first = input[at];

        if (first > ' ') {
            take.at.* = at + 1;

            return at;
        }

        const pair = std.mem.readInt(u16, input[at..][0..2], .little);

        if (pair == newline_space) {
            assert(at < take.limit);

            return newline_take(input, take, at + 1);
        }

        if (pair >> 8 > ' ') {
            @branchHint(.likely);

            if (!blank_table[first]) return null;

            const token = at + 1;

            assert(token < input.len);

            take.at.* = token + 1;

            return token;
        }
    }

    const end = blank_end_far(input, at);
    if (end == input.len) return null;

    assert(end >= at);

    take.at.* = end + 1;

    return end;
}

inline fn newline_take(input: []const u8, take: Take, start: u32) ?u32 {
    assert(start > 0);
    assert(start < input.len);
    assert(take.indent.* <= indent_words * word_bytes);

    const count = take.indent.*;
    const predicted = start + count;

    assert(predicted >= start);

    if (comptime lanes_enabled) {
        const measured: u32 = @ctz(~lane_spaces(input, start));

        if (measured == count) {
            @branchHint(.likely);

            if (input[predicted] > ' ') {
                @branchHint(.likely);

                take.at.* = predicted + 1;

                return predicted;
            }
        } else {
            const stop = start + measured;

            assert(stop >= start);

            if (input[stop] > ' ') {
                @branchHint(.likely);

                take.indent.* = measured;
                take.at.* = stop + 1;

                return stop;
            }

            if (indent_predicted(input, start, count)) {
                take.at.* = predicted + 1;

                return predicted;
            }
        }
    } else {
        if (indent_predicted(input, start, count)) {
            take.at.* = predicted + 1;

            return predicted;
        }
    }

    const after = indent_measure_far(input, start);

    take.indent.* = after.count;

    if (after.position == input.len) return null;

    assert(after.position > start);

    take.at.* = after.position + 1;

    return after.position;
}

const Indented = packed struct(u64) {
    count: u32,
    position: u32,
};

inline fn indent_predicted(input: []const u8, start: u64, count: u32) bool {
    assert(count <= indent_words * word_bytes);
    assert(start < input.len);

    if (!indent_matches(input, start, count)) return false;

    return input[@intCast(start + count)] > ' ';
}

noinline fn indent_measure_far(input: []const u8, start: u32) Indented {
    assert(start < input.len);
    assert(input[start] == ' ');

    const index: u32 = @intCast(indent_skip(input, start));
    const measured = index - start;

    if (input[index] > ' ') return .{ .count = measured, .position = index };

    return .{ .count = measured, .position = blank_end_far(input, index) };
}

pub noinline fn blank_end_far(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    return @intCast(blank_skip(input, start));
}

pub inline fn string_close(input: []const u8, reach: Reach) Close {
    assert(reach.open < input.len);
    assert(input[reach.open] == '"');

    var index: u64 = reach.open + 1;

    while (index < reach.limit) {
        if (lanes_enabled) {
            const special = special_lanes(input, index);

            if (special == 0) {
                index += lane_bytes;

                continue;
            }

            index += @ctz(special);
        } else {
            const special = special_mask(word_at(input, index));

            if (special == 0) {
                index += word_bytes;

                continue;
            }

            index += @ctz(special) >> 3;
        }

        const current = input[@intCast(index)];

        if (current == '"') {
            @branchHint(.likely);

            return .{ .escaped = false, .position = @intCast(index) };
        }

        if (current < 0x80) break;

        index = sequences_skip_far(input, index);
        if (index == position_failed) return .failed;
    }

    return string_close_slow(input, index);
}

pub inline fn key_close(input: []const u8, reach: Reach) Close {
    assert(reach.open < input.len);
    assert(input[reach.open] == '"');

    var index: u64 = reach.open + 1;

    while (index < reach.limit) {
        const special = special_mask(word_at(input, index));

        if (special != 0) {
            index += key_stop_offset(special);

            if (input[@intCast(index)] == '"') {
                @branchHint(.likely);

                return .{ .escaped = false, .position = @intCast(index) };
            }

            break;
        }

        index += word_bytes;
    }

    return string_close_slow(input, index);
}

noinline fn string_close_slow(input: []const u8, from: u64) Close {
    assert(from <= input.len);
    assert(from > 0);

    var escaped = false;
    var index = from;

    for (0..input.len) |_| {
        index = special_find(input, index);
        if (index == input.len) return .failed;

        const current = input[@intCast(index)];

        if (current == '"') return .{ .escaped = escaped, .position = @intCast(index) };

        if (current == '\\') {
            escaped = true;

            if (index + 1 < input.len) {
                if (escape_bytes[input[@intCast(index + 1)]] != 0) {
                    index += 2;

                    continue;
                }
            }

            const text = input[@intCast(index)..];
            const length = tokenizer_module.escape_length(text) catch return .failed;

            index += length;
        } else {
            if (current < 0x20) return .failed;

            index = sequences_skip(input, index, .inlined);
            if (index == position_failed) return .failed;
        }
    }

    return .failed;
}

const Bounds = enum {
    checked,
    unchecked,
};

const Cold = struct {
    depth: u32,
    depth_seen: u32,
    escaped_size: u32,
    frames: [depth_max]Frame,
    indent: u32,
    node: u32,
    records: []Record,
    text: []u8,
    text_count: u32,
};

const Exit = struct {
    outcome: Outcome,
    state: State,

    const failed: Exit = .{ .outcome = .failed, .state = .done };
};

const Extent = struct {
    end: u64,
    start: u64,
};

const Far = struct {
    input: []const u8,
    limit: u64,
};

const Frame = struct {
    children: u32,
    container: u32,
};

const Colon = enum {
    blank,
    failed,
    near,
    ready,
};

const Outcome = enum(u8) {
    done,
    failed,
    near,
};

const Resume = struct {
    index: u64,
    open: u64,
};

const Placement = enum {
    inlined,
    outlined,
};

const Role = enum {
    key,
    value,
};

const RunSpot = struct {
    source: u64,
    written: u64,
};

const TripleBytes = struct {
    follow: u8,
    lead: u8,
};

const State = enum(u8) {
    array_first,
    array_next,
    colon,
    done,
    key,
    key_ready,
    member_end,
    object_first,
    object_next,
    value,
    value_ready,
};

const Value = enum {
    array,
    failed,
    near,
    object,
    scalar,
};

const ValueClass = enum(u8) {
    array,
    false_value,
    invalid,
    negative,
    null_value,
    number,
    object,
    string,
    true_value,
};

const Walked = packed struct(u48) {
    node: u32,
    outcome: Outcome,
    state: State,
};

const Zone = enum {
    far,
    near,
};

const blank_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (" \t\n\r") |byte| table[byte] = true;

    break :table table;
};

const escape_bytes: [256]u8 = table: {
    var table: [256]u8 = @splat(0);

    for ("\"\\/bfnrt", "\"\\/\x08\x0c\n\r\t") |letter, byte| table[letter] = byte;

    break :table table;
};

const stop_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (0..0x20) |byte| table[byte] = true;

    table['"'] = true;
    table['\\'] = true;

    break :table table;
};

const special_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (0..0x20) |byte| table[byte] = true;
    for (0x80..0x100) |byte| table[byte] = true;

    table['"'] = true;
    table['\\'] = true;

    break :table table;
};

const value_classes: [256]ValueClass = classes: {
    var table: [256]ValueClass = @splat(.invalid);

    for ('0'..'9' + 1) |digit| table[digit] = .number;

    table['"'] = .string;
    table['-'] = .negative;
    table['['] = .array;
    table['f'] = .false_value;
    table['n'] = .null_value;
    table['t'] = .true_value;
    table['{'] = .object;

    break :classes table;
};

fn document_parse(
    comptime bounds: Bounds,
    comptime padding: Padding,
    input: []const u8,
    records: []Record,
    text: []u8,
) Built {
    assert(input.len <= input_bytes_max);
    assert(records.len > 0);
    assert(text.len <= storage_module.text_bytes_limit);

    var cold: Cold = .{
        .depth = 0,
        .depth_seen = 0,
        .escaped_size = 0,
        .frames = undefined,
        .indent = 0,
        .node = 0,
        .records = records,
        .text = text,
        .text_count = 0,
    };

    var parser: Parser = .{
        .children = 0,
        .cold = &cold,
        .container = container_root,
        .input = input,
        .limit = if (input.len > margin_bytes) input.len - margin_bytes else 0,
        .position = 0,
        .slots = records,
    };

    var node: u32 = 0;
    var state: State = .value;

    if (input.len > margin_bytes) {
        const far = document_walk(bounds, .far, &parser, state);
        if (far.outcome == .failed) return Built.failed;

        node = far.node;
        state = far.state;
    }

    if (padding == .padded) {
        assert(input.len > margin_bytes);

        if (state != .done) return Built.failed;

        const content = input[0 .. input.len - margin_bytes];
        if (parser.position > content.len) return Built.failed;
        if (blank_skip(content, parser.position) != content.len) return Built.failed;

        parser.position = input.len;

        return parser.built(node);
    }

    const exit = document_walk(bounds, .near, &parser, state);
    if (exit.outcome != .done) return Built.failed;
    return parser.built(exit.node);
}

const document_walk = if (structural.functions_aligned)
    document_walk_aligned
else
    document_walk_unaligned;

noinline fn document_walk_aligned(
    comptime bounds: Bounds,
    comptime zone: Zone,
    parser: *Parser,
    state: State,
) align(64) Walked {
    assert(parser.position <= parser.input.len);
    if (zone == .far) assert(parser.input.len > margin_bytes);

    var walk = parser.*;
    defer parser.synchronize(&walk);

    walk.slots = parser.cold.records[parser.cold.node..];

    const exit = walk_states(bounds, zone, &walk, state);

    return .{ .node = walk.node_index(), .outcome = exit.outcome, .state = exit.state };
}

noinline fn document_walk_unaligned(
    comptime bounds: Bounds,
    comptime zone: Zone,
    parser: *Parser,
    state: State,
) Walked {
    assert(parser.position <= parser.input.len);
    if (zone == .far) assert(parser.input.len > margin_bytes);

    var walk = parser.*;
    defer parser.synchronize(&walk);

    walk.slots = parser.cold.records[parser.cold.node..];

    const exit = walk_states(bounds, zone, &walk, state);

    return .{ .node = walk.node_index(), .outcome = exit.outcome, .state = exit.state };
}

inline fn walk_states(
    comptime bounds: Bounds,
    comptime zone: Zone,
    walk: *Parser,
    state: State,
) Exit {
    assert(walk.position <= walk.input.len);
    assert(zone == .near or state == .value);

    parse: switch (state) {
        inline .array_first, .array_next, .object_first, .object_next => |member| {
            const object = member == .object_first or member == .object_next;
            const next = member == .array_next or member == .object_next;
            const closing: u8 = if (object) '}' else ']';

            const current = walk.blank_byte(zone);
            if (zone == .far) if (current == 0) return .{ .outcome = .near, .state = member };

            const ended = if (next) current != ',' else current == closing;

            if (ended) {
                if (current != closing) return Exit.failed;

                walk.container_close(if (object) .object else .array);

                continue :parse .member_end;
            }

            if (next) {
                walk.position += 1;

                continue :parse if (object) .key else .value;
            }

            continue :parse if (object) .key_ready else .value_ready;
        },
        .colon => switch (walk.colon_pass(zone)) {
            .blank => continue :parse .value,
            .failed => return Exit.failed,
            .near => return .{ .outcome = .near, .state = .colon },
            .ready => continue :parse .value_ready,
        },
        .done => return walk.document_end(zone),
        inline .key, .key_ready => |key| switch (walk.key_add(bounds, zone, key == .key_ready)) {
            .blank => continue :parse .colon,
            .failed => return Exit.failed,
            .near => return .{ .outcome = .near, .state = key },
            .ready => continue :parse .value_ready,
        },
        .member_end => {
            if (walk.container & container_object == 0) continue :parse .array_next;
            if (walk.container == container_root) continue :parse .done;
            continue :parse .object_next;
        },
        inline .value, .value_ready => |value| switch (walk.value_step(bounds, zone, value)) {
            .array => continue :parse .array_first,
            .failed => return Exit.failed,
            .near => return .{ .outcome = .near, .state = value },
            .object => continue :parse .object_first,
            .scalar => continue :parse .member_end,
        },
    }
}

const Parser = struct {
    children: u32,
    cold: *Cold,
    container: u32,
    input: []const u8,
    limit: u64,
    position: u64,
    slots: []Record,

    inline fn built(parser: *const Parser, node: u32) Built {
        assert(parser.cold.depth == 0);
        assert(parser.position == parser.input.len);
        assert(node > 0);

        return .{
            .depth_seen = parser.cold.depth_seen,
            .node_count = node,
            .text_count = parser.cold.text_count,
        };
    }

    inline fn synchronize(parser: *Parser, walk: *const Parser) void {
        assert(walk.position <= walk.input.len);
        assert(walk.cold == parser.cold);

        parser.children = walk.children;
        parser.container = walk.container;
        parser.position = walk.position;
        parser.cold.node = walk.node_index();
    }

    inline fn node_index(parser: *const Parser) u32 {
        const base = @intFromPtr(parser.cold.records.ptr);
        const slot = @intFromPtr(parser.slots.ptr);

        assert(slot >= base);
        assert(slot - base <= parser.cold.records.len * @sizeOf(Record));

        return @intCast(@divExact(slot - base, @sizeOf(Record)));
    }

    inline fn colon_pass(parser: *Parser, comptime zone: Zone) Colon {
        assert(parser.position <= parser.input.len);
        assert(parser.container & container_object != 0);

        const current = parser.blank_byte(zone);
        if (zone == .far) if (current == 0) return .near;
        if (current != ':') return .failed;

        const colon = parser.position;

        parser.position = colon + 1;

        if (zone == .near) return .blank;
        if (colon > parser.limit) return .blank;

        const next = parser.input[@intCast(colon + 1)];
        if (next > ' ') return .ready;
        if (next != ' ') return .blank;
        if (parser.input[@intCast(colon + 2)] <= ' ') return .blank;

        parser.position = colon + 2;

        return .ready;
    }

    inline fn colon_follow(parser: *Parser) bool {
        assert(parser.position > 0);
        assert(parser.input[@intCast(parser.position - 1)] == '"');

        const input = parser.input;
        const colon = parser.position;

        if (colon > parser.limit) return false;
        if (input[@intCast(colon)] != ':') return false;

        const next = input[@intCast(colon + 1)];

        if (next > ' ') {
            parser.position = colon + 1;

            return true;
        }

        if (next != ' ') return false;
        if (input[@intCast(colon + 2)] <= ' ') return false;

        parser.position = colon + 2;

        return true;
    }

    inline fn key_add(
        parser: *Parser,
        comptime bounds: Bounds,
        comptime zone: Zone,
        comptime ready: bool,
    ) Colon {
        assert(parser.position <= parser.input.len);
        assert(parser.container & container_object != 0);

        const current = if (ready) parser.byte(zone) else parser.blank_byte(zone);
        if (zone == .far) if (current == 0) return .near;
        if (current != '"') return .failed;
        if (parser.string_add(bounds, zone, .key) == .failed) return .failed;
        if (zone == .far) if (parser.colon_follow()) return .ready;
        return .blank;
    }

    inline fn document_end(parser: *Parser, comptime zone: Zone) Exit {
        assert(parser.cold.depth == 0);
        assert(parser.container == container_root);

        if (zone == .far) return .{ .outcome = .near, .state = .done };

        parser.position = blank_skip(parser.input, parser.position);

        if (parser.position != parser.input.len) return Exit.failed;
        return .{ .outcome = .done, .state = .done };
    }

    inline fn blank_byte(parser: *Parser, comptime zone: Zone) u8 {
        assert(parser.position <= parser.input.len);
        assert(parser.limit <= parser.input.len);

        const input = parser.input;
        const start = parser.position;

        if (zone == .near) {
            parser.position = blank_skip(input, start);

            return parser.byte(.near);
        }

        if (start > parser.limit) return 0;

        const at: usize = @intCast(start);
        const first = input[at];
        if (first > ' ') return first;

        const second = input[at + 1];

        if (second > ' ') {
            if (blank_table[first]) {
                parser.position = start + 1;

                assert(input[@intCast(parser.position)] == second);

                return second;
            }
        }

        if (first == '\n') {
            if (second == ' ') {
                const after = parser.indent_pass(start + 1);
                if (after != 0) assert(input[@intCast(parser.position)] == after);
                return after;
            }
        }

        parser.position = blank_skip_run(input, start);

        if (parser.position > parser.limit) return 0;

        const position_at: usize = @intCast(parser.position);

        return input[position_at];
    }

    inline fn indent_pass(parser: *Parser, start: u64) u8 {
        assert(start <= parser.limit + 1);
        assert(parser.input[@intCast(start)] == ' ');

        const input = parser.input;
        const cold = parser.cold;
        const predicted = start + cold.indent;
        const predicted_at: usize = @intCast(predicted);
        const expected = input[predicted_at];

        if (expected > ' ') {
            if (indent_matches(input, start, cold.indent)) {
                parser.position = predicted;

                return expected;
            }
        }

        const index = indent_skip(input, start);

        cold.indent = @intCast(index - start);
        parser.position = index;

        const index_at: usize = @intCast(index);
        const after = input[index_at];
        if (after > ' ') return after;

        parser.position = blank_skip_run(input, index);

        if (parser.position > parser.limit) return 0;

        const at: usize = @intCast(parser.position);

        return input[at];
    }

    inline fn byte(parser: *const Parser, comptime zone: Zone) u8 {
        assert(parser.position <= parser.input.len);
        if (zone == .far) assert(parser.position <= parser.limit + reach_bytes);

        if (zone == .near) {
            if (parser.position == parser.input.len) return 0;
        }

        const at: usize = @intCast(parser.position);

        return parser.input[at];
    }

    inline fn value_step(
        parser: *Parser,
        comptime bounds: Bounds,
        comptime zone: Zone,
        comptime state: State,
    ) Value {
        comptime assert(state == .value or state == .value_ready);
        assert(parser.position <= parser.input.len);

        const current = if (state == .value_ready) parser.byte(zone) else parser.blank_byte(zone);
        if (zone == .far) if (current == 0) return .near;
        return parser.value_add(bounds, zone, current);
    }

    inline fn value_add(
        parser: *Parser,
        comptime bounds: Bounds,
        comptime zone: Zone,
        current: u8,
    ) Value {
        assert(parser.position <= parser.input.len);
        if (zone == .far) assert(current != 0);

        if (bounds == .checked) {
            if (parser.slots.len == 0) return .failed;
        }

        if (current == '"') return parser.string_add(bounds, zone, .value);

        return switch (value_classes[current]) {
            .array => parser.container_open(.array),
            .false_value => parser.literal_add(zone, .false_value),
            .invalid => .failed,
            .negative => parser.number_add(zone, true),
            .null_value => parser.literal_add(zone, .null_value),
            .number => parser.number_add(zone, false),
            .object => parser.container_open(.object),
            .string => parser.string_add(bounds, zone, .value),
            .true_value => parser.literal_add(zone, .true_value),
        };
    }

    inline fn container_open(parser: *Parser, comptime kind: Record.Kind) Value {
        comptime assert(kind == .array or kind == .object);
        assert(parser.position < parser.input.len);

        const cold = parser.cold;
        if (cold.depth == depth_max) return .failed;

        const node = parser.node_index();
        const start = parser.position;

        cold.frames[cold.depth] = .{
            .children = parser.children + 1,
            .container = parser.container,
        };

        parser.node_add(kind, .{ .end = start + 1, .start = start });
        parser.children = 0;
        parser.container = if (kind == .object) node | container_object else node;
        parser.position = start + 1;
        cold.depth += 1;
        cold.depth_seen = @max(cold.depth_seen, cold.depth);

        return if (kind == .object) .object else .array;
    }

    inline fn container_close(parser: *Parser, comptime kind: Record.Kind) void {
        comptime assert(kind == .array or kind == .object);
        assert(parser.cold.depth > 0);
        assert(parser.position < parser.input.len);

        const record = &parser.cold.records[parser.container & container_index_mask];

        assert(record.kind() == kind);
        assert(parser.position >= record.start);

        record.end = @intCast(parser.position + 1);
        record.link |= parser.node_index();
        record.size = if (kind == .object) @divExact(parser.children, 2) else parser.children;

        const cold = parser.cold;

        cold.depth -= 1;
        parser.children = cold.frames[cold.depth].children;
        parser.container = cold.frames[cold.depth].container;
        parser.position += 1;
    }

    inline fn string_add(
        parser: *Parser,
        comptime bounds: Bounds,
        comptime zone: Zone,
        comptime role: Role,
    ) Value {
        assert(parser.position < parser.input.len);
        assert(parser.input[@intCast(parser.position)] == '"');

        const capacity_checked = bounds == .checked and role == .key;

        if (capacity_checked) {
            if (parser.slots.len == 0) return .failed;
        }

        const input = parser.input;
        const open = parser.position;

        const result = switch (zone) {
            .far => string_close_far(parser.far(), open, parser.cold, role),
            .near => string_close_rest(input, .{ .index = open + 1, .open = open }, parser.cold),
        };

        if (result == position_failed) return .failed;

        const close = result & ~escaped_bit;

        parser.node_add(.string, .{ .end = close + 1, .start = open });

        if (result & escaped_bit != 0) {
            const cold = parser.cold;
            const record = &cold.records[parser.node_index() - 1];

            record.link = link_of(.string_escaped, cold.text_count);
            record.size = cold.escaped_size;
            cold.text_count += cold.escaped_size;

            assert(record.size > 0);
            assert(record.size < close - open - 1);
        }

        parser.children += 1;
        parser.position = close + 1;

        return .scalar;
    }

    inline fn literal_add(parser: *Parser, comptime zone: Zone, comptime kind: Record.Kind) Value {
        comptime assert(kind == .false_value or kind == .null_value or kind == .true_value);
        assert(parser.position < parser.input.len);

        const text = comptime switch (kind) {
            .false_value => "false",
            .null_value => "null",
            .true_value => "true",
            else => unreachable,
        };

        const rest = parser.input[@intCast(parser.position)..];

        if (zone == .near) {
            if (rest.len < text.len) return .failed;
        }

        const word = std.mem.readInt(u32, rest[0..4], .little);
        if (word != comptime std.mem.readInt(u32, text[0..4], .little)) return .failed;
        if (text.len == 5) if (rest[4] != text[4]) return .failed;

        parser.scalar_add(kind, parser.position + text.len);

        return .scalar;
    }

    inline fn number_add(parser: *Parser, comptime zone: Zone, comptime negative: bool) Value {
        assert(parser.position < parser.input.len);
        if (negative) assert(parser.input[@intCast(parser.position)] == '-');

        const input = parser.input;
        const start = parser.position;

        const end = switch (zone) {
            .far => number_end_far(parser.far(), start, negative),
            .near => number_end(input, start, negative),
        };

        if (end == position_failed) return .failed;

        parser.scalar_add(.number, end);

        return .scalar;
    }

    inline fn scalar_add(parser: *Parser, comptime kind: Record.Kind, end: u64) void {
        comptime assert(kind != .array);
        comptime assert(kind != .object);
        assert(end > parser.position);

        parser.node_add(kind, .{ .end = end, .start = parser.position });
        parser.children += 1;
        parser.position = end;
    }

    inline fn node_add(parser: *Parser, comptime kind: Record.Kind, extent: Extent) void {
        comptime assert(kind != .string_escaped);
        assert(extent.start < extent.end);

        const record = &parser.slots[0];

        record.end = @intCast(extent.end);
        record.link = comptime link_of(kind, 0);
        record.size = 0;
        record.start = @intCast(extent.start);

        parser.slots = parser.slots[1..];
    }

    inline fn far(parser: *const Parser) Far {
        assert(parser.limit + margin_bytes == parser.input.len);
        assert(parser.position <= parser.limit + reach_bytes);

        return .{ .input = parser.input, .limit = parser.limit };
    }
};

inline fn word_at(input: []const u8, index: u64) u64 {
    assert(index <= input.len);
    assert(input.len - index >= word_bytes);

    return std.mem.readInt(u64, input[@intCast(index)..][0..word_bytes], .little);
}

inline fn indent_skip(input: []const u8, start: u64) u64 {
    assert(start < input.len);
    assert(input.len - start >= indent_words * word_bytes);

    var masks: [indent_words]u64 = undefined;

    inline for (&masks, 0..) |*mask, word_index| {
        mask.* = spaces_mask(word_at(input, start + word_index * word_bytes));
    }

    const result = found: {
        inline for (masks, 0..) |mask, word_index| {
            if (mask != 0) break :found start + word_index * word_bytes + (@ctz(mask) >> 3);
        }

        break :found start + indent_words * word_bytes;
    };

    assert(result >= start);
    assert(result <= start + indent_words * word_bytes);

    return result;
}

inline fn indent_matches(input: []const u8, start: u64, count: u32) bool {
    assert(count <= indent_words * word_bytes);
    assert(input.len - start >= indent_words * word_bytes);

    const spaces = byte_lows * ' ';

    if (count < word_bytes) {
        if (count == 0) return false;

        const head = word_at(input, start) ^ spaces;

        return head << @intCast((word_bytes - count) * 8) == 0;
    }

    var differ = word_at(input, start + count - word_bytes) ^ spaces;

    for (0..@intCast(@divFloor(count, word_bytes))) |word_index| {
        differ |= word_at(input, start + word_index * word_bytes) ^ spaces;
    }

    return differ == 0;
}

inline fn spaces_mask(word: u64) u64 {
    const spaces = word ^ (byte_lows * ' ');
    const result = (((spaces & byte_sevens) + byte_sevens) | spaces) & byte_highs;

    assert(result & ~byte_highs == 0);

    return result;
}

inline fn blank_skip(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    if (start == input.len) return start;
    if (input[@intCast(start)] > ' ') return start;

    const next = start + 1;

    const result = skipped: {
        if (next < input.len) {
            if (input[@intCast(next)] > ' ') {
                if (input[@intCast(start)] == ' ') break :skipped next;
            }
        }

        break :skipped blank_skip_run(input, start);
    };

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

inline fn blank_skip_run(input: []const u8, start: u64) u64 {
    assert(start < input.len);
    assert(input[@intCast(start)] <= ' ');

    var index = start;

    for (0..@intCast(input.len - start)) |_| {
        const current = input[@intCast(index)];

        if (current == ' ') {
            index = spaces_skip(input, index + 1);
        } else {
            if (!blank_table[current]) return index;

            index += 1;
        }

        if (index == input.len) return index;
    }

    return index;
}

inline fn spaces_skip(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const word_count = @divFloor(input.len - start, word_bytes);

    const result = found: {
        for (0..@intCast(word_count)) |word_index| {
            const index = start + word_index * word_bytes;
            const others = spaces_mask(word_at(input, index));
            if (others != 0) break :found index + (@ctz(others) >> 3);
        }

        const rest: usize = @intCast(start + word_count * word_bytes);

        for (input[rest..], rest..) |current, position| {
            if (current != ' ') break :found position;
        }

        break :found input.len;
    };

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

inline fn string_close_far(far: Far, open: u64, cold: *Cold, comptime role: Role) u64 {
    assert(open <= far.limit + reach_bytes);
    assert(far.input[@intCast(open)] == '"');

    const input = far.input;
    const limit = far.limit;

    var index = open + 1;

    while (index <= limit) {
        if (comptime lanes_enabled) {
            const stops = stop_lanes(input, index);

            if (stops == 0) {
                index += lane_bytes;

                continue;
            }

            index += if (role == .value) @ctz(stops) else lane_stop_offset(stops);
        } else {
            const first = stop_mask(word_at(input, index));

            if (first == 0) {
                const second = stop_mask(word_at(input, index + word_bytes));

                if (second == 0) {
                    index += 2 * word_bytes;

                    continue;
                }

                index += word_bytes + stop_offset(second, role);
            } else {
                index += stop_offset(first, role);
            }
        }

        return string_stop(input, .{ .index = index, .open = open }, cold);
    }

    return string_close_rest(input, .{ .index = index, .open = open }, cold);
}

inline fn string_stop(input: []const u8, at: Resume, cold: *Cold) u64 {
    assert(at.index < input.len);
    assert(stop_table[input[@intCast(at.index)]]);

    const current = input[@intCast(at.index)];
    if (current == '"') return at.index;
    if (current == '\\') return escaped_close(input, at, cold);
    return position_failed;
}

noinline fn string_close_rest(input: []const u8, from: Resume, cold: *Cold) u64 {
    assert(from.index <= input.len);
    assert(input[@intCast(from.open)] == '"');

    const index = stop_find(input, from.index);
    if (index == input.len) return position_failed;
    return string_stop(input, .{ .index = index, .open = from.open }, cold);
}

noinline fn escaped_close(input: []const u8, from: Resume, cold: *Cold) u64 {
    assert(input[@intCast(from.open)] == '"');
    assert(input[@intCast(from.index)] == '\\');

    const start = from.index;
    const first = from.open + 1;
    const available = cold.text.len - cold.text_count;
    const target = cold.text[cold.text_count..];

    if (start - first > available) return position_failed;

    run_copy(target, input[@intCast(first)..@intCast(start)]);

    var spot: RunSpot = .{ .source = start, .written = start - first };

    for (0..input.len) |_| {
        const pending = spot.source < input.len and input[@intCast(spot.source)] == '\\';

        if (!pending) {
            spot = run_take(input, target, spot);
            if (spot.source == input.len) return position_failed;
            if (spot.source - first > available) return position_failed;
        }

        const current = input[@intCast(spot.source)];

        if (current == '"') {
            cold.escaped_size = @intCast(spot.written);

            return spot.source | escaped_bit;
        }

        if (current == '\\') {
            const piece = escape_write(input, spot.source, target[@intCast(spot.written)..]);
            if (piece.consumed == 0) return position_failed;
            if (spot.source + piece.consumed - first > available) return position_failed;

            spot.source += piece.consumed;
            spot.written += piece.produced;

            continue;
        }

        assert(current < 0x20);

        return position_failed;
    }

    return position_failed;
}

inline fn run_take(input: []const u8, target: []u8, from: RunSpot) RunSpot {
    assert(from.source <= input.len);
    assert(from.written <= target.len);

    var spot = from;

    const reach = @min(input.len - spot.source, target.len - spot.written);

    for (0..@intCast(@divFloor(reach, run_stride))) |_| {
        const source_lane = input[@intCast(spot.source)..][0..run_stride];
        const target_lane = target[@intCast(spot.written)..][0..run_stride];
        const special = run_mask(input, spot.source);

        target_lane.* = source_lane.*;

        if (special != 0) {
            const offset = @ctz(special) >> run_mask_shift;

            return .{ .source = spot.source + offset, .written = spot.written + offset };
        }

        spot.source += run_stride;
        spot.written += run_stride;
    }

    return run_take_tail(input, target, spot);
}

inline fn run_mask(input: []const u8, index: u64) u64 {
    assert(index <= input.len);
    assert(input.len - index >= run_stride);

    if (comptime lanes_enabled) return stop_lanes(input, index);
    return stop_mask(word_at(input, index));
}

noinline fn run_take_tail(input: []const u8, target: []u8, from: RunSpot) RunSpot {
    @branchHint(.cold);

    assert(from.source <= input.len);
    assert(from.written <= target.len);

    var spot = from;

    for (input[@intCast(spot.source)..]) |current| {
        if (stop_table[current]) return spot;
        if (spot.written == target.len) return .{ .source = input.len, .written = spot.written };

        target[@intCast(spot.written)] = current;
        spot.source += 1;
        spot.written += 1;
    }

    assert(spot.source == input.len);

    return spot;
}

const Piece = struct {
    consumed: u64,
    produced: u64,
};

fn escape_write(input: []const u8, index: u64, target: []u8) Piece {
    assert(input[@intCast(index)] == '\\');
    assert(index < input.len);
    assert(target.len <= storage_module.text_bytes_limit);

    const failed: Piece = .{ .consumed = 0, .produced = 0 };
    if (input.len - index < 2) return failed;

    const short = escape_bytes[input[@intCast(index + 1)]];

    if (short != 0) {
        if (target.len == 0) return failed;

        target[0] = short;

        return .{ .consumed = 2, .produced = 1 };
    }

    const text = input[@intCast(index)..];

    if (target.len >= 4) {
        if (text[1] != 'u') return failed;

        const piece = string.unicode_piece_checked(text, target[0..4]) orelse return failed;

        return .{ .consumed = piece.consumed, .produced = piece.produced };
    }

    const length = tokenizer_module.escape_length(text) catch return failed;
    const decoded = string.escape_decode(text, length) catch return failed;
    if (decoded.count > target.len) return failed;

    @memcpy(target[0..decoded.count], decoded.buffer[0..decoded.count]);

    return .{ .consumed = decoded.consumed, .produced = decoded.count };
}

inline fn special_find(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const word_count = @divFloor(input.len - start, word_bytes);

    const result = found: {
        if (comptime lanes_enabled) {
            const lane_count = @divFloor(input.len - start, lane_bytes);

            for (0..@intCast(lane_count)) |lane_index| {
                const index = start + lane_index * lane_bytes;
                const special = special_lanes(input, index);
                if (special != 0) break :found index + @ctz(special);
            }

            break :found special_find_tail(input, start + lane_count * lane_bytes);
        }

        for (0..@intCast(word_count)) |word_index| {
            const index = start + word_index * word_bytes;
            const special = special_mask(word_at(input, index));
            if (special != 0) break :found index + (@ctz(special) >> 3);
        }

        break :found special_find_tail(input, start + word_count * word_bytes);
    };

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

inline fn key_stop_offset(mask: u64) u64 {
    assert(mask != 0);
    assert(mask & ~byte_highs == 0);

    const result: u64 = found: {
        inline for (0..word_bytes - 1) |offset| {
            if (mask & (@as(u64, 0x80) << (8 * offset)) != 0) {
                @branchHint(if (offset == word_bytes - 2) .likely else .none);

                break :found offset;
            }
        }

        break :found word_bytes - 1;
    };

    assert(result < word_bytes);

    return result;
}

inline fn lane_stop_offset(mask: u16) u64 {
    assert(mask != 0);

    const result: u64 = found: {
        inline for (0..lane_bytes - 1) |offset| {
            if (mask & (@as(u16, 1) << offset) != 0) break :found offset;
        }

        break :found lane_bytes - 1;
    };

    assert(result < lane_bytes);

    return result;
}

inline fn stop_offset(mask: u64, comptime role: Role) u64 {
    assert(mask != 0);
    assert(mask & ~byte_highs == 0);

    const result: u64 = switch (role) {
        .key => word_stop_offset(mask),
        .value => @ctz(mask) >> 3,
    };

    assert(result < word_bytes);

    return result;
}

inline fn word_stop_offset(mask: u64) u64 {
    assert(mask != 0);
    assert(mask & ~byte_highs == 0);

    const result: u64 = found: {
        inline for (0..word_bytes - 1) |offset| {
            if (mask & (@as(u64, 0x80) << (8 * offset)) != 0) break :found offset;
        }

        break :found word_bytes - 1;
    };

    assert(result < word_bytes);

    return result;
}

inline fn lane_spaces(input: []const u8, index: u64) u16 {
    assert(index <= input.len);
    assert(input.len - index >= lane_bytes);

    const bytes: Lane = input[@intCast(index)..][0..lane_bytes].*;
    const matches: LaneBits = @intFromBool(bytes == @as(Lane, @splat(' ')));
    const result: u16 = @bitCast(matches);

    assert(@popCount(result) <= lane_bytes);

    return result;
}

inline fn special_lanes(input: []const u8, index: u64) u16 {
    assert(index <= input.len);
    assert(input.len - index >= lane_bytes);

    const bytes: Lane = input[@intCast(index)..][0..lane_bytes].*;
    const signed: @Vector(lane_bytes, i8) = @bitCast(bytes);
    const below: LaneBits = @intFromBool(signed < @as(@Vector(lane_bytes, i8), @splat(0x20)));
    const quote: LaneBits = @intFromBool(bytes == @as(Lane, @splat('"')));
    const backslash: LaneBits = @intFromBool(bytes == @as(Lane, @splat('\\')));
    const result: u16 = @bitCast(below | quote | backslash);

    if (result != 0) assert(special_table[input[@intCast(index + @ctz(result))]]);

    return result;
}

inline fn stop_lanes(input: []const u8, index: u64) u16 {
    assert(index <= input.len);
    assert(input.len - index >= lane_bytes);

    const bytes: Lane = input[@intCast(index)..][0..lane_bytes].*;
    const control: LaneBits = @intFromBool(bytes < @as(Lane, @splat(0x20)));
    const quote: LaneBits = @intFromBool(bytes == @as(Lane, @splat('"')));
    const backslash: LaneBits = @intFromBool(bytes == @as(Lane, @splat('\\')));
    const result: u16 = @bitCast(control | quote | backslash);

    if (result != 0) assert(stop_table[input[@intCast(index + @ctz(result))]]);

    return result;
}

inline fn special_mask(word: u64) u64 {
    return special_bits(word) & byte_highs;
}

inline fn stop_mask(word: u64) u64 {
    const quote = (word ^ (byte_lows * '"')) -% byte_lows;
    const backslash = (word ^ (byte_lows * '\\')) -% byte_lows;
    const control = word -% byte_lows * 0x20;

    return (quote | backslash | control) & ~word & byte_highs;
}

inline fn special_bits(word: u64) u64 {
    const quote = (word ^ (byte_lows * '"')) -% byte_lows;
    const backslash = (word ^ (byte_lows * '\\')) -% byte_lows;
    const control = word -% byte_lows * 0x20;

    return quote | backslash | control | word;
}

fn special_find_tail(input: []const u8, start: u64) u64 {
    @branchHint(.cold);

    assert(start <= input.len);
    assert(input.len - start < 2 * word_bytes);

    const from: usize = @intCast(start);

    for (input[from..], from..) |current, index| {
        if (special_table[current]) return index;
    }

    return input.len;
}

inline fn stop_find(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const word_count = @divFloor(input.len - start, word_bytes);

    const result = found: {
        if (comptime lanes_enabled) {
            const lane_count = @divFloor(input.len - start, lane_bytes);

            for (0..@intCast(lane_count)) |lane_index| {
                const index = start + lane_index * lane_bytes;
                const stops = stop_lanes(input, index);
                if (stops != 0) break :found index + @ctz(stops);
            }

            break :found stop_find_tail(input, start + lane_count * lane_bytes);
        }

        for (0..@intCast(word_count)) |word_index| {
            const index = start + word_index * word_bytes;
            const stops = stop_mask(word_at(input, index));
            if (stops != 0) break :found index + (@ctz(stops) >> 3);
        }

        break :found stop_find_tail(input, start + word_count * word_bytes);
    };

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

fn stop_find_tail(input: []const u8, start: u64) u64 {
    @branchHint(.cold);

    assert(start <= input.len);
    assert(input.len - start < 2 * word_bytes);

    const from: usize = @intCast(start);

    for (input[from..], from..) |current, index| {
        if (stop_table[current]) return index;
    }

    return input.len;
}

noinline fn sequences_skip_far(input: []const u8, start: u64) u64 {
    assert(start < input.len);
    assert(input[@intCast(start)] >= 0x80);

    return sequences_skip(input, start, .inlined);
}

inline fn sequences_skip(input: []const u8, start: u64, comptime placement: Placement) u64 {
    assert(start < input.len);
    assert(input[@intCast(start)] >= 0x80);

    var index = start;

    while (index + 4 <= input.len) {
        const word = std.mem.readInt(u32, input[@intCast(index)..][0..4], .little);
        if (word & 0x80 == 0) return index;

        if (word & 0xc0c0f0 == 0x8080e0) {
            index = triples_skip(input, index, placement);
        } else if (word & 0xc0e0 == 0x80c0) {
            index = pairs_skip(input, index);
        } else {
            const length = sequence_word_length(word);
            if (length == 0) return position_failed;

            index += length;
        }

        if (index == position_failed) return position_failed;
    }

    return sequences_skip_tail(input, index);
}

fn triple_lane_of(comptime bytes: TripleBytes) Lane {
    comptime assert(lane_bytes % 3 == 1);
    comptime assert(bytes.lead & bytes.follow != 0);

    var result: [lane_bytes]u8 = @splat(0);

    for (0..@divFloor(lane_bytes, 3)) |triple| {
        result[3 * triple] = bytes.lead;
        result[3 * triple + 1] = bytes.follow;
        result[3 * triple + 2] = bytes.follow;
    }

    return result;
}

noinline fn triples_lanes_far(input: []const u8, start: u64) u64 {
    comptime assert(lanes_enabled);
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    return triples_lanes_skip(input, start);
}

inline fn triples_lanes_skip(input: []const u8, start: u64) u64 {
    comptime assert(lanes_enabled);
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    var index = start;

    while (input.len - index >= lane_bytes) {
        const bytes: Lane = input[@intCast(index)..][0..lane_bytes].*;
        const shaped: u16 = @bitCast(bytes & triple_lane_mask == triple_lane_want);
        if (shaped != std.math.maxInt(u16)) return index;

        const lead_low: u16 = @bitCast(bytes == @as(Lane, @splat(0xe0)));
        const lead_high: u16 = @bitCast(bytes == @as(Lane, @splat(0xed)));
        if (lead_low | lead_high != 0) return index;

        index += triple_lane_bytes;
    }

    return index;
}

inline fn triples_skip(input: []const u8, start: u64, comptime placement: Placement) u64 {
    assert(start + 4 <= input.len);
    assert(input[@intCast(start)] & 0xf0 == 0xe0);

    var index = start;

    if (comptime lanes_enabled) {
        index = switch (placement) {
            .inlined => triples_lanes_skip(input, start),
            .outlined => triples_lanes_far(input, start),
        };
    }

    while (index + 4 <= input.len) {
        const word = std.mem.readInt(u32, input[@intCast(index)..][0..4], .little);
        if (word & 0xc0c0f0 != 0x8080e0) return index;
        if (three_length(word & 0x200f) == 0) return position_failed;

        index += 3;
    }

    return index;
}

inline fn pairs_skip(input: []const u8, start: u64) u64 {
    assert(start + 4 <= input.len);
    assert(input[@intCast(start)] & 0xe0 == 0xc0);

    const lanes_low: u64 = 0x0001000100010001;
    const lanes_high = lanes_low * 0x8000;

    var index = start;

    while (index + word_bytes <= input.len) {
        const word = word_at(input, index);
        if (word & 0xc0e0c0e0c0e0c0e0 != 0x80c080c080c080c0) break;

        const leads = (word & (lanes_low * 0x1e)) + lanes_low * 0x7fff;
        if (leads & lanes_high != lanes_high) return position_failed;

        index += word_bytes;
    }

    while (index + 4 <= input.len) {
        const word = std.mem.readInt(u32, input[@intCast(index)..][0..4], .little);
        if (word & 0xc0e0 != 0x80c0) return index;
        if (word & 0x1e == 0) return position_failed;

        index += 2;
    }

    return index;
}

noinline fn sequences_skip_tail(input: []const u8, start: u64) u64 {
    @branchHint(.cold);

    assert(start <= input.len);
    assert(input.len - start < 4);

    var index = start;

    while (index < input.len) {
        if (input[@intCast(index)] < 0x80) return index;

        const length = sequence_length_tail(input[@intCast(index)..]);
        if (length == 0) return position_failed;

        index += length;
    }

    return index;
}

inline fn sequence_word_length(word: u32) u32 {
    assert(word & 0x80 != 0);
    assert(word <= std.math.maxInt(u32));

    if (word & 0xc0e0 == 0x80c0) return if (word & 0x1e == 0) 0 else 2;
    if (word & 0xc0c0f0 == 0x8080e0) return three_length(word & 0x200f);
    if (word & 0xc0c0c0f8 == 0x808080f0) return four_length(word & 0x3007);
    return 0;
}

inline fn three_length(bits: u32) u32 {
    assert(bits & ~@as(u32, 0x200f) == 0);
    assert(bits <= 0x200f);

    if (bits == 0) return 0;
    if (bits == 0x200d) return 0;
    return 3;
}

inline fn four_length(bits: u32) u32 {
    assert(bits & ~@as(u32, 0x3007) == 0);
    assert(bits <= 0x3007);

    const lead = bits & 7;
    const second = bits >> 12;

    if (lead == 0) return if (second == 0) 0 else 4;
    if (lead < 4) return 4;
    if (lead > 4) return 0;
    return if (second == 0) 4 else 0;
}

noinline fn sequence_length_tail(bytes: []const u8) u32 {
    @branchHint(.cold);

    assert(bytes.len > 0);
    assert(bytes.len < 4);

    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return 0;
    if (length > bytes.len) return 0;

    _ = std.unicode.utf8Decode(bytes[0..length]) catch return 0;

    return length;
}

inline fn number_end_far(far: Far, start: u64, comptime negative: bool) u64 {
    assert(start <= far.limit + reach_bytes);
    if (negative) assert(far.input[@intCast(start)] == '-');

    const input = far.input;

    const first = start + @intFromBool(negative);
    const lead = input[@intCast(first)];

    var index = first + 1;

    if (lead != '0') {
        if (lead -% '1' > 8) return position_failed;

        index = whole_far(far, index);
        if (index == digits_overrun) return number_end(input, start, negative);
    }

    if (input[@intCast(index)] == '.') {
        const fraction = digits_far(far, index + 1);
        if (fraction == digits_overrun) return number_end(input, start, negative);
        if (fraction == index + 1) return position_failed;

        index = fraction;
    }

    assert(index > start);

    if (input[@intCast(index)] | 0x20 != 'e') return index;
    return exponent_skip(input, index);
}

inline fn whole_far(far: Far, start: u64) u64 {
    assert(start <= far.limit + (reach_bytes + "-0".len));
    assert(far.limit + margin_bytes == far.input.len);

    const input = far.input;

    const result = if (input[@intCast(start)] -% '0' > 9)
        start
    else if (input[@intCast(start + 1)] -% '0' > 9)
        start + 1
    else if (input[@intCast(start + 2)] -% '0' > 9)
        start + 2
    else
        digits_far(far, start + 3);

    assert(result >= start);

    return result;
}

inline fn digits_far(far: Far, start: u64) u64 {
    assert(start <= far.input.len);
    assert(far.limit + margin_bytes == far.input.len);

    var index = start;

    const result = found: {
        for (0..far.input.len) |_| {
            if (index > far.limit) break :found digits_overrun;

            const others = digits_mask(word_at(far.input, index));
            if (others != 0) break :found index + word_stop_offset(others);

            index += word_bytes;
        }

        break :found digits_overrun;
    };

    if (result != digits_overrun) assert(result <= far.limit + word_bytes);

    return result;
}

inline fn number_end(input: []const u8, start: u64, comptime negative: bool) u64 {
    assert(start < input.len);
    if (negative) assert(input[@intCast(start)] == '-');

    const first = start + @intFromBool(negative);
    if (first == input.len) return position_failed;

    var index = first + 1;

    if (input[@intCast(first)] != '0') {
        if (input[@intCast(first)] -% '1' > 8) return position_failed;

        index = digits_skip(input, index);
    }

    index = fraction_skip(input, index);
    if (index == position_failed) return position_failed;

    return exponent_skip(input, index);
}

inline fn fraction_skip(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(start > 0);

    if (start == input.len) return start;
    if (input[@intCast(start)] != '.') return start;

    const end = digits_skip(input, start + 1);
    if (end == start + 1) return position_failed;

    assert(end > start + 1);

    return end;
}

inline fn exponent_skip(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(start > 0);

    if (start == input.len) return start;
    if (input[@intCast(start)] | 0x20 != 'e') return start;

    var index = start + 1;

    if (index < input.len) {
        const sign = input[@intCast(index)];
        const signed = sign == '+' or sign == '-';

        index += @intFromBool(signed);
    }

    const end = digits_skip(input, index);
    if (end == index) return position_failed;
    return end;
}

inline fn digits_skip(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const word_count = @divFloor(input.len - start, word_bytes);

    const result = found: {
        for (0..@intCast(word_count)) |word_index| {
            const index = start + word_index * word_bytes;
            const others = digits_mask(word_at(input, index));
            if (others != 0) break :found index + (@ctz(others) >> 3);
        }

        break :found digits_skip_tail(input, start + word_count * word_bytes);
    };

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

inline fn digits_mask(word: u64) u64 {
    const below = word -% byte_lows * '0';
    const above = word +% byte_lows * (0x80 - ':');

    return (below | above | word) & byte_highs;
}

fn digits_skip_tail(input: []const u8, start: u64) u64 {
    @branchHint(.cold);

    assert(start <= input.len);
    assert(input.len - start < 2 * word_bytes);

    const from: usize = @intCast(start);

    for (input[from..], from..) |current, index| {
        if (current -% '0' > 9) return index;
    }

    return input.len;
}

inline fn run_copy(target: []u8, run: []const u8) void {
    assert(run.len <= target.len);
    assert(run.len <= input_bytes_max);

    if (run.len >= lane_bytes) {
        var index: usize = 0;

        while (index + lane_bytes < run.len) : (index += lane_bytes) {
            target[index..][0..lane_bytes].* = run[index..][0..lane_bytes].*;
        }

        const last = run.len - lane_bytes;

        target[last..][0..lane_bytes].* = run[last..][0..lane_bytes].*;

        return;
    }

    if (run.len >= word_bytes) return run_copy_ends(word_bytes, target, run);
    if (run.len >= 4) return run_copy_ends(4, target, run);
    if (run.len >= 2) return run_copy_ends(2, target, run);
    if (run.len == 1) target[0] = run[0];
}

inline fn run_copy_ends(comptime size: u32, target: []u8, run: []const u8) void {
    assert(run.len >= size);
    assert(run.len <= 2 * size);
    assert(target.len >= run.len);

    const last = run.len - size;

    target[0..size].* = run[0..size].*;
    target[last..][0..size].* = run[last..][0..size].*;
}

inline fn padded_copy(target: []u8, input: []const u8) bool {
    assert(input.len > 0);
    assert(input.len <= target.len);

    if (input.len >= lane_bytes) {
        var seen: Lane = @splat(0);
        var index: usize = 0;

        while (index + lane_bytes < input.len) : (index += lane_bytes) {
            const lane: Lane = input[index..][0..lane_bytes].*;

            target[index..][0..lane_bytes].* = lane;
            seen |= lane;
        }

        const last = input.len - lane_bytes;
        const lane_last: Lane = input[last..][0..lane_bytes].*;

        target[last..][0..lane_bytes].* = lane_last;
        seen |= lane_last;

        const signed: @Vector(lane_bytes, i8) = @bitCast(seen);

        return @reduce(.Or, signed < @as(@Vector(lane_bytes, i8), @splat(0)));
    }

    if (input.len >= word_bytes) return padded_copy_ends(u64, target, input);
    if (input.len >= 4) return padded_copy_ends(u32, target, input);
    if (input.len >= 2) return padded_copy_ends(u16, target, input);

    target[0] = input[0];

    return input[0] >= 0x80;
}

inline fn padded_copy_ends(comptime Word: type, target: []u8, input: []const u8) bool {
    const size = @sizeOf(Word);

    assert(input.len >= size);
    assert(input.len <= 2 * size);
    assert(target.len >= input.len);

    const last = input.len - size;
    const head = std.mem.readInt(Word, input[0..size], .little);
    const tail = std.mem.readInt(Word, input[last..][0..size], .little);
    const highs: Word = @truncate(byte_highs);

    std.mem.writeInt(Word, target[0..size], head, .little);
    std.mem.writeInt(Word, target[last..][0..size], tail, .little);

    return (head | tail) & highs != 0;
}

const testing = std.testing;

const test_borders = [_]u8{ 0x00, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xff };

fn test_string_accepted(content: []const u8, filler_bytes: u32) !bool {
    assert(content.len <= 64);
    assert(filler_bytes <= 256);

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try sink.writeAll("[\"");
    try sink.writeAll(content);
    try sink.writeAll("\"");

    for (0..filler_bytes) |_| try sink.writeAll(",1");

    try sink.writeAll("]");

    var records: [256]Record = undefined;
    var text: [512]u8 = undefined;

    return build(sink.buffered(), &records, &text) != null;
}

fn test_utf8_agree(sequence: []const u8) !void {
    assert(sequence.len > 0);
    assert(sequence.len <= 4);

    var content: [64]u8 = undefined;

    for ([_]u32{ 1, 2, 3, 5, 9 }) |repeat| {
        var length: u32 = 0;

        for (0..repeat) |_| {
            @memcpy(content[length..][0..sequence.len], sequence);
            length += @intCast(sequence.len);
        }

        try test_run_agree(content[0..length]);
    }

    for ([_][]const u8{ "\xd0\x9b", "\xe3\x81\x82" }) |valid| {
        for (0..4) |before| {
            var length: u32 = 0;

            for (0..before) |_| {
                @memcpy(content[length..][0..valid.len], valid);
                length += @intCast(valid.len);
            }

            @memcpy(content[length..][0..sequence.len], sequence);
            length += @intCast(sequence.len);

            for (0..4) |_| {
                @memcpy(content[length..][0..valid.len], valid);
                length += @intCast(valid.len);
            }

            try test_run_agree(content[0..length]);
        }
    }
}

fn test_run_agree(run: []const u8) !void {
    assert(run.len > 0);
    assert(run.len <= 64);

    const plain = std.mem.findAny(u8, run, "\"\\") == null;
    const printable = for (run) |byte| {
        if (byte < 0x20) break false;
    } else true;

    const expected = plain and printable and std.unicode.utf8ValidateSlice(run);

    for ([_]u32{ 0, 1, 64 }) |filler| {
        try testing.expectEqual(expected, try test_string_accepted(run, filler));
    }
}

fn test_escaped_agree(run: []const u8, filler_bytes: u32) !void {
    assert(run.len <= 64);
    assert(filler_bytes <= 256);

    var input_buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&input_buffer);

    try sink.writeAll("[\"\\n");
    try sink.writeAll(run);
    try sink.writeAll("\"");

    for (0..filler_bytes) |_| try sink.writeAll(",1");

    try sink.writeAll("]");

    const plain = std.mem.findAny(u8, run, "\"\\") == null;
    const printable = for (run) |byte| {
        if (byte < 0x20) break false;
    } else true;

    const expected = plain and printable and std.unicode.utf8ValidateSlice(run);
    const raw_bytes = run.len + 2;

    var records: [256]Record = undefined;
    var text: [512]u8 = undefined;

    const built = build(sink.buffered(), &records, &text);

    try testing.expectEqual(expected, built != null);

    if (built) |result| {
        try testing.expectEqual(run.len + 1, result.text_count);
        try testing.expectEqual('\n', text[0]);
        try testing.expectEqualSlices(u8, run, text[1..][0..run.len]);
    }

    const fits = build(sink.buffered(), &records, text[0..raw_bytes]);
    const short = build(sink.buffered(), &records, text[0 .. raw_bytes - 1]);

    try testing.expectEqual(expected, fits != null);
    try testing.expect(short == null);
}

fn test_stop_byte(random: std.Random, odds: u32, stops: []const u8) u8 {
    assert(odds > 0);
    assert(stops.len > 0);

    const stop_count: u32 = @intCast(stops.len);
    const plain = 0x20 + random.uintLessThan(u8, 0xe0);

    const result = if (random.uintLessThan(u32, odds) == 0)
        stops[random.uintLessThan(u32, stop_count)]
    else if (stop_table[plain])
        'a'
    else
        plain;

    assert(stop_table[result] == (std.mem.findScalar(u8, stops, result) != null));

    return result;
}

fn test_stops_agree(buffer: []const u8, start: u32) !void {
    assert(start <= buffer.len);
    assert(buffer.len <= input_bytes_max);

    const expected = for (buffer[start..], start..) |byte, index| {
        if (stop_table[byte]) break index;
    } else buffer.len;

    try testing.expectEqual(@as(u64, expected), stop_find(buffer, start));

    if (buffer.len - start >= lane_bytes) {
        const lanes = stop_lanes(buffer, start);

        for (0..lane_bytes) |offset| {
            const set = lanes & (@as(u16, 1) << @intCast(offset)) != 0;

            try testing.expectEqual(stop_table[buffer[start + offset]], set);
        }
    }

    if (buffer.len - start >= word_bytes) {
        const mask = stop_mask(word_at(buffer, start));

        if (expected < start + word_bytes) {
            try testing.expectEqual(expected - start, @ctz(mask) >> 3);
        } else {
            try testing.expectEqual(@as(u64, 0), mask);
        }
    }
}

fn test_bare_agree(content: []const u8, before: u32) !void {
    assert(content.len <= 16);
    assert(before <= 200);

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try sink.writeAll("[");

    for (0..before) |_| try sink.writeAll("1,");

    try sink.writeAll("\"");
    try sink.writeAll(content);
    try sink.writeAll("\"");

    for (0..200 - before) |_| try sink.writeAll(",1");

    try sink.writeAll("]");

    const input = sink.buffered();

    assert(input.len > padded_bytes_max);

    var records: [512]Record = undefined;
    var text: [64]u8 = undefined;

    const plain = std.mem.findAny(u8, content, "\"\\") == null;
    const printable = for (content) |byte| {
        if (byte < 0x20) break false;
    } else true;

    const expected = plain and printable and std.unicode.utf8ValidateSlice(content);

    try testing.expectEqual(expected, build(input, &records, &text) != null);
}

fn test_triple_run_agree(sequence: *const [3]u8) !void {
    assert(sequence[0] >= 0xe0);
    assert(sequence[0] < 0xf0);

    const valid = "\xe3\x81\x82";

    var content: [64]u8 = undefined;

    for (0..13) |before| {
        var length: u32 = 0;

        for (0..before) |_| {
            @memcpy(content[length..][0..valid.len], valid);
            length += valid.len;
        }

        @memcpy(content[length..][0..sequence.len], sequence);
        length += sequence.len;

        for (0..8) |_| {
            @memcpy(content[length..][0..valid.len], valid);
            length += valid.len;
        }

        try test_run_agree(content[0..length]);

        for ([_]u32{ 0, 64 }) |filler| {
            try test_escaped_agree(content[0..length], filler);
        }
    }
}

fn test_token_input_fill(random: std.Random, buffer: []u8) []const u8 {
    assert(buffer.len >= 256);
    assert(buffer.len <= input_bytes_max);

    const blanks = " \t\r";
    const tokens = "{}[],:\"1a\x01";
    const spaces_limit: u32 = 2 * indent_words * word_bytes;

    var size: u32 = 0;

    for (0..64) |_| {
        const newlines = random.uintLessThan(u32, 3);
        const spaces = random.uintLessThan(u32, spaces_limit);

        if (buffer.len - size < newlines + spaces + 2) break;

        @memset(buffer[size..][0..newlines], '\n');
        size += newlines;

        @memset(buffer[size..][0..spaces], ' ');
        size += spaces;

        if (random.uintLessThan(u8, 4) == 0) {
            buffer[size] = blanks[random.uintLessThan(u32, blanks.len)];
            size += 1;
        }

        buffer[size] = tokens[random.uintLessThan(u32, tokens.len)];
        size += 1;
    }

    assert(size <= buffer.len);

    return buffer[0..size];
}

fn test_blank_walk_end(input: []const u8, start: u32) u32 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    var position = start;

    for (input[start..]) |byte| {
        if (!blank_table[byte]) break;

        position += 1;
    }

    assert(position <= input.len);

    return position;
}

fn test_token_walk_agree(input: []const u8) !void {
    assert(input.len <= input_bytes_max);

    const limit: u32 = @intCast(input.len -| margin_bytes);

    var at: u32 = 0;
    var indent: u32 = 0;
    var cursor: u32 = 0;

    for (0..input.len + 1) |_| {
        cursor = test_blank_walk_end(input, cursor);

        const token = token_take(input, .{ .at = &at, .indent = &indent, .limit = limit });

        try std.testing.expect(indent <= indent_words * word_bytes);

        if (cursor == input.len) {
            try std.testing.expectEqual(null, token);

            return;
        }

        if (input[cursor] <= ' ') {
            if (token) |position| try std.testing.expectEqual(cursor, position);

            return;
        }

        try std.testing.expectEqual(cursor, token.?);
        try std.testing.expectEqual(cursor + 1, at);

        cursor += 1;
    }

    return error.TestUnexpectedResult;
}

const test_prefix_letters = "abcdefghijklmnopqrstu";

fn test_unicode_write(target: *[6]u8, unit: u16, random: std.Random) []const u8 {
    assert(unit <= std.math.maxInt(u16));

    const digits_lower = "0123456789abcdef";
    const digits_upper = "0123456789ABCDEF";

    target[0] = '\\';
    target[1] = 'u';

    for (0..4) |position| {
        const nibble = (unit >> @intCast(4 * (3 - position))) & 0xf;
        const digits = if (random.boolean()) digits_lower else digits_upper;

        target[2 + position] = digits[nibble];
    }

    assert((std.fmt.parseInt(u16, target[2..6], 16) catch null) == unit);

    return target;
}

fn test_unicode_reference(content: []const u8, target: *[64]u8) ?[]const u8 {
    assert(content.len <= 48);

    var written: u32 = 0;
    var index: u32 = 0;

    while (content[index] != '"') {
        if (content[index] != '\\') {
            target[written] = content[index];
            written += 1;
            index += 1;

            continue;
        }

        const rest = content[index..];
        const length = tokenizer_module.escape_length(rest) catch return null;
        const decoded = string.escape_decode(rest, length) catch return null;

        @memcpy(target[written..][0..decoded.count], decoded.buffer[0..decoded.count]);
        written += @intCast(decoded.count);
        index += length;
    }

    return target[0..written];
}

fn test_unicode_agree(escape: []const u8, prefix_bytes: u32) !void {
    assert(escape.len <= 12);
    assert(prefix_bytes <= test_prefix_letters.len);

    const prefix = test_prefix_letters[0..prefix_bytes];

    var input_buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&input_buffer);

    try sink.writeAll("[\"");
    try sink.writeAll(prefix);
    try sink.writeAll(escape);
    try sink.writeAll("z\"]");

    const input = sink.buffered();

    var reference_buffer: [64]u8 = undefined;
    const reference = test_unicode_reference(input[2..], &reference_buffer);

    var records: [16]Record = undefined;
    var text: [64]u8 = undefined;
    const raw_bytes = prefix.len + escape.len + 1;

    for ([_]usize{ text.len, raw_bytes }) |room| {
        const built = build(input, &records, text[0..room]);

        try testing.expectEqual(reference != null, built != null);

        if (built) |result| {
            try testing.expectEqualSlices(u8, reference.?, text[0..result.text_count]);
        }
    }
}

fn test_escape_run_write(random: std.Random, target: *[240]u8) []const u8 {
    const shorts = [_][]const u8{ "\\n", "\\t", "\\\"", "\\\\", "\\/", "\\b", "\\f", "\\r", "q" };

    var length: u32 = 0;
    var unit_escape: [6]u8 = undefined;

    for (0..random.intRangeAtMost(u32, 1, 18)) |index| {
        if (random.uintLessThan(u32, 3) == 0) {
            const choices: u32 = if (index == 0) shorts.len - 1 else shorts.len;
            const piece = shorts[random.uintLessThan(u32, choices)];

            @memcpy(target[length..][0..piece.len], piece);
            length += @intCast(piece.len);

            continue;
        }

        const unit = random.int(u16);

        @memcpy(target[length..][0..6], test_unicode_write(&unit_escape, unit, random));
        length += 6;

        if (unit & 0xfc00 == 0xd800) {
            if (random.uintLessThan(u32, 4) != 0) {
                const low = random.intRangeAtMost(u16, 0xdc00, 0xdfff);

                @memcpy(target[length..][0..6], test_unicode_write(&unit_escape, low, random));
                length += 6;
            }
        }
    }

    assert(length <= target.len);

    return target[0..length];
}

fn test_escape_run_agree(content: []const u8, filler_numbers: u32) !void {
    assert(content.len <= 240);
    assert(filler_numbers <= 160);

    var input_buffer: [600]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&input_buffer);

    try sink.writeAll("[");

    for (0..filler_numbers) |_| try sink.writeAll("1,");

    try sink.writeAll("\"");
    try sink.writeAll(content);
    try sink.writeAll("\"]");

    var expected_buffer: [240]u8 = undefined;
    var records: [256]Record = undefined;
    var text: [512]u8 = undefined;

    const expected = string.unescape(content, &expected_buffer) catch null;
    const built = build(sink.buffered(), &records, &text);

    try testing.expectEqual(expected != null, built != null);

    if (expected) |decoded| {
        try testing.expectEqual(decoded.len, built.?.text_count);
        try testing.expectEqualSlices(u8, decoded, text[0..decoded.len]);
    }
}

test "the predicted stop offsets name the first stop byte as a count of trailing zeros does" {
    for (1..std.math.maxInt(u16) + 1) |value| {
        const mask: u16 = @intCast(value);

        try testing.expectEqual(@as(u64, @ctz(mask)), lane_stop_offset(mask));
    }

    for (1..std.math.maxInt(u8) + 1) |value| {
        const highs: u8 = @intCast(value);

        var mask: u64 = 0;

        for (0..word_bytes) |byte_index| {
            if (highs & (@as(u8, 1) << @intCast(byte_index)) != 0) {
                mask |= @as(u64, 0x80) << @intCast(8 * byte_index);
            }
        }

        const expected: u64 = @ctz(highs);

        try testing.expectEqual(expected, word_stop_offset(mask));
        try testing.expectEqual(expected, stop_offset(mask, .key));
        try testing.expectEqual(expected, stop_offset(mask, .value));
    }
}

test "the token take finds the tokens that a walk over the bytes finds" {
    var prng: std.Random.DefaultPrng = .init(0x70c3);
    var buffer: [4096]u8 = undefined;

    for (0..4096) |_| {
        const capacity = 256 + prng.random().uintLessThan(u32, buffer.len - 256);
        const input = test_token_input_fill(prng.random(), buffer[0..capacity]);

        try test_token_walk_agree(input);
    }
}

test "the scalar path unescapes a string around every kind of run" {
    var content: [64]u8 = undefined;

    for (0..48) |ascii_bytes| {
        @memset(content[0..ascii_bytes], 'a');

        for ([_]u32{ 0, 1, 64 }) |filler| {
            try test_escaped_agree(content[0..ascii_bytes], filler);
        }
    }

    for ([_]u8{ 0xe0, 0xe1, 0xec, 0xed, 0xee, 0xef }) |lead| {
        for ([_]u8{ 0x7f, 0x80, 0x9f, 0xa0, 0xbf, 0xc0 }) |second| {
            for ([_]u8{ 0x7f, 0x80, 0xbf, 0xc0 }) |third| {
                try test_triple_run_agree(&.{ lead, second, third });
            }
        }
    }
}

test "the scalar path keeps the text between repeated escapes" {
    const letters: [40]u8 = @splat('z');
    const input_head = "[\"ab\\ncd\\\"\xe3\x81\x82\\t\\u0041";
    const input_tail = "\\\\end\",1,1,1,1,1,1,1,1,1,1]";
    const input = input_head ++ letters ++ input_tail;
    const expected = "ab\ncd\"\xe3\x81\x82\tA" ++ letters ++ "\\end";

    var records: [64]Record = undefined;
    var text: [256]u8 = undefined;

    const built = build(input, &records, &text) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(expected.len, built.text_count);
    try testing.expectEqualSlices(u8, expected, text[0..expected.len]);
}

test "the scalar path accepts a string exactly when its bytes are valid UTF-8" {
    for (0x80..0x100) |lead| {
        for (test_borders) |second| {
            try test_utf8_agree(&.{ @intCast(lead), second });
        }
    }

    for (0xe0..0xf0) |lead| {
        for (test_borders) |second| {
            for (test_borders) |third| {
                try test_utf8_agree(&.{ @intCast(lead), second, third });
            }
        }
    }

    for (0xf0..0xf8) |lead| {
        for (test_borders) |second| {
            for ([_]u8{ 0x7f, 0x80, 0xbf, 0xc0 }) |rest| {
                try test_utf8_agree(&.{ @intCast(lead), second, rest, rest });
            }
        }
    }
}

test "the stop scans find the first quote, backslash, or control byte as a byte loop does" {
    var prng: std.Random.DefaultPrng = .init(0x5709);
    const random = prng.random();
    const stops = [_]u8{ '"', '\\', 0x00, 0x09, 0x1f };

    var buffer: [96]u8 = undefined;

    for (0..4096) |_| {
        const odds = 4 + random.uintLessThan(u32, 40);

        for (&buffer) |*byte| byte.* = test_stop_byte(random, odds, &stops);

        for (0..48) |start| try test_stops_agree(&buffer, @intCast(start));
    }
}

test "the padded copy copies each byte and reports a byte at or above 0x80" {
    var prng: std.Random.DefaultPrng = .init(0xc097);
    const random = prng.random();

    var input: [96]u8 = undefined;
    var target: [96]u8 = undefined;

    for (1..input.len + 1) |length| {
        for (0..64) |_| {
            for (input[0..length]) |*byte| byte.* = random.uintLessThan(u8, 0x80);

            if (random.boolean()) input[random.uintLessThan(u32, @intCast(length))] |= 0x80;

            const expected = for (input[0..length]) |byte| {
                if (byte >= 0x80) break true;
            } else false;

            @memset(&target, 0xaa);

            try testing.expectEqual(expected, padded_copy(&target, input[0..length]));
            try testing.expectEqualSlices(u8, input[0..length], target[0..length]);
            try testing.expect(std.mem.allEqual(u8, target[length..], 0xaa));

            if (length >= lane_bytes) {
                try testing.expectEqual(expected, high_present(input[0..length]));
            }
        }
    }
}

test "the bare scalar path accepts a string exactly when its bytes are valid UTF-8" {
    const valid = "\xe3\x81\x82";

    for (0x80..0x100) |lead| {
        for (test_borders) |second| {
            const sequence = [_]u8{ @intCast(lead), second, 'z' };

            for ([_]u32{ 0, 70, 150 }) |before| {
                try test_bare_agree(&sequence, before);
                try test_bare_agree(valid ++ sequence, before);
            }
        }
    }
}

test "the scalar path decodes each unicode escape as the escape decoder does" {
    var prng: std.Random.DefaultPrng = .init(0x75657363);
    const random = prng.random();
    const prefixes = [_]u32{ 0, 2, test_prefix_letters.len };

    var pair: [12]u8 = undefined;

    for (0..0x10000) |unit| {
        const escape = test_unicode_write(pair[0..6], @intCast(unit), random);

        try test_unicode_agree(escape, prefixes[unit % prefixes.len]);
    }

    for (0..8192) |_| {
        const high = random.intRangeAtMost(u16, 0xd800, 0xdbff);
        const low = random.intRangeAtMost(u16, 0xd000, 0xe0ff);

        _ = test_unicode_write(pair[0..6], high, random);
        _ = test_unicode_write(pair[6..12], low, random);

        try test_unicode_agree(&pair, prefixes[random.uintLessThan(u32, prefixes.len)]);
        try test_unicode_agree(pair[0..6], prefixes[random.uintLessThan(u32, prefixes.len)]);
    }

    for (0..4) |position| {
        for ("gG/:@`xz \"") |invalid| {
            _ = test_unicode_write(pair[0..6], 0x00e9, random);
            pair[2 + position] = invalid;

            for (prefixes) |prefix| try test_unicode_agree(pair[0..6], prefix);
        }
    }

    for (0..256) |byte| {
        _ = test_unicode_write(pair[0..6], 0x0041, random);
        pair[1] = @intCast(byte);

        for (prefixes) |prefix| try test_unicode_agree(pair[0..6], prefix);
    }
}

test "the scalar path decodes runs of adjacent escapes as the reference unescape does" {
    var prng: std.Random.DefaultPrng = .init(0x61646a61);
    const random = prng.random();

    var raw: [240]u8 = undefined;

    for (0..4096) |_| {
        const content = test_escape_run_write(random, &raw);

        try test_escape_run_agree(content, 0);
        try test_escape_run_agree(content, 140);
    }
}

test "the bare scalar path refuses a string that ends at or inside an escape" {
    const tails = [_][]const u8{
        "\\",
        "\\n",
        "\\n\\t",
        "\\u00",
        "\\u00e9",
        "\\u00e9\\\\",
        "\\ud83d",
        "\\ud83d\\ude00",
    };

    var input_buffer: [600]u8 = undefined;
    var records: [256]Record = undefined;
    var text: [512]u8 = undefined;

    for (tails) |tail| {
        var sink: std.Io.Writer = .fixed(&input_buffer);

        try sink.writeAll("[");

        for (0..140) |_| try sink.writeAll("1,");

        try sink.writeAll("\"ab");
        try sink.writeAll(tail);

        const input = sink.buffered();

        assert(input.len > padded_bytes_max);

        try testing.expect(build(input, &records, &text) == null);
        try testing.expect(build(input[0 .. input.len - 1], &records, &text) == null);
    }
}
