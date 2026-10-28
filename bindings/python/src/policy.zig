const std = @import("std");

const json = @import("json");
const lacuna = @import("lacuna");

const objects = @import("objects.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const PyObject = c.PyObject;

pub const Policy = struct {
    key_error: ?*PyObject,
    none: *PyObject,
    rule: Rule,

    pub const Rule = union(enum) {
        callable: *PyObject,
        mapping: *PyObject,
        style: json.Rename,
    };

    const Outcome = struct {
        key: *PyObject,
        result: *PyObject,
    };

    pub fn of(object: *PyObject) lacuna.PythonError!Policy {
        assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        const rule = try rule_of(object);
        const key_error = if (rule == .mapping) try key_error_of() else null;
        errdefer if (key_error) |class| c.Py_DecRef(class);

        const none = c.Py_BuildValue("") orelse return error.PythonError;

        return .{ .key_error = key_error, .none = none, .rule = rule };
    }

    pub fn deinit(policy: *const Policy) void {
        assert(@intFromPtr(policy.none) % @alignOf(*PyObject) == 0);
        assert((policy.key_error != null) == (policy.rule == .mapping));

        c.Py_DecRef(policy.none);

        if (policy.key_error) |class| c.Py_DecRef(class);
    }

    pub fn renamed(policy: *const Policy, text: []const u8) ?*PyObject {
        assert(text.len <= std.math.maxInt(u32));
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        switch (policy.rule) {
            .style => return policy.style_renamed(text),
            .callable => |callable| {
                const key = objects.text_object(text) orelse return null;
                defer c.Py_DecRef(key);

                const result = c.PyObject_CallFunction(callable, "O", key) orelse return null;

                return policy.result_checked(.{ .key = key, .result = result });
            },
            .mapping => |mapping| {
                const key = objects.text_object(text) orelse return null;
                defer c.Py_DecRef(key);

                const result = c.PyObject_GetItem(mapping, key) orelse {
                    if (c.PyErr_ExceptionMatches(policy.key_error.?) == 0) return null;

                    c.PyErr_Clear();
                    c.Py_IncRef(key);

                    return key;
                };

                return policy.result_checked(.{ .key = key, .result = result });
            },
        }
    }

    fn result_checked(policy: *const Policy, outcome: Outcome) ?*PyObject {
        assert(policy.rule != .style);
        assert(@intFromPtr(outcome.result) % @alignOf(*PyObject) == 0);

        if (outcome.result == policy.none) {
            c.Py_DecRef(outcome.result);
            c.Py_IncRef(outcome.key);

            return outcome.key;
        }

        if (text_is(outcome.result)) return outcome.result;

        c.Py_DecRef(outcome.result);
        objects.builtin_raise(.type_error, "rename must give each key a str or None");

        return null;
    }

    fn style_renamed(policy: *const Policy, text: []const u8) ?*PyObject {
        assert(policy.rule == .style);
        assert(text.len <= std.math.maxInt(u32));

        const style = policy.rule.style;
        const size = 2 * text.len + 1;
        const scratch = if (size > scratch_inline_bytes) scratch_of(size) else null;
        defer if (scratch) |object| c.Py_DecRef(object);

        var inline_buffer: [scratch_inline_bytes]u8 = undefined;

        const buffer = if (scratch) |object|
            c.PyBytes_AsString(object).?[0..size]
        else
            inline_buffer[0..size];

        if (json.rename(style, text, buffer)) |result| return objects.text_object(result);

        const key = objects.text_object(text) orelse return null;
        defer c.Py_DecRef(key);

        return switch (style) {
            .camel => words_renamed(key, .kept),
            .kebab => unreachable,
            .lower => c.PyObject_CallMethod(key, "lower", null),
            .pascal => words_renamed(key, .titled),
            .snake => snake_renamed(text),
            .upper => c.PyObject_CallMethod(key, "upper", null),
        };
    }
};

const Leading = enum {
    kept,
    titled,
};

const scratch_inline_bytes: u32 = 2 * 64 + 1;
const style_message = "rename names no style; use camel, kebab, lower, pascal, snake, or upper";
const type_message = "rename must be a str, a mapping, or a callable";

fn rule_of(object: *PyObject) lacuna.PythonError!Policy.Rule {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    if (text_is(object)) {
        const name = objects.text_of(object) orelse return error.PythonError;

        const style = std.meta.stringToEnum(json.Rename, name) orelse {
            objects.builtin_raise(.value_error, style_message);

            return error.PythonError;
        };

        return .{ .style = style };
    }

    if (c.PyCallable_Check(object) != 0) return .{ .callable = object };

    const subscript = c.PyObject_GetAttrString(object, "__getitem__") orelse {
        c.PyErr_Clear();
        objects.builtin_raise(.type_error, type_message);

        return error.PythonError;
    };

    c.Py_DecRef(subscript);

    return .{ .mapping = object };
}

fn key_error_of() lacuna.PythonError!*PyObject {
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);
    assert(@sizeOf(Policy) <= 64);

    return objects.builtin_class(.key_error) orelse error.PythonError;
}

