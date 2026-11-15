const std = @import("std");

const codec = @import("codec.zig");
const shortest = @import("shortest.zig");
const string = @import("string.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const EncodeOptions = codec.EncodeOptions;
const Out = writer_module.Out;
const Writer = writer_module.Writer;

const Pass = struct {
    depth: u32,
    options: *const EncodeOptions,
    writer: *Writer,
};

pub fn encode(
    comptime T: type,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    assert(writer.options.layout == .compact);
    assert(writer.options.utf8 == .trusted);
    assert(writer.options.notation == .ecmascript);

    try writer.value_open();

    const pass: Pass = .{ .depth = writer.depth, .options = options, .writer = writer };

    try value_put(T, 0, &pass, value);

    writer.value_close();
}

noinline fn through_writer(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.depth_valid(T, depth));
    assert(pass.depth + depth <= codec.depth_max);

    const writer = pass.writer;
    const depth_saved = writer.depth;
    const frame_saved = writer.frame;

    writer.depth = pass.depth + depth + 1;
    writer.frame = .object_value;

    try codec.value_encode(T, depth, writer, value, pass.options);

    writer.depth = depth_saved;
    writer.frame = frame_saved;
}

fn value_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.depth_valid(T, depth));
    assert(pass.depth + depth <= codec.depth_max);

    var out: Out = .of(pass.writer.sink);

    try member_value_put(T, depth, .none, pass, &out, value);

    out.commit();
}

inline fn member_value_put(
    comptime T: type,
    comptime depth: u32,
    comptime lead: Out.Lead,
    pass: *const Pass,
    out: *Out,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.depth_valid(T, depth));
    comptime assert(lead.text.len <= codec.input_bytes_max);
    assert(out.rest.len <= out.sink.buffer.len);

    switch (comptime codec.shape_of(T)) {
        .array => try array_member_put(T, depth + 1, lead, pass, out, value),
        .boolean, .integer => try out.scalar_put(lead, T, value.*),
        .enumeration => {
            const text = codec.enumeration_text(T, value) catch |err| {
                out.commit();

                return err;
            };

            try out.string_put(lead, text);
        },
        .float => try float_member_put(T, depth, lead, pass, out, value),
        .optional => {
            if (value.*) |*child| {
                const Child = @typeInfo(T).optional.child;

                try member_value_put(Child, depth + 1, lead, pass, out, child);
            } else {
                try out.literal_put(lead.text ++ "null");
            }
        },
        .string => try out.string_put(lead, value.*),
        .sequence => {
            if (lead.text.len > 0) try out.literal_put(lead.text);

            try sequence_member_put(T, depth + 1, pass, out, value);
        },
        .choice, .map, .object => {
            if (lead.text.len > 0) try out.literal_put(lead.text);

            out.commit();

            switch (comptime codec.shape_of(T)) {
                .choice => try choice_put(T, depth + 1, pass, value),
                .map => try map_put(T, depth + 1, pass, value),
                .object => try object_put(T, depth + 1, pass, value),
                else => comptime unreachable,
            }

            out.reload();
        },
        .adapted, .raw => try out_through(T, depth, lead, pass, out, value),
        .entry => @compileError("an entry is encoded only inside a map"),
    }
}

inline fn array_member_put(
    comptime T: type,
    comptime depth: u32,
    comptime lead: Out.Lead,
    pass: *const Pass,
    out: *Out,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .array);
    comptime assert(codec.depth_valid(T, depth));
    comptime assert(lead.text.len <= codec.input_bytes_max);
    assert(out.rest.len <= out.sink.buffer.len);

    const Element = @typeInfo(T).array.child;
    const open: Out.Lead = comptime .of(lead.text ++ "[");

    try member_value_put(Element, depth, open, pass, out, &value[0]);

    for (value[1..]) |*item| try member_value_put(Element, depth, .comma, pass, out, item);

    try out.literal_put("]");
}

inline fn float_member_put(
    comptime T: type,
    comptime depth: u32,
    comptime lead: Out.Lead,
    pass: *const Pass,
    out: *Out,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .float);
    comptime assert(codec.depth_valid(T, depth));
    comptime assert(lead.text.len <= codec.input_bytes_max);
    assert(out.rest.len <= out.sink.buffer.len);

    if (comptime T == f64) {
        const bits: u64 = @bitCast(value.*);

        if (shortest.regular_is(bits)) return out.regular_put(lead, bits);
    }

    if (std.math.isFinite(value.*)) {
        try out.scalar_put(lead, T, value.*);
    } else {
        try out_through(T, depth, lead, pass, out, value);
    }
}

