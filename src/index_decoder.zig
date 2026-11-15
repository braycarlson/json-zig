const std = @import("std");

const codec = @import("codec.zig");
const number = @import("number.zig");
const region_module = @import("region.zig");
const scalar = @import("scalar.zig");
const string = @import("string.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Region = region_module.Region;
const UnknownMembers = codec.DecodeOptions.UnknownMembers;

const Literal = tokenizer_module.Literal;
const Spot = structural.Spot;

const Key = struct {
    size: u32,
    text: []const u8,
    word: u64,
};

const KeyCold = packed struct(u64) {
    size: u32,
    failed: bool,
    refilled: bool,
    padding: u30 = 0,
};

const KeyPlan = struct {
    exact: bool,
    seed: u64,
    shift: u6,
    slots: []const u8,
    tail_used: bool,

    inline fn slot(comptime plan: KeyPlan, key: Key) u32 {
        comptime assert(plan.slots.len > 0);
        assert(key.size <= tokenizer_module.input_bytes_max);

        const mask = key_masks[key.size & key_mask_index_mask];

        var mixed = (key.word & mask) ^ key.size;

        if (comptime plan.tail_used) {
            const offset = @max(key.size, key_word_bytes) - key_word_bytes;
            const tail = word_read(key.text[offset..]);

            mixed ^= std.math.rotl(u64, tail & mask, key_tail_rotation);
        }

        const slot_index: u32 = @intCast((mixed *% plan.seed) >> plan.shift);
        const result = plan.slots[slot_index];

        assert(result <= key_slot_empty);

        return result;
    }
};

const SkipState = enum {
    array_next,
    array_value,
    closed,
    object_key,
    object_next,
    object_value,
};

const Cursor = if (walk_direct) u32 else u64;

const array_close_offset: u8 = ']' - '[';
const at_limit = if (walk_direct) std.math.maxInt(u32) else entries_capacity;
const colon_after_quote: u16 = '"' | @as(u16, ':') << 8;
const comma_after_quote: u16 = '"' | @as(u16, ',') << 8;
const container_curl: u8 = '{' - '[';
const depth_max = tokenizer_module.depth_max;
const walk_direct = structural.walk_direct;
const entries_capacity = structural.entries_capacity;
const entry_sentinel = structural.entry_sentinel;
const key_buffer_bytes: u32 = 256;
const key_field_count_max: u32 = 255;
const key_mask_index_mask: u32 = key_masks.len - 1;

const key_masks: [64]u64 = masks: {
    var table: [64]u64 = @splat(std.math.maxInt(u64));

    for (table[0..8], 0..) |*mask, size| mask.* = (@as(u64, 1) << (8 * size)) - 1;

    break :masks table;
};

const key_plan_quota: u32 = 4_000_000;
const key_seed_count: u32 = 64;
const key_seed_first: u64 = 0x9e3779b97f4a7c15;
const key_seed_step: u64 = 0xbf58476d1ce4e5b9;
const key_slot_bits_extra: u32 = 5;
const key_slot_empty: u8 = 0xff;
const key_tail_rotation: u32 = 29;
const key_word_bytes: u32 = @sizeOf(u64);
const lane_count = tokenizer_module.lane_count;
const literal_false_bytes: u32 = "false".len;
const literal_false_word: u32 = std.mem.readInt(u32, "fals", .little);
const literal_null_bytes: u32 = "null".len;
const literal_null_word: u32 = std.mem.readInt(u32, "null", .little);
const literal_true_bytes: u32 = "true".len;
const literal_true_word: u32 = std.mem.readInt(u32, "true", .little);
const literal_valid = tokenizer_module.literal_valid;
const object_close_offset: u8 = '}' - '{';
const walk_failed: u32 = std.math.maxInt(u32);

comptime {
    assert(tokenizer_module.input_bytes_max <= structural.index_escaped);
    assert(std.math.isPowerOfTwo(key_masks.len));
    assert(key_field_count_max == key_slot_empty);
    assert(key_buffer_bytes >= 2 * key_word_bytes);
    assert(array_close_offset == object_close_offset);
    assert(literal_null_bytes == literal_true_bytes);
    assert('[' | container_curl == '{');
    assert(@popCount(container_curl) == 1);
}

const Walk = struct {
    batch: if (walk_direct) void else structural.Batch,
    indent: u32,
    indexer: if (walk_direct) void else structural.Indexer,
    input: []const u8,
    key_buffer: [key_buffer_bytes + key_word_bytes]u8,
    key_text: []const u8,
    limit: u32,
    region: *Region,
    unknown_members: UnknownMembers,
};

const Pass = struct {
    at: Cursor,
    input: []const u8,
    limit: u32,
    walk: *Walk,

    inline fn init(walk: *Walk, start: u32) Pass {
        assert(walk.input.len <= tokenizer_module.input_bytes_max);
        assert(start < at_limit);

        return .{ .at = start, .input = walk.input, .limit = walk.limit, .walk = walk };
    }

    inline fn scalar_ended(pass: *Pass, end: u64) void {
        assert(end <= pass.input.len);
        assert(end > 0);

        if (comptime walk_direct) pass.at = @intCast(end);
    }

    inline fn at_narrow(pass: *const Pass) u32 {
        assert(pass.at < at_limit);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        return @intCast(pass.at);
    }

    inline fn spot_of(pass: *const Pass, open: u64) Spot {
        assert(pass.at < at_limit);
        assert(open < pass.input.len);

        return .{ .at = pass.at_narrow(), .open = @intCast(open) };
    }

    inline fn advanced(pass: *Pass, next: u32) bool {
        assert(next < at_limit or next == walk_failed);
        assert(pass.at < at_limit);

        pass.at = next;

        return next != walk_failed;
    }

    inline fn take(pass: *Pass) ?u64 {
        assert(pass.at < at_limit);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        if (comptime walk_direct) {
            const token = scalar.token_take(pass.input, .{
                .at = &pass.at,
                .indent = &pass.walk.indent,
                .limit = pass.limit,
            }) orelse return null;

            return token;
        }

        const entry: u64 = pass.walk.batch.indices[pass.at];

        pass.at += 1;

        if (entry < pass.input.len) {
            @branchHint(.likely);

            return entry;
        }

        return pass.take_cold(entry);
    }

    inline fn take_cold(pass: *Pass, entry: u64) ?u64 {
        @branchHint(.cold);
        assert(entry >= pass.input.len);

        if (entry != entry_sentinel) return null;
        if (!pass.walk.batch.refill(pass.input)) return null;

        pass.at = 1;

        const first: u64 = pass.walk.batch.indices[0];

        return if (first < pass.input.len) first else null;
    }

    inline fn string_skip(pass: *Pass, open: u64) bool {
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        if (comptime walk_direct) {
            const close = scalar.string_close(pass.input, .{
                .limit = pass.limit,
                .open = @intCast(open),
            });

            if (close.position == 0) return false;

            pass.at = close.position + 1;

            return true;
        }

        const position = pass.walk.batch.indices[pass.at] & structural.index_position_mask;

        if (position < pass.input.len) {
            @branchHint(.likely);

            if (pass.input[position - 1] == '"') {
                @branchHint(.likely);

                pass.walk.batch.indices[pass.at] = position;

                return true;
            }
        }

        return pass.advanced(string_skip_cold(pass.walk, pass.spot_of(open)));
    }

    inline fn string_then_comma(pass: *Pass, open: u64) bool {
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        if (comptime walk_direct) {
            if (!pass.string_skip(open)) return false;
            if (pass.at >= pass.limit) return false;
            if (pass.input[pass.at] != ',') return false;

            pass.at += 1;

            return true;
        }

        const entry: u64 = pass.walk.batch.indices[pass.at] & structural.index_position_mask;

        if (entry >= pass.input.len) return false;
        if (pair_read(pass.input, entry - 1) != comma_after_quote) return false;

        pass.at += 1;

        return true;
    }

    inline fn string_skip_rest(pass: *Pass, open: u64) bool {
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        if (comptime walk_direct) {
            if (pass.at > open + 1) return true;
        }

        return pass.string_skip(open);
    }

    inline fn after_colon(pass: *Pass, colon: u32) void {
        comptime assert(walk_direct);
        assert(pass.input[colon] == ':');

        if (pass.input[colon + 1] == ' ') {
            @branchHint(.likely);

            pass.at = colon + 2;
        } else {
            pass.at = colon + 1;
        }
    }

    inline fn key_skip(pass: *Pass, open: u64) bool {
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        if (comptime walk_direct) {
            const close = scalar.key_close(pass.input, .{
                .limit = pass.limit,
                .open = @intCast(open),
            });

            if (close.position == 0) return false;

            const end = close.position + 1;

            if (end < pass.limit) {
                @branchHint(.likely);

                if (pass.input[end] == ':') {
                    @branchHint(.likely);

                    pass.after_colon(end);

                    return true;
                }
            }

            pass.at = end;

            const colon = pass.take() orelse return false;

            return pass.input[@intCast(colon)] == ':';
        }

        const entry: u64 = pass.walk.batch.indices[pass.at] & structural.index_position_mask;

        if (entry < pass.input.len) {
            @branchHint(.likely);

            if (pair_read(pass.input, entry - 1) == colon_after_quote) {
                @branchHint(.likely);

                pass.at += 1;

                return true;
            }
        }

        return pass.advanced(key_skip_cold(pass.walk, pass.spot_of(open)));
    }

    inline fn key_skip_value(pass: *Pass, open: u64) ?u64 {
        assert(open < pass.input.len);
        assert(pass.at < at_limit);

        if (pass.input[@intCast(open)] != '"') return null;
        if (!pass.key_skip(open)) return null;

        return pass.take();
    }

    inline fn literal_take(pass: *Pass, position: u64, comptime literal: Literal) bool {
        const text = comptime literal.text();

        assert(position < pass.input.len);
        assert(pass.at < at_limit);

        if (comptime !walk_direct) {
            const next: u64 = pass.walk.batch.indices[pass.at];

            if (next -% position == text.len) {
                const word = std.mem.readInt(u32, pass.input[position..][0..4], .little);

                if (word != comptime std.mem.readInt(u32, text[0..4], .little)) return false;
                if (comptime text.len == 4) return true;

                return pass.input[position + 4] == text[4];
            }
        }

        if (!literal_valid(pass.input, position, literal)) return false;

        pass.scalar_ended(position + text.len);

        return true;
    }

    inline fn literal_before_token(pass: *const Pass, position: u64) bool {
        assert(position < pass.input.len);
        assert(pass.at < at_limit);

        if (comptime walk_direct) return false;

        const next: u64 = pass.walk.batch.indices[pass.at];
        const size = next -% position;

        if (size == literal_null_bytes) {
            const word = std.mem.readInt(u32, pass.input[position..][0..4], .little);

            if (word == literal_true_word) return true;

            return word == literal_null_word;
        }

        if (size == literal_false_bytes) {
            const word = std.mem.readInt(u32, pass.input[position..][0..4], .little);

            if (word == literal_false_word) return pass.input[position + 4] == 'e';
        }

        return false;
    }

    inline fn raw_of(pass: *Pass, open: u64) ?[]const u8 {
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        if (comptime walk_direct) {
            const close = scalar.string_close(pass.input, .{
                .limit = pass.limit,
                .open = @intCast(open),
            });

            if (close.position == 0) return null;

            pass.at = close.position + 1;

            return pass.input[@intCast(open + 1)..close.position];
        }

        const entry: u64 = pass.walk.batch.indices[pass.at];

        if (entry < pass.input.len) {
            if (pass.input[entry - 1] == '"') return pass.input[open + 1 .. entry - 1];
        }

        const close = pass.walk.batch.close_find(pass.input, pass.spot_of(open));
        if (close.position == 0) return null;

        if (close.refilled) pass.at = 0;

        return pass.input[open + 1 .. close.position];
    }

    inline fn key_of_direct(pass: *Pass, open: u64) ?Key {
        comptime assert(walk_direct);
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        const close = scalar.key_close(pass.input, .{
            .limit = pass.limit,
            .open = @intCast(open),
        });

        if (close.position == 0) return null;

        const start: u32 = @intCast(open + 1);
        const end = close.position + 1;

        if (end < pass.limit) {
            @branchHint(.likely);

            if (!close.escaped) {
                @branchHint(.likely);

                if (pass.input[end] == ':') {
                    @branchHint(.likely);

                    pass.after_colon(end);

                    return .{
                        .size = close.position - start,
                        .text = pass.input[start..],
                        .word = word_read(pass.input[start..]),
                    };
                }
            }
        }

        const size = key_cold(pass.walk, close, start);
        if (size == walk_failed) return null;

        pass.at = end;

        const colon = pass.take() orelse return null;
        if (pass.input[@intCast(colon)] != ':') return null;

        return .{
            .size = size,
            .text = pass.walk.key_text,
            .word = word_read(pass.walk.key_text),
        };
    }

    inline fn key_of(pass: *Pass, open: u64) ?Key {
        assert(open < pass.input.len);
        assert(pass.input[@intCast(open)] == '"');

        if (comptime walk_direct) return pass.key_of_direct(open);

        const entry: u64 = pass.walk.batch.indices[pass.at];

        if (entry + key_word_bytes < pass.input.len) {
            if (pair_read(pass.input, entry - 1) == colon_after_quote) {
                assert(entry - 1 > open);

                const start = open + 1;

                pass.at += 1;

                return .{
                    .size = @intCast(entry - open - 2),
                    .text = pass.input[start..],
                    .word = word_read(pass.input[start..]),
                };
            }
        }

        const cold = key_cold_batch(pass.walk, pass.spot_of(open));
        if (cold.failed) return null;

        pass.at = (if (cold.refilled) 0 else pass.at) + 1;

        return .{
            .size = cold.size,
            .text = pass.walk.key_text,
            .word = word_read(pass.walk.key_text),
        };
    }

    inline fn finished(pass: *Pass) bool {
        assert(pass.at < at_limit);
        assert(pass.input.len <= tokenizer_module.input_bytes_max);

        if (comptime walk_direct) return scalar.blank_end(pass.input, pass.at) == pass.input.len;

        for (0..@divFloor(pass.input.len, structural.block_bytes) + 2) |_| {
            if (pass.walk.batch.indices[pass.at] != entry_sentinel) return false;
            if (pass.walk.batch.cursor.exhausted) return true;
            if (!pass.walk.batch.refill(pass.input)) return false;

            pass.at = 0;
        }

        return false;
    }
};

inline fn pair_read(input: []const u8, position: u64) u32 {
    assert(position < input.len);
    assert(input.len - position >= 2);

    return std.mem.readInt(u16, input[position..][0..2], .little);
}

inline fn word_read(text: []const u8) u64 {
    assert(@sizeOf(u64) == key_word_bytes);
    assert(text.len >= key_word_bytes);

    return std.mem.readInt(u64, text[0..8], .little);
}

pub fn decode(
    comptime T: type,
    region: *Region,
    input: []const u8,
    target: *T,
    unknown_members: UnknownMembers,
) bool {
    comptime assert(@typeInfo(codec.traits_of(T, 0).adapted_errors) == .error_set);
    assert(input.len <= tokenizer_module.input_bytes_max);
    assert(region.used <= region.top);

    if (input.len >= structural.index_position_mask) return false;

    var walk: Walk = undefined;

    walk.indent = 0;
    walk.input = input;
    walk.key_text = input;
    walk.limit = @intCast(input.len -| scalar.margin_bytes);
    walk.region = region;
    walk.unknown_members = unknown_members;

    if (comptime !walk_direct) {
        walk.indexer = .empty;
        walk.batch.cursor = .{
            .count = 0,
            .exhausted = false,
            .failed = false,
            .indexer = &walk.indexer,
            .indices = walk.batch.indices[0..structural.index_capacity],
            .position = 0,
        };
    }

    const used = region.used;
    const top = region.top;

    if (!document_walk(T, &walk, target)) {
        region.used = used;
        region.top = top;

        return false;
    }

    assert(region.top == top);
    assert(region.used >= used);

    return true;
}

fn document_walk(comptime T: type, walk: *Walk, target: *T) bool {
    assert(walk.input.len <= tokenizer_module.input_bytes_max);
    assert(walk.limit <= walk.input.len);

    if (comptime !walk_direct) {
        assert(walk.batch.cursor.count == 0);
        assert(walk.batch.cursor.position == 0);

        if (!walk.batch.refill(walk.input)) return false;
    }

    var pass: Pass = .init(walk, 0);

    const position = pass.take() orelse return false;
    if (!element_take(T, 0, &pass, position, target)) return false;

    return pass.finished();
}

inline fn element_take(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    position: u64,
    target: *T,
) bool {
    comptime assert(nesting <= depth_max + 1);
    assert(position < pass.input.len);

    if (comptime !codec.null_taken(T)) {
        if (pass.input[@intCast(position)] == 'n') {
            if (!pass.literal_take(position, .null_value)) return false;

            codec.default_assign(T, target) catch return false;

            return true;
        }
    }

    return value_take(T, nesting, pass, position, target);
}

inline fn field_take(
    comptime T: type,
    comptime index: usize,
    comptime nesting: u8,
    pass: *Pass,
    position: u64,
    target: *T,
) bool {
    comptime assert(nesting <= depth_max + 1);
    comptime assert(index < @typeInfo(T).@"struct".field_names.len);
    assert(position < pass.input.len);

    const structure = @typeInfo(T).@"struct";
    const Field = structure.field_types[index];
    const field = &@field(target, structure.field_names[index]);

    if (comptime !codec.null_taken(Field)) {
        if (pass.input[@intCast(position)] == 'n') {
            if (!pass.literal_take(position, .null_value)) return false;

            codec.field_null_assign(T, index, field) catch return false;

            return true;
        }
    }

    return value_take(Field, nesting, pass, position, field);
}

inline fn value_take(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    position: u64,
    target: *T,
) bool {
    comptime assert(nesting <= depth_max + 1);
    assert(position < pass.input.len);

    switch (comptime codec.shape_of(T)) {
        .adapted => return adapted_take(T, nesting, pass, position, target),
        .array => {
            if (pass.input[@intCast(position)] != '[') return false;
            if (comptime nesting >= depth_max) return false;

            return array_take(T, nesting + 1, pass, target);
        },
        .boolean => return boolean_take(pass, position, target),
        .choice => {
            const spot = pass.spot_of(position);

            return pass.advanced(choice_walk(T, nesting, pass.walk, spot, target));
        },
        .entry => @compileError("an entry is decoded only inside a map"),
        .enumeration => return enumeration_take(T, pass, position, target),
        .float => return float_take(T, pass, position, target),
        .integer => return integer_take(T, pass, position, target),
        .map => {
            if (pass.input[@intCast(position)] != '{') return false;
            if (comptime nesting >= depth_max) return false;

            const start = pass.at_narrow();

            return pass.advanced(map_walk(T, nesting + 1, pass.walk, start, target));
        },
        .object => {
            if (pass.input[@intCast(position)] != '{') return false;
            if (comptime nesting >= depth_max) return false;

            const start = pass.at_narrow();

            return pass.advanced(object_walk(T, nesting + 1, pass.walk, start, target));
        },
        .optional => return optional_take(T, nesting, pass, position, target),
        .raw => {
            const spot = pass.spot_of(position);

            return pass.advanced(raw_walk(T, nesting, pass.walk, spot, target));
        },
        .sequence => {
            if (pass.input[@intCast(position)] != '[') return false;
            if (comptime nesting >= depth_max) return false;

            const start = pass.at_narrow();

            return pass.advanced(sequence_walk(T, nesting + 1, pass.walk, start, target));
        },
        .string => {
            comptime codec.sentinel_check(T);

            return string_take(pass, position, target);
        },
    }
}

inline fn array_take(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    target: *T,
) bool {
    comptime assert(codec.shape_of(T) == .array);
    comptime assert(nesting <= depth_max);
    assert(target.len > 0);

    const Element = @typeInfo(T).array.child;

    for (target, 1..) |*item, count| {
        const position = pass.take() orelse return false;

        if (!element_take(Element, nesting, pass, position, item)) return false;

        const separator = pass.take() orelse return false;
        const expected: u8 = if (count < target.len) ',' else ']';

        if (pass.input[@intCast(separator)] != expected) return false;
    }

    return true;
}

inline fn adapted_take(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    position: u64,
    target: *T,
) bool {
    comptime assert(codec.shape_of(T) == .adapted);
    assert(position < pass.input.len);

    const Wire = codec.WireType(T);

    var wire: Wire = undefined;

    if (!value_take(Wire, nesting, pass, position, &wire)) return false;

    target.* = T.json_decode(wire) catch return false;

    return true;
}

inline fn optional_take(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    position: u64,
    target: *T,
) bool {
    comptime assert(codec.shape_of(T) == .optional);
    assert(position < pass.input.len);

    const Child = @typeInfo(T).optional.child;

    if (pass.input[@intCast(position)] == 'n') {
        if (!pass.literal_take(position, .null_value)) return false;

        target.* = null;

        return true;
    }

    var child: Child = undefined;

    if (!value_take(Child, nesting, pass, position, &child)) return false;

    target.* = child;

    return true;
}

inline fn boolean_take(pass: *Pass, position: u64, target: *bool) bool {
    assert(position < pass.input.len);
    assert(pass.input.len <= tokenizer_module.input_bytes_max);

    switch (pass.input[@intCast(position)]) {
        't' => {
            if (!pass.literal_take(position, .true_value)) return false;

            target.* = true;

            return true;
        },
        'f' => {
            if (!pass.literal_take(position, .false_value)) return false;

            target.* = false;

            return true;
        },
        else => return false,
    }
}

inline fn integer_take(comptime T: type, pass: *Pass, position: u64, target: *T) bool {
    comptime assert(@typeInfo(T) == .int);
    assert(position < pass.input.len);

    if (comptime @bitSizeOf(T) <= 64) {
        if (number.integer_far(T, pass.input, @intCast(position))) |far| {
            target.* = far.value;

            pass.scalar_ended(far.end);

            return true;
        }
    }

    const end = integer_near(T, pass.input, @intCast(position), target);
    if (end == walk_failed) return false;

    pass.scalar_ended(end);

    return true;
}

noinline fn integer_near(comptime T: type, input: []const u8, position: u32, target: *T) u32 {
    comptime assert(@typeInfo(T) == .int);
    assert(position < input.len);

    const end = number_valid_end(input, position) orelse return walk_failed;

    target.* = number.integer_parse(T, input[position..end]) orelse return walk_failed;

    return end;
}

inline fn float_take(comptime T: type, pass: *Pass, position: u64, target: *T) bool {
    comptime assert(@typeInfo(T) == .float);
    assert(position < pass.input.len);

    if (comptime T == f64) {
        if (number.float_far(pass.input, @intCast(position))) |far| {
            target.* = far.value;

            pass.scalar_ended(far.end);

            return true;
        }
    }

    const end = float_near(T, pass.input, @intCast(position), target);
    if (end == walk_failed) return false;

    pass.scalar_ended(end);

    return true;
}

noinline fn float_near(comptime T: type, input: []const u8, position: u32, target: *T) u32 {
    comptime assert(@typeInfo(T) == .float);
    assert(position < input.len);

    const end = number_valid_end(input, position) orelse return walk_failed;
    const value = number.float_parse(T, input[position..end]) orelse return walk_failed;
    if (!std.math.isFinite(value)) return walk_failed;

    target.* = value;

    return end;
}

inline fn number_valid_end(input: []const u8, position: u32) ?u32 {
    assert(position < input.len);
    assert(input.len <= tokenizer_module.input_bytes_max);

    return switch (input[position]) {
        '-' => tokenizer_module.number_valid_end(input, position, true),
        '0'...'9' => tokenizer_module.number_valid_end(input, position, false),
        else => null,
    };
}

inline fn string_take(pass: *Pass, open: u64, target: *[]const u8) bool {
    assert(open < pass.input.len);
    assert(pass.input.len <= tokenizer_module.input_bytes_max);

    if (pass.input[@intCast(open)] != '"') return false;

    if (comptime walk_direct) {
        const close = scalar.string_close(pass.input, .{
            .limit = pass.limit,
            .open = @intCast(open),
        });

        if (close.position == 0) return false;

        pass.at = close.position + 1;

        if (!close.escaped) {
            target.* = pass.input[@intCast(open + 1)..close.position];

            return true;
        }

        const length: u32 = @intCast(close.position - open - 1);

        return string_escaped(pass.walk, pass.input[@intCast(open + 1)..], length, target);
    }

    const entry = pass.walk.batch.indices[pass.at];

    if (entry < pass.input.len) {
        if (pass.input[entry - 1] == '"') {
            target.* = pass.input[open + 1 .. entry - 1];

            return true;
        }
    }

    return pass.advanced(string_take_cold(pass.walk, pass.spot_of(open), target));
}

noinline fn string_take_cold(walk: *Walk, spot: Spot, target: *[]const u8) u32 {
    comptime assert(!walk_direct);
    assert(spot.open < walk.input.len);
    assert(spot.at < at_limit);

    const start = spot.open + 1;
    const close = walk.batch.close_find(walk.input, spot);
    if (close.position == 0) return walk_failed;

    if (close.escaped) {
        const length = close.position - start;

        if (!string_escaped(walk, walk.input[start..], length, target)) return walk_failed;
    } else {
        target.* = walk.input[start..close.position];
    }

    return if (close.refilled) 0 else spot.at;
}

fn string_escaped(walk: *Walk, window: []const u8, length: u32, target: *[]const u8) bool {
    assert(length <= window.len);
    assert(window.len <= walk.input.len);

    const region = walk.region;
    const raw = window[0..length];
    const available = region.buffer[region.used..region.top];

    if (available.len >= length + lane_count) {
        const size = string.unescape_checked(window, length, available) orelse return false;

        target.* = available[0..size];
        region.used += size;

        return true;
    }

    const reserved = region.reserve(u8, length) catch return false;

    target.* = string.unescape_bounded(raw, reserved) catch return false;

    return true;
}

inline fn enumeration_take(comptime T: type, pass: *Pass, open: u64, target: *T) bool {
    comptime assert(@typeInfo(T) == .@"enum");
    assert(open < pass.input.len);

    if (pass.input[@intCast(open)] != '"') return false;

    const raw = pass.raw_of(open) orelse return false;

    target.* = codec.enumeration_of(T, .{ .string = raw }) catch return false;

    return true;
}

fn object_walk(
    comptime T: type,
    comptime nesting: u8,
    walk: *Walk,
    start: u32,
    target: *T,
) u32 {
    comptime assert(codec.shape_of(T) == .object);
    comptime assert(nesting <= depth_max);
    assert(start < at_limit);

    comptime codec.names_check(T);
    codec.defaults_assign(T, target);

    var pass: Pass = .init(walk, start);
    var seen: codec.SeenType(T) = if (comptime codec.required_count(T) > 0) .empty else {};
    var open = pass.take() orelse return walk_failed;

    if (pass.input[@intCast(open)] == '}') {
        codec.required_check(T, &seen) catch return walk_failed;

        return pass.at_narrow();
    }

    while (pass.input[@intCast(open)] == '"') {
        const key = pass.key_of(open) orelse break;
        const value = pass.take() orelse break;

        if (!field_dispatch(T, nesting, &pass, key, value, target, &seen)) break;

        const separator = pass.take() orelse break;
        const byte = pass.input[@intCast(separator)];

        if (byte != ',') {
            if (byte != '}') break;

            codec.required_check(T, &seen) catch break;

            return pass.at_narrow();
        }

        open = pass.take() orelse break;
    }

    return walk_failed;
}

inline fn field_dispatch(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    key: Key,
    value: u64,
    target: *T,
    seen: *codec.SeenType(T),
) bool {
    comptime assert(nesting >= 1);
    assert(value < pass.input.len);
    assert(key.size <= tokenizer_module.input_bytes_max);

    const structure = @typeInfo(T).@"struct";
    const field_count = structure.field_names.len;

    if (comptime field_count == 0) return member_skip(T, nesting, pass, value);

    const plan = comptime key_plan_of(T);

    dispatch: switch (plan.slot(key)) {
        inline 0...field_count - 1 => |field_index| {
            const name = comptime codec.name_of(T, structure.field_names[field_index]);

            if (!key_matches(name, key)) {
                if (comptime plan.exact) return member_skip(T, nesting, pass, value);

                continue :dispatch key_linear(T, key);
            }

            if (!field_take(T, field_index, nesting, pass, value, target)) return false;

            if (comptime codec.required_count(T) > 0) {
                if (comptime codec.field_required(T, field_index)) seen.set(field_index);
            }

            return true;
        },
        field_count => return member_skip(T, nesting, pass, value),
        else => unreachable,
    }
}

inline fn key_linear(comptime T: type, key: Key) u32 {
    comptime assert(codec.shape_of(T) == .object);
    assert(key.size <= tokenizer_module.input_bytes_max);

    const names = comptime codec.names_of(T);

    return codec.name_index(names, false, key.text[0..key.size]) orelse names.entries.len;
}

inline fn member_skip(
    comptime T: type,
    comptime nesting: u8,
    pass: *Pass,
    value: u64,
) bool {
    comptime assert(codec.shape_of(T) == .object);
    comptime assert(nesting <= depth_max);
    assert(value < pass.input.len);

    if (T != codec.Empty) {
        if (pass.walk.unknown_members == .refused) return false;
    }

    switch (pass.input[@intCast(value)]) {
        '"' => return pass.string_skip(value),
        '[', '{' => {
            const limit = depth_max - nesting;

            return pass.advanced(container_skip(pass.walk, pass.spot_of(value), limit));
        },
        else => {
            if (pass.literal_before_token(value)) return true;

            const end = scalar_skip(pass.input, @intCast(value));
            if (end == walk_failed) return false;

            pass.scalar_ended(end);

            return true;
        },
    }
}

inline fn key_matches(comptime name: []const u8, key: Key) bool {
    comptime assert(name.len <= tokenizer_module.input_bytes_max);
    assert(key.size <= tokenizer_module.input_bytes_max);

    if (key.size != name.len) return false;

    if (comptime name.len < key_word_bytes) {
        const mask = comptime key_masks[name.len];

        return key.word & mask == comptime name_word_of(name);
    }

    if (key.word != comptime name_word_of(name)) return false;

    comptime var offset: u32 = key_word_bytes;

    inline while (offset < name.len - key_word_bytes) : (offset += key_word_bytes) {
        const word = comptime std.mem.readInt(u64, name[offset..][0..8], .little);

        if (word_read(key.text[offset..]) != word) return false;
    }

    if (comptime name.len > key_word_bytes) {
        const offset_last = comptime name.len - key_word_bytes;
        const word = comptime std.mem.readInt(u64, name[offset_last..][0..8], .little);

        if (word_read(key.text[offset_last..]) != word) return false;
    }

    return true;
}

noinline fn key_cold(walk: *Walk, close: scalar.Close, start: u32) u32 {
    @branchHint(.unlikely);
    comptime assert(walk_direct);
    assert(close.position >= start);
    assert(start > 0);

    const raw = walk.input[start..close.position];

    if (!close.escaped) {
        if (walk.input.len - start >= key_word_bytes) {
            const plain_size: u32 = @intCast(raw.len);

            walk.key_text = walk.input[start..];

            assert(plain_size < walk_failed);

            return plain_size;
        }
    }

    if (raw.len > key_buffer_bytes) return walk_failed;

    const size: u32 = if (close.escaped) escaped: {
        const buffer = walk.key_buffer[0..key_buffer_bytes];
        const text = string.unescape(raw, buffer) catch return walk_failed;

        break :escaped @intCast(text.len);
    } else plain: {
        @memcpy(walk.key_buffer[0..raw.len], raw);

        break :plain @intCast(raw.len);
    };

    @memset(walk.key_buffer[size..][0..key_word_bytes], 0);

    walk.key_text = walk.key_buffer[0 .. size + key_word_bytes];

    assert(size <= raw.len);

    return size;
}

noinline fn key_cold_batch(walk: *Walk, spot: Spot) KeyCold {
    @branchHint(.unlikely);
    comptime assert(!walk_direct);
    assert(spot.open < walk.input.len);
    assert(spot.at < at_limit);

    const failed: KeyCold = .{ .size = 0, .failed = true, .refilled = false };
    const close = walk.batch.close_find(walk.input, spot);
    if (close.position == 0) return failed;

    const colon = walk.batch.indices[if (close.refilled) 0 else spot.at];
    if (colon >= walk.input.len) return failed;
    if (walk.input[colon] != ':') return failed;

    const start = spot.open + 1;
    const raw = walk.input[start..close.position];

    if (!close.escaped) {
        if (walk.input.len - start >= key_word_bytes) {
            walk.key_text = walk.input[start..];

            return .{ .size = @intCast(raw.len), .failed = false, .refilled = close.refilled };
        }
    }

    if (raw.len > key_buffer_bytes) return failed;

    const size: u32 = if (close.escaped) escaped: {
        const text = string.unescape(raw, walk.key_buffer[0..key_buffer_bytes]) catch return failed;

        break :escaped @intCast(text.len);
    } else plain: {
        @memcpy(walk.key_buffer[0..raw.len], raw);

        break :plain @intCast(raw.len);
    };

    @memset(walk.key_buffer[size..][0..key_word_bytes], 0);

    walk.key_text = walk.key_buffer[0 .. size + key_word_bytes];

    assert(size <= raw.len);

    return .{ .size = size, .failed = false, .refilled = close.refilled };
}

fn name_word_of(comptime name: []const u8) u64 {
    comptime assert(name.len <= tokenizer_module.input_bytes_max);

    var padded: [key_word_bytes]u8 = @splat(0);
    const count = @min(name.len, key_word_bytes);

    @memcpy(padded[0..count], name[0..count]);

    return std.mem.readInt(u64, &padded, .little);
}

fn name_mixed_of(comptime name: []const u8, comptime tail_used: bool) u64 {
    comptime assert(name.len <= tokenizer_module.input_bytes_max);

    const mask = key_masks[name.len & key_mask_index_mask];

    var mixed = (name_word_of(name) & mask) ^ name.len;

    if (tail_used) {
        const tail = if (name.len <= key_word_bytes)
            name_word_of(name)
        else
            std.mem.readInt(u64, name[name.len - key_word_bytes ..][0..8], .little);

        mixed ^= std.math.rotl(u64, tail & mask, key_tail_rotation);
    }

    return mixed;
}

fn key_plan_of(comptime T: type) KeyPlan {
    const names = codec.names_of(T);
    const count = names.entries.len;

    comptime assert(count > 0);

    @setEvalBranchQuota(key_plan_quota);

    if (count > key_field_count_max) {
        return .{
            .exact = false,
            .seed = 1,
            .shift = 63,
            .slots = &.{ key_slot_empty, key_slot_empty },
            .tail_used = false,
        };
    }

    const bits_min: u32 = @max(3, std.math.log2_int_ceil(u32, @intCast(count)) + 1);

    var mixed: [count]u64 = undefined;

    for ([_]bool{ false, true }) |tail_used| {
        for (names.entries, 0..) |entry, index| mixed[index] = name_mixed_of(entry.text, tail_used);

        for (bits_min..bits_min + key_slot_bits_extra) |bits| {
            var seed = key_seed_first;

            for (0..key_seed_count) |_| {
                if (key_slots_try(&mixed, bits, seed)) {
                    return key_plan_build(&mixed, bits, seed, tail_used);
                }

                seed = (seed *% key_seed_step) | 1;
            }
        }
    }

    var result = key_plan_build(&mixed, bits_min, key_seed_first, true);

    result.exact = false;

    return result;
}

fn key_slots_try(mixed: []const u64, comptime bits: u32, seed: u64) bool {
    comptime assert(bits >= 3);
    comptime assert(bits <= 16);
    assert(mixed.len > 0);
    assert(seed % 2 == 1);

    const shift: u6 = @intCast(64 - bits);

    var used: std.StaticBitSet(1 << bits) = .empty;

    for (mixed) |value| {
        const slot: u32 = @intCast((value *% seed) >> shift);

        if (used.isSet(slot)) return false;

        used.set(slot);
    }

    return true;
}

fn key_plan_build(
    mixed: []const u64,
    comptime bits: u32,
    seed: u64,
    tail_used: bool,
) KeyPlan {
    comptime assert(bits >= 3);
    comptime assert(bits <= 16);
    assert(mixed.len > 0);
    assert(seed % 2 == 1);

    const shift: u6 = @intCast(64 - bits);

    const empty: u8 = @intCast(mixed.len);

    var slots: [1 << bits]u8 = @splat(empty);

    for (mixed, 0..) |value, index| {
        const slot: u32 = @intCast((value *% seed) >> shift);

        if (slots[slot] == empty) slots[slot] = @intCast(index);
    }

    const final = slots;

    return .{
        .exact = true,
        .seed = seed,
        .shift = shift,
        .slots = &final,
        .tail_used = tail_used,
    };
}

fn sequence_walk(
    comptime T: type,
    comptime nesting: u8,
    walk: *Walk,
    start: u32,
    target: *T,
) u32 {
    comptime assert(codec.shape_of(T) == .sequence);
    comptime assert(nesting <= depth_max);
    assert(start < at_limit);

    const Element = @typeInfo(T).pointer.child;

    comptime codec.sentinel_check(T);

    var pass: Pass = .init(walk, start);

    const region = walk.region;
    const stack_mark = region.mark();

    var count: u32 = 0;
    var position = pass.take() orelse return walk_failed;

    if (pass.input[@intCast(position)] != ']') {
        for (0..pass.input.len) |_| {
            const item = region.push(Element) catch return walk_failed;

            if (!element_take(Element, nesting, &pass, position, item)) return walk_failed;

            count += 1;

            const separator = pass.take() orelse return walk_failed;
            const byte = pass.input[@intCast(separator)];

            if (byte == ',') {
                position = pass.take() orelse return walk_failed;

                continue;
            }

            if (byte != ']') return walk_failed;

            break;
        } else return walk_failed;
    }

    target.* = region.take(Element, stack_mark, count) catch return walk_failed;

    return pass.at_narrow();
}

fn map_walk(
    comptime T: type,
    comptime nesting: u8,
    walk: *Walk,
    start: u32,
    target: *T,
) u32 {
    comptime assert(codec.shape_of(T) == .map);
    comptime assert(nesting <= depth_max);
    assert(start < at_limit);

    const Entry = @typeInfo(T).pointer.child;
    const Value = @FieldType(Entry, "value");

    comptime codec.sentinel_check(T);

    var pass: Pass = .init(walk, start);

    const region = walk.region;
    const stack_mark = region.mark();

    var count: u32 = 0;
    var open = pass.take() orelse return walk_failed;

    if (pass.input[@intCast(open)] != '}') {
        for (0..pass.input.len) |_| {
            const item = region.push(Entry) catch return walk_failed;

            if (!string_take(&pass, open, &item.key)) return walk_failed;

            const colon = pass.take() orelse return walk_failed;
            if (pass.input[@intCast(colon)] != ':') return walk_failed;

            const value = pass.take() orelse return walk_failed;

            if (!element_take(Value, nesting, &pass, value, &item.value)) return walk_failed;

            count += 1;

            const separator = pass.take() orelse return walk_failed;
            const byte = pass.input[@intCast(separator)];

            if (byte == ',') {
                open = pass.take() orelse return walk_failed;

                continue;
            }

            if (byte != '}') return walk_failed;

            break;
        } else return walk_failed;
    }

    const items = region.take(Entry, stack_mark, count) catch return walk_failed;

    target.* = codec.entries_deduplicate(Entry, region, items) catch return walk_failed;

    return pass.at_narrow();
}

fn choice_walk(
    comptime T: type,
    comptime nesting: u8,
    walk: *Walk,
    spot: Spot,
    target: *T,
) u32 {
    comptime assert(codec.shape_of(T) == .choice);
    comptime assert(nesting <= depth_max);
    assert(spot.at < at_limit);
    assert(spot.open < walk.input.len);

    const choice = @typeInfo(T).@"union";
    const table = comptime codec.choice_table(T);
    const position = spot.open;

    var pass: Pass = .init(walk, spot.at);

    const kind = kind_of_byte(pass.input[position]) orelse return walk_failed;
    const index = table[@backingInt(kind)] orelse return walk_failed;

    switch (index) {
        inline 0...choice.field_names.len - 1 => |variant_index| {
            const name = choice.field_names[variant_index];
            const Payload = choice.field_types[variant_index];

            if (Payload == void) {
                if (!literal_valid(pass.input, position, .null_value)) return walk_failed;

                pass.scalar_ended(position + literal_null_bytes);

                target.* = @unionInit(T, name, {});
            } else {
                target.* = @unionInit(T, name, undefined);

                const payload = &@field(target.*, name);

                if (!value_take(Payload, nesting, &pass, position, payload)) return walk_failed;
            }
        },
        else => unreachable,
    }

    return pass.at_narrow();
}

fn kind_of_byte(byte: u8) ?codec.Kind {
    assert(@sizeOf(codec.Kind) == 1);
    assert(@typeInfo(codec.Kind).@"enum".field_names.len == 6);

    return switch (byte) {
        '"' => .string,
        '-', '0'...'9' => .number,
        '[' => .array,
        'f', 't' => .boolean,
        'n' => .null_value,
        '{' => .object,
        else => null,
    };
}

fn raw_walk(
    comptime T: type,
    comptime nesting: u8,
    walk: *Walk,
    spot: Spot,
    target: *T,
) u32 {
    comptime assert(codec.shape_of(T) == .raw);
    comptime assert(nesting <= depth_max);
    assert(spot.at < at_limit);
    assert(spot.open < walk.input.len);

    var pass: Pass = .init(walk, spot.at);

    const end = raw_end(nesting, &pass, spot.open) orelse return walk_failed;

    target.* = .{ .text = pass.input[spot.open..end] };

    return pass.at_narrow();
}

inline fn raw_end(comptime nesting: u8, pass: *Pass, position: u64) ?u32 {
    comptime assert(nesting <= depth_max);
    assert(position < pass.input.len);

    const input = pass.input;

    const end: u64 = switch (input[@intCast(position)]) {
        '"' => string_end: {
            const raw = pass.raw_of(position) orelse return null;

            break :string_end position + raw.len + 2;
        },
        '[', '{' => container_end: {
            const limit = depth_max - nesting;
            const next = container_skip(pass.walk, pass.spot_of(position), limit);

            if (!pass.advanced(next)) return null;

            if (comptime walk_direct) break :container_end pass.at;

            break :container_end pass.walk.batch.indices[pass.at - 1] + 1;
        },
        'f' => if (literal_valid(input, position, .false_value))
            position + literal_false_bytes
        else
            return null,
        'n' => if (literal_valid(input, position, .null_value))
            position + literal_null_bytes
        else
            return null,
        't' => if (literal_valid(input, position, .true_value))
            position + literal_true_bytes
        else
            return null,
        else => number_valid_end(input, @intCast(position)) orelse return null,
    };

    const result: u32 = @intCast(end);

    assert(result > position);
    assert(result <= input.len);

    pass.scalar_ended(result);

    return result;
}

noinline fn scalar_skip(input: []const u8, position: u32) u32 {
    assert(position < input.len);
    assert(input.len <= tokenizer_module.input_bytes_max);

    return scalar_end(input, position);
}

inline fn scalar_end(input: []const u8, position: u32) u32 {
    assert(position < input.len);
    assert(input.len <= tokenizer_module.input_bytes_max);

    return switch (input[position]) {
        'f' => if (literal_valid(input, position, .false_value))
            position + literal_false_bytes
        else
            walk_failed,
        'n' => if (literal_valid(input, position, .null_value))
            position + literal_null_bytes
        else
            walk_failed,
        't' => if (literal_valid(input, position, .true_value))
            position + literal_true_bytes
        else
            walk_failed,
        else => number_valid_end(input, position) orelse walk_failed,
    };
}

inline fn scalar_advance(pass: *Pass, at: u64) bool {
    assert(at < pass.input.len);
    assert(pass.input.len <= tokenizer_module.input_bytes_max);

    if (pass.literal_before_token(at)) return true;

    const end = scalar_end(pass.input, @intCast(at));
    if (end == walk_failed) return false;

    pass.scalar_ended(end);

    return true;
}

noinline fn container_skip(walk: *Walk, spot: Spot, limit: u8) u32 {
    assert(spot.open < walk.input.len);
    assert(spot.at < at_limit);
    assert(limit <= depth_max);

    if (limit == 0) return walk_failed;

    var pass: Pass = .init(walk, spot.at);
    var kinds: [depth_max]u8 = undefined;

    kinds[0] = pass.input[spot.open];

    const first = pass.take() orelse return walk_failed;

    return container_skip_states(&pass, &kinds, first, limit);
}

inline fn container_skip_states(pass: *Pass, kinds: *[depth_max]u8, first: u64, limit: u8) u32 {
    assert(first < pass.input.len);
    assert(limit >= 1);

    var depth: u8 = 1;
    var at = first;

    state: switch (skip_state_first(pass, kinds[0], at)) {
        .closed => {
            depth -= 1;

            if (depth == 0) return pass.at_narrow();
            if (kinds[depth - 1] == '[') continue :state .array_next;
            continue :state .object_next;
        },
        .object_key => {
            at = pass.key_skip_value(at) orelse break :state;
            continue :state .object_value;
        },
        inline .array_next, .object_next => |current| {
            const array = current == .array_next;
            const separator = pass.take() orelse break :state;
            const byte = pass.input[@intCast(separator)];

            if (byte != ',') {
                if (byte != comptime skip_closing_of(array)) break :state;
                continue :state .closed;
            }

            at = pass.take() orelse break :state;
            continue :state comptime skip_state_after_comma(array);
        },
        inline .array_value, .object_value => |current| {
            const array = current == .array_value;
            const after: SkipState = if (array) .array_next else .object_next;
            const byte = pass.input[@intCast(at)];

            if (byte == '"') {
                if (pass.string_then_comma(at)) {
                    at = pass.take() orelse break :state;
                    continue :state comptime skip_state_after_comma(array);
                }

                if (!pass.string_skip_rest(at)) break :state;
                continue :state after;
            }

            if (byte | container_curl == '{') {
                if (depth == limit) break :state;

                kinds[depth] = byte;
                depth += 1;
                at = pass.take() orelse break :state;

                if (comptime !walk_direct) continue :state skip_state_first(pass, byte, at);
                if (pass.input[@intCast(at)] == byte + array_close_offset) continue :state .closed;
                if (byte == '[') continue :state .array_value;
                continue :state .object_key;
            }

            if (!scalar_advance(pass, at)) break :state;
            continue :state after;
        },
    }

    return walk_failed;
}

fn skip_closing_of(comptime array: bool) u8 {
    return if (array) ']' else '}';
}

fn skip_state_after_comma(comptime array: bool) SkipState {
    return if (array) .array_value else .object_key;
}

inline fn skip_state_first(pass: *const Pass, kind: u8, at: u64) SkipState {
    assert(kind == '[' or kind == '{');
    assert(at < pass.input.len);

    if (pass.input[@intCast(at)] == kind + array_close_offset) return .closed;
    return if (kind == '[') .array_value else .object_key;
}

noinline fn string_skip_cold(walk: *Walk, spot: Spot) u32 {
    comptime assert(!walk_direct);
    assert(spot.open < walk.input.len);
    assert(spot.at < at_limit);

    const close = walk.batch.close_find(walk.input, spot);
    if (close.position == 0) return walk_failed;

    return if (close.refilled) 0 else spot.at;
}

noinline fn key_skip_cold(walk: *Walk, spot: Spot) u32 {
    comptime assert(!walk_direct);
    assert(spot.open < walk.input.len);
    assert(spot.at < at_limit);

    const close = walk.batch.close_find(walk.input, spot);
    if (close.position == 0) return walk_failed;

    const at: u32 = if (close.refilled) 0 else spot.at;
    const colon = walk.batch.indices[at];
    if (colon >= walk.input.len) return walk_failed;
    if (walk.input[colon] != ':') return walk_failed;

    const result = at + 1;

    assert(result < entries_capacity);

    return result;
}

const testing = std.testing;

const TestPort = struct {
    name: []const u8 = "",
    port_private: u16 = 0,

    pub const json = .{ .name = "Name", .port_private = "PrivatePort" };
};

const TestColor = enum {
    blue,
    red,
    unrecognized,
};

const TestChoice = union(enum) {
    empty: void,
    number: f64,
    text: []const u8,
};

const TestEpoch = struct {
    seconds: u32,

    pub const json_shape: codec.Shape = .adapted;

    pub fn json_decode(wire: u32) error{Invalid}!TestEpoch {
        if (wire == 13) return error.Invalid;

        return .{ .seconds = wire };
    }
};

const TestRecord = struct {
    active: bool = false,
    choice: TestChoice = .{ .empty = {} },
    color: TestColor = .unrecognized,
    epoch: TestEpoch = .{ .seconds = 0 },
    extra: codec.Raw = .{},
    identifier: u64,
    labels: []const codec.EntryType(i32) = &.{},
    long_member_name_with_shared_affix: []const u8 = "",
    long_member_text_with_shared_affix: []const u8 = "",
    maybe: ?i64 = null,
    nested: []const []const i8 = &.{},
    ports: []const TestPort = &.{},
    ratio: f64 = 0,
    small: f32 = 0,
    text: []const u8 = "",
    wide: i128 = 0,
};

fn test_paths_agree(comptime T: type, input: []const u8) !void {
    assert(input.len <= tokenizer_module.input_bytes_max);

    errdefer std.debug.print("disagreement on {s}\n", .{input});

    const buffer_exact = try testing.allocator.alloc(u8, 2 * input.len * @sizeOf(T) + 65536);
    defer testing.allocator.free(buffer_exact);

    const buffer_index = try testing.allocator.alloc(u8, 2 * input.len * @sizeOf(T) + 65536);
    defer testing.allocator.free(buffer_index);

    var region_exact: Region = .init(buffer_exact);
    var region_index: Region = .init(buffer_index);
    var result_exact: T = undefined;
    var result_index: T = undefined;

    const exact = codec.decode_exact(T, &region_exact, input, &result_exact, .{
        .diagnostic = null,
        .unknown_members = .ignored,
    });

    const direct = decode(T, &region_index, input, &result_index, .ignored);

    if (exact) |_| {
        try testing.expect(direct);
        try testing.expectEqualDeep(result_exact, result_index);
    } else |_| {
        try testing.expect(!direct);
    }

    const refused_exact = codec.decode_exact(T, &region_exact, input, &result_exact, .{
        .diagnostic = null,
        .unknown_members = .refused,
    });

    const refused_index = decode(T, &region_index, input, &result_index, .refused);

    if (refused_exact) |_| {
        if (refused_index) try testing.expectEqualDeep(result_exact, result_index);
    } else |_| {
        try testing.expect(!refused_index);
    }
}

const test_spaces: [120]u8 = @splat(' ');
const test_blanks = "   \n \n" ++ test_spaces;

const test_inputs = [_][]const u8{
    "{\"identifier\":7\n" ++ test_blanks,
    "{\"identifier\":7,\n" ++ test_blanks,
    "{\"identifier\":\n" ++ test_blanks,
    "{\"identifier\":7}\n" ++ test_blanks,
    "{\"identifier\": 7}",
    "{\"identifier\":18446744073709551615,\"maybe\":-9223372036854775808}",
    "{\"identifier\":18446744073709551616}",
    "{\"identifier\":-1}",
    "{\"identifier\":-0}",
    "{\"identifier\":1.0}",
    "{\"identifier\":1e3}",
    "{\"identifier\":01}",
    "{\"identifier\":\"7\"}",
    "{\"identifier\":null}",
    "{}",
    "[]",
    "null",
    "7",
    "{\"identifier\":7",
    "{\"identifier\":7,}",
    "{\"identifier\":7}x",
    "{\"identifier\":7} {}",
    "{\"identifier\" 7}",
    "{\"identifier\":7 \"text\":\"a\"}",
    "{\"identifier\":7,\"text\":\"a\\nb\"}",
    "{\"identifier\":7,\"text\":\"a\\qb\"}",
    "{\"identifier\":7,\"text\":\"\\u00e9\\ud83d\\ude00\"}",
    "{\"identifier\":7,\"text\":\"\\ud83d\"}",
    "{\"identifier\":7,\"text\":null}",
    "{\"identifier\":7,\"text\":5}",
    "{\"ident\\u0069fier\":7}",
    "{\"ident\\u0069fie\\q\":7}",
    "{\"identifier\":1,\"identifier\":2,\"text\":\"a\",\"text\":\"b\"}",
    " { \"identifier\" : 7 , \"text\" : \"a\" , \"maybe\" : null } ",
    "{\"identifier\":7,\"active\":true,\"ratio\":1.5e2,\"small\":0.1}",
    "{\"identifier\":7,\"active\":truex}",
    "{\"identifier\":7,\"active\":fals}",
    "{\"identifier\":7,\"active\":\"true\"}",
    "{\"identifier\":7,\"active\":null}",
    "{\"identifier\":7,\"ratio\":1e999}",
    "{\"identifier\":7,\"ratio\":-0.0}",
    "{\"identifier\":7,\"ratio\":1.7976931348623157e308}",
    "{\"identifier\":7,\"ratio\":123456789012345678901234567890.5e-5}",
    "{\"identifier\":7,\"ratio\":1.}",
    "{\"identifier\":7,\"ratio\":.5}",
    "{\"identifier\":7,\"small\":1e39}",
    "{\"identifier\":7,\"wide\":-170141183460469231731687303715884105728}",
    "{\"identifier\":7,\"wide\":170141183460469231731687303715884105728}",
    "{\"identifier\":7,\"color\":\"red\"}",
    "{\"identifier\":7,\"color\":\"r\\u0065d\"}",
    "{\"identifier\":7,\"color\":\"green\"}",
    "{\"identifier\":7,\"color\":3}",
    "{\"identifier\":7,\"choice\":null}",
    "{\"identifier\":7,\"choice\":2.5}",
    "{\"identifier\":7,\"choice\":\"a\\tb\"}",
    "{\"identifier\":7,\"choice\":true}",
    "{\"identifier\":7,\"choice\":[]}",
    "{\"identifier\":7,\"epoch\":12}",
    "{\"identifier\":7,\"epoch\":13}",
    "{\"identifier\":7,\"epoch\":null}",
    "{\"identifier\":7,\"extra\":null}",
    "{\"identifier\":7,\"extra\":true}",
    "{\"identifier\":7,\"extra\":-1.5e3}",
    "{\"identifier\":7,\"extra\":\"a\\\"b\"}",
    "{\"identifier\":7,\"extra\":\"a\\qb\"}",
    "{\"identifier\":7,\"extra\":[1,{\"a\":[]},\"b\"] }",
    "{\"identifier\":7,\"extra\":{\"a\":{\"b\":[1,2,3]}},\"text\":\"x\"}",
    "{\"identifier\":7,\"extra\":{\"a\":}}",
    "{\"identifier\":7,\"labels\":{}}",
    "{\"identifier\":7,\"labels\":{\"b\":2,\"a\":1,\"b\":3}}",
    "{\"identifier\":7,\"labels\":{\"a\\u0041\":1,\"aA\":2}}",
    "{\"identifier\":7,\"labels\":{\"a\":null}}",
    "{\"identifier\":7,\"labels\":null}",
    "{\"identifier\":7,\"labels\":[]}",
    "{\"identifier\":7,\"maybe\":null}",
    "{\"identifier\":7,\"maybe\":5}",
    "{\"identifier\":7,\"maybe\":\"a\"}",
    "{\"identifier\":7,\"nested\":[[1,2],[],[-128,127]]}",
    "{\"identifier\":7,\"nested\":[[128]]}",
    "{\"identifier\":7,\"nested\":[null]}",
    "{\"identifier\":7,\"nested\":[[1,]]}",
    "{\"identifier\":7,\"nested\":[[1],]}",
    "{\"identifier\":7,\"nested\":null}",
    "{\"identifier\":7,\"ports\":[{\"Name\":\"a\",\"PrivatePort\":80},{\"PrivatePort\":null}]}",
    "{\"identifier\":7,\"ports\":[null]}",
    "{\"identifier\":7,\"ports\":[{\"PrivatePort\":65536}]}",
    "{\"identifier\":7,\"long_member_name_with_shared_affix\":\"a\"}",
    "{\"identifier\":7,\"long_member_text_with_shared_affix\":\"b\"}",
    "{\"identifier\":7,\"long_member_nope_with_shared_affix\":\"c\"}",
    "{\"identifier\":7,\"unknown\":{\"a\":[1,2,{\"b\":null}],\"c\":\"d\"},\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":[1,2,}",
    "{\"identifier\":7,\"unknown\":tru}",
    "{\"identifier\":7,\"unknown\":\"a\\qb\"}",
    "{\"identifier\":7,\"unknown\":\"a\\u0041b\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\uD83D\\uDE00\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\uD83D\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\uDE00\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\uD83D\\u0041\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\\\uDE00\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\\\\\uDE00\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":\"\\u12\",\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":[\"\\x\"],\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":{\"\\x\":1},\"text\":\"e\"}",
    "{\"identifier\":7,\"unknown\":01}",
    "{\"identifier\":7,\"unknown\":{\"a\" 1}}",
    "{\"identifier\":7,\"unknown\":{\"a\":1,}}",
    "{\"identifier\":7,\"unknown\":[1 2]}",
    "{\"identifier\":7,\"unknown\":[}]}",
    "{\"identifier\":7,\"\":1}",
    "{\"\":1,\"identifier\":7}",
};

test "the index decoder agrees with the exact decoder on every shape" {
    assert(test_inputs.len > 0);

    for (test_inputs) |input| try test_paths_agree(TestRecord, input);
}

test "the index decoder handles top level scalars at the end of the input" {
    try test_paths_agree(u32, "7");
    try test_paths_agree(u32, " 7 ");
    try test_paths_agree(u32, "");
    try test_paths_agree(u32, "   ");
    try test_paths_agree(u32, "-");
    try test_paths_agree(u32, "7 8");
    try test_paths_agree(f64, "1.5");
    try test_paths_agree(f64, "1e400");
    try test_paths_agree(bool, "true");
    try test_paths_agree(bool, "fals");
    try test_paths_agree(?bool, "null");
    try test_paths_agree(?bool, "nul");
    try test_paths_agree([]const u8, "\"a\"");
    try test_paths_agree([]const u8, "\"a\\n\"");
    try test_paths_agree([]const u8, "\"a");
    try test_paths_agree([]const u8, "\"a\\\"");
    try test_paths_agree(TestColor, "\"red\"");
    try test_paths_agree(TestChoice, "null");
    try test_paths_agree(TestChoice, "1");
    try test_paths_agree(codec.Raw, "[1]");
    try test_paths_agree(codec.Raw, "\"a\"");
    try test_paths_agree(codec.Raw, "12");
    try test_paths_agree(codec.Empty, "{\"a\":1}");
    try test_paths_agree(codec.Empty, "{\"a\":1}x");
}

test "the index decoder crosses every batch boundary" {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    try builder.appendSlice(testing.allocator, "{\"identifier\":7,\"unknown\":[");

    for (0..9000) |index| {
        if (index > 0) try builder.append(testing.allocator, ',');

        try builder.appendSlice(testing.allocator, "\"a\\n\",{\"b\":[null]}");
    }

    try builder.appendSlice(testing.allocator, "],\"nested\":[");

    for (0..9000) |index| {
        if (index > 0) try builder.append(testing.allocator, ',');

        try builder.appendSlice(testing.allocator, "[1,2]");
    }

    try builder.appendSlice(testing.allocator, "],\"ports\":[");

    for (0..9000) |index| {
        if (index > 0) try builder.append(testing.allocator, ',');

        try builder.appendSlice(
            testing.allocator,
            "{\"Name\":\"x\\ty\",\"PrivatePort\":1,\"z\":\"\\\\\"}",
        );
    }

    try builder.appendSlice(testing.allocator, "]}   ");

    try test_paths_agree(TestRecord, builder.items);

    const truncated = builder.items[0 .. builder.items.len - 7];

    try test_paths_agree(TestRecord, truncated);
}

test "a failed refill never exposes the overwritten batch" {
    const tail_bytes: u32 = 70;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    try builder.append(testing.allocator, '[');
    try builder.appendNTimes(testing.allocator, ' ', structural.scan_bytes_max - 2);
    try builder.append(testing.allocator, '"');

    assert(builder.items.len == structural.scan_bytes_max);

    try builder.appendNTimes(testing.allocator, 'a', tail_bytes);
    try builder.appendSlice(testing.allocator, "\x01\"]");

    try test_paths_agree([]const []const u8, builder.items);
    try test_paths_agree([]const codec.Raw, builder.items);
}

test "the index decoder enforces the nesting limit" {
    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    for ([_]u32{ depth_max - 1, depth_max, depth_max + 1 }) |levels| {
        builder.clearRetainingCapacity();

        try builder.appendSlice(testing.allocator, "{\"identifier\":7,\"unknown\":");

        for (0..levels) |_| try builder.append(testing.allocator, '[');
        for (0..levels) |_| try builder.append(testing.allocator, ']');

        try builder.append(testing.allocator, '}');

        try test_paths_agree(TestRecord, builder.items);

        builder.clearRetainingCapacity();

        for (0..levels) |_| try builder.append(testing.allocator, '[');
        for (0..levels) |_| try builder.append(testing.allocator, ']');

        try test_paths_agree(codec.Raw, builder.items);
    }
}

test "the key plan is perfect for distinct names and falls back for shared affixes" {
    const plan = comptime key_plan_of(TestRecord);
    const plan_port = comptime key_plan_of(TestPort);

    try testing.expect(!plan.exact);
    try testing.expect(plan_port.exact);

    const names = comptime codec.names_of(TestPort);

    for (names.entries) |entry| {
        const padded = try testing.allocator.alloc(u8, entry.text.len + key_word_bytes);
        defer testing.allocator.free(padded);

        @memcpy(padded[0..entry.text.len], entry.text);
        @memset(padded[entry.text.len..], '"');

        const key: Key = .{
            .size = @intCast(entry.text.len),
            .text = padded,
            .word = word_read(padded),
        };

        try testing.expectEqual(entry.index, plan_port.slot(key));
    }
}

test "a long escaped string decodes at each region capacity up past a lane" {
    var prng: std.Random.DefaultPrng = .init(0x72656769);
    const random = prng.random();
    const pieces = [_][]const u8{
        "a",
        "0123456789abcdef",
        "caf\xc3\xa9",
        "\\\"",
        "\\\\",
        "\\n",
        "\\u0001",
        "\\u4e2d\\u6587",
        "\\ud83d\\ude00",
    };

    var raw_buffer: [1000]u8 = undefined;
    var expected: [1000]u8 = undefined;
    var quoted_buffer: [1100]u8 = undefined;
    var object_buffer: [1100]u8 = undefined;
    var buffer: [1100]u8 align(region_module.alignment_bytes) = undefined;
    var escaped: u32 = 0;

    for (0..200) |_| {
        const length = string.pieces_fill(random, &pieces, &raw_buffer);
        const raw = raw_buffer[0..length];
        const decoded = try string.unescape(raw, &expected);
        const quoted = try std.mem.print(&quoted_buffer, "\"{s}\"", .{raw});
        const object = try std.mem.print(&object_buffer, "{{\"Name\":\"{s}\"}}", .{raw});

        escaped += @intFromBool(decoded.len < length);

        for (0..lane_count + 2) |slack| {
            const bytes = @max(length + slack, region_module.alignment_bytes);

            var region: Region = .init(buffer[0..bytes]);
            var text: []const u8 = undefined;

            try testing.expect(decode([]const u8, &region, quoted, &text, .ignored));
            try testing.expectEqualStrings(decoded, text);

            region.reset();

            var port: TestPort = .{};

            try testing.expect(decode(TestPort, &region, object, &port, .ignored));
            try testing.expectEqualStrings(decoded, port.name);
        }
    }

    try testing.expect(escaped > 100);
}
