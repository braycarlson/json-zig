const std = @import("std");

const json = @import("json");
const lacuna = @import("lacuna");

const indexed = @import("indexed.zig");
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

pub const Failure = error{Declined} || lacuna.PythonError;

const blank_share_min: u32 = 2;
const blank_share_scale: u32 = 5;
const chunk_bytes: u32 = 16;
const depth_max = json.limits.depth_max;
const items_inline_count: u32 = 2048;
const lane_count: u32 = structural.lane_count;
const probe_bytes_max: u32 = 4096;

const Chunk = @Vector(chunk_bytes, u8);
const Lanes = @Vector(lane_count, u8);
const LaneMask = @Int(.unsigned, lane_count);

comptime {
    assert(depth_max <= std.math.maxInt(u8));
    assert(std.math.isPowerOfTwo(items_inline_count));
    assert(lane_count == 16 or lane_count == 32);
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

const Span = struct {
    close: u32,
    open: u32,
};

const Quoted = struct {
    close: u32,
    escaped: bool,
    high: bool,
};

fn ContextType(comptime renamed: bool) type {
    return struct {
        buffer: ?*PyObject,
        frames: [depth_max]Frame,
        input: [:0]const u8,
        integers: *integers.Cache,
        keys: *keys.CacheType(if (renamed) .renamed else .plain),
        scratch: ?*PyObject,
        singletons: *const objects.Singletons,

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

        noinline fn escaped_of(context: *@This(), span: Span) Failure![]const u8 {
            assert(span.open < span.close);
            assert(span.close < context.input.len);

            const open = span.open;
            const close = span.close;

            const size = context.input.len + lane_count;

            if (context.scratch == null) {
                context.scratch = c.PyBytes_FromStringAndSize(null, @intCast(size)) orelse {
                    return error.PythonError;
                };
            }

            const target = c.PyBytes_AsString(context.scratch.?).?[0..size];
            const window = context.input[open + 1 ..];
            const length = close - open - 1;
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
        depth: u32,
        input: [:0]const u8,
        items: []*PyObject,
        object: bool,
        position: u32,

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

        inline fn blank_skip(walk: *@This()) void {
            assert(walk.position <= walk.input.len);
            assert(walk.input[walk.input.len] == 0);

            const first = walk.input[walk.position];
            if (!blank_table[first]) return;

            const second = walk.input[walk.position + 1];

            if (second > ' ') {
                walk.position += 1;

                return;
            }

            if (first == '\n') {
                if (second == ' ') {
                    if (indent_end(walk.input, walk.position + 1)) |end| {
                        walk.position = end;

                        return;
                    }
                }
            }

            walk.position = blank_run_end(walk.input, walk.position);
        }

        inline fn states(walk: *@This()) Failure!void {
            assert(walk.depth == 0);
            assert(walk.count == 0);

            state: switch (State.value) {
                .value => {
                    walk.blank_skip();

                    const byte = walk.input[walk.position];

                    if (byte == '"') {
                        try walk.string_push();

                        continue :state .after;
                    }

                    if (number_start_table[byte]) {
                        if (walk.array_inside()) {
                            if (try walk.numbers_push() == .value) continue :state .value;
                            continue :state .after;
                        }

                        try walk.number_push();

                        continue :state .after;
                    }

                    if (byte | 0x20 == '{') {
                        continue :state try walk.container_open();
                    }

                    try walk.literal_push();

                    continue :state .after;
                },
                .key => {
                    walk.blank_skip();

                    try walk.key_push();

                    walk.blank_skip();
                    if (walk.input[walk.position] != ':') return error.Declined;
                    walk.position += 1;

                    continue :state .value;
                },
                .after => {
                    if (walk.depth == 0) break :state;

                    walk.blank_skip();

                    const byte = walk.input[walk.position];

                    walk.position += 1;

                    if (byte == ',') {
                        if (walk.object) continue :state .key;
                        continue :state .value;
                    }

                    if (byte != @as(u8, if (walk.object) '}' else ']')) return error.Declined;

                    try walk.close();

                    continue :state .after;
                },
            }
        }

        inline fn array_inside(walk: *const @This()) bool {
            assert(walk.depth <= depth_max);
            assert(walk.count <= walk.items.len);

            if (walk.depth == 0) return false;
            return !walk.object;
        }

        inline fn number_push(walk: *@This()) Failure!void {
            assert(walk.position < walk.input.len);
            assert(walk.depth <= depth_max);

            const parsed = try number.parsed_of(walk.input, walk.position, walk.context.integers);

            walk.position = parsed.end;

            try walk.push(parsed.object);
        }

        inline fn numbers_push(walk: *@This()) Failure!State {
            assert(walk.depth > 0);
            assert(!walk.object);

            for (0..walk.input.len) |_| {
                try walk.number_push();

                if (walk.input[walk.position] != ',') walk.blank_skip();

                const byte = walk.input[walk.position];

                walk.position += 1;

                if (byte != ',') {
                    if (byte != ']') return error.Declined;

                    try walk.close();

                    return .after;
                }

                const next = walk.input[walk.position];

                if (!number_start_table[next]) {
                    if (next != ' ') return .value;

                    walk.position += 1;

                    if (!number_start_table[walk.input[walk.position]]) return .value;
                }
            }

            return error.Declined;
        }

        inline fn string_push(walk: *@This()) Failure!void {
            assert(walk.input[walk.position] == '"');
            assert(walk.depth <= depth_max);

            const open = walk.position;
            const quoted = quoted_scan(walk.input, open) orelse return error.Declined;

            walk.position = quoted.close + 1;

            const object = try walk.string_object(open, quoted);

            try walk.push(object);
        }

        inline fn string_object(walk: *@This(), open: u32, quoted: Quoted) Failure!*PyObject {
            assert(open < quoted.close);
            assert(walk.input[quoted.close] == '"');

            const raw = walk.input[open + 1 .. quoted.close];

            if (!quoted.escaped) {
                if (!quoted.high) return objects.ascii_object(raw) orelse error.PythonError;
                if (!structural.utf8_valid(raw)) return error.Declined;

                return objects.text_object(raw) orelse error.PythonError;
            }

            if (quoted.high) {
                if (!structural.utf8_valid(raw)) return error.Declined;
            }

            const text = try walk.context.escaped_of(.{ .close = quoted.close, .open = open });

            return objects.text_object(text) orelse error.PythonError;
        }

        inline fn key_push(walk: *@This()) Failure!void {
            assert(walk.depth > 0);
            assert(walk.object);

            const open = walk.position;
            if (walk.input[open] != '"') return error.Declined;

            const quoted = quoted_scan(walk.input, open) orelse return error.Declined;
            const raw = walk.input[open + 1 .. quoted.close];

            walk.position = quoted.close + 1;

            if (quoted.high) {
                if (!structural.utf8_valid(raw)) return error.Declined;
            }

            if (!quoted.escaped) {
                if (raw.len <= keys.cached_bytes_max) return walk.key_cached_push(raw);
            }

            const text = if (quoted.escaped)
                try walk.context.escaped_of(.{ .close = quoted.close, .open = open })
            else
                raw;

            const object = if (renamed)
                walk.context.keys.policy.renamed(text) orelse return error.PythonError
            else
                objects.text_object(text) orelse return error.PythonError;

            try walk.push(object);
        }

        inline fn key_cached_push(walk: *@This(), raw: []const u8) Failure!void {
            assert(raw.len <= keys.cached_bytes_max);
            assert(@intFromPtr(raw.ptr) > @intFromPtr(walk.input.ptr));

            const offset = @intFromPtr(raw.ptr) - @intFromPtr(walk.input.ptr);
            const window: keys.Window = .{
                .length = @intCast(raw.len),
                .reach = walk.input[offset..],
            };

            const found = walk.context.keys.object_of(window, {});
            const cached = found orelse return error.PythonError;

            objects.acquire(cached);

            try walk.push(cached);
        }

        inline fn literal_push(walk: *@This()) Failure!void {
            assert(walk.position <= walk.input.len);
            assert(walk.depth <= depth_max);

            const singletons = walk.context.singletons;
            const rest = walk.input[walk.position..];
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

            const end = walk.position + length;
            if (!structural.scalar_ended(walk.input, end)) return error.Declined;

            walk.position = end;

            try walk.push(singletons.acquire(object));
        }

        inline fn container_open(walk: *@This()) Failure!State {
            assert(walk.position < walk.input.len);
            assert(walk.input[walk.position] | 0x20 == '{');

            if (walk.depth == depth_max) return error.Declined;

            const object = walk.input[walk.position] == '{';

            walk.context.frames[walk.depth] = .{ .mark = @intCast(walk.count), .object = object };
            walk.depth += 1;
            walk.object = object;
            walk.position += 1;
            walk.blank_skip();

            if (walk.input[walk.position] != @as(u8, if (object) '}' else ']')) {
                return if (object) .key else .value;
            }

            walk.position += 1;

            try walk.close();

            return .after;
        }

        inline fn close(walk: *@This()) Failure!void {
            assert(walk.depth > 0);
            assert(walk.depth <= depth_max);

            walk.depth -= 1;

            const frame = walk.context.frames[walk.depth];
            const members = walk.items[frame.mark..walk.count];
            const container = try container_build(frame.object, members);

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

const string_stop_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (0..0x20) |byte| table[byte] = true;

    table['"'] = true;
    table['\\'] = true;

    break :table table;
};

const blank_table: [256]bool = table: {
    var table: [256]bool = @splat(false);

    for (" \t\n\r") |byte| table[byte] = true;

    break :table table;
};

inline fn indent_end(input: [:0]const u8, start: u32) ?u32 {
    assert(start < input.len);
    assert(input[start] == ' ');

    if (input.len - start < lane_count) return null;

    const chunk: Lanes = input[start..][0..lane_count].*;
    const spaces: LaneMask = @bitCast(chunk == @as(Lanes, @splat(' ')));
    const solid = ~spaces;
    if (solid == 0) return null;

    const end = start + @ctz(solid);
    if (input[end] <= ' ') return null;

    assert(end > start);

    return end;
}

fn blank_run_end(input: [:0]const u8, start: u32) u32 {
    assert(start < input.len);
    assert(blank_table[input[start]]);

    var position = start;

    for (0..input.len) |_| {
        if (input.len - position < lane_count) break;

        const chunk: Lanes = input[position..][0..lane_count].*;
        const space: LaneMask = @bitCast(chunk == @as(Lanes, @splat(' ')));
        const newline: LaneMask = @bitCast(chunk == @as(Lanes, @splat('\n')));
        const tab: LaneMask = @bitCast(chunk == @as(Lanes, @splat('\t')));
        const carriage: LaneMask = @bitCast(chunk == @as(Lanes, @splat('\r')));
        const solid = ~(space | newline | tab | carriage);

        if (solid != 0) {
            const result = position + @ctz(solid);

            assert(!blank_table[input[result]]);

            return result;
        }

        position += lane_count;
    }

    for (0..lane_count) |_| {
        if (!blank_table[input[position]]) break;

        position += 1;
    }

    assert(position <= input.len);
    assert(!blank_table[input[position]]);

    return position;
}

inline fn quoted_scan(input: [:0]const u8, open: u32) ?Quoted {
    assert(open < input.len);
    assert(input[open] == '"');

    var index = open + 1;
    var escaped = false;
    var high: LaneMask = 0;

    for (0..input.len) |_| {
        if (input.len - index < lane_count) {
            const byte = input[index];

            if (!string_stop_table[byte]) {
                high |= @intFromBool(byte >= 0x80);
                index += 1;

                continue;
            }
        } else {
            const chunk: Lanes = input[index..][0..lane_count].*;
            const quote: LaneMask = @bitCast(chunk == @as(Lanes, @splat('"')));
            const backslash: LaneMask = @bitCast(chunk == @as(Lanes, @splat('\\')));
            const control: LaneMask = @bitCast(chunk < @as(Lanes, @splat(0x20)));
            const highs: LaneMask = @bitCast(chunk >= @as(Lanes, @splat(0x80)));
            const stops = quote | backslash | control;

            if (stops == 0) {
                high |= highs;
                index += lane_count;

                continue;
            }

            const offset: u32 = @ctz(stops);

            high |= highs & ((@as(LaneMask, 1) << @intCast(offset)) -% 1);
            index += offset;
        }

        const stop = input[index];

        if (stop == '"') return .{ .close = index, .escaped = escaped, .high = high != 0 };
        if (stop != '\\') return null;
        if (input.len - index < 2) return null;

        escaped = true;
        index += 2;
    }

    return null;
}

pub noinline fn container_build(object: bool, members: []const *PyObject) Failure!*PyObject {
    assert(members.len <= std.math.maxInt(u32));
    if (object) assert(members.len % 2 == 0);

    if (object) return dictionary_build(members);

    const list = objects.list_new(@intCast(members.len)) orelse return error.PythonError;

    objects.list_fill(list, members);

    return list;
}

fn dictionary_build(items: []const *PyObject) Failure!*PyObject {
    assert(items.len % 2 == 0);
    assert(items.len <= std.math.maxInt(u32));

    const count: u32 = @intCast(@divExact(items.len, 2));
    const dictionary = objects.dictionary_new(count) orelse return error.PythonError;

    for (0..count) |pair| {
        const member: objects.Member = .{ .key = items[2 * pair], .value = items[2 * pair + 1] };

        if (!objects.dictionary_store(dictionary, member)) {
            c.Py_DecRef(dictionary);

            return error.PythonError;
        }
    }

    for (items) |item| objects.release(item);

    return dictionary;
}

pub fn loads(
    comptime renamed: bool,
    input: [:0]const u8,
    policy: if (renamed) *const Policy else void,
) Failure!lacuna.Reference {
    assert(input.len <= json.limits.input_bytes_max);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);
    if (renamed) assert((policy.key_error != null) == (policy.rule == .mapping));

    if (root_object(input)) |object| {
        return .{ .pointer = object };
    } else |failure| switch (failure) {
        error.Declined => {},
        error.PythonError => return error.PythonError,
    }

    if (blank_heavy(input)) return indexed.loads(renamed, input, policy);

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
        .frames = undefined,
        .input = input,
        .integers = &integer_cache,
        .keys = &cache,
        .scratch = null,
        .singletons = &singletons,
    };

    defer if (context.scratch) |scratch| c.Py_DecRef(scratch);
    defer if (context.buffer) |buffer| c.Py_DecRef(buffer);

    var items_inline: [items_inline_count]*PyObject = undefined;

    const result = try walk_run(renamed, &context, &items_inline);

    return .{ .pointer = result };
}

fn walk_run(
    comptime renamed: bool,
    context: *ContextType(renamed),
    items: []*PyObject,
) Failure!*PyObject {
    assert(items.len == items_inline_count);
    assert(context.input.len <= json.limits.input_bytes_max);

    var walk: WalkType(renamed) = .{
        .context = context,
        .count = 0,
        .depth = 0,
        .input = context.input,
        .items = items,
        .object = false,
        .position = 0,
    };

    errdefer for (walk.items[0..walk.count]) |item| c.Py_DecRef(item);

    try walk.states();

    walk.blank_skip();
    if (walk.position != walk.input.len) return error.Declined;

    assert(walk.count == 1);
    assert(walk.depth == 0);

    return walk.items[0];
}

fn root_object(input: [:0]const u8) Failure!*PyObject {
    assert(input.len <= json.limits.input_bytes_max);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const start = blank_skip(input);
    if (start == input.len) return error.Declined;

    const byte = input[start];
    if (byte | 0x20 == '{') return error.Declined;

    const end = blank_trim(input, start);

    assert(start < end);

    if (byte == '"') return string_root(input[start..end]);
    if (number_start_table[byte]) return number.root_object(input, .{ .end = end, .start = start });

    return literal_root(input[start..end]);
}

fn blank_skip(input: []const u8) u32 {
    assert(input.len <= json.limits.input_bytes_max);

    const result: u32 = for (input, 0..) |byte, index| {
        if (!blank_table[byte]) break @intCast(index);
    } else @intCast(input.len);

    assert(result <= input.len);
    if (result < input.len) assert(!blank_table[input[result]]);

    return result;
}

fn blank_trim(input: []const u8, start: u32) u32 {
    assert(start < input.len);
    assert(!blank_table[input[start]]);

    var end: u32 = @intCast(input.len);

    for (start..input.len) |_| {
        if (!blank_table[input[end - 1]]) break;

        end -= 1;
    }

    assert(end > start);

    return end;
}

fn string_root(span: []const u8) Failure!*PyObject {
    assert(span.len > 0);
    assert(span[0] == '"');

    if (span.len < 2) return error.Declined;
    if (span[span.len - 1] != '"') return error.Declined;

    const text = span[1 .. span.len - 1];
    if (!plain_is(text)) return error.Declined;
    if (!std.unicode.utf8ValidateSlice(text)) return error.Declined;

    return objects.text_object(text) orelse error.PythonError;
}

fn plain_is(text: []const u8) bool {
    assert(text.len <= json.limits.input_bytes_max);
    assert(@sizeOf(Chunk) == chunk_bytes);

    var index: u64 = 0;

    while (index + chunk_bytes <= text.len) : (index += chunk_bytes) {
        const chunk: Chunk = text[index..][0..chunk_bytes].*;
        const quote: u16 = @bitCast(chunk == @as(Chunk, @splat('"')));
        const backslash: u16 = @bitCast(chunk == @as(Chunk, @splat('\\')));
        const control: u16 = @bitCast(chunk < @as(Chunk, @splat(0x20)));

        if (quote | backslash | control != 0) return false;
    }

    for (text[index..]) |byte| {
        if (byte == '"') return false;
        if (byte == '\\') return false;
        if (byte < 0x20) return false;
    }

    return true;
}

fn literal_root(text: []const u8) Failure!*PyObject {
    assert(text.len > 0);
    assert(text[0] != '"');

    if (std.mem.eql(u8, text, "null")) return c.Py_BuildValue("") orelse error.PythonError;
    if (std.mem.eql(u8, text, "true")) return c.PyBool_FromLong(1) orelse error.PythonError;
    if (std.mem.eql(u8, text, "false")) return c.PyBool_FromLong(0) orelse error.PythonError;

    return error.Declined;
}

fn blank_heavy(input: [:0]const u8) bool {
    assert(input.len <= json.limits.input_bytes_max);
    assert(probe_bytes_max % lane_count == 0);

    const probe_bytes: u32 = @intCast(@min(input.len, probe_bytes_max));
    const probe_end = @divFloor(probe_bytes, lane_count) * lane_count;

    var blanks: u32 = 0;
    var position: u32 = 0;

    while (position < probe_end) : (position += lane_count) {
        const chunk: Lanes = input[position..][0..lane_count].*;
        const space: LaneMask = @bitCast(chunk == @as(Lanes, @splat(' ')));
        const newline: LaneMask = @bitCast(chunk == @as(Lanes, @splat('\n')));

        blanks += @popCount(space | newline);
    }

    assert(blanks <= probe_end);

    return blanks * blank_share_scale > probe_end * blank_share_min;
}
