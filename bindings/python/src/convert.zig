const std = @import("std");

const json = @import("json");
const lacuna = @import("lacuna");

const keys = @import("keys.zig");
const number = @import("number.zig");
const objects = @import("objects.zig");
const policy_module = @import("policy.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const Policy = policy_module.Policy;
const PyObject = c.PyObject;
const Record = @typeInfo(@FieldType(json.Storage, "records")).pointer.child;

pub const Error = lacuna.PythonError;

const depth_max = json.limits.depth_max;

comptime {
    assert(depth_max <= std.math.maxInt(u8));
    assert(@sizeOf(Record) == 16);
}

const Frame = struct {
    container: *PyObject,
    index: u32,
    object: bool,
    remaining: u32,
};

const Owned = struct {
    object: *PyObject,
    owned: bool,
};

fn BuilderType(comptime renamed: bool) type {
    return struct {
        depth: u32,
        document: *const json.Document,
        frames: [depth_max]Frame,
        keys: keys.CacheType(if (renamed) .renamed else .plain),
        root: ?*PyObject,
        singletons: objects.Singletons,

        fn deinit(builder: *@This()) void {
            assert(builder.depth <= depth_max);
            assert(builder.document.node_count > 0);

            builder.keys.deinit();

            if (builder.root) |root| c.Py_DecRef(root);

            builder.singletons.deinit();
        }

        fn top(builder: *@This()) *Frame {
            assert(builder.depth > 0);
            assert(builder.depth <= depth_max);

            return &builder.frames[builder.depth - 1];
        }

        fn push(builder: *@This(), record: *const Record, container: *PyObject) void {
            assert(builder.depth < depth_max);
            assert(record.size > 0);

            builder.frames[builder.depth] = .{
                .container = container,
                .index = 0,
                .object = record.kind() == .object,
                .remaining = record.size,
            };

            builder.depth += 1;
        }

        fn value_of(builder: *@This(), record: *const Record) Error!*PyObject {
            assert(record.start < record.end);
            assert(record.end <= builder.document.source.len);

            const source = builder.document.source;
            const singletons = &builder.singletons;

            const result = switch (record.kind()) {
                .array => objects.list_new(record.size),
                .false_value => singletons.acquire(singletons.false_value),
                .null_value => singletons.acquire(singletons.none),
                .number => return number.object_of(.{
                    .length = record.end - record.start,
                    .reach = source[record.start..],
                }),
                .object => objects.dictionary_new(record.size),
                .string => objects.text_object(source[record.start + 1 .. record.end - 1]),
                .string_escaped => objects.text_object(builder.escaped_of(record)),
                .true_value => singletons.acquire(singletons.true_value),
            };

            return result orelse error.PythonError;
        }

        fn escaped_of(builder: *@This(), record: *const Record) []const u8 {
            assert(record.kind() == .string_escaped);
            assert(record.size > 0);

            const result = builder.document.storage.text[record.target()..][0..record.size];

            assert(result.len == record.size);

            return result;
        }

        fn key_of(builder: *@This(), record: *const Record) Error!Owned {
            assert(record.kind() == .string or record.kind() == .string_escaped);
            assert(builder.depth > 0);

            const text, const reach = switch (record.kind()) {
                .string => .{
                    builder.document.source[record.start + 1 .. record.end - 1],
                    builder.document.source[record.start + 1 ..],
                },
                .string_escaped => .{ builder.escaped_of(record), builder.escaped_of(record) },
                else => unreachable,
            };

            if (text.len > keys.cached_bytes_max) {
                const object = if (renamed)
                    builder.keys.policy.renamed(text) orelse return error.PythonError
                else
                    objects.text_object(text) orelse return error.PythonError;

                return .{ .object = object, .owned = true };
            }

            const window: keys.Window = .{ .length = @intCast(text.len), .reach = reach };
            const object = builder.keys.object_of(window, {}) orelse return error.PythonError;

            return .{ .object = object, .owned = false };
        }

        fn member_add(builder: *@This(), frame: *Frame, records: []const Record) Error!*PyObject {
            assert(frame.object);
            assert(records.len == 2);

            const key = try builder.key_of(&records[0]);
            defer if (key.owned) c.Py_DecRef(key.object);

            const value = try builder.value_of(&records[1]);

            const member: objects.Member = .{ .key = key.object, .value = value };

            if (!objects.dictionary_store(frame.container, member)) {
                c.Py_DecRef(value);

                return error.PythonError;
            }

            objects.release(value);

            return value;
        }

        fn element_add(builder: *@This(), frame: *Frame, record: *const Record) Error!*PyObject {
            assert(!frame.object);
            assert(frame.remaining > 0);

            const value = try builder.value_of(record);

            const element: objects.Element = .{ .index = frame.index, .value = value };

            if (!objects.list_store(frame.container, element)) return error.PythonError;

            frame.index += 1;

            return value;
        }
    };
}

pub fn objects_build(
    comptime renamed: bool,
    document: *const json.Document,
    policy: if (renamed) *const Policy else void,
) Error!lacuna.Reference {
    assert(document.node_count > 0);
    assert(c.PyErr_Occurred() == null);

    var builder: BuilderType(renamed) = .{
        .depth = 0,
        .document = document,
        .frames = undefined,
        .keys = undefined,
        .root = null,
        .singletons = objects.Singletons.init() orelse return error.PythonError,
    };

    builder.keys.policy = policy;
    builder.keys.reset();
    defer builder.deinit();

    const records = document.storage.records[0..document.node_count];
    const root = try builder.value_of(&records[0]);

    builder.root = root;

    if (container_open(&records[0])) builder.push(&records[0], root);

    try records_add(renamed, &builder, records);

    assert(builder.depth == 0);

    builder.root = null;

    return .{ .pointer = root };
}

fn records_add(
    comptime renamed: bool,
    builder: *BuilderType(renamed),
    records: []const Record,
) Error!void {
    assert(records.len > 0);
    assert(builder.depth <= 1);

    var index: u64 = 1;

    for (0..2 * records.len) |_| {
        if (builder.depth == 0) break;

        const frame = builder.top();
        const opened = if (frame.object)
            try members_add(renamed, builder, frame, records, &index)
        else
            try elements_add(renamed, builder, frame, records, &index);

        if (!opened) builder.depth -= 1;
    }

    assert(builder.depth == 0);
    assert(index == records.len);
}

fn members_add(
    comptime renamed: bool,
    builder: *BuilderType(renamed),
    frame: *Frame,
    records: []const Record,
    index: *u64,
) Error!bool {
    assert(frame.object);
    assert(index.* + 2 * @as(u64, frame.remaining) <= records.len);

    for (0..frame.remaining) |_| {
        const record = &records[index.* + 1];
        const value = try builder.member_add(frame, records[index.*..][0..2]);

        frame.remaining -= 1;
        index.* += 2;

        if (container_open(record)) {
            builder.push(record, value);

            return true;
        }
    }

    assert(frame.remaining == 0);

    return false;
}

fn elements_add(
    comptime renamed: bool,
    builder: *BuilderType(renamed),
    frame: *Frame,
    records: []const Record,
    index: *u64,
) Error!bool {
    assert(!frame.object);
    assert(index.* + frame.remaining <= records.len);

    for (0..frame.remaining) |_| {
        const record = &records[index.*];
        const value = try builder.element_add(frame, record);

        frame.remaining -= 1;
        index.* += 1;

        if (container_open(record)) {
            builder.push(record, value);

            return true;
        }
    }

    assert(frame.remaining == 0);

    return false;
}

fn container_open(record: *const Record) bool {
    assert(record.start < record.end);
    assert(@sizeOf(Record) == 16);

    return switch (record.kind()) {
        .array, .object => record.size > 0,
        .false_value, .null_value, .number, .string, .string_escaped, .true_value => false,
    };
}
