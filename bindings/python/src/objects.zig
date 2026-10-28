const std = @import("std");
const builtin = @import("builtin");

const lacuna = @import("lacuna");

const transcode = @import("transcode.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const PyObject = c.PyObject;

pub const Kind = enum(u3) {
    ascii,
    latin1,
    ucs2,
    ucs4,
};

pub const Shape = struct {
    count: u32,
    kind: Kind,
};

pub const Element = struct {
    index: u32,
    value: *PyObject,
};

pub const Member = struct {
    key: *PyObject,
    value: *PyObject,
};

pub const Compact = struct {
    magnitude: u32,
    negative: bool,
};

pub const Builtin = enum {
    key_error,
    memory_error,
    type_error,
    value_error,

    pub fn name(builtin_type: Builtin) [:0]const u8 {
        return switch (builtin_type) {
            .key_error => "KeyError",
            .memory_error => "MemoryError",
            .type_error => "TypeError",
            .value_error => "ValueError",
        };
    }
};

pub const Singletons = struct {
    false_value: *PyObject,
    none: *PyObject,
    true_value: *PyObject,

    pub fn init() ?Singletons {
        if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);
        assert(@sizeOf(Singletons) == 3 * @sizeOf(*PyObject));

        const none = c.Py_BuildValue("") orelse return null;
        const false_value = c.PyBool_FromLong(0) orelse return null;
        const true_value = c.PyBool_FromLong(1) orelse return null;

        assert(none != false_value);
        assert(false_value != true_value);

        return .{ .false_value = false_value, .none = none, .true_value = true_value };
    }

    pub fn deinit(singletons: *const Singletons) void {
        assert(singletons.none != singletons.true_value);
        assert(singletons.false_value != singletons.true_value);

        if (immortal) return;

        c.Py_DecRef(singletons.none);
        c.Py_DecRef(singletons.false_value);
        c.Py_DecRef(singletons.true_value);
    }

    pub fn acquire(singletons: *const Singletons, object: *PyObject) *PyObject {
        assert(object == singletons.none or object == singletons.false_value or
            object == singletons.true_value);
        assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);

        if (!versioned) c.Py_IncRef(object);

        return object;
    }
};

pub const versioned = c.versioned;

const immortal = c.abi_minor != null;

const ascii_mask: u64 = 0x8080808080808080;
const chunk_bytes: u32 = 16;
const latin1_lead_max: u8 = 0xc3;
const list_copy_inline_max: u32 = 8;
const ucs2_lead_max: u8 = 0xef;

const Chunk = @Vector(chunk_bytes, u8);
const Pairs = @Vector(8, u16);
const Quad = @Vector(4, u32);

const triple_mask: Chunk = .{
    0xf0,
    0xc0,
    0xc0,
    0xf0,
    0xc0,
    0xc0,
    0xf0,
    0xc0,
    0xc0,
    0xf0,
    0xc0,
    0xc0,
    0,
    0,
    0,
    0,
};

const triple_pattern: Chunk = .{
    0xe0,
    0x80,
    0x80,
    0xe0,
    0x80,
    0x80,
    0xe0,
    0x80,
    0x80,
    0xe0,
    0x80,
    0x80,
    0,
    0,
    0,
    0,
};

comptime {
    assert(@sizeOf(*PyObject) == 8);
    assert(builtin.target.cpu.arch.endian() == .little);
    assert(@sizeOf(c.PyObject_Header) == 16 or !versioned);
    assert(@sizeOf(c.PyASCIIObject) == 40 or !versioned);
    assert(@sizeOf(c.PyCompactUnicodeObject) == 56 or !versioned);
}

pub fn list_new(count: u32) ?*PyObject {
    assert(count <= std.math.maxInt(i32));
    assert(@sizeOf(c.Py_ssize_t) == 8);

    return c.PyList_New(count);
}

pub fn list_store(list: *PyObject, element: Element) bool {
    assert(@intFromPtr(list) != @intFromPtr(element.value));
    assert(element.index <= std.math.maxInt(i32));

    const index = element.index;
    const value = element.value;

    if (versioned) {
        const view: *c.PyListObject = @ptrCast(@alignCast(list));
        const items = view.ob_item.?;

        assert(index < view.ob_base.ob_size);
        assert(items[index] == null);

        items[index] = value;

        return true;
    }

    return c.PyList_SetItem(list, index, value) == 0;
}

