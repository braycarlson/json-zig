const std = @import("std");

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
const margin_bytes: u64 = 64;
const position_failed: u64 = std.math.maxInt(u64);
const reach_bytes: u64 = 1 + indent_words * word_bytes;
const indent_words: u64 = 4;
const word_bytes: u64 = @sizeOf(u64);

comptime {
    assert(input_bytes_max < position_failed);
    assert(input_bytes_max < escaped_bit);
    assert(position_failed & escaped_bit != 0);
    assert(container_index_mask >= storage_module.node_count_limit);
    assert(container_root & container_object != 0);
    assert(word_bytes == 8);
    assert(margin_bytes >= reach_bytes + 2 * word_bytes + "false".len);
}

pub const Built = struct {
    depth_seen: u32,
    node_count: u32,
    text_count: u32,
};

pub fn build(input: []const u8, records: []Record, text: []u8) ?Built {
    assert(input.len <= input_bytes_max);
    assert(records.len > 0);
    assert(text.len <= storage_module.text_bytes_limit);

    if (records.len >= input.len) return document_parse(.unchecked, input, records, text);
    return document_parse(.checked, input, records, text);
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

const Outcome = enum {
    done,
    failed,
    near,
};

const Resume = struct {
    index: u64,
    open: u64,
};

const Role = enum {
    key,
    value,
};

const State = enum {
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

noinline fn document_parse(
    comptime bounds: Bounds,
    input: []const u8,
    records: []Record,
    text: []u8,
) ?Built {
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

    var state: State = .value;

    if (input.len > margin_bytes) {
        const far = document_walk(bounds, .far, &parser, state);
        if (far.outcome == .failed) return null;

        state = far.state;
    }

    const exit = document_walk(bounds, .near, &parser, state);
    if (exit.outcome != .done) return null;
    return parser.built();
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
) align(64) Exit {
    assert(parser.position <= parser.input.len);
    if (zone == .far) assert(parser.input.len > margin_bytes);

    var walk = parser.*;
    defer parser.synchronize(&walk);

    walk.slots = parser.cold.records[parser.cold.node..];

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

noinline fn document_walk_unaligned(
    comptime bounds: Bounds,
    comptime zone: Zone,
    parser: *Parser,
    state: State,
) Exit {
    assert(parser.position <= parser.input.len);
    if (zone == .far) assert(parser.input.len > margin_bytes);

    var walk = parser.*;
    defer parser.synchronize(&walk);

    walk.slots = parser.cold.records[parser.cold.node..];

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

    inline fn built(parser: *const Parser) Built {
        assert(parser.cold.depth == 0);
        assert(parser.position == parser.input.len);

        return .{
            .depth_seen = parser.cold.depth_seen,
            .node_count = parser.cold.node,
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
        const first = special_mask(word_at(input, index));

        if (first == 0) {
            const second = special_mask(word_at(input, index + word_bytes));

            if (second == 0) {
                index += 2 * word_bytes;

                continue;
            }

            index += word_bytes + stop_offset(second, role);
        } else {
            index += stop_offset(first, role);
        }

        const stop = index;
        const current = input[@intCast(stop)];
        if (current == '"') return stop;
        if (current == '\\') return escaped_close(input, .{ .index = stop, .open = open }, cold);
        if (current < 0x20) return position_failed;

        index = sequences_skip(input, stop);
        if (index == position_failed) return position_failed;
    }

    return string_close_rest(input, .{ .index = index, .open = open }, cold);
}

noinline fn string_close_rest(input: []const u8, from: Resume, cold: *Cold) u64 {
    assert(from.index <= input.len);
    assert(input[@intCast(from.open)] == '"');

    const open = from.open;

    var index = from.index;

    for (0..input.len) |_| {
        index = special_find(input, index);
        if (index == input.len) return position_failed;

        const current = input[@intCast(index)];
        if (current == '"') return index;
        if (current == '\\') return escaped_close(input, .{ .index = index, .open = open }, cold);
        if (current < 0x20) return position_failed;

        index = sequences_skip(input, index);
        if (index == position_failed) return position_failed;
    }

    return position_failed;
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

    var written = start - first;
    var index = start;

    for (0..input.len) |_| {
        if (index == input.len) return position_failed;

        if (input[@intCast(index)] == '\\') {
            const piece = escape_write(input, index, target[@intCast(written)..]);
            if (piece.consumed == 0) return position_failed;
            if (index + piece.consumed - first > available) return position_failed;

            written += piece.produced;
            index += piece.consumed;

            continue;
        }

        const stop = run_end(input, index);
        if (stop == position_failed) return position_failed;
        if (stop - first > available) return position_failed;

        run_copy(target[@intCast(written)..], input[@intCast(index)..@intCast(stop)]);
        written += stop - index;
        index = stop;

        if (input[@intCast(index)] == '"') {
            cold.escaped_size = @intCast(written);

            return index | escaped_bit;
        }
    }

    return position_failed;
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
    const length = tokenizer_module.escape_length(text) catch return failed;
    const decoded = string.escape_decode(text, length) catch return failed;
    if (decoded.count > target.len) return failed;

    @memcpy(target[0..decoded.count], decoded.buffer[0..decoded.count]);

    return .{ .consumed = decoded.consumed, .produced = decoded.count };
}

fn run_end(input: []const u8, start: u64) u64 {
    assert(start < input.len);
    assert(input[@intCast(start)] != '\\');

    var index = start;

    for (0..input.len) |_| {
        index = special_find(input, index);
        if (index == input.len) return position_failed;

        const current = input[@intCast(index)];
        if (current == '"') return index;
        if (current == '\\') return index;
        if (current < 0x20) return position_failed;

        index = sequences_skip(input, index);
        if (index == position_failed) return position_failed;
    }

    return position_failed;
}

inline fn special_find(input: []const u8, start: u64) u64 {
    assert(start <= input.len);
    assert(input.len <= input_bytes_max);

    const word_count = @divFloor(input.len - start, word_bytes);

    const result = found: {
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

inline fn stop_offset(mask: u64, comptime role: Role) u64 {
    assert(mask != 0);
    assert(mask & ~byte_highs == 0);

    const result: u64 = found: {
        if (role == .value) break :found @ctz(mask) >> 3;

        inline for (0..word_bytes - 1) |offset| {
            if (mask & (@as(u64, 0x80) << (8 * offset)) != 0) break :found offset;
        }

        break :found word_bytes - 1;
    };

    assert(result < word_bytes);

    return result;
}

inline fn special_mask(word: u64) u64 {
    return special_bits(word) & byte_highs;
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

inline fn sequences_skip(input: []const u8, start: u64) u64 {
    assert(start < input.len);
    assert(input[@intCast(start)] >= 0x80);

    var index = start;

    while (index + 4 <= input.len) {
        const word = std.mem.readInt(u32, input[@intCast(index)..][0..4], .little);
        if (word & 0x80 == 0) return index;

        if (word & 0xc0c0f0 == 0x8080e0) {
            index = triples_skip(input, index);
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

inline fn triples_skip(input: []const u8, start: u64) u64 {
    assert(start + 4 <= input.len);
    assert(input[@intCast(start)] & 0xf0 == 0xe0);

    var index = start;

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

        index = digits_far(far, index);
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

inline fn digits_far(far: Far, start: u64) u64 {
    assert(start <= far.input.len);
    assert(far.limit + margin_bytes == far.input.len);

    var index = start;

    const result = found: {
        for (0..far.input.len) |_| {
            if (index > far.limit) break :found digits_overrun;

            const others = digits_mask(word_at(far.input, index));
            if (others != 0) break :found index + (@ctz(others) >> 3);

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

    var index: u64 = 0;

    while (index + word_bytes <= run.len) : (index += word_bytes) {
        target[@intCast(index)..][0..word_bytes].* = run[@intCast(index)..][0..word_bytes].*;
    }

    while (index < run.len) : (index += 1) {
        target[@intCast(index)] = run[@intCast(index)];
    }
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
