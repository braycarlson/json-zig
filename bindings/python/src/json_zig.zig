const std = @import("std");

const json = @import("json");
const lacuna = @import("lacuna");

const convert = @import("convert.zig");
const encode = @import("dumps.zig");
const fast = @import("fast.zig");
const objects = @import("objects.zig");
const policy_module = @import("policy.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const Policy = policy_module.Policy;
const Record = @typeInfo(@FieldType(json.Storage, "records")).pointer.child;

const node_bytes_estimate: u32 = 8;
const node_count_slack: u32 = 64;
const workspace_alignment: u32 = @max(@alignOf(json.Document), @alignOf(Record));

comptime {
    assert(std.math.isPowerOfTwo(workspace_alignment));
    assert(node_bytes_estimate > 0);
}

pub const module: lacuna.Module = .{
    .name = "json_zig",
    .doc = "Parse JSON with json-zig.",
    .classes = &.{Document},
    .functions = Functions,
    .thread_safe = true,
};

pub const Error = lacuna.PythonError;

const DumpsArguments = struct {
    value: lacuna.Object,
    default: ?lacuna.Object = null,
    rename: ?lacuna.Object = null,

    pub const keyword_only = .{ .default, .rename };
};

const Functions = struct {
    pub const docs = .{
        .dumps = "Serialize a Python object to compact UTF-8 JSON bytes.",
        .loads = "Parse a JSON document from bytes, str, or a buffer into Python objects.",
    };

    pub fn dumps(arguments: DumpsArguments) Error!lacuna.Reference {
        assert(@intFromPtr(arguments.value.pointer) != 0);
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        if (arguments.default == null) {
            if (arguments.rename == null) return dumps_with(false, arguments.value.pointer, {});
        }

        return dumps_extended(&arguments);
    }

    pub fn loads(
        arguments: struct {
            data: lacuna.Object,
            rename: ?lacuna.Object = null,

            pub const keyword_only = .{.rename};
        },
    ) Error!lacuna.Reference {
        assert(@intFromPtr(arguments.data.pointer) != 0);
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        const rename = arguments.rename orelse return loads_with(false, arguments.data, {});
        const policy = try Policy.of(rename.pointer);
        defer policy.deinit();

        return loads_with(true, arguments.data, &policy);
    }
};

fn dumps_with(
    comptime extended: bool,
    value: *c.PyObject,
    hooks: if (extended) *const encode.Hooks else void,
) Error!lacuna.Reference {
    assert(@intFromPtr(value) != 0);
    if (extended) assert(hooks.default != null or hooks.policy != null);

    var problem: ?encode.Problem = null;

    const result = encode.dumps(extended, value, hooks, &problem) catch |err| switch (err) {
        error.PythonError => return error.PythonError,
        error.TypeError => return problem_raise(.type_error, problem.?),
        error.ValueError => return problem_raise(.value_error, problem.?),
    };

    assert(result.pointer != null);

    return result;
}

fn dumps_extended(arguments: *const DumpsArguments) Error!lacuna.Reference {
    assert(@intFromPtr(arguments.value.pointer) != 0);
    assert(arguments.default != null or arguments.rename != null);

    const rename = arguments.rename;
    const policy: ?Policy = if (rename) |object| try Policy.of(object.pointer) else null;
    defer if (policy) |*found| found.deinit();

    const hooks: encode.Hooks = .{
        .default = if (arguments.default) |object| object.pointer else null,
        .policy = if (policy) |*found| found else null,
    };

    return dumps_with(true, arguments.value.pointer, &hooks);
}

fn problem_raise(comptime builtin_type: objects.Builtin, problem: encode.Problem) Error {
    comptime assert(builtin_type != .key_error);
    assert(problem.message.len > 0);

    objects.builtin_raise(builtin_type, problem.message);

    return error.PythonError;
}

fn loads_with(
    comptime renamed: bool,
    data: lacuna.Object,
    policy: if (renamed) *const Policy else void,
) Error!lacuna.Reference {
    assert(@intFromPtr(data.pointer) != 0);
    if (renamed) assert((policy.key_error != null) == (policy.rule == .mapping));

    const source = try Source.of(data, .text_allowed);
    defer source.deinit();

    const text = source.text;

    if (text.len <= json.limits.input_bytes_max) {
        assert(text.ptr[text.len] == 0);

        const terminated = text.ptr[0..text.len :0];

        if (fast.loads(renamed, terminated, policy)) |result| {
            return result;
        } else |failure| switch (failure) {
            error.Declined => {},
            error.PythonError => return error.PythonError,
        }
    }

    var parsed = try Parsed.init(&source);
    defer parsed.deinit();

    const result = try convert.objects_build(renamed, parsed.document, policy);

    assert(result.pointer != null);

    return result;
}

pub const Document = struct {
    data: lacuna.Reference,
    node_count: u32,
    parsed: Parsed,

    pub const doc = "A parsed JSON document that keeps json-zig's records without Python objects.";

    pub const docs = .{
        .as_objects = "Convert the document into Python objects.",
        .node_count = "The number of values and keys in the document.",
    };

    pub const fields = .{ .node_count = .read };

    pub fn init(document: *Document, arguments: struct { data: lacuna.Object }) Error!void {
        assert(@intFromPtr(arguments.data.pointer) != 0);
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        const source = try Source.of(arguments.data, .bytes_only);
        defer source.deinit();

        const parsed = try Parsed.init(&source);
        const kept: lacuna.Object = .{ .pointer = source.owned orelse arguments.data.pointer };

        document.* = .{
            .data = .acquire(kept),
            .node_count = parsed.document.node_count,
            .parsed = parsed,
        };

        assert(document.node_count > 0);
        assert(document.data.pointer != null);
    }

    pub fn deinit(document: *Document) void {
        assert(document.node_count == document.parsed.document.node_count);
        assert(document.data.pointer != null);

        document.parsed.deinit();
        document.data.release();
    }

    pub fn as_objects(document: *const Document) Error!lacuna.Reference {
        assert(document.node_count > 0);
        assert(document.data.pointer != null);

        return convert.objects_build(false, document.parsed.document, {});
    }
};

const Accepted = enum {
    bytes_only,
    text_allowed,
};

const Source = struct {
    data: *c.PyObject,
    owned: ?*c.PyObject,
    text: []const u8,

    fn of(data: lacuna.Object, accepted: Accepted) Error!Source {
        assert(@intFromPtr(data.pointer) != 0);
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        const object = data.pointer;

        if (c.PyBytes_AsString(object)) |bytes| {
            const length: u64 = @intCast(c.PyBytes_Size(object));

            return .{ .data = object, .owned = null, .text = bytes[0..length] };
        }

        c.PyErr_Clear();

        if (accepted == .text_allowed) {
            var length: c.Py_ssize_t = 0;

            if (c.PyUnicode_AsUTF8AndSize(object, &length)) |text| {
                return .{ .data = object, .owned = null, .text = text[0..@intCast(length)] };
            }

            c.PyErr_Clear();
        }

        const copy = objects.buffer_copy(object) orelse {
            objects.builtin_raise(.type_error, switch (accepted) {
                .bytes_only => "the document must be bytes or support the buffer protocol",
                .text_allowed => "the document must be bytes or str or support the buffer protocol",
            });

            return error.PythonError;
        };

        const length: u64 = @intCast(c.PyBytes_Size(copy));

        return .{ .data = object, .owned = copy, .text = c.PyBytes_AsString(copy).?[0..length] };
    }

    fn deinit(source: *const Source) void {
        assert(@intFromPtr(source.data) != 0);
        assert(source.text.len <= std.math.maxInt(u32) or source.owned == null);

        if (source.owned) |copy| c.Py_DecRef(copy);
    }
};

const Parsed = struct {
    document: *json.Document,
    workspace: lacuna.Reference,

    const larger_message = std.fmt.comptimePrint(
        "the document is larger than {d} bytes",
        .{json.limits.input_bytes_max},
    );

    fn init(source: *const Source) Error!Parsed {
        assert(source.text.len <= std.math.maxInt(u32));
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

        const text = source.text;

        if (text.len > json.limits.input_bytes_max) {
            objects.builtin_raise(.value_error, larger_message);

            return error.PythonError;
        }

        const length: u32 = @intCast(text.len);
        const estimate = @divFloor(length, node_bytes_estimate) + node_count_slack;
        const first = @min(estimate, @max(length, 1));

        return attempt(source, first) catch |err| switch (err) {
            error.NodesExhausted => attempt(source, @max(length, 1)) catch |retry| {
                return switch (retry) {
                    error.NodesExhausted => unreachable,
                    else => |other| other,
                };
            },
            else => |other| other,
        };
    }

    fn attempt(source: *const Source, node_count_max: u32) (Error || error{NodesExhausted})!Parsed {
        assert(node_count_max > 0);
        assert(source.text.len <= json.limits.input_bytes_max);

        const capacity: json.Capacity = .{
            .node_count_max = node_count_max,
            .text_bytes_max = @intCast(source.text.len),
        };

        var workspace = try Workspace.init(capacity);
        errdefer workspace.reference.release();

        workspace.document.parse(workspace.storage, source.text) catch |err| {
            if (err == error.NodesExhausted) return error.NodesExhausted;

            decode_error_raise(source, json.message(err), workspace.document.diagnostic);

            return error.PythonError;
        };

        assert(workspace.document.node_count > 0);

        return .{ .document = workspace.document, .workspace = workspace.reference };
    }

    fn deinit(parsed: *Parsed) void {
        assert(parsed.document.node_count > 0);
        assert(parsed.workspace.pointer != null);

        parsed.workspace.release();
    }
};

fn decode_error_raise(source: *const Source, message: []const u8, position: json.Position) void {
    assert(message.len > 0);
    assert(position.line >= 1);

    const offset = offset_of(source.text, position);
    const module_json = c.PyImport_ImportModule("json") orelse return;
    defer c.Py_DecRef(module_json);

    const class = c.PyObject_GetAttrString(module_json, "JSONDecodeError") orelse return;
    defer c.Py_DecRef(class);

    const document = document_text(source) orelse return;
    defer c.Py_DecRef(document);

    const text = c.PyUnicode_FromStringAndSize(message.ptr, @intCast(message.len)) orelse return;
    defer c.Py_DecRef(text);

    const characters = characters_of(source.text[0..offset]) orelse return;
    const created = c.PyObject_CallFunction(class, "OOn", text, document, characters);
    const instance = created orelse return;
    defer c.Py_DecRef(instance);

    c.PyErr_SetObject(class, instance);
}

fn offset_of(text: []const u8, position: json.Position) u64 {
    assert(position.line >= 1);
    assert(text.len <= json.limits.input_bytes_max);

    var line: u32 = 1;
    var start: u64 = 0;

    for (text, 0..) |byte, index| {
        if (line == position.line) break;

        if (byte == '\n') {
            line += 1;
            start = index + 1;
        }
    }

    const result = @min(start + (position.column -| 1), text.len);

    assert(result <= text.len);

    return result;
}

fn document_text(source: *const Source) ?*c.PyObject {
    assert(@intFromPtr(source.data) != 0);
    assert(source.text.len <= json.limits.input_bytes_max);

    const flags = c.PyType_GetFlags(objects.type_of(source.data));

    if (flags & c.Py_TPFLAGS_UNICODE_SUBCLASS != 0) {
        c.Py_IncRef(source.data);

        return source.data;
    }

    return text_decoded(source.text);
}

fn characters_of(text: []const u8) ?c.Py_ssize_t {
    assert(text.len <= json.limits.input_bytes_max);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const decoded = text_decoded(text) orelse return null;
    defer c.Py_DecRef(decoded);

    const result = c.PyObject_Size(decoded);

    assert(result >= 0);

    return result;
}

fn text_decoded(text: []const u8) ?*c.PyObject {
    assert(text.len <= json.limits.input_bytes_max);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const bytes = c.PyBytes_FromStringAndSize(text.ptr, @intCast(text.len)) orelse return null;
    defer c.Py_DecRef(bytes);

    return c.PyObject_CallMethod(bytes, "decode", "ss", "utf-8", "replace");
}

const Workspace = struct {
    document: *json.Document,
    reference: lacuna.Reference,
    storage: json.Storage,

    fn init(capacity: json.Capacity) Error!Workspace {
        assert(capacity.node_count_max > 0);
        assert(capacity.text_bytes_max <= json.limits.text_bytes_max);

        const records_bytes = @as(u64, capacity.node_count_max) * @sizeOf(Record);
        const document_bytes = std.mem.alignForward(u64, @sizeOf(json.Document), @alignOf(Record));
        const text_start = document_bytes + records_bytes;
        const total = workspace_alignment + text_start + capacity.text_bytes_max;

        const object = c.PyBytes_FromStringAndSize(null, @intCast(total)) orelse {
            c.PyErr_Clear();

            const class = objects.builtin_class(.memory_error) orelse return error.PythonError;
            defer c.Py_DecRef(class);

            const size: c_ulonglong = total;

            _ = c.PyErr_Format(class, "no memory for a %llu byte workspace", size);

            return error.PythonError;
        };

        const bytes = c.PyBytes_AsString(object).?[0..total];
        const base = std.mem.alignForward(u64, @intFromPtr(bytes.ptr), workspace_alignment);
        const start = base - @intFromPtr(bytes.ptr);
        const records = bytes[start + document_bytes ..][0..records_bytes];

        const result: Workspace = .{
            .document = @ptrCast(@alignCast(bytes[start..][0..@sizeOf(json.Document)])),
            .reference = .{ .pointer = object },
            .storage = .{
                .records = @alignCast(std.mem.bytesAsSlice(Record, records)),
                .text = bytes[start + text_start ..][0..capacity.text_bytes_max],
            },
        };

        assert(result.storage.records.len == capacity.node_count_max);
        assert(result.storage.text.len == capacity.text_bytes_max);

        return result;
    }
};
