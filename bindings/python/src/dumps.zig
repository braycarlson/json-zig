const std = @import("std");

const lacuna = @import("lacuna");

const keys = @import("keys.zig");
const objects = @import("objects.zig");
const output_module = @import("output.zig");
const policy_module = @import("policy.zig");
const shortest = @import("shortest.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const Cursor = output_module.Cursor;
const Policy = policy_module.Policy;
const PyObject = c.PyObject;
const Renames = keys.CacheType(.held);

pub const Failure = error{ TypeError, ValueError } || lacuna.PythonError;

pub const Hooks = struct {
    default: ?*PyObject,
    policy: ?*const Policy,
};

pub const Problem = struct {
    failure: Failure,
    message: [:0]const u8,
};

const default_chain_max: u32 = 254;
const depth_max: u32 = 1024;
const float_run_count: u32 = 4;
const scalar_bytes_max: u32 = 64;
const step_count_max: u64 = std.math.maxInt(u64);

comptime {
    assert(scalar_bytes_max > output_module.float_text_max);
    assert(depth_max <= std.math.maxInt(u16));
}

const Kind = enum {
    boolean,
    dictionary,
    floating,
    integer,
    list,
    none,
    string,
    tuple,
    unsupported,
};

const Section = if (c.free_threaded) c.PyCriticalSection else struct {};

const Types = struct {
    boolean: *PyObject,
    dictionary: *PyObject,
    floating: *PyObject,
    integer: *PyObject,
    list: *PyObject,
    none: *PyObject,
    string: *PyObject,
    tuple: *PyObject,
    unknown: *PyObject,

    fn init(singletons: *const objects.Singletons) Types {
        assert(singletons.none != singletons.true_value);
        assert(objects.type_of(singletons.true_value) == objects.type_of(singletons.false_value));

        const unknown = singletons.none;

        return .{
            .boolean = objects.type_of(singletons.true_value),
            .dictionary = unknown,
            .floating = unknown,
            .integer = unknown,
            .list = unknown,
            .none = objects.type_of(singletons.none),
            .string = unknown,
            .tuple = unknown,
            .unknown = unknown,
        };
    }

    fn learn(types: *Types, kind: Kind, type_object: *PyObject) void {
        assert(type_object != types.unknown);
        assert(@intFromPtr(type_object) % @alignOf(*PyObject) == 0);

        const slot = switch (kind) {
            .dictionary => &types.dictionary,
            .floating => &types.floating,
            .integer => &types.integer,
            .list => &types.list,
            .string => &types.string,
            .tuple => &types.tuple,
            .boolean, .none, .unsupported => return,
        };

        if (slot.* == types.unknown) slot.* = type_object;
    }
};

const Members = union(enum) {
    general: []const c.PyDictKeyEntry,
    items: []const ?*PyObject,
    mapping,
    sequence: objects.Container,
    unicode: []const c.PyDictUnicodeEntry,
};

const Floats = struct {
    cursor: Cursor,
    index: u64,
};

const Frame = struct {
    closing: u8,
    container: *PyObject,
    count: u64,
    index: u64,
    members: Members,
};

const Slow = struct {
    cursor: Cursor,
    opened: bool,
};

fn EncoderType(comptime extended: bool) type {
    return struct {
        default: if (extended) ?*PyObject else void,
        depth: u32,
        frames: [depth_max + 1]Frame,
        output: output_module.Output,
        pairs_held: if (extended) bool else void,
        problem: ?Problem,
        renames: if (extended) ?*Renames else void,
        sections: [depth_max + 1]Section,
        singletons: objects.Singletons,
        types: Types,

        const Encoder = @This();

        const mutation_possible = extended or c.free_threaded;

        fn fail(encoder: *Encoder, failure: Failure, message: [:0]const u8) Failure {
            assert(message.len > 0);
            assert(failure != error.PythonError);
            assert(encoder.problem == null);

            encoder.problem = .{ .failure = failure, .message = message };

            return failure;
        }

        inline fn reserve(encoder: *Encoder, cursor: *Cursor, count: u64) Failure!void {
            assert(cursor.length <= cursor.bytes.len);
            assert(count <= std.math.maxInt(u40));

            if (cursor.free() >= count) return;

            cursor.bytes = try encoder.output.grow(.{ .extra = count, .used = cursor.length });
        }

        inline fn value_put(encoder: *Encoder, cursor: *Cursor, object: *PyObject) Failure!bool {
            assert(encoder.depth <= depth_max);
            assert(cursor.free() >= scalar_bytes_max);

            const types = &encoder.types;
            const type_object = objects.type_of(object);

            if (type_object == types.string) {
                try encoder.string_put(cursor, object);

                return false;
            }

            if (type_object == types.integer) {
                try encoder.integer_put(cursor, object);

                return false;
            }

            if (type_object == types.floating) {
                try encoder.float_put(cursor, object);

                return false;
            }

            if (type_object == types.list) return encoder.frame_open(cursor, object, .list);
            if (type_object == types.dictionary) {
                return encoder.frame_open(cursor, object, .dictionary);
            }

            if (type_object == types.none) {
                cursor.literal_put("null,");

                return false;
            }

            if (type_object == types.boolean) {
                encoder.boolean_put(cursor, object);

                return false;
            }

            if (extended) return encoder.value_extended(cursor, object);

            const slow = try encoder.value_slow(cursor.*, object);

            cursor.* = slow.cursor;

            return slow.opened;
        }

        noinline fn value_slow(
            encoder: *Encoder,
            cursor_initial: Cursor,
            object: *PyObject,
        ) Failure!Slow {
            assert(cursor_initial.free() >= scalar_bytes_max);
            assert(encoder.depth <= depth_max);

            const type_object = objects.type_of(object);
            const kind = try encoder.classify(type_object);

            encoder.types.learn(kind, type_object);

            var result: Slow = .{ .cursor = cursor_initial, .opened = false };

            switch (kind) {
                .boolean => encoder.boolean_put(&result.cursor, object),
                .dictionary => {
                    result.opened = try encoder.frame_open(&result.cursor, object, .dictionary);
                },
                .floating => try encoder.float_put(&result.cursor, object),
                .integer => try encoder.integer_put(&result.cursor, object),
                .list => {
                    result.opened = try encoder.frame_open(&result.cursor, object, .list);
                },
                .none => result.cursor.literal_put("null,"),
                .string => try encoder.string_put(&result.cursor, object),
                .tuple => {
                    result.opened = try encoder.frame_open(&result.cursor, object, .tuple);
                },
                .unsupported => {
                    return encoder.fail(error.TypeError, "the type is not JSON serializable");
                },
            }

            return result;
        }

        noinline fn value_extended(
            encoder: *Encoder,
            cursor: *Cursor,
            object: *PyObject,
        ) Failure!bool {
            comptime assert(extended);
            assert(cursor.free() >= scalar_bytes_max);

            const kind = try encoder.classify(objects.type_of(object));

            const resolved = if (kind == .unsupported)
                try encoder.default_resolve(object)
            else
                object;

            defer if (resolved != object) c.Py_DecRef(resolved);

            const slow = try encoder.value_slow(cursor.*, resolved);

            cursor.* = slow.cursor;

            return slow.opened;
        }

        fn default_resolve(encoder: *Encoder, object: *PyObject) Failure!*PyObject {
            comptime assert(extended);
            if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

            const default = encoder.default orelse {
                return encoder.fail(error.TypeError, "the type is not JSON serializable");
            };

            var current = object;

            for (0..default_chain_max) |step| {
                const result = c.PyObject_CallFunction(default, "O", current);

                if (step > 0) c.Py_DecRef(current);

                current = result orelse return error.PythonError;
                errdefer c.Py_DecRef(current);

                const kind = try encoder.classify(objects.type_of(current));
                if (kind != .unsupported) return current;
            }

            c.Py_DecRef(current);

            return encoder.fail(error.ValueError, "default nests too deep or returns a cycle");
        }

        fn classify(encoder: *const Encoder, type_object: *PyObject) lacuna.PythonError!Kind {
            assert(@intFromPtr(type_object) != 0);
            assert(type_object != encoder.types.unknown);

            if (type_object == encoder.types.none) return .none;
            if (type_object == encoder.types.boolean) return .boolean;

            const flags = c.PyType_GetFlags(type_object);

            if (flags & c.Py_TPFLAGS_UNICODE_SUBCLASS != 0) return .string;
            if (flags & c.Py_TPFLAGS_LONG_SUBCLASS != 0) return .integer;
            if (flags & c.Py_TPFLAGS_DICT_SUBCLASS != 0) return .dictionary;
            if (flags & c.Py_TPFLAGS_LIST_SUBCLASS != 0) return .list;
            if (flags & c.Py_TPFLAGS_TUPLE_SUBCLASS != 0) return .tuple;

            const floating = objects.floating_is(type_object) orelse return error.PythonError;
            if (floating) return .floating;
            return .unsupported;
        }

        inline fn boolean_put(encoder: *const Encoder, cursor: *Cursor, object: *PyObject) void {
            assert(objects.type_of(object) == encoder.types.boolean);
            assert(cursor.free() >= 8);

            if (object == encoder.singletons.true_value) {
                cursor.literal_put("true,");
            } else {
                cursor.literal_put("false,");
            }
        }

        inline fn string_put(encoder: *Encoder, cursor: *Cursor, object: *PyObject) Failure!void {
            assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
            assert(encoder.problem == null);

            const text = objects.text_of(object) orelse return error.PythonError;

            try encoder.reserve(cursor, output_module.text_bytes_max(text.len));

            cursor.text_put(text, ',');
        }

        inline fn key_put(encoder: *Encoder, cursor: *Cursor, key: *PyObject) Failure!void {
            assert(@intFromPtr(key) % @alignOf(*PyObject) == 0);
            assert(encoder.problem == null);

            if (extended) {
                if (encoder.renames) |renames| return encoder.key_renamed_put(cursor, key, renames);
            }

            return encoder.key_text_put(cursor, key);
        }

        noinline fn key_renamed_put(
            encoder: *Encoder,
            cursor: *Cursor,
            key: *PyObject,
            renames: *Renames,
        ) Failure!void {
            comptime assert(extended);
            assert(@intFromPtr(key) % @alignOf(*PyObject) == 0);

            const text = objects.text_of(key) orelse return error.PythonError;

            if (text.len > keys.cached_bytes_max) {
                const renamed = renames.policy.renamed(text) orelse return error.PythonError;
                defer c.Py_DecRef(renamed);

                return encoder.key_text_put(cursor, renamed);
            }

            const window: keys.Window = .{ .length = @intCast(text.len), .reach = text };
            const renamed = renames.object_of(window, key) orelse return error.PythonError;

            return encoder.key_text_put(cursor, renamed);
        }

        inline fn key_text_put(encoder: *Encoder, cursor: *Cursor, key: *PyObject) Failure!void {
            assert(@intFromPtr(key) % @alignOf(*PyObject) == 0);
            assert(encoder.problem == null);

            const text = objects.text_of(key) orelse return error.PythonError;
            const extra = output_module.text_bytes_max(text.len) + scalar_bytes_max;

            try encoder.reserve(cursor, extra);

            cursor.text_put(text, ':');
        }

        fn key_check(encoder: *Encoder, key: *PyObject) Failure!void {
            assert(@intFromPtr(key) % @alignOf(*PyObject) == 0);
            assert(encoder.problem == null);

            const type_object = objects.type_of(key);
            if (type_object == encoder.types.string) return;

            const kind = try encoder.classify(type_object);
            if (kind == .string) return;

            return encoder.fail(error.TypeError, "dict keys must be str");
        }

        inline fn integer_put(encoder: *Encoder, cursor: *Cursor, object: *PyObject) Failure!void {
            assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
            assert(cursor.free() >= scalar_bytes_max);

            if (objects.integer_compact(object)) |compact| return cursor.compact_put(compact);

            cursor.* = try encoder.integer_wide_put(cursor.*, object);
        }

        noinline fn integer_wide_put(
            encoder: *Encoder,
            cursor_initial: Cursor,
            object: *PyObject,
        ) Failure!Cursor {
            assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
            assert(cursor_initial.free() >= scalar_bytes_max);

            var cursor = cursor_initial;

            if (objects.integer_small(object)) |value| {
                cursor.integer_put(value < 0, @abs(value));

                return cursor;
            }

            if (integer_wide(object)) |value| {
                cursor.integer_put(value < 0, @abs(value));

                return cursor;
            } else |failure| switch (failure) {
                error.Overflow => {},
                error.PythonError => return error.PythonError,
            }

            const text = try integer_text(object);
            defer c.Py_DecRef(text);

            var length: c.Py_ssize_t = 0;
            const digits = c.PyUnicode_AsUTF8AndSize(text, &length) orelse return error.PythonError;
            const count: u64 = @intCast(length);

            try encoder.reserve(&cursor, count + 1);

            cursor.put(digits[0..count]);
            cursor.byte_put(',');

            return cursor;
        }

        inline fn floats_run(
            encoder: *Encoder,
            cursor_initial: Cursor,
            items: []const ?*PyObject,
            start: u64,
        ) Failure!Floats {
            assert(start < items.len);
            assert(objects.type_of(items[start].?) == encoder.types.floating);

            var cursor = cursor_initial;
            var index = start;

            for (0..items.len - start) |_| {
                if (index == items.len) break;

                const first = items[index].?;
                if (objects.type_of(first) != encoder.types.floating) break;

                try encoder.reserve(&cursor, float_run_count * scalar_bytes_max);

                if (index + float_run_count <= items.len) {
                    const group = items[index..][0..float_run_count];

                    if (encoder.float_group_put(&cursor, float_run_count, group)) {
                        index += float_run_count;

                        continue;
                    }
                }

                if (index + 2 <= items.len) {
                    if (encoder.float_group_put(&cursor, 2, items[index..][0..2])) {
                        index += 2;

                        continue;
                    }
                }

                try encoder.float_put(&cursor, first);

                index += 1;
            }

            assert(index > start);

            return .{ .cursor = cursor, .index = index };
        }

        inline fn float_group_put(
            encoder: *Encoder,
            cursor: *Cursor,
            comptime count: u32,
            group: *const [count]?*PyObject,
        ) bool {
            assert(objects.type_of(group[0].?) == encoder.types.floating);
            assert(cursor.free() >= count * scalar_bytes_max);

            var values: [count]u64 = undefined;

            inline for (group, &values) |item, *bits| {
                if (objects.type_of(item.?) != encoder.types.floating) return false;

                bits.* = objects.float_bits(item.?);
                if (!shortest.regular_is(bits.*)) return false;
            }

            cursor.regular_run_put(count, values);

            return true;
        }

        inline fn float_put(encoder: *Encoder, cursor: *Cursor, object: *PyObject) Failure!void {
            assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
            assert(cursor.free() >= scalar_bytes_max);

            const bits = objects.float_bits(object);
            if (shortest.regular_is(bits)) return cursor.regular_put(bits);

            cursor.* = try encoder.float_special_put(cursor.*, bits);
        }

        noinline fn float_special_put(
            encoder: *Encoder,
            cursor_initial: Cursor,
            bits: u64,
        ) Failure!Cursor {
            assert(cursor_initial.free() >= scalar_bytes_max);
            assert(!shortest.regular_is(bits));
            if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

            const value: f64 = @bitCast(bits);

            if (!std.math.isFinite(value)) {
                return encoder.fail(error.ValueError, "a non-finite float cannot be written");
            }

            var cursor = cursor_initial;

            cursor.float_put(value);

            return cursor;
        }

        inline fn frame_open(
            encoder: *Encoder,
            cursor: *Cursor,
            container: *PyObject,
            comptime shape: objects.Container,
        ) Failure!bool {
            assert(cursor.free() >= scalar_bytes_max);
            assert(encoder.depth <= depth_max);
            if (std.debug.runtime_safety) assert(objects.shape_matches(container, shape));

            const depth = encoder.depth;
            const section = &encoder.sections[depth];

            section_begin(section, container);

            const count = objects.container_length(container, shape);

            if (count == 0) {
                section_end(section);

                if (shape == .dictionary) cursor.literal_put("{},") else cursor.literal_put("[],");

                return false;
            }

            if (depth == depth_max) {
                section_end(section);

                const message = "the object nests too deep or contains a cycle";

                return encoder.fail(error.ValueError, message);
            }

            if (extended) {
                encoder.frames[depth + 1] = frame_guarded_of(container, shape, count);
                c.Py_IncRef(container);
            } else {
                encoder.frames[depth + 1] = frame_of(container, shape, count);
            }

            cursor.byte_put(if (shape == .dictionary) '{' else '[');

            return true;
        }

        inline fn items_run(encoder: *Encoder, cursor: *Cursor) Failure!bool {
            assert(encoder.frames[encoder.depth].members == .items);
            assert(encoder.depth <= depth_max);

            var frame = &encoder.frames[encoder.depth];
            var items = frame.members.items;
            var index = frame.index;

            for (0..step_count_max) |_| {
                if (index == items.len) {
                    if (encoder.depth == 0) return true;

                    try encoder.frame_close(cursor, frame);

                    frame = &encoder.frames[encoder.depth];
                    if (frame.members != .items) return false;

                    items = frame.members.items;
                    index = frame.index;

                    continue;
                }

                try encoder.reserve(cursor, scalar_bytes_max);

                const item = items[index].?;

                if (objects.type_of(item) == encoder.types.floating) {
                    const floats = try encoder.floats_run(cursor.*, items, index);

                    cursor.* = floats.cursor;
                    index = floats.index;

                    continue;
                }

                index += 1;

                if (try encoder.value_put(cursor, item)) {
                    frame.index = index;
                    encoder.depth += 1;
                    frame = &encoder.frames[encoder.depth];
                    if (frame.members != .items) return false;

                    items = frame.members.items;
                    index = 0;
                }
            }

            return true;
        }

        inline fn entries_run(
            encoder: *Encoder,
            comptime Entry: type,
            cursor: *Cursor,
        ) Failure!bool {
            assert(encoder.depth > 0);
            assert(encoder.depth <= depth_max);

            var frame = &encoder.frames[encoder.depth];
            var entries = entries_of(Entry, frame).?;
            var index = frame.index;

            for (0..step_count_max) |_| {
                if (index == entries.len) {
                    try encoder.frame_close(cursor, frame);

                    frame = &encoder.frames[encoder.depth];
                    entries = entries_of(Entry, frame) orelse return false;
                    index = frame.index;

                    continue;
                }

                const entry = entries[index];

                index += 1;

                const value = entry.me_value orelse continue;
                const key = entry.me_key.?;

                if (Entry == c.PyDictKeyEntry) try encoder.key_check(key);

                try encoder.key_put(cursor, key);

                if (try encoder.value_put(cursor, value)) {
                    frame.index = index;
                    encoder.depth += 1;
                    frame = &encoder.frames[encoder.depth];
                    entries = entries_of(Entry, frame) orelse return false;
                    index = 0;
                }
            }

            return true;
        }

        inline fn frame_close(
            encoder: *Encoder,
            cursor: *Cursor,
            frame: *const Frame,
        ) Failure!void {
            assert(encoder.depth > 0);
            assert(frame.closing != 0);

            try encoder.reserve(cursor, 2);

            cursor.close(frame.closing);
            encoder.depth -= 1;
            section_end(&encoder.sections[encoder.depth]);

            if (extended) c.Py_DecRef(frame.container);
        }

        inline fn mapping_put(encoder: *Encoder, cursor: *Cursor, frame: *Frame) Failure!bool {
            assert(frame.members == .mapping);
            assert(frame.count > 0);

            const held = if (extended) encoder.pairs_held else false;

            for (0..if (extended) step_count_max else frame.count + 1) |_| {
                var position: c.Py_ssize_t = @intCast(frame.index);
                var key: ?*PyObject = null;
                var value: ?*PyObject = null;

                const found = c.PyDict_Next(frame.container, &position, &key, &value) != 0;

                frame.index = @intCast(position);
                if (!found) break;

                if (held) {
                    c.Py_IncRef(key.?);
                    c.Py_IncRef(value.?);
                }

                defer if (held) {
                    c.Py_DecRef(key.?);
                    c.Py_DecRef(value.?);
                };

                try encoder.key_check(key.?);
                try encoder.key_put(cursor, key.?);

                if (try encoder.value_put(cursor, value.?)) return true;
            }

            return false;
        }

        inline fn sequence_put(
            encoder: *Encoder,
            cursor: *Cursor,
            frame: *Frame,
            shape: objects.Container,
        ) Failure!bool {
            assert(shape != .dictionary);
            if (!extended) assert(frame.index <= frame.count);

            for (frame.index..if (extended) step_count_max else frame.count) |index| {
                if (mutation_possible) {
                    if (index >= objects.container_length(frame.container, shape)) break;
                }

                try encoder.reserve(cursor, scalar_bytes_max);

                const item = objects.item_of(frame.container, index, shape);

                if (try encoder.value_put(cursor, item)) {
                    frame.index = index + 1;

                    return true;
                }
            }

            frame.index = frame.count;

            return false;
        }

        inline fn mapping_run(encoder: *Encoder, cursor: *Cursor) Failure!bool {
            assert(encoder.depth > 0);
            assert(encoder.frames[encoder.depth].members == .mapping);

            const frame = &encoder.frames[encoder.depth];

            if (try encoder.mapping_put(cursor, frame)) {
                encoder.depth += 1;

                return false;
            }

            try encoder.frame_close(cursor, frame);

            return false;
        }

        inline fn sequence_run(
            encoder: *Encoder,
            cursor: *Cursor,
            shape: objects.Container,
        ) Failure!bool {
            assert(encoder.depth > 0);
            assert(encoder.frames[encoder.depth].members == .sequence);
            assert(encoder.frames[encoder.depth].members.sequence == shape);

            const frame = &encoder.frames[encoder.depth];

            if (try encoder.sequence_put(cursor, frame, shape)) {
                encoder.depth += 1;

                return false;
            }

            try encoder.frame_close(cursor, frame);

            return false;
        }

        fn run(encoder: *Encoder, root: *PyObject) Failure!u64 {
            assert(encoder.depth == 0);
            assert(encoder.problem == null);

            const roots = [1]?*PyObject{root};

            var cursor: Cursor = .{ .bytes = encoder.output.bytes(), .length = 0 };

            encoder.frames[0] = .{
                .closing = 0,
                .container = root,
                .count = 1,
                .index = 0,
                .members = .{ .items = &roots },
            };

            errdefer if (extended) encoder.frames_release();
            errdefer encoder.sections_end();

            for (0..step_count_max) |_| {
                const finished = switch (encoder.frames[encoder.depth].members) {
                    .general => try encoder.entries_run(c.PyDictKeyEntry, &cursor),
                    .items => try encoder.items_run(&cursor),
                    .mapping => try encoder.mapping_run(&cursor),
                    .sequence => |shape| try encoder.sequence_run(&cursor, shape),
                    .unicode => try encoder.entries_run(c.PyDictUnicodeEntry, &cursor),
                };

                if (finished) break;
            }

            assert(encoder.depth == 0);
            assert(cursor.length > 0);

            return cursor.length - 1;
        }

        fn frames_release(encoder: *Encoder) void {
            comptime assert(extended);
            assert(encoder.depth <= depth_max);

            for (1..encoder.depth + 1) |depth| c.Py_DecRef(encoder.frames[depth].container);
        }

        fn hooks_attach(encoder: *Encoder, hooks: *const Hooks, renames: *Renames) void {
            comptime assert(extended);
            assert(encoder.depth == 0);

            encoder.default = hooks.default;
            encoder.pairs_held = false;
            encoder.renames = null;

            if (hooks.policy) |policy| {
                encoder.pairs_held = policy.rule != .style;
                renames.policy = policy;
                renames.reset();
                encoder.renames = renames;
            }
        }

        fn hooks_detach(encoder: *Encoder) void {
            comptime assert(extended);
            assert(encoder.depth <= depth_max);

            const renames = encoder.renames orelse return;

            assert(@intFromPtr(renames.policy) % @alignOf(Policy) == 0);

            renames.deinit();
        }

        fn sections_end(encoder: *Encoder) void {
            assert(encoder.depth <= depth_max);
            assert(encoder.sections.len == depth_max + 1);

            for (0..encoder.depth) |offset| {
                section_end(&encoder.sections[encoder.depth - 1 - offset]);
            }
        }
    };
}

fn entries_of(comptime Entry: type, frame: *const Frame) ?[]const Entry {
    comptime assert(Entry == c.PyDictKeyEntry or Entry == c.PyDictUnicodeEntry);
    assert(frame.index <= frame.count or frame.members == .mapping);

    return switch (frame.members) {
        .general => |entries| if (Entry == c.PyDictKeyEntry) entries else null,
        .items, .mapping, .sequence => null,
        .unicode => |entries| if (Entry == c.PyDictUnicodeEntry) entries else null,
    };
}

fn frame_of(container: *PyObject, shape: objects.Container, length: u64) Frame {
    assert(length > 0);
    assert(@intFromPtr(container) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(objects.container_length(container, shape) == length);

    const members: Members = switch (shape) {
        .dictionary => if (objects.entries_of(container)) |entries| switch (entries) {
            .general => |slice| .{ .general = slice },
            .unicode => |slice| .{ .unicode = slice },
        } else .mapping,
        .list => if (objects.versioned) .{ .items = objects.list_items(container) } else .{
            .sequence = .list,
        },
        .tuple => .{ .sequence = .tuple },
    };

    const count = switch (members) {
        .general => |entries| entries.len,
        .items => |items| items.len,
        .mapping, .sequence => length,
        .unicode => |entries| entries.len,
    };

    assert(count >= length);

    return .{
        .closing = if (shape == .dictionary) '}' else ']',
        .container = container,
        .count = count,
        .index = 0,
        .members = members,
    };
}

fn frame_guarded_of(container: *PyObject, shape: objects.Container, length: u64) Frame {
    assert(length > 0);
    assert(@intFromPtr(container) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(objects.container_length(container, shape) == length);

    const members: Members = switch (shape) {
        .dictionary => .mapping,
        .list => .{ .sequence = .list },
        .tuple => .{ .sequence = .tuple },
    };

    return .{
        .closing = if (shape == .dictionary) '}' else ']',
        .container = container,
        .count = length,
        .index = 0,
        .members = members,
    };
}

fn section_begin(section: *Section, container: *PyObject) void {
    assert(@intFromPtr(container) % @alignOf(*PyObject) == 0);
    assert(@intFromPtr(section) % @alignOf(Section) == 0);

    if (c.free_threaded) c.PyCriticalSection_Begin(section, container);
}

fn section_end(section: *Section) void {
    assert(@intFromPtr(section) % @alignOf(Section) == 0);
    assert(@sizeOf(Section) == 0 or c.free_threaded);

    if (c.free_threaded) c.PyCriticalSection_End(section);
}

noinline fn integer_wide(object: *PyObject) (lacuna.PythonError || error{Overflow})!i64 {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    var overflow: c_int = 0;
    const value = c.PyLong_AsLongLongAndOverflow(object, &overflow);
    if (overflow != 0) return error.Overflow;
    if (value == -1) if (c.PyErr_Occurred() != null) return error.PythonError;
    return value;
}

noinline fn integer_text(object: *PyObject) Failure!*PyObject {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const exact = c.PyNumber_Index(object) orelse return error.PythonError;
    defer c.Py_DecRef(exact);

    return c.PyObject_Str(exact) orelse error.PythonError;
}

pub fn dumps(
    comptime extended: bool,
    value: *PyObject,
    hooks: if (extended) *const Hooks else void,
    problem: *?Problem,
) Failure!lacuna.Reference {
    assert(@intFromPtr(value) % @alignOf(*PyObject) == 0);
    assert(problem.* == null);
    if (extended) assert(hooks.default != null or hooks.policy != null);

    const singletons = objects.Singletons.init() orelse return error.PythonError;
    defer singletons.deinit();

    var encoder: EncoderType(extended) = undefined;

    encoder.depth = 0;
    encoder.output.capacity = output_module.stack_bytes;
    encoder.output.object = null;
    encoder.problem = null;
    encoder.singletons = singletons;
    encoder.types = .init(&singletons);

    var renames: if (extended) Renames else void = undefined;

    if (extended) encoder.hooks_attach(hooks, &renames);
    defer if (extended) encoder.hooks_detach();

    errdefer encoder.output.deinit();
    errdefer problem.* = encoder.problem;

    const length = try encoder.run(value);
    const result = encoder.output.finish(length) orelse return error.PythonError;

    return .{ .pointer = result };
}