fn scratch_of(size: u64) ?*PyObject {
    assert(size > scratch_inline_bytes);
    assert(size <= 2 * @as(u64, std.math.maxInt(u32)) + 1);

    return c.PyBytes_FromStringAndSize(null, @intCast(size));
}

fn text_is(object: *PyObject) bool {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(c.Py_TPFLAGS_UNICODE_SUBCLASS != 0);

    return c.PyType_GetFlags(objects.type_of(object)) & c.Py_TPFLAGS_UNICODE_SUBCLASS != 0;
}

fn words_renamed(key: *PyObject, leading: Leading) ?*PyObject {
    assert(@intFromPtr(key) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const parts = c.PyObject_CallMethod(key, "split", "s", "_") orelse return null;
    defer c.Py_DecRef(parts);

    const count: u64 = @intCast(c.PyList_Size(parts));

    if (count == 1) {
        if (leading == .kept) {
            c.Py_IncRef(key);

            return key;
        }
    }

    var first = true;

    for (0..count) |index| {
        const part = c.PyList_GetItem(parts, @intCast(index)) orelse return null;

        if (first) {
            if (c.PyObject_Size(part) == 0) {
                const underscore = c.PyUnicode_FromStringAndSize("_", 1) orelse return null;
                if (c.PyList_SetItem(parts, @intCast(index), underscore) != 0) return null;

                continue;
            }

            first = false;

            if (leading == .kept) continue;
        }

        const titled = c.PyObject_CallMethod(part, "title", null) orelse return null;
        if (c.PyList_SetItem(parts, @intCast(index), titled) != 0) return null;
    }

    const joiner = c.PyUnicode_FromStringAndSize("", 0) orelse return null;
    defer c.Py_DecRef(joiner);

    return c.PyObject_CallMethod(joiner, "join", "O", parts);
}

fn snake_renamed(text: []const u8) ?*PyObject {
    assert(text.len <= std.math.maxInt(u32));
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const size = 2 * text.len + 1;
    const scratch = c.PyBytes_FromStringAndSize(null, @intCast(size)) orelse return null;
    defer c.Py_DecRef(scratch);

    const buffer = c.PyBytes_AsString(scratch).?[0..size];

    var length: u64 = 0;

    for (text, 0..) |byte, index| {
        const broken = snake_broken(text, @intCast(index)) orelse return null;

        if (broken) {
            buffer[length] = '_';
            length += 1;
        }

        buffer[length] = if (byte == '-') '_' else byte;
        length += 1;
    }

    assert(length < size);

    const spliced = objects.text_object(buffer[0..length]) orelse return null;
    defer c.Py_DecRef(spliced);

    return c.PyObject_CallMethod(spliced, "lower", null);
}

fn snake_broken(text: []const u8, index: u32) ?bool {
    assert(index < text.len);
    assert(text.len <= std.math.maxInt(u32));

    if (index == 0) return false;
    if (!std.ascii.isUpper(text[index])) return false;

    const previous = text[index - 1];
    if (std.ascii.isLower(previous)) return true;
    if (std.ascii.isDigit(previous)) return true;

    if (std.ascii.isUpper(previous)) {
        if (index + 1 == text.len) return false;
        return std.ascii.isLower(text[index + 1]);
    }

    if (std.ascii.isAscii(previous)) return false;

    var lead = index - 1;

    for (0..3) |_| {
        if (text[lead] & 0xc0 != 0x80) break;

        lead -= 1;
    }

    return decimal_is(text[lead..index]);
}

fn decimal_is(character: []const u8) ?bool {
    assert(character.len >= 2);
    assert(character.len <= 4);

    const object = objects.text_object(character) orelse return null;
    defer c.Py_DecRef(object);

    const result = c.PyObject_CallMethod(object, "isdecimal", null) orelse return null;
    defer c.Py_DecRef(result);

    return c.PyObject_IsTrue(result) == 1;
}