pub fn list_fill(list: *PyObject, items: []const *PyObject) void {
    assert(items.len <= std.math.maxInt(i32));
    assert(@intFromPtr(list) % @alignOf(*PyObject) == 0);

    if (items.len == 0) return;

    if (versioned) {
        const view: *c.PyListObject = @ptrCast(@alignCast(list));
        const slots: [*]*PyObject = @ptrCast(view.ob_item.?);

        assert(view.ob_base.ob_size == items.len);

        if (items.len > list_copy_inline_max) {
            @memcpy(slots[0..items.len], items);

            return;
        }

        for (0..list_copy_inline_max) |index| {
            if (index == items.len) break;

            slots[index] = items[index];
        }

        return;
    }

    for (items, 0..) |item, index| {
        const status = c.PyList_SetItem(list, @intCast(index), item);

        assert(status == 0);
    }
}

pub fn dictionary_new(count: u32) ?*PyObject {
    assert(count <= std.math.maxInt(i32));
    assert(@sizeOf(c.Py_ssize_t) == 8);

    if (versioned) return c._PyDict_NewPresized(count);
    return c.PyDict_New();
}

pub fn dictionary_store(dictionary: *PyObject, member: Member) bool {
    assert(@intFromPtr(dictionary) != @intFromPtr(member.key));
    assert(@intFromPtr(dictionary) != @intFromPtr(member.value));

    const key = member.key;
    const value = member.value;

    if (versioned) {
        const header: *const c.PyASCIIObject = @ptrCast(@alignCast(key));

        assert(header.state & c.unicode_state_compact != 0);

        if (header.hash != -1) {
            return c._PyDict_SetItem_KnownHash(dictionary, key, value, header.hash) == 0;
        }
    }

    return c.PyDict_SetItem(dictionary, key, value) == 0;
}

pub fn truncate(bytes: *PyObject, length: u64) void {
    assert(versioned);
    assert(length <= std.math.maxInt(i32) or @sizeOf(c.Py_ssize_t) == 8);

    const view: *c.PyVarObject_Header = @ptrCast(@alignCast(bytes));
    const data = c.PyBytes_AsString(bytes).?;

    assert(length <= view.ob_size);

    view.ob_size = @intCast(length);
    data[length] = 0;
}

pub fn acquire(object: *PyObject) void {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    if (!versioned) return c.Py_IncRef(object);

    const header: *c.PyObject_Header = @ptrCast(@alignCast(object));
    if (immortal_is(header)) return;

    assert(header.ob_refcnt > 0);

    header.ob_refcnt += 1;
}

fn immortal_is(header: *const c.PyObject_Header) bool {
    assert(versioned);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    const low: i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(header.ob_refcnt)))));

    return low < 0;
}

pub fn release(object: *PyObject) void {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    if (!versioned) return c.Py_DecRef(object);

    const header: *c.PyObject_Header = @ptrCast(@alignCast(object));
    if (immortal_is(header)) return;
    if (header.ob_refcnt == 1) return c.Py_DecRef(object);

    assert(header.ob_refcnt > 1);

    header.ob_refcnt -= 1;
}

pub const Container = enum {
    dictionary,
    list,
    tuple,
};

pub const Entries = union(enum) {
    general: []const c.PyDictKeyEntry,
    unicode: []const c.PyDictUnicodeEntry,
};

pub fn entries_of(dictionary: *PyObject) ?Entries {
    assert(@intFromPtr(dictionary) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.PyDictUnicodeEntry) == 2 * @sizeOf(*PyObject));

    if (!versioned) return null;

    const view = dictionary_view(dictionary);
    if (view.ma_values != null) return null;

    const keys = view.ma_keys.?;
    const count: u64 = @intCast(keys.dk_nentries);
    const base: [*]const u8 = @ptrCast(keys);
    const indices_bytes = @as(u64, 1) << @intCast(keys.dk_log2_index_bytes);
    const start = base + @offsetOf(c.PyDictKeysObject, "dk_indices") + indices_bytes;

    return switch (keys.dk_kind) {
        c.api_versioned.DICT_KEYS_GENERAL => .{
            .general = entries_view(c.PyDictKeyEntry, start, count),
        },
        c.api_versioned.DICT_KEYS_UNICODE => .{
            .unicode = entries_view(c.PyDictUnicodeEntry, start, count),
        },
        else => null,
    };
}

