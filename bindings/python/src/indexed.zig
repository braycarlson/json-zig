const std = @import("std");

const json = @import("json");
const lacuna = @import("lacuna");

const fast = @import("fast.zig");
const integers = @import("integers.zig");
const keys = @import("keys.zig");
const number = @import("number.zig");
const objects = @import("objects.zig");
const policy_module = @import("policy.zig");

const assert = std.debug.assert;

const c = lacuna.c;
const structural = json.structural;

const Policy = policy_module.Policy;
const PyObject = c.PyObject;

const Failure = fast.Failure;

const depth_max = json.limits.depth_max;
const items_inline_count: u32 = 2048;

comptime {
    assert(depth_max <= std.math.maxInt(u8));
    assert(std.math.isPowerOfTwo(items_inline_count));
}

const Frame = struct {
    mark: u32,
    object: bool,
};

const State = enum {
    after,
    key,
    value,
};

const Resume = struct {
    position: u32,
    state: State,
};

fn ContextType(comptime renamed: bool) type {
    return struct {
        buffer: ?*PyObject,
        count: u64,
        frames: [depth_max]Frame,
        input: [:0]const u8,
        integers: *integers.Cache,
        keys: *keys.CacheType(if (renamed) .renamed else .plain),
        scratch: ?*PyObject,
        singletons: *const objects.Singletons,

        const Quoted = struct {
            length: u32,
            open_index: u32,
        };

        noinline fn grow(context: *@This(), items: []*PyObject) Failure![]*PyObject {
            assert(items.len >= items_inline_count);
            assert(items.len < @divFloor(std.math.maxInt(u32), 2));

            const capacity: u64 = items.len * 2;
            const size = capacity * @sizeOf(*PyObject);
            const buffer = c.PyBytes_FromStringAndSize(null, @intCast(size)) orelse {
                return error.PythonError;
            };

            const bytes = c.PyBytes_AsString(buffer).?[0..size];
            const result: []*PyObject = @alignCast(std.mem.bytesAsSlice(*PyObject, bytes));

            @memcpy(result[0..items.len], items);

            if (context.buffer) |previous| c.Py_DecRef(previous);

            context.buffer = buffer;

            assert(result.len == capacity);

            return result;
        }

        noinline fn escaped_of(context: *@This(), quoted: Quoted) Failure![]const u8 {
            assert(quoted.open_index < context.input.len);
            assert(quoted.length <= context.input.len - quoted.open_index);

            const open_index = quoted.open_index;
            const length = quoted.length;

            const size = context.input.len + structural.lane_count;

            if (context.scratch == null) {
                context.scratch = c.PyBytes_FromStringAndSize(null, @intCast(size)) orelse {
                    return error.PythonError;
                };
            }

            const target = c.PyBytes_AsString(context.scratch.?).?[0..size];
            const window = context.input[open_index + 1 ..];
            const written = structural.unescape_checked(window, length, target) orelse {
                return error.Declined;
            };

            assert(written <= length);

            return target[0..written];
        }
    };
}