inline fn sequence_member_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    out: *Out,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .sequence);
    comptime assert(codec.depth_valid(T, depth));
    assert(value.len <= codec.input_bytes_max);

    if (comptime leaf_is(@typeInfo(T).pointer.child)) {
        try sequence_body_put(T, depth, pass, out, value);
    } else {
        out.commit();

        try sequence_put(T, depth, pass, value);

        out.reload();
    }
}

inline fn out_through(
    comptime T: type,
    comptime depth: u32,
    comptime lead: Out.Lead,
    pass: *const Pass,
    out: *Out,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.depth_valid(T, depth));
    comptime assert(lead.text.len <= codec.input_bytes_max);
    assert(out.rest.len <= out.sink.buffer.len);

    if (lead.text.len > 0) try out.literal_put(lead.text);

    out.commit();

    try through_writer(T, depth, pass, value);

    out.reload();
}

fn object_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .object);
    comptime assert(codec.depth_valid(T, depth));
    comptime codec.names_check(T);

    const structure = @typeInfo(T).@"struct";

    var out: Out = .of(pass.writer.sink);

    try out.literal_put("{");

    var emitted = false;

    inline for (structure.field_names, structure.field_types, 0..) |name, Field, index| {
        if (!codec.member_omitted(T, index, value, pass.options)) {
            const field = &@field(value, name);

            codec.enumeration_check(Field, field) catch |err| {
                out.commit();

                return err;
            };

            const wire = comptime codec.name_of(T, name);

            try member_put(wire, Field, depth, pass, &out, field, emitted);

            emitted = true;
        }
    }

    try out.literal_put("}");

    out.commit();
}

inline fn member_put(
    comptime wire: []const u8,
    comptime Field: type,
    comptime depth: u32,
    pass: *const Pass,
    out: *Out,
    field: *const Field,
    emitted: bool,
) Writer.Error!void {
    comptime assert(wire.len <= codec.input_bytes_max);
    comptime assert(codec.depth_valid(Field, depth));
    assert(out.rest.len <= out.sink.buffer.len);

    if (comptime string.verbatim_is(wire)) {
        if (emitted) {
            const later: Out.Lead = comptime .of(",\"" ++ wire ++ "\":");

            try member_value_put(Field, depth, later, pass, out, field);
        } else {
            const first: Out.Lead = comptime .of("\"" ++ wire ++ "\":");

            try member_value_put(Field, depth, first, pass, out, field);
        }
    } else {
        if (emitted) try out.literal_put(",");

        try out.string_put(.none, wire);
        try member_value_put(Field, depth, .colon, pass, out, field);
    }
}

fn sequence_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .sequence);
    comptime assert(codec.depth_valid(T, depth));
    assert(value.len <= codec.input_bytes_max);

    var out: Out = .of(pass.writer.sink);

    try sequence_body_put(T, depth, pass, &out, value);

    out.commit();
}

fn leaf_is(comptime T: type) bool {
    return switch (comptime codec.shape_of(T)) {
        .boolean, .float, .integer, .string => true,
        .adapted, .array, .choice, .entry, .enumeration, .map, .object => false,
        .optional, .raw, .sequence => false,
    };
}

inline fn sequence_body_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    out: *Out,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .sequence);
    comptime assert(codec.depth_valid(T, depth));
    assert(value.len <= codec.input_bytes_max);

    const Element = @typeInfo(T).pointer.child;

    if (value.len == 0) {
        try out.literal_put("[]");
    } else {
        try member_value_put(Element, depth, .open, pass, out, &value.*[0]);

        for (value.*[1..]) |*item| try member_value_put(Element, depth, .comma, pass, out, item);

        try out.literal_put("]");
    }
}

fn map_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .map);
    comptime assert(codec.depth_valid(T, depth));
    assert(value.len <= codec.input_bytes_max);

    const Value = @FieldType(@typeInfo(T).pointer.child, "value");

    var out: Out = .of(pass.writer.sink);

    try out.literal_put("{");

    for (value.*, 0..) |*entry, index| {
        codec.enumeration_check(Value, &entry.value) catch |err| {
            out.commit();

            return err;
        };

        if (index > 0) try out.literal_put(",");

        try out.string_put(.none, entry.key);
        try member_value_put(Value, depth, .colon, pass, &out, &entry.value);
    }

    try out.literal_put("}");

    out.commit();
}

fn choice_put(
    comptime T: type,
    comptime depth: u32,
    pass: *const Pass,
    value: *const T,
) Writer.Error!void {
    comptime assert(codec.shape_of(T) == .choice);
    comptime assert(codec.depth_valid(T, depth));

    switch (value.*) {
        inline else => |*payload| {
            const Payload = @TypeOf(payload.*);

            if (Payload == void) {
                var out: Out = .of(pass.writer.sink);

                try out.literal_put("null");

                out.commit();
            } else {
                try value_put(Payload, depth, pass, payload);
            }
        },
    }
}