fn entries_view(comptime Entry: type, start: [*]const u8, count: u64) []const Entry {
    assert(@intFromPtr(start) % @alignOf(Entry) == 0);
    assert(count <= std.math.maxInt(u32));

    const entries: [*]const Entry = @ptrCast(@alignCast(start));

    return entries[0..count];
}

pub fn type_of(object: *PyObject) *PyObject {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.PyObject_Header) >= @sizeOf(c.Py_ssize_t) + @sizeOf(*PyObject));

    const header: *const c.PyObject_Header = @ptrCast(@alignCast(object));

    return header.ob_type.?;
}

pub fn buffer_copy(object: *PyObject) ?*PyObject {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    var view: c.Py_buffer = undefined;

    if (c.PyObject_GetBuffer(object, &view, c.PyBUF_SIMPLE) != 0) {
        c.PyErr_Clear();

        return null;
    }

    defer c.PyBuffer_Release(&view);

    return c.PyBytes_FromStringAndSize(@ptrCast(view.buf), view.len) orelse {
        c.PyErr_Clear();

        return null;
    };
}

pub fn builtin_raise(comptime builtin_type: Builtin, message: [:0]const u8) void {
    comptime assert(builtin_type.name().len > 0);
    assert(message.len > 0);

    const class = builtin_class(builtin_type) orelse return;
    defer c.Py_DecRef(class);

    c.PyErr_SetString(class, message);
}

pub fn builtin_class(comptime builtin_type: Builtin) ?*PyObject {
    comptime assert(builtin_type.name().len > 0);
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    const builtins = c.PyImport_ImportModule("builtins") orelse return null;
    defer c.Py_DecRef(builtins);

    return c.PyObject_GetAttrString(builtins, builtin_type.name());
}