fn WalkType(comptime renamed: bool) type {
    return struct {
        context: *ContextType(renamed),
        count: u64,
        cursor: structural.Cursor,
        depth: u32,
        input: [:0]const u8,
        items: []*PyObject,
        object: bool,

        inline fn next(walk: *@This()) Failure!u32 {
            assert(walk.depth <= depth_max);
            assert(walk.count <= walk.items.len);

            const entry = walk.cursor.next(walk.input) orelse return error.Declined;

            assert(entry & structural.index_escaped == 0);

            return entry;
        }

        inline fn push(walk: *@This(), item: *PyObject) Failure!void {
            assert(walk.count <= walk.items.len);
            assert(@intFromPtr(item) % @alignOf(*PyObject) == 0);

            if (walk.count == walk.items.len) {
                walk.items = walk.context.grow(walk.items) catch |err| {
                    c.Py_DecRef(item);

                    return err;
                };
            }

            walk.items[walk.count] = item;
            walk.count += 1;
        }

        inline fn text_of(walk: *@This(), open_index: u32) Failure![]const u8 {
            assert(open_index < walk.input.len);
            assert(walk.input[open_index] == '"');

            const entry = walk.cursor.peek_or_end(walk.input);
            if (walk.cursor.failed) return error.Declined;

            const before = entry & structural.index_position_mask;
            const close_index = structural.string_close_find(walk.input, before);
            if (close_index <= open_index) return error.Declined;

            const length = close_index - open_index - 1;

            if (entry & structural.index_escaped == 0) {
                return walk.input[open_index + 1 .. close_index];
            }

            walk.cursor.flag_clear();

            return walk.context.escaped_of(.{ .length = length, .open_index = open_index });
        }

        inline fn string_push(walk: *@This(), open_index: u32) Failure!void {
            assert(open_index < walk.input.len);
            assert(walk.depth <= depth_max);

            const text = try walk.text_of(open_index);
            const object = objects.text_object(text) orelse return error.PythonError;

            try walk.push(object);
        }

        inline fn key_push(walk: *@This(), open_index: u32) Failure!void {
            assert(walk.depth > 0);
            assert(walk.object);

            if (walk.input[open_index] != '"') return error.Declined;

            const text = try walk.text_of(open_index);
            const offset = @intFromPtr(text.ptr) -% @intFromPtr(walk.input.ptr);

            if (key_cached(walk.input, text, offset)) {
                const window: keys.Window = .{
                    .length = @intCast(text.len),
                    .reach = walk.input[offset..],
                };

                const found = walk.context.keys.object_of(window, {});
                const cached = found orelse return error.PythonError;

                objects.acquire(cached);

                return walk.push(cached);
            }

            const object = if (renamed)
                walk.context.keys.policy.renamed(text) orelse return error.PythonError
            else
                objects.text_object(text) orelse return error.PythonError;

            try walk.push(object);
        }

        inline fn literal_push(walk: *@This(), position: u32) Failure!void {
            assert(position < walk.input.len);
            assert(walk.depth <= depth_max);

            const singletons = walk.context.singletons;
            const rest = walk.input[position..];
            if (rest.len < 4) return error.Declined;

            const word = std.mem.readInt(u32, rest[0..4], .little);

            const object, const length: u32 = switch (word) {
                std.mem.readInt(u32, "null", .little) => .{ singletons.none, 4 },
                std.mem.readInt(u32, "true", .little) => .{ singletons.true_value, 4 },
                std.mem.readInt(u32, "fals", .little) => .{ singletons.false_value, 5 },
                else => return error.Declined,
            };

            if (length == 5) {
                if (rest[4] != 'e') return error.Declined;
            }

            if (!structural.scalar_ended(walk.input, position + length)) return error.Declined;

            try walk.push(singletons.acquire(object));
        }

        inline fn states(walk: *@This(), position_first: u32) Failure!void {
            assert(walk.depth == 0);
            assert(position_first < walk.input.len);

            var position = position_first;

            state: switch (State.value) {
                .value => {
                    const byte = walk.input[position];

                    if (byte == '"') {
                        try walk.string_push(position);

                        continue :state .after;
                    }

                    if (number_start_table[byte]) {
                        if (walk.array_inside()) {
                            const resumed = try walk.numbers_push(position);

                            position = resumed.position;
                            if (resumed.state == .value) continue :state .value;
                            continue :state .after;
                        }

                        try walk.number_push(position);

                        continue :state .after;
                    }

                    if (byte | 0x20 == '{') {
                        const opened = try walk.open(position);
                        if (opened == .after) continue :state .after;

                        position = try walk.next();
                        if (opened == .key) continue :state .key;
                        continue :state .value;
                    }

                    try walk.literal_push(position);

                    continue :state .after;
                },
                .key => {
                    position = try walk.key_step(position);

                    continue :state .value;
                },
                .after => {
                    if (walk.depth == 0) break :state;

                    const delimiter = try walk.next();
                    const byte = walk.input[delimiter];

                    if (byte == ',') {
                        position = try walk.next();
                        if (walk.object) continue :state .key;
                        continue :state .value;
                    }

                    if (byte != @as(u8, if (walk.object) '}' else ']')) return error.Declined;

                    try walk.close();

                    continue :state .after;
                },
            }
        }

        inline fn key_step(walk: *@This(), position: u32) Failure!u32 {
            assert(walk.depth > 0);
            if (std.debug.runtime_safety) assert(position < walk.input.len);

            try walk.key_push(position);

            const colon = try walk.next();
            if (walk.input[colon] != ':') return error.Declined;

            return walk.next();
        }

        inline fn array_inside(walk: *const @This()) bool {
            assert(walk.depth <= depth_max);
            assert(walk.count <= walk.items.len);

            if (walk.depth == 0) return false;
            return !walk.object;
        }

        inline fn number_push(walk: *@This(), position: u32) Failure!void {
            assert(walk.depth <= depth_max);
            if (std.debug.runtime_safety) assert(position < walk.input.len);

            try walk.push(try number.fused_of(walk.input, position, walk.context.integers));
        }

        inline fn numbers_push(walk: *@This(), start: u32) Failure!Resume {
            assert(walk.depth > 0);
            assert(!walk.object);
            if (std.debug.runtime_safety) assert(start < walk.input.len);

            var position = start;

            for (0..walk.input.len) |_| {
                try walk.number_push(position);

                const delimiter = try walk.next();
                const byte = walk.input[delimiter];

                if (byte != ',') {
                    if (byte != ']') return error.Declined;

                    try walk.close();

                    return .{ .position = delimiter, .state = .after };
                }

                position = try walk.next();

                if (!number_start_table[walk.input[position]]) {
                    return .{ .position = position, .state = .value };
                }
            }

            return error.Declined;
        }

        inline fn open(walk: *@This(), position: u32) Failure!State {
            assert(position < walk.input.len);
            assert(walk.input[position] | 0x20 == '{');

            if (walk.depth == depth_max) return error.Declined;

            const object = walk.input[position] == '{';

            walk.context.frames[walk.depth] = .{ .mark = @intCast(walk.count), .object = object };
            walk.depth += 1;
            walk.object = object;

            const entry = walk.cursor.peek_or_end(walk.input);
            if (walk.cursor.failed) return error.Declined;

            const following = entry & structural.index_position_mask;
            if (following == walk.input.len) return error.Declined;
            if (walk.input[following] != @as(u8, if (object) '}' else ']')) {
                return if (object) .key else .value;
            }

            _ = try walk.next();

            try walk.close();

            return .after;
        }

        inline fn close(walk: *@This()) Failure!void {
            assert(walk.depth > 0);
            assert(walk.depth <= depth_max);

            walk.depth -= 1;

            const frame = walk.context.frames[walk.depth];
            const members = walk.items[frame.mark..walk.count];
            const container = try fast.container_build(frame.object, members);

            walk.count = frame.mark;
            walk.object = if (walk.depth == 0)
                false
            else
                walk.context.frames[walk.depth - 1].object;

            try walk.push(container);
        }
    };
}