pub fn floating_is(type_object: *PyObject) ?bool {
    assert(@intFromPtr(type_object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(f64) == 8);

    const sample = c.PyFloat_FromDouble(0.5) orelse return null;
    defer c.Py_DecRef(sample);

    const float_type = type_of(sample);
    if (type_object == float_type) return true;
    return c.PyType_IsSubtype(type_object, float_type) != 0;
}

pub fn shape_matches(container: *PyObject, shape: Container) bool {
    assert(@intFromPtr(container) % @alignOf(*PyObject) == 0);
    assert(c.Py_TPFLAGS_DICT_SUBCLASS != c.Py_TPFLAGS_LIST_SUBCLASS);

    const flags = c.PyType_GetFlags(type_of(container));

    const flag: c_ulong = switch (shape) {
        .dictionary => c.Py_TPFLAGS_DICT_SUBCLASS,
        .list => c.Py_TPFLAGS_LIST_SUBCLASS,
        .tuple => c.Py_TPFLAGS_TUPLE_SUBCLASS,
    };

    return flags & flag != 0;
}

pub fn container_length(container: *PyObject, shape: Container) u64 {
    assert(@intFromPtr(container) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    const length = switch (shape) {
        .dictionary => if (versioned)
            dictionary_view(container).ma_used
        else
            c.PyDict_Size(container),
        .list => if (versioned) list_view(container).ob_base.ob_size else c.PyList_Size(container),
        .tuple => c.PyTuple_Size(container),
    };

    assert(length >= 0);

    return @intCast(length);
}

pub fn item_of(container: *PyObject, index: u64, shape: Container) *PyObject {
    assert(shape != .dictionary);
    assert(index <= std.math.maxInt(i32));

    if (shape == .tuple) return c.PyTuple_GetItem(container, @intCast(index)).?;
    if (versioned) return list_view(container).ob_item.?[index].?;
    return c.PyList_GetItem(container, @intCast(index)).?;
}

fn dictionary_view(dictionary: *PyObject) *const c.PyDictObject {
    assert(versioned);
    assert(@intFromPtr(dictionary) % @alignOf(c.PyDictObject) == 0);

    return @ptrCast(@alignCast(dictionary));
}

fn list_view(list: *PyObject) *const c.PyListObject {
    assert(versioned);
    assert(@intFromPtr(list) % @alignOf(c.PyListObject) == 0);

    return @ptrCast(@alignCast(list));
}

pub fn integer_compact(object: *PyObject) ?Compact {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    if (!versioned) return null;

    const view: *const c.PyLongObject = @ptrCast(@alignCast(object));
    const tag = view.long_value.lv_tag;
    if (tag >> c.api_versioned._PyLong_NON_SIZE_BITS > 1) return null;

    const result: Compact = .{
        .magnitude = view.long_value.ob_digit[0],
        .negative = tag & c.api_versioned._PyLong_SIGN_MASK == 2,
    };

    assert(result.magnitude < 1 << c.api_versioned.PyLong_SHIFT);

    return result;
}

pub fn list_items(list: *PyObject) []const ?*PyObject {
    assert(versioned);
    assert(@intFromPtr(list) % @alignOf(c.PyListObject) == 0);

    const view = list_view(list);
    const count: u64 = @intCast(view.ob_base.ob_size);
    if (count == 0) return &.{};

    const result = view.ob_item.?[0..count];

    assert(result.len == count);

    return result;
}

pub fn integer_small(object: *PyObject) ?i64 {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    if (!versioned) return null;

    const view: *const c.PyLongObject = @ptrCast(@alignCast(object));
    const tag = view.long_value.lv_tag;
    const digit_count = tag >> c.api_versioned._PyLong_NON_SIZE_BITS;
    if (digit_count > 2) return null;

    const digits: [*]const u32 = &view.long_value.ob_digit;
    const high: u64 = if (digit_count == 2) digits[1] else 0;
    const magnitude: i64 = @intCast(@as(u64, digits[0]) | high << c.api_versioned.PyLong_SHIFT);
    const sign = 1 - @as(i64, @intCast(tag & c.api_versioned._PyLong_SIGN_MASK));
    const result = sign * magnitude;

    assert(@abs(result) < 1 << (2 * c.api_versioned.PyLong_SHIFT));

    return result;
}

pub fn float_bits(object: *PyObject) u64 {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(f64) == @sizeOf(u64));

    if (!versioned) {
        const value = c.PyFloat_AsDouble(object);
        const result: u64 = @bitCast(value);

        assert(@as(f64, @bitCast(result)) == value or std.math.isNan(value));

        return result;
    }

    const view: *const c.PyFloatObject = @ptrCast(@alignCast(object));
    const bits: *const u64 = @ptrCast(&view.ob_fval);

    return bits.*;
}

pub inline fn text_of(object: *PyObject) ?[]const u8 {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.PyASCIIObject) == 40 or !versioned);

    if (versioned) {
        const header: *const c.PyASCIIObject = @ptrCast(@alignCast(object));
        const compact_ascii = c.unicode_state_compact | c.unicode_state_ascii;

        if (header.state & compact_ascii == compact_ascii) {
            const base: [*]const u8 = @ptrCast(object);
            const length: u64 = @intCast(header.length);

            return base[@sizeOf(c.PyASCIIObject)..][0..length];
        }

        if (header.state & c.unicode_state_compact != 0) {
            const view: *const c.PyCompactUnicodeObject = @ptrCast(@alignCast(object));

            if (view.utf8) |utf8| return utf8[0..@intCast(view.utf8_length)];
        }
    }

    return text_encoded(object);
}

fn text_encoded(object: *PyObject) ?[]const u8 {
    assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);
    assert(@sizeOf(c.Py_ssize_t) == 8);

    var length: c.Py_ssize_t = 0;
    const bytes = c.PyUnicode_AsUTF8AndSize(object, &length) orelse return null;

    return bytes[0..@intCast(length)];
}