const number_start_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for ("-0123456789") |byte| table[byte] = true;

    break :table table;
};

fn key_cached(input: [:0]const u8, text: []const u8, offset: u64) bool {
    assert(input.len <= json.limits.input_bytes_max);
    assert(text.len <= input.len + structural.lane_count);

    if (text.len > keys.cached_bytes_max) return false;
    return offset < input.len;
}

pub fn loads(
    comptime renamed: bool,
    input: [:0]const u8,
    policy: if (renamed) *const Policy else void,
) Failure!lacuna.Reference {
    assert(input.len <= json.limits.input_bytes_max);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    var cache: keys.CacheType(if (renamed) .renamed else .plain) = undefined;
    var integer_cache: integers.Cache = undefined;

    cache.policy = policy;
    cache.reset();
    defer cache.deinit();

    integer_cache.reset();
    defer integer_cache.deinit();

    const singletons = objects.Singletons.init() orelse return error.PythonError;
    defer singletons.deinit();

    var context: ContextType(renamed) = .{
        .buffer = null,
        .count = 0,
        .frames = undefined,
        .input = input,
        .integers = &integer_cache,
        .keys = &cache,
        .scratch = null,
        .singletons = &singletons,
    };

    defer if (context.scratch) |scratch| c.Py_DecRef(scratch);
    defer if (context.buffer) |buffer| c.Py_DecRef(buffer);

    var indexer: structural.Indexer = .empty;
    var indices: structural.Indices = undefined;
    var items_inline: [items_inline_count]*PyObject = undefined;

    const cursor: structural.Cursor = .{
        .count = 0,
        .exhausted = false,
        .failed = false,
        .indexer = &indexer,
        .indices = &indices,
        .position = 0,
    };

    const result = try walk_run(renamed, &context, cursor, &items_inline);

    return .{ .pointer = result };
}

fn walk_run(
    comptime renamed: bool,
    context: *ContextType(renamed),
    cursor: structural.Cursor,
    items: []*PyObject,
) Failure!*PyObject {
    assert(context.count == 0);
    assert(items.len == items_inline_count);

    var walk: WalkType(renamed) = .{
        .context = context,
        .count = 0,
        .cursor = cursor,
        .depth = 0,
        .input = context.input,
        .items = items,
        .object = false,
    };

    errdefer for (walk.items[0..walk.count]) |item| c.Py_DecRef(item);

    try walk.states(try walk.next());

    try walk_finish(walk.cursor, walk.input);

    assert(walk.count == 1);
    assert(walk.depth == 0);

    return walk.items[0];
}

fn walk_finish(cursor_final: structural.Cursor, input: [:0]const u8) Failure!void {
    assert(cursor_final.position <= cursor_final.count);
    assert(input.len <= json.limits.input_bytes_max);

    var cursor = cursor_final;

    if (cursor.next(input) != null) return error.Declined;
    if (cursor.failed) return error.Declined;
    if (!cursor.exhausted) return error.Declined;
}