pub fn text_object(text: []const u8) ?*PyObject {
    assert(text.len <= std.math.maxInt(u32));
    if (std.debug.runtime_safety) assert(c.PyErr_Occurred() == null);

    if (!versioned) return c.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len));

    const shape = shape_of(text);
    const object = c.PyUnicode_New(shape.count, character_max(shape.kind)) orelse return null;
    const base: [*]u8 = @ptrCast(object);
    const header: *const c.PyASCIIObject = @ptrCast(@alignCast(object));

    assert(header.length == shape.count);
    assert(header.state & c.unicode_state_compact != 0);

    switch (shape.kind) {
        .ascii => {
            assert(header.state & c.unicode_state_ascii != 0);

            @memcpy(base[@sizeOf(c.PyASCIIObject)..][0..text.len], text);
        },
        .latin1 => decode(u8, text, units_of(u8, base, shape)),
        .ucs2 => decode(u16, text, units_of(u16, base, shape)),
        .ucs4 => decode(u32, text, units_of(u32, base, shape)),
    }

    return object;
}

pub fn ascii_object(text: []const u8) ?*PyObject {
    assert(text.len <= std.math.maxInt(u32));
    if (std.debug.runtime_safety) assert(ascii_is(text));

    if (!versioned) return c.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len));

    const object = c.PyUnicode_New(@intCast(text.len), 0x7f) orelse return null;
    const base: [*]u8 = @ptrCast(object);
    const header: *const c.PyASCIIObject = @ptrCast(@alignCast(object));

    assert(header.length == text.len);
    assert(header.state & c.unicode_state_ascii != 0);

    copy_bytes(base[@sizeOf(c.PyASCIIObject)..][0..text.len], text);

    return object;
}

inline fn copy_bytes(target: []u8, source: []const u8) void {
    assert(target.len == source.len);
    assert(@intFromPtr(target.ptr) + target.len <= @intFromPtr(source.ptr) or
        @intFromPtr(source.ptr) + source.len <= @intFromPtr(target.ptr));

    const length = source.len;

    if (length >= 16) {
        if (length > 32) return @memcpy(target, source);

        const head: @Vector(16, u8) = source[0..16].*;
        const tail: @Vector(16, u8) = source[length - 16 ..][0..16].*;

        target[0..16].* = head;
        target[length - 16 ..][0..16].* = tail;

        return;
    }

    if (length >= 8) {
        const head = std.mem.readInt(u64, source[0..8], .little);
        const tail = std.mem.readInt(u64, source[length - 8 ..][0..8], .little);

        std.mem.writeInt(u64, target[0..8], head, .little);
        std.mem.writeInt(u64, target[length - 8 ..][0..8], tail, .little);

        return;
    }

    if (length >= 4) {
        const head = std.mem.readInt(u32, source[0..4], .little);
        const tail = std.mem.readInt(u32, source[length - 4 ..][0..4], .little);

        std.mem.writeInt(u32, target[0..4], head, .little);
        std.mem.writeInt(u32, target[length - 4 ..][0..4], tail, .little);

        return;
    }

    for (source, 0..) |byte, index| target[index] = byte;
}

pub fn shape_of(text: []const u8) Shape {
    assert(text.len <= std.math.maxInt(u32));
    assert(chunk_bytes == @sizeOf(Chunk));

    if (ascii_is(text)) return .{ .count = @intCast(text.len), .kind = .ascii };

    var continuation_count: u32 = 0;
    var chunk_max: Chunk = @splat(0);
    var index: u64 = 0;

    while (index + chunk_bytes <= text.len) : (index += chunk_bytes) {
        const chunk: Chunk = text[index..][0..chunk_bytes].*;
        const trailing = chunk & @as(Chunk, @splat(0xc0)) == @as(Chunk, @splat(0x80));

        continuation_count += std.simd.countTrues(trailing);
        chunk_max = @max(chunk_max, chunk);
    }

    var byte_max: u8 = @reduce(.Max, chunk_max);

    for (text[index..]) |byte| {
        continuation_count += @intFromBool(byte & 0xc0 == 0x80);
        byte_max = @max(byte_max, byte);
    }

    assert(byte_max >= 0xc2);
    assert(continuation_count < text.len);

    const kind: Kind = if (byte_max <= latin1_lead_max)
        .latin1
    else if (byte_max <= ucs2_lead_max)
        .ucs2
    else
        .ucs4;

    return .{ .count = @intCast(text.len - continuation_count), .kind = kind };
}

fn ascii_is(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(ascii_mask == 0x8080808080808080);

    if (text.len < 8) {
        var highs: u8 = 0;

        for (text) |byte| highs |= byte;

        return highs & 0x80 == 0;
    }

    var highs = std.mem.readInt(u64, text[text.len - 8 ..][0..8], .little);
    var index: u64 = 0;

    while (index + 8 <= text.len) : (index += 8) {
        highs |= std.mem.readInt(u64, text[index..][0..8], .little);
    }

    return highs & ascii_mask == 0;
}

fn character_max(kind: Kind) u32 {
    assert(@sizeOf(Kind) == 1);
    assert(latin1_lead_max < ucs2_lead_max);

    return switch (kind) {
        .ascii => 0x7f,
        .latin1 => 0xff,
        .ucs2 => 0xffff,
        .ucs4 => 0x10ffff,
    };
}

fn units_of(comptime Unit: type, base: [*]u8, shape: Shape) []Unit {
    assert(shape.kind != .ascii);
    assert(@sizeOf(Unit) <= 4);
    assert(@intFromPtr(base) % @alignOf(c.PyCompactUnicodeObject) == 0);

    const header: *const c.PyASCIIObject = @ptrCast(@alignCast(base));
    const kind = (header.state & c.unicode_state_kind_mask) >> c.unicode_state_kind_shift;
    const data: [*]Unit = @ptrCast(@alignCast(base + @sizeOf(c.PyCompactUnicodeObject)));

    assert(kind == @sizeOf(Unit));
    assert(header.state & c.unicode_state_ascii == 0);

    return data[0..shape.count];
}

fn decode(comptime Unit: type, text: []const u8, target: []Unit) void {
    assert(target.len <= text.len);
    assert(target.len > 0);

    if (transcode.enabled) {
        if (Unit == u16) {
            if (2 * text.len >= 5 * target.len) return decode_shuffled(Unit, true, text, target);
        }

        if (Unit != u32) return decode_shuffled(Unit, false, text, target);
    }

    if ((text.len - target.len) * 4 < text.len) return decode_loop(Unit, false, text, target);
    return decode_loop(Unit, true, text, target);
}

fn decode_shuffled(
    comptime Unit: type,
    comptime triples_first: bool,
    text: []const u8,
    target: []Unit,
) void {
    comptime assert(transcode.enabled);
    assert(target.len <= text.len);
    assert(target.len > 0);

    var source_index: u64 = 0;
    var target_index: u64 = 0;

    for (0..text.len) |_| {
        if (source_index == text.len) break;

        if (text.len - source_index >= 8) {
            const word = std.mem.readInt(u64, text[source_index..][0..8], .little);

            if (word & ascii_mask == 0) {
                const bytes: @Vector(8, u8) = text[source_index..][0..8].*;

                target[target_index..][0..8].* = @as(@Vector(8, Unit), bytes);
                source_index += 8;
                target_index += 8;

                continue;
            }
        }

        if (text.len - source_index >= transcode.window_bytes) {
            if (target.len - target_index >= transcode.target_room_min) {
                const window = text[source_index..][0..transcode.window_bytes];
                const rest = target[target_index..];
                const progress = transcode.step(Unit, triples_first, window, rest);

                if (progress.source_count > 0) {
                    source_index += progress.source_count;
                    target_index += progress.target_count;

                    continue;
                }
            }
        }

        const step = point_decode(text[source_index..]);

        target[target_index] = @intCast(step.point);
        source_index += step.length;
        target_index += 1;
    }

    assert(source_index == text.len);
    assert(target_index == target.len);
}

inline fn decode_loop(
    comptime Unit: type,
    comptime dense: bool,
    text: []const u8,
    target: []Unit,
) void {
    assert(target.len <= text.len);
    assert(target.len > 0);

    var source_index: u64 = 0;
    var target_index: u64 = 0;

    for (0..text.len) |_| {
        if (source_index == text.len) break;

        if (source_index + 8 <= text.len) {
            const word = std.mem.readInt(u64, text[source_index..][0..8], .little);

            if (word & ascii_mask == 0) {
                const bytes: @Vector(8, u8) = text[source_index..][0..8].*;

                target[target_index..][0..8].* = @as(@Vector(8, Unit), bytes);
                source_index += 8;
                target_index += 8;

                continue;
            }
        }

        if (dense) {
            const progress = dense_decode(Unit, text[source_index..], target[target_index..]);

            if (progress.source_count > 0) {
                source_index += progress.source_count;
                target_index += progress.target_count;

                continue;
            }
        }

        const step = point_decode(text[source_index..]);

        target[target_index] = @intCast(step.point);
        source_index += step.length;
        target_index += 1;
    }

    assert(source_index == text.len);
    assert(target_index == target.len);
}

const Progress = struct {
    source_count: u32,
    target_count: u32,
};

inline fn dense_decode(comptime Unit: type, rest: []const u8, target: []Unit) Progress {
    assert(rest.len > 0);
    assert(target.len > 0);

    if (rest.len >= chunk_bytes) {
        const progress = run_decode(Unit, rest[0..chunk_bytes], target);
        if (progress.source_count > 0) return progress;
    }

    if (rest.len < 8) return .{ .source_count = 0, .target_count = 0 };

    const lanes: @Vector(4, u16) = @as(*align(1) const [4]u16, @ptrCast(rest[0..8])).*;
    const pair_mask: @Vector(4, u16) = @splat(0xc0e0);
    const pair_pattern: @Vector(4, u16) = @splat(0x80c0);
    const pairs = lanes & pair_mask == pair_pattern;
    if (!@reduce(.And, pairs)) return .{ .source_count = 0, .target_count = 0 };

    const high = (lanes & @as(@Vector(4, u16), @splat(0x1f))) << @splat(6);
    const points = high | ((lanes >> @splat(8)) & @as(@Vector(4, u16), @splat(0x3f)));

    assert(target.len >= 4);

    target[0..4].* = @as(@Vector(4, Unit), @intCast(points));

    return .{ .source_count = 8, .target_count = 4 };
}

fn run_decode(comptime Unit: type, bytes: *const [chunk_bytes]u8, target: []Unit) Progress {
    assert(bytes[0] & 0xc0 != 0x80);
    assert(target.len > 0);

    const lanes: Pairs = @as(*align(1) const [8]u16, @ptrCast(bytes)).*;

    if (@reduce(.And, lanes & @as(Pairs, @splat(0xc0e0)) == @as(Pairs, @splat(0x80c0)))) {
        const high = (lanes & @as(Pairs, @splat(0x1f))) << @splat(6);
        const points = high | ((lanes >> @splat(8)) & @as(Pairs, @splat(0x3f)));

        assert(target.len >= 8);

        target[0..8].* = @as(@Vector(8, Unit), @intCast(points));

        return .{ .source_count = 16, .target_count = 8 };
    }

    if (Unit == u8) return .{ .source_count = 0, .target_count = 0 };

    const chunk: Chunk = bytes.*;
    if (!@reduce(.And, chunk & triple_mask == triple_pattern)) {
        return .{ .source_count = 0, .target_count = 0 };
    }

    const leads: Quad = @shuffle(u8, chunk, undefined, [4]i32{ 0, 3, 6, 9 });
    const firsts: Quad = @shuffle(u8, chunk, undefined, [4]i32{ 1, 4, 7, 10 });
    const seconds: Quad = @shuffle(u8, chunk, undefined, [4]i32{ 2, 5, 8, 11 });
    const high = (leads & @as(Quad, @splat(0x0f))) << @splat(12);
    const middle = (firsts & @as(Quad, @splat(0x3f))) << @splat(6);
    const points = high | middle | (seconds & @as(Quad, @splat(0x3f)));

    assert(target.len >= 4);

    target[0..4].* = @as(@Vector(4, Unit), @intCast(points));

    return .{ .source_count = 12, .target_count = 4 };
}

const Step = struct {
    length: u32,
    point: u32,
};

fn point_decode(rest: []const u8) Step {
    assert(rest.len > 0);
    assert(rest[0] & 0xc0 != 0x80);

    const lead = rest[0];

    const result: Step = if (lead < 0x80)
        .{ .length = 1, .point = lead }
    else if (lead < 0xe0)
        .{ .length = 2, .point = @as(u32, lead & 0x1f) << 6 | continuation(rest, 1) }
    else if (lead < 0xf0)
        .{
            .length = 3,
            .point = @as(u32, lead & 0x0f) << 12 | continuation(rest, 1) << 6 |
                continuation(rest, 2),
        }
    else
        .{
            .length = 4,
            .point = @as(u32, lead & 0x07) << 18 | continuation(rest, 1) << 12 |
                continuation(rest, 2) << 6 | continuation(rest, 3),
        };

    assert(result.length <= rest.len);
    assert(result.point <= 0x10ffff);

    return result;
}

fn continuation(rest: []const u8, index: u32) u32 {
    assert(index < rest.len);
    assert(rest[index] & 0xc0 == 0x80);

    return rest[index] & 0x3f;
}

test shape_of {
    const latin1_run = run: {
        var bytes: [40]u8 = undefined;

        for (0..20) |index| {
            bytes[2 * index] = 0xc3;
            bytes[2 * index + 1] = 0xbf;
        }

        break :run bytes;
    };

    const Case = struct {
        count: u32,
        kind: Kind,
        text: []const u8,
    };

    const cases = [_]Case{
        .{ .count = 0, .kind = .ascii, .text = "" },
        .{ .count = 3, .kind = .ascii, .text = "abc" },
        .{ .count = 4, .kind = .latin1, .text = "caf\u{e9}" },
        .{ .count = 3, .kind = .ucs2, .text = "\u{65e5}\u{672c}\u{8a9e}" },
        .{ .count = 2, .kind = .ucs2, .text = "\u{100}a" },
        .{ .count = 2, .kind = .ucs4, .text = "a\u{1f600}" },
        .{ .count = 20, .kind = .latin1, .text = &latin1_run },
    };

    for (cases) |case| {
        const shape = shape_of(case.text);

        try std.testing.expectEqual(case.count, shape.count);
        try std.testing.expectEqual(case.kind, shape.kind);
    }
}

test "decoding agrees with the standard library on every kind" {
    var prng: std.Random.DefaultPrng = .init(0x6a736f6e);
    const random = prng.random();

    var text: [4096]u8 = undefined;
    var expected: [1024]u32 = undefined;

    for (0..4000) |_| {
        const ranges = [_]u32{ 0x80, 0x100, 0x800, 0x10000, 0x110000 };
        const limit = ranges[random.uintLessThan(u32, ranges.len)];
        const floor: u32 = if (random.boolean()) 0 else @min(limit, 0x10000) >> 1;
        const count = random.uintLessThan(u32, 64);

        var length: u64 = 0;

        for (expected[0..count]) |*point| {
            point.* = point_random(random, .{ .floor = floor, .limit = limit });
            length += std.unicode.utf8Encode(@intCast(point.*), text[length..]) catch unreachable;
        }

        const shape = shape_of(text[0..length]);

        try std.testing.expectEqual(count, shape.count);

        if (shape.kind == .ascii) continue;

        try decode_check(u32, text[0..length], expected[0..count]);
        if (shape.kind != .ucs4) try decode_check(u16, text[0..length], expected[0..count]);
        if (shape.kind == .latin1) try decode_check(u8, text[0..length], expected[0..count]);
    }
}

fn decode_check(comptime Unit: type, text: []const u8, expected: []const u32) !void {
    assert(expected.len <= 1024);
    assert(text.len >= expected.len);

    var actual: [1024]Unit = undefined;

    decode(Unit, text, actual[0..expected.len]);

    for (expected, actual[0..expected.len]) |point, unit| {
        try std.testing.expectEqual(point, unit);
    }
}

const PointRange = struct {
    floor: u32,
    limit: u32,
};

fn point_random(random: std.Random, range: PointRange) u32 {
    assert(range.limit >= 0x80);
    assert(range.limit <= 0x110000);
    assert(range.floor < range.limit);

    for (0..64) |_| {
        const bound = if (random.boolean()) @min(range.floor + 0x80, range.limit) else range.limit;
        const point = random.intRangeLessThan(u32, range.floor, bound);

        switch (point) {
            0xd800...0xdfff => {},
            else => return point,
        }
    }

    return 'x';
}
