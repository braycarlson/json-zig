const std = @import("std");

const number = @import("number.zig");
const region_module = @import("region.zig");
const rename_module = @import("rename.zig");
const index_tokenizer = @import("index_tokenizer.zig");
const string = @import("string.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const FieldAttributes = std.lang.Type.Struct.FieldAttributes;
const KindSet = std.EnumSet(Kind);
const Position = tokenizer_module.Position;
const Region = region_module.Region;
const Rename = rename_module.Rename;
const Syntax = tokenizer_module.Syntax;
const Token = tokenizer_module.Token;
const Tokenizer = tokenizer_module.Tokenizer;
const TokenizerType = tokenizer_module.TokenizerType;
const Writer = writer_module.Writer;

const depth_max = tokenizer_module.depth_max;

const indexed_enabled = std.simd.suggestVectorLength(u8) != null and
    !structural.lanes_narrow;

const input_bytes_max = tokenizer_module.input_bytes_max;
const kind_count = @typeInfo(Kind).@"enum".field_names.len;
const traits_branch_quota: u32 = 1_000_000;
pub const type_depth_max: u32 = depth_max;

comptime {
    assert(type_depth_max >= 16);
    assert(type_depth_max <= depth_max);
    assert(kind_count == 6);
}

pub const CapacityError = Tokenizer.CapacityError || error{RegionFull};
pub const DecodeError = CapacityError || SyntaxError || MismatchError;

pub const DecodeOptions = struct {
    diagnostic: ?*Diagnostic = null,
    unknown_members: UnknownMembers = .ignored,

    pub const UnknownMembers = enum {
        ignored,
        refused,
    };
};

fn DecoderType(comptime syntax: Syntax, comptime indexed: bool) type {
    comptime assert(@sizeOf(TokenizerType(syntax)) == @sizeOf(Tokenizer));
    if (indexed) comptime assert(syntax == .strict);

    return struct {
        region: *Region,
        tokenizer: if (indexed) index_tokenizer.IndexTokenizer else TokenizerType(syntax),
        unknown_members: DecodeOptions.UnknownMembers,
        unmatched: if (indexed) void else []const u8,

        const exact = !indexed;
        const relaxed = syntax == .relaxed;

        fn string_decode(decoder: *@This(), raw: []const u8) DecodeError![]const u8 {
            assert(raw.len <= decoder.tokenizer.input.len);
            assert(decoder.region.used <= decoder.region.top);

            if (string.backslash_free(raw)) return raw;

            const target = try decoder.region.reserve(u8, @intCast(raw.len));

            const text = string.unescape(raw, target) catch |err| switch (err) {
                error.Malformed => return error.Malformed,
                error.Overflow => unreachable,
            };

            assert(text.len < raw.len);

            return text;
        }
    };
}

pub const Diagnostic = struct {
    member: []const u8,
    position: Position,
};

pub const Empty = struct {};

pub const EncodeOptions = struct {
    null_members: NullMembers = .omitted,

    pub const NullMembers = enum {
        emitted,
        omitted,
    };
};

const Kind = enum {
    array,
    boolean,
    null_value,
    number,
    object,
    string,
};

const Member = struct {
    key: []const u8,
    value: Token,
};

pub const MismatchError = error{
    MemberMissing,
    MemberUnknown,
    Mismatch,
};

const Name = struct {
    index: u32,
    text: []const u8,
};

const Names = struct {
    bytes_max: u32,
    entries: []const Name,
    lengths: []const u32,
};

pub const Raw = struct {
    text: []const u8 = "",

    pub const json_shape: Shape = .raw;
};

pub const Shape = enum {
    adapted,
    boolean,
    choice,
    entry,
    enumeration,
    float,
    integer,
    map,
    object,
    optional,
    raw,
    sequence,
    string,
};

pub const SyntaxError = Tokenizer.SyntaxError;

const Traits = struct {
    adapted_errors: type,
    element_bytes_max: u64,
    enumeration_open: bool,
    float: bool,
    height: u32,
    raw: bool,
};

const traits_none: Traits = .{
    .adapted_errors = error{},
    .element_bytes_max = 0,
    .enumeration_open = false,
    .float = false,
    .height = 0,
    .raw = false,
};

pub fn EntryType(comptime Value: type) type {
    return struct {
        key: []const u8,
        value: Value,

        pub const json_shape: Shape = .entry;
    };
}

fn OrderType(comptime Entry: type) type {
    return struct {
        entries: []const Entry,

        fn less(order: @This(), left: u32, right: u32) bool {
            assert(left < order.entries.len);
            assert(right < order.entries.len);

            const left_key = order.entries[left].key;
            const right_key = order.entries[right].key;

            return switch (std.mem.order(u8, left_key, right_key)) {
                .eq => left < right,
                .gt => false,
                .lt => true,
            };
        }
    };
}

fn SeenType(comptime T: type) type {
    if (required_count(T) == 0) return void;
    return std.StaticBitSet(@typeInfo(T).@"struct".field_names.len);
}

pub fn EncodeErrorType(comptime T: type) type {
    const traits = traits_of(T, 0);

    var result = error{WriteFailed} || traits.adapted_errors;

    if (traits.enumeration_open) result = result || error{EnumerationUnrecognized};
    if (traits.float) result = result || error{FloatNonFinite};
    if (traits.raw) result = result || error{ DepthExceeded, RawMalformed };

    return result;
}

pub fn shape_of(comptime T: type) Shape {
    switch (@typeInfo(T)) {
        .bool => return .boolean,
        .@"enum" => |enumeration| {
            if (enumeration.mode == .nonexhaustive) {
                @compileError("the enumeration " ++ @typeName(T) ++
                    " is non-exhaustive; declare an unrecognized member instead");
            }

            return .enumeration;
        },
        .float => return .float,
        .int => return .integer,
        .optional => return .optional,
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("the type " ++ @typeName(T) ++ " is not a slice; use []const " ++
                    @typeName(pointer.child));
            }

            if (!pointer.attrs.@"const") {
                @compileError("the type " ++ @typeName(T) ++ " is a mutable slice; use []const " ++
                    @typeName(pointer.child));
            }

            return slice_shape(T, pointer.child);
        },
        .@"struct" => {
            if (@hasDecl(T, "json_shape")) return T.json_shape;
            return .object;
        },
        .@"union" => |choice| {
            if (choice.tag_type == null) {
                @compileError("the union " ++ @typeName(T) ++ " has no tag");
            }

            return .choice;
        },
        else => @compileError("the type " ++ @typeName(T) ++ " has no JSON shape"),
    }
}

fn slice_shape(comptime T: type, comptime Element: type) Shape {
    if (Element == u8) return .string;

    if (@sizeOf(Element) == 0) {
        @compileError("the type " ++ @typeName(T) ++ " holds elements of zero size");
    }

    if (@alignOf(Element) > region_module.alignment_bytes) {
        @compileError("the type " ++ @typeName(T) ++ " holds elements aligned past " ++
            std.fmt.comptimePrint("{d}", .{region_module.alignment_bytes}) ++ " bytes");
    }

    if (@typeInfo(Element) == .@"struct") {
        if (@hasDecl(Element, "json_shape")) {
            if (Element.json_shape == .entry) return .map;
        }
    }

    return .sequence;
}

pub fn default_of(comptime T: type) T {
    if (comptime !default_exists(T)) {
        @compileError("the type " ++ @typeName(T) ++ " has no JSON default");
    }

    return switch (comptime shape_of(T)) {
        .boolean => false,
        .adapted, .choice, .entry => unreachable,
        .enumeration => .unrecognized,
        .float, .integer => 0,
        .map, .sequence => &.{},
        .object, .raw => .{},
        .optional => null,
        .string => "",
    };
}

fn default_exists(comptime T: type) bool {
    return switch (shape_of(T)) {
        .boolean, .float, .integer, .map, .optional, .raw, .sequence, .string => true,
        .adapted, .choice, .entry => false,
        .enumeration => @hasField(T, "unrecognized"),
        .object => required_count(T) == 0,
    };
}

fn traits_of(comptime T: type, comptime depth: u32) Traits {
    assert(depth_valid(T, depth));

    @setEvalBranchQuota(traits_branch_quota);

    if (T == void) return traits_none;

    var result = traits_none;

    switch (shape_of(T)) {
        .adapted => result = adapted_traits(T, depth),
        .boolean, .integer, .string => {},
        .choice => {
            for (@typeInfo(T).@"union".field_types) |Payload| {
                traits_merge(&result, traits_of(Payload, depth + 1));
            }
        },
        .entry => @compileError("an entry is decoded and encoded only inside a map"),
        .enumeration => result.enumeration_open = @hasField(T, "unrecognized"),
        .float => result.float = true,
        .map => {
            const Entry = @typeInfo(T).pointer.child;

            result = traits_of(@FieldType(Entry, "value"), depth + 1);
            result.element_bytes_max = @max(result.element_bytes_max, @sizeOf(Entry));
            result.height += 1;
        },
        .object => {
            for (@typeInfo(T).@"struct".field_types) |Field| {
                traits_merge(&result, traits_of(Field, depth + 1));
            }

            result.height += 1;
        },
        .optional => result = traits_of(@typeInfo(T).optional.child, depth + 1),
        .raw => result.raw = true,
        .sequence => {
            const Element = @typeInfo(T).pointer.child;

            result = traits_of(Element, depth + 1);
            result.element_bytes_max = @max(result.element_bytes_max, @sizeOf(Element));
            result.height += 1;
        },
    }

    assert(result.height <= type_depth_max);

    return result;
}

fn adapted_traits(comptime T: type, comptime depth: u32) Traits {
    comptime assert(shape_of(T) == .adapted);
    comptime assert(depth_valid(T, depth));

    var result = traits_none;

    if (@hasDecl(T, "json_decode")) {
        result.element_bytes_max = traits_of(WireType(T), depth + 1).element_bytes_max;
    }

    if (@hasDecl(T, "json_encode")) result.adapted_errors = AdaptedErrorType(T);

    assert(result.height == 0);

    return result;
}

fn WireType(comptime T: type) type {
    comptime assert(shape_of(T) == .adapted);

    if (!@hasDecl(T, "json_decode")) {
        @compileError("the type " ++ @typeName(T) ++ " is adapted but declares no json_decode");
    }

    const function = @typeInfo(@TypeOf(T.json_decode)).@"fn";

    if (function.param_types.len != 1) {
        @compileError("the function " ++ @typeName(T) ++ ".json_decode takes " ++
            "one parameter, the value as decode reads it");
    }

    const Return = function.return_type.?;

    const Payload = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => noreturn,
    };

    if (Payload != T) {
        @compileError("the function " ++ @typeName(T) ++ ".json_decode returns " ++
            @typeName(Return) ++ "; return an error union of " ++ @typeName(T));
    }

    return function.param_types[0].?;
}

fn AdaptedErrorType(comptime T: type) type {
    comptime assert(shape_of(T) == .adapted);

    if (!@hasDecl(T, "json_encode")) {
        @compileError("the type " ++ @typeName(T) ++ " is adapted but declares no json_encode");
    }

    const function = @typeInfo(@TypeOf(T.json_encode)).@"fn";
    const expected = [_]?type{ *const T, *Writer };

    if (!std.mem.eql(?type, function.param_types, &expected)) {
        @compileError("the function " ++ @typeName(T) ++ ".json_encode takes " ++
            "(*const " ++ @typeName(T) ++ ", *json.Writer)");
    }

    const Return = function.return_type.?;

    const Payload = switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => noreturn,
    };

    if (Payload != void) {
        @compileError("the function " ++ @typeName(T) ++ ".json_encode returns " ++
            @typeName(Return) ++ "; return an error union of void");
    }

    const Errors = @typeInfo(Return).error_union.error_set;

    if ((Errors || Writer.Error) != Writer.Error) {
        @compileError("the function " ++ @typeName(T) ++ ".json_encode returns errors " ++
            "outside json.Writer.Error");
    }

    return Errors;
}

fn traits_merge(target: *Traits, part: Traits) void {
    assert(target.height <= type_depth_max);
    assert(part.height <= type_depth_max);

    target.* = .{
        .adapted_errors = target.adapted_errors || part.adapted_errors,
        .element_bytes_max = @max(target.element_bytes_max, part.element_bytes_max),
        .enumeration_open = target.enumeration_open or part.enumeration_open,
        .float = target.float or part.float,
        .height = @max(target.height, part.height),
        .raw = target.raw or part.raw,
    };
}

fn depth_valid(comptime T: type, comptime depth: u32) bool {
    comptime assert(depth <= type_depth_max);

    if (depth < type_depth_max) return true;

    @compileError("the type " ++ @typeName(T) ++ " nests deeper than " ++
        std.fmt.comptimePrint("{d}", .{type_depth_max}) ++ " levels or contains itself");
}

pub fn region_bytes_max(comptime T: type, input_bytes: u64) u64 {
    const traits = comptime traits_of(T, 0);
    const weight: u64 = @max(1, 2 * traits.element_bytes_max);

    assert(input_bytes <= input_bytes_max);

    const result = input_bytes * weight + region_module.alignment_bytes - 1;

    assert(result >= input_bytes);

    return result;
}

fn required_count(comptime T: type) u32 {
    var result: u32 = 0;

    for (@typeInfo(T).@"struct".field_attrs) |attributes| {
        if (attributes.default_value_ptr == null) result += 1;
    }

    return result;
}

fn names_check(comptime T: type) void {
    const declared = @hasDecl(T, "json");

    if (!declared) {
        if (!@hasDecl(T, "json_rename")) return;
    }

    if (declared) {
        const names = @typeInfo(@TypeOf(T.json)).@"struct".field_names;

        @setEvalBranchQuota(64 * names.len + 1000);

        for (names) |name| {
            if (!@hasField(T, name)) {
                @compileError("the type " ++ @typeName(T) ++ " names " ++ name ++
                    " in its json declaration, which is not one of its fields");
            }
        }
    }

    names_distinct_check(T);
}

fn names_distinct_check(comptime T: type) void {
    const field_names = field_names_of(T);

    @setEvalBranchQuota(64 * field_names.len * field_names.len + 1000);

    for (field_names, 0..) |left, index| {
        if (!name_listed(T, left)) continue;

        const text = name_of(T, left);

        for (field_names[index + 1 ..]) |right| {
            if (!name_listed(T, right)) continue;

            if (std.mem.eql(u8, text, name_of(T, right))) {
                @compileError("the type " ++ @typeName(T) ++ " gives the members " ++ left ++
                    " and " ++ right ++ " the one JSON name " ++ text);
            }
        }
    }
}

fn name_listed(comptime T: type, comptime field_name: []const u8) bool {
    comptime assert(field_name.len > 0);
    comptime assert(@hasField(T, field_name));

    if (@typeInfo(T) != .@"enum") return true;
    return !std.mem.eql(u8, field_name, "unrecognized");
}

fn name_of(comptime T: type, comptime field_name: []const u8) []const u8 {
    comptime assert(@hasField(T, field_name));

    if (@hasDecl(T, "json")) {
        if (@hasField(@TypeOf(T.json), field_name)) return @field(T.json, field_name);
    }

    if (@hasDecl(T, "json_rename")) return renamed_of(T, field_name);

    return field_name;
}

fn renamed_of(comptime T: type, comptime field_name: []const u8) []const u8 {
    comptime assert(@hasDecl(T, "json_rename"));
    comptime assert(@hasField(T, field_name));

    const Policy = @TypeOf(T.json_rename);

    if (@typeInfo(Policy) == .@"fn") {
        const result: []const u8 = T.json_rename(field_name);

        return result;
    }

    const style = style_of(T);

    @setEvalBranchQuota(64 * field_name.len + 1000);

    var buffer: [2 * field_name.len + 1]u8 = undefined;

    const text = rename_module.rename(style, field_name, &buffer) orelse {
        @compileError("the type " ++ @typeName(T) ++ " renames the non-ASCII member " ++
            field_name ++ " under the " ++ @tagName(style) ++ " style; give it a json entry");
    };

    const result = text[0..text.len].*;

    return &result;
}

fn style_of(comptime T: type) Rename {
    const policy = T.json_rename;
    const Policy = @TypeOf(policy);

    if (Policy == Rename) return policy;

    if (Policy == @TypeOf(.enum_literal)) {
        if (@hasField(Rename, @tagName(policy))) return @field(Rename, @tagName(policy));

        @compileError("the type " ++ @typeName(T) ++ " renames its members by ." ++
            @tagName(policy) ++ ", which is not a json.Rename style");
    }

    @compileError("the type " ++ @typeName(T) ++ " declares json_rename as " ++
        @typeName(Policy) ++ ", which is neither a json.Rename style nor a function of a name");
}

fn field_names_of(comptime T: type) []const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"enum" => |enumeration| enumeration.field_names,
        .@"struct" => |structure| structure.field_names,
        else => @compileError("the type " ++ @typeName(T) ++ " has no JSON names"),
    };
}

fn names_of(comptime T: type) Names {
    const field_names = field_names_of(T);

    @setEvalBranchQuota(64 * field_names.len * field_names.len + 1000);
    names_check(T);

    var entries: [field_names.len]Name = undefined;
    var lengths: [field_names.len]u32 = undefined;
    var count: u32 = 0;
    var lengths_found: u32 = 0;
    var bytes_max: u32 = 1;

    for (field_names, 0..) |name, index| {
        if (@typeInfo(T) == .@"enum") {
            if (std.mem.eql(u8, name, "unrecognized")) continue;
        }

        const text = name_of(T, name);

        entries[count] = .{ .index = index, .text = text };
        count += 1;
        bytes_max = @max(bytes_max, text.len);

        if (std.mem.findScalar(u32, lengths[0..lengths_found], text.len) == null) {
            lengths[lengths_found] = text.len;
            lengths_found += 1;
        }
    }

    const entries_final = entries[0..count].*;
    const lengths_final = lengths[0..lengths_found].*;
    const result: Names = .{
        .bytes_max = bytes_max,
        .entries = &entries_final,
        .lengths = &lengths_final,
    };

    for (result.entries) |entry| assert(name_index(result, false, entry.text).? == entry.index);

    return result;
}

inline fn name_index(comptime names: Names, comptime raw: bool, key: []const u8) ?u32 {
    comptime assert(names.entries.len > 0);
    assert(key.len <= input_bytes_max);

    inline for (names.lengths) |length| {
        if (key.len == length) return name_length_index(names, raw, key[0..length]);
    }

    return null;
}

inline fn name_length_index(
    comptime names: Names,
    comptime raw: bool,
    key: anytype,
) ?u32 {
    comptime assert(names.entries.len > 0);
    comptime assert(@typeInfo(@TypeOf(key)) == .pointer);

    const length = key.len;

    inline for (names.entries) |entry| {
        if (comptime name_matchable(entry.text, length, raw)) {
            if (std.mem.eql(u8, key, entry.text)) return entry.index;
        }
    }

    return null;
}

fn name_matchable(comptime text: []const u8, comptime length: u32, comptime raw: bool) bool {
    comptime assert(text.len <= input_bytes_max);
    comptime assert(length <= input_bytes_max);

    if (text.len != length) return false;
    if (!raw) return true;
    return std.mem.findScalar(u8, text, '\\') == null;
}

const Match = union(enum) {
    field: u32,
    unknown,
};

inline fn name_find(comptime names: Names, key: []const u8) DecodeError!Match {
    comptime assert(names.entries.len > 0);
    assert(key.len <= input_bytes_max);

    if (name_index(names, true, key)) |index| return .{ .field = index };
    if (string.backslash_free(key)) return .unknown;

    var buffer: [names.bytes_max]u8 = undefined;

    const resolved = string.unescape(key, &buffer) catch |err| switch (err) {
        error.Malformed => return error.Malformed,
        error.Overflow => return .unknown,
    };

    const index = name_index(names, false, resolved) orelse return .unknown;

    return .{ .field = index };
}

fn kinds_of(comptime T: type) KindSet {
    if (T == void) return .initOne(.null_value);

    return switch (shape_of(T)) {
        .adapted => kinds_of(WireType(T)),
        .boolean => .initOne(.boolean),
        .choice => choice_kinds(T),
        .entry => @compileError("an entry is decoded only inside a map"),
        .enumeration, .string => .initOne(.string),
        .float, .integer => .initOne(.number),
        .map, .object => .initOne(.object),
        .optional => optional_kinds(T),
        .raw => .full,
        .sequence => .initOne(.array),
    };
}

fn optional_kinds(comptime T: type) KindSet {
    var result = kinds_of(@typeInfo(T).optional.child);

    result.insert(.null_value);

    return result;
}

fn choice_kinds(comptime T: type) KindSet {
    const table = choice_table(T);

    var result: KindSet = .empty;

    for (table, 0..) |slot, index| {
        if (slot != null) result.insert(@fromBackingInt(index));
    }

    return result;
}

fn choice_table(comptime T: type) [kind_count]?u32 {
    const choice = @typeInfo(T).@"union";

    var table: [kind_count]?u32 = @splat(null);
    var raw_index: ?u32 = null;

    for (choice.field_types, choice.field_names, 0..) |Payload, name, index| {
        if (Payload != void) {
            if (shape_of(Payload) == .raw) {
                if (raw_index != null) {
                    @compileError("the union " ++ @typeName(T) ++ " has two Raw variants");
                }

                raw_index = index;

                continue;
            }
        }

        const kinds = kinds_of(Payload);

        for (std.enums.values(Kind)) |kind| {
            if (!kinds.contains(kind)) continue;

            if (table[@backingInt(kind)] != null) {
                @compileError("the union " ++ @typeName(T) ++ " has two variants that claim " ++
                    @tagName(kind) ++ ", one of them " ++ name);
            }

            table[@backingInt(kind)] = index;
        }
    }

    if (raw_index) |index| {
        for (&table) |*slot| slot.* = slot.* orelse index;
    }

    return table;
}

fn null_taken(comptime T: type) bool {
    return switch (shape_of(T)) {
        .adapted => kinds_of(WireType(T)).contains(.null_value),
        .choice => choice_table(T)[@backingInt(Kind.null_value)] != null,
        .raw => true,
        .boolean, .entry, .enumeration, .float, .integer, .map, .object => false,
        .optional, .sequence, .string => false,
    };
}

pub fn decode(
    comptime T: type,
    region: *Region,
    input: []const u8,
    target: *T,
    options: DecodeOptions,
) DecodeError!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(input.len <= input_bytes_max);
    assert(region.used <= region.top);

    if (indexed_enabled) {
        if (indexed_decode(T, region, input, target, options)) return;
    }

    return syntax_decode(DecoderType(.strict, false), T, region, input, target, options);
}

fn indexed_decode(
    comptime T: type,
    region: *Region,
    input: []const u8,
    target: *T,
    options: DecodeOptions,
) bool {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(input.len <= input_bytes_max);
    assert(region.used <= region.top);

    const Decoder = DecoderType(.strict, true);
    const used = region.used;
    const top = region.top;

    var indexer: structural.Indexer = .empty;
    var indices: structural.Indices = undefined;

    var decoder = Decoder{
        .region = region,
        .tokenizer = .init(input, &indexer, &indices),
        .unknown_members = options.unknown_members,
        .unmatched = {},
    };

    document_decode(Decoder, T, &decoder, target) catch {
        region.used = used;
        region.top = top;

        return false;
    };

    assert(region.top == top);
    assert(region.used >= used);

    return true;
}

pub fn decode_relaxed(
    comptime T: type,
    region: *Region,
    input: []const u8,
    target: *T,
    options: DecodeOptions,
) DecodeError!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(input.len <= input_bytes_max);
    assert(region.used <= region.top);

    return syntax_decode(DecoderType(.relaxed, false), T, region, input, target, options);
}

inline fn syntax_decode(
    comptime Decoder: type,
    comptime T: type,
    region: *Region,
    input: []const u8,
    target: *T,
    options: DecodeOptions,
) DecodeError!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(input.len <= input_bytes_max);

    const used = region.used;
    const top = region.top;

    var decoder = Decoder{
        .region = region,
        .tokenizer = .init(input),
        .unknown_members = options.unknown_members,
        .unmatched = undefined,
    };

    document_decode(Decoder, T, &decoder, target) catch |err| {
        region.used = used;
        region.top = top;

        if (options.diagnostic) |diagnostic| {
            const index = failure_index(Decoder, &decoder, err);

            diagnostic.* = .{
                .member = failure_member(Decoder, &decoder, err),
                .position = tokenizer_module.position_of(input, index),
            };
        }

        return err;
    };

    assert(region.top == top);
    assert(region.used >= used);
}

fn failure_index(
    comptime Decoder: type,
    decoder: *const Decoder,
    err: DecodeError,
) u32 {
    assert(@errorName(err).len > 0);
    assert(decoder.tokenizer.index <= decoder.tokenizer.input.len);
    assert(decoder.tokenizer.value_start <= decoder.tokenizer.index);

    const result = switch (err) {
        error.MemberUnknown => decoder.tokenizer.key_start - 1,
        error.Mismatch => decoder.tokenizer.value_start,
        error.DepthExceeded, error.Malformed, error.MemberMissing => decoder.tokenizer.index,
        error.RegionFull => decoder.tokenizer.index,
    };

    assert(result <= decoder.tokenizer.input.len);

    return result;
}

fn failure_member(
    comptime Decoder: type,
    decoder: *const Decoder,
    err: DecodeError,
) []const u8 {
    comptime assert(Decoder.exact);
    assert(@errorName(err).len > 0);

    return switch (err) {
        error.MemberMissing => decoder.unmatched,
        error.MemberUnknown => key_raw_of(decoder.tokenizer.input, decoder.tokenizer.key_start),
        error.DepthExceeded, error.Malformed, error.Mismatch, error.RegionFull => "",
    };
}

fn key_raw_of(input: []const u8, start: u32) []const u8 {
    assert(start > 0);
    assert(start <= input.len);
    assert(input[start - 1] == '"');

    var index = start;

    for (0..input.len - start) |_| {
        assert(index < input.len);

        switch (input[index]) {
            '"' => {
                const result = input[start..index];

                assert(result.len < input.len);

                return result;
            },
            '\\' => index += 2,
            else => index += 1,
        }
    }

    unreachable;
}

fn document_decode(
    comptime Decoder: type,
    comptime T: type,
    decoder: *Decoder,
    target: *T,
) DecodeError!void {
    assert(decoder.tokenizer.input.len <= input_bytes_max);
    assert(decoder.region.used <= decoder.region.top);

    const first = try decoder.tokenizer.next();
    if (first == .end) return error.Malformed;

    try element_decode(Decoder, T, 0, decoder, first, target);

    const last = try decoder.tokenizer.next();
    if (last != .end) return error.Malformed;

    assert(decoder.tokenizer.depth == 0);
}

fn element_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(token != .end);
    assert(token != .key);

    if (token == .null_value) {
        if (comptime !null_taken(T)) return default_assign(T, target);
    }

    try value_decode(Decoder, T, depth, decoder, token, target);
}

fn default_assign(comptime T: type, target: *T) MismatchError!void {
    comptime assert(!null_taken(T));

    switch (comptime shape_of(T)) {
        .map, .sequence => return error.Mismatch,
        .adapted, .boolean, .choice, .entry, .enumeration, .float, .integer, .object => {},
        .optional, .raw, .string => {},
    }

    if (comptime default_exists(T)) {
        target.* = default_of(T);
    } else {
        return error.Mismatch;
    }
}

fn value_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(token != .end);
    assert(token != .key);

    switch (comptime shape_of(T)) {
        .adapted => try adapted_decode(Decoder, T, depth + 1, decoder, token, target),
        .boolean => target.* = try boolean_of(token),
        .choice => try choice_decode(Decoder, T, depth + 1, decoder, token, target),
        .entry => @compileError("an entry is decoded only inside a map"),
        .enumeration => target.* = try enumeration_of(T, token),
        .float => target.* = try float_of(Decoder.relaxed, T, token),
        .integer => target.* = try integer_of(T, token),
        .map => try map_decode(Decoder, T, depth + 1, decoder, token, target),
        .object => try object_decode(Decoder, T, depth + 1, decoder, token, target),
        .optional => try optional_decode(Decoder, T, depth + 1, decoder, token, target),
        .raw => try raw_decode(Decoder, T, decoder, token, target),
        .sequence => try sequence_decode(Decoder, T, depth + 1, decoder, token, target),
        .string => {
            comptime sentinel_check(T);

            target.* = try decoder.string_decode(try string_of(token));
        },
    }
}

fn adapted_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .adapted);
    comptime assert(depth_valid(T, depth));
    assert(token != .end);
    assert(token != .key);

    const Wire = WireType(T);
    const start = decoder.tokenizer.value_start;

    var wire: Wire = undefined;

    try value_decode(Decoder, Wire, depth + 1, decoder, token, &wire);

    target.* = T.json_decode(wire) catch {
        decoder.tokenizer.value_start = start;

        return error.Mismatch;
    };
}

fn sentinel_check(comptime T: type) void {
    const pointer = @typeInfo(T).pointer;
    if (pointer.sentinel_ptr == null) return;

    @compileError("the type " ++ @typeName(T) ++ " has a sentinel that decode cannot write; " ++
        "use []const " ++ @typeName(pointer.child));
}

fn optional_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .optional);
    comptime assert(depth_valid(T, depth));
    assert(token != .end);

    const Child = @typeInfo(T).optional.child;

    if (token == .null_value) {
        target.* = null;

        return;
    }

    var child: Child = undefined;

    try value_decode(Decoder, Child, depth + 1, decoder, token, &child);

    target.* = child;
}

fn object_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(token != .end);
    assert(token != .null_value);

    if (token != .object_begin) return error.Mismatch;

    comptime names_check(T);
    defaults_assign(T, target);

    var seen: SeenType(T) = if (comptime required_count(T) > 0) .empty else {};

    for (0..decoder.tokenizer.input.len + 1) |_| {
        const key = switch (try decoder.tokenizer.next()) {
            .key => |text| text,
            .object_end => {
                if (!Decoder.exact) return required_check(T, &seen);

                return required_check(T, &seen) catch |err| {
                    if (comptime required_count(T) > 0) decoder.unmatched = missing_name(T, &seen);

                    return err;
                };
            },
            else => return error.Malformed,
        };

        const value = try decoder.tokenizer.next();
        const member = Member{ .key = key, .value = value };

        try member_decode(Decoder, T, depth, decoder, member, target, &seen);
    }

    return error.Malformed;
}

fn defaults_assign(comptime T: type, target: *T) void {
    comptime assert(shape_of(T) == .object);

    const structure = @typeInfo(T).@"struct";

    inline for (structure.field_names, structure.field_attrs, 0..) |name, attributes, index| {
        const Field = structure.field_types[index];

        if (comptime attributes.defaultValue(Field)) |default| @field(target, name) = default;
    }
}

fn required_check(comptime T: type, seen: *const SeenType(T)) MismatchError!void {
    comptime assert(shape_of(T) == .object);

    if (comptime required_count(T) == 0) return;

    assert(seen.count() <= required_count(T));

    if (seen.count() < required_count(T)) return error.MemberMissing;
}

fn missing_name(comptime T: type, seen: *const SeenType(T)) []const u8 {
    comptime assert(required_count(T) > 0);
    assert(seen.count() < required_count(T));

    const field_names = @typeInfo(T).@"struct".field_names;

    inline for (field_names, 0..) |name, index| {
        if (comptime field_required(T, index)) {
            if (!seen.isSet(index)) return comptime name_of(T, name);
        }
    }

    unreachable;
}

fn member_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    member: Member,
    target: *T,
    seen: *SeenType(T),
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(member.value != .end);
    assert(member.key.len <= decoder.tokenizer.input.len);

    if (comptime @typeInfo(T).@"struct".field_names.len > 0) {
        return field_find_decode(Decoder, T, depth, decoder, member, target, seen);
    }

    try member_skip(Decoder, T, decoder, member.value);
}

inline fn member_skip(
    comptime Decoder: type,
    comptime T: type,
    decoder: *Decoder,
    value: Token,
) DecodeError!void {
    comptime assert(shape_of(T) == .object);
    assert(value != .end);

    if (T != Empty) {
        if (decoder.unknown_members == .refused) return error.MemberUnknown;
    }

    try decoder.tokenizer.skip(value);
}

fn field_find_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    member: Member,
    target: *T,
    seen: *SeenType(T),
) DecodeError!void {
    comptime assert(depth_valid(T, depth));
    assert(member.value != .end);

    const field_names = @typeInfo(T).@"struct".field_names;
    const names = comptime names_of(T);
    const value = member.value;
    const index = switch (try name_find(names, member.key)) {
        .field => |index| index,
        .unknown => return member_skip(Decoder, T, decoder, value),
    };

    switch (index) {
        inline 0...field_names.len - 1 => |field_index| {
            try field_decode(Decoder, T, field_index, depth, decoder, value, target);

            if (comptime required_count(T) > 0) {
                if (comptime field_required(T, field_index)) seen.set(field_index);
            }
        },
        else => unreachable,
    }
}

fn field_required(comptime T: type, comptime index: usize) bool {
    comptime assert(index < @typeInfo(T).@"struct".field_names.len);

    return @typeInfo(T).@"struct".field_attrs[index].default_value_ptr == null;
}

fn field_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime index: usize,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(index < @typeInfo(T).@"struct".field_names.len);
    comptime assert(depth_valid(T, depth));
    assert(token != .end);
    assert(token != .key);

    const structure = @typeInfo(T).@"struct";
    const Field = structure.field_types[index];
    const field = &@field(target, structure.field_names[index]);

    if (token == .null_value) {
        if (comptime !null_taken(Field)) return field_null_assign(T, index, field);
    }

    try value_decode(Decoder, Field, depth + 1, decoder, token, field);
}

fn field_null_assign(
    comptime T: type,
    comptime index: usize,
    field: *@typeInfo(T).@"struct".field_types[index],
) MismatchError!void {
    const structure = @typeInfo(T).@"struct";

    comptime assert(index < structure.field_names.len);

    const Field = structure.field_types[index];

    if (comptime structure.field_attrs[index].defaultValue(Field)) |default| {
        field.* = default;
    } else if (comptime shape_of(Field) == .optional) {
        field.* = null;
    } else {
        return error.Mismatch;
    }
}

fn sequence_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .sequence);
    comptime assert(depth_valid(T, depth));
    assert(token != .null_value);

    const Element = @typeInfo(T).pointer.child;

    comptime sentinel_check(T);

    if (token != .array_begin) return error.Mismatch;

    const stack_mark = decoder.region.mark();
    var count: u32 = 0;

    for (0..decoder.tokenizer.input.len + 1) |_| {
        const element = try decoder.tokenizer.next();
        if (element == .array_end) break;

        const item = try decoder.region.push(Element);

        try element_decode(Decoder, Element, depth + 1, decoder, element, item);

        count += 1;
    } else return error.Malformed;

    target.* = try decoder.region.take(Element, stack_mark, count);
}

fn map_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .map);
    comptime assert(depth_valid(T, depth));
    assert(token != .null_value);

    const Entry = @typeInfo(T).pointer.child;
    const Value = @FieldType(Entry, "value");

    comptime sentinel_check(T);

    if (token != .object_begin) return error.Mismatch;

    const stack_mark = decoder.region.mark();
    var count: u32 = 0;

    for (0..decoder.tokenizer.input.len + 1) |_| {
        const key = switch (try decoder.tokenizer.next()) {
            .key => |text| text,
            .object_end => break,
            else => return error.Malformed,
        };

        const entry = try decoder.region.push(Entry);

        entry.key = try decoder.string_decode(key);

        const value = try decoder.tokenizer.next();

        try element_decode(Decoder, Value, depth + 1, decoder, value, &entry.value);

        count += 1;
    } else return error.Malformed;

    const entries = try decoder.region.take(Entry, stack_mark, count);

    target.* = try entries_deduplicate(Entry, decoder.region, entries);
}

fn entries_deduplicate(
    comptime Entry: type,
    region: *Region,
    entries: []Entry,
) CapacityError![]Entry {
    comptime assert(shape_of(Entry) == .entry);
    assert(entries.len <= input_bytes_max);

    if (entries.len < 2) return entries;

    const used = region.used;
    defer region.used = used;

    const order = try region.reserve(u32, @intCast(entries.len));

    for (order, 0..) |*slot, index| slot.* = @intCast(index);

    std.sort.pdq(u32, order, OrderType(Entry){ .entries = entries }, OrderType(Entry).less);

    var survivor_count: u32 = 0;
    var run_start: u32 = 0;

    for (1..order.len + 1) |position| {
        if (position < order.len) {
            const key = entries[order[position]].key;
            if (std.mem.eql(u8, key, entries[order[run_start]].key)) continue;
        }

        const first = order[run_start];

        entries[first].value = entries[order[position - 1]].value;
        order[survivor_count] = first;
        survivor_count += 1;
        run_start = @intCast(position);
    }

    assert(survivor_count >= 1);
    assert(survivor_count <= entries.len);

    return entries_compact(Entry, entries, order[0..survivor_count]);
}

fn entries_compact(comptime Entry: type, entries: []Entry, survivors: []u32) []Entry {
    comptime assert(shape_of(Entry) == .entry);
    assert(survivors.len <= entries.len);

    if (survivors.len == entries.len) return entries;

    std.sort.pdq(u32, survivors, {}, std.sort.asc(u32));

    for (survivors, 0..) |index, position| {
        assert(index >= position);

        entries[position] = entries[index];
    }

    return entries[0..survivors.len];
}

fn choice_decode(
    comptime Decoder: type,
    comptime T: type,
    comptime depth: u32,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .choice);
    comptime assert(depth_valid(T, depth));
    assert(token != .end);
    assert(token != .key);

    const choice = @typeInfo(T).@"union";
    const table = comptime choice_table(T);
    const index = table[@backingInt(kind_of(token))] orelse return error.Mismatch;

    switch (index) {
        inline 0...choice.field_names.len - 1 => |variant_index| {
            const name = choice.field_names[variant_index];
            const Payload = choice.field_types[variant_index];

            if (Payload == void) {
                assert(token == .null_value);

                target.* = @unionInit(T, name, {});
            } else {
                target.* = @unionInit(T, name, undefined);

                const payload = &@field(target.*, name);

                try value_decode(Decoder, Payload, depth + 1, decoder, token, payload);
            }
        },
        else => unreachable,
    }
}

fn kind_of(token: Token) Kind {
    assert(token != .end);
    assert(token != .key);

    return switch (token) {
        .array_begin => .array,
        .boolean => .boolean,
        .null_value => .null_value,
        .number => .number,
        .object_begin => .object,
        .string => .string,
        .array_end, .end, .key, .object_end => unreachable,
    };
}

fn raw_decode(
    comptime Decoder: type,
    comptime T: type,
    decoder: *Decoder,
    token: Token,
    target: *T,
) DecodeError!void {
    comptime assert(shape_of(T) == .raw);
    assert(token != .end);
    assert(token != .key);

    const start = decoder.tokenizer.value_start;

    try decoder.tokenizer.skip(token);

    const end = decoder.tokenizer.index;

    assert(start < end);
    assert(end <= decoder.tokenizer.input.len);

    target.* = .{ .text = decoder.tokenizer.input[start..end] };
}

fn boolean_of(token: Token) DecodeError!bool {
    assert(token != .end);
    assert(token != .null_value);

    return switch (token) {
        .boolean => |value| value,
        else => error.Mismatch,
    };
}

fn string_of(token: Token) DecodeError![]const u8 {
    assert(token != .end);
    assert(token != .null_value);

    return switch (token) {
        .string => |text| text,
        else => error.Mismatch,
    };
}

fn integer_of(comptime T: type, token: Token) DecodeError!T {
    comptime assert(@typeInfo(T) == .int);
    assert(token != .null_value);

    const text = switch (token) {
        .number => |text| text,
        else => return error.Mismatch,
    };

    return std.fmt.parseInt(T, text, 10) catch error.Mismatch;
}

fn float_of(comptime relaxed: bool, comptime T: type, token: Token) DecodeError!T {
    comptime assert(@typeInfo(T) == .float);
    assert(token != .null_value);

    const text = switch (token) {
        .number => |text| text,
        else => return error.Mismatch,
    };

    const result = std.fmt.parseFloat(T, text) catch return error.Mismatch;

    if (relaxed) {
        if (number.non_finite_is(text)) return result;
    }

    if (!std.math.isFinite(result)) return error.Mismatch;
    return result;
}

fn enumeration_of(comptime T: type, token: Token) DecodeError!T {
    comptime assert(@typeInfo(T) == .@"enum");
    assert(token != .null_value);

    const raw = try string_of(token);
    const field_names = @typeInfo(T).@"enum".field_names;
    const names = comptime names_of(T);
    const index = switch (try name_find(names, raw)) {
        .field => |index| index,
        .unknown => return enumeration_unknown(T),
    };

    switch (index) {
        inline 0...field_names.len - 1 => |field_index| return @field(T, field_names[field_index]),
        else => unreachable,
    }
}

fn enumeration_unknown(comptime T: type) MismatchError!T {
    comptime assert(@typeInfo(T) == .@"enum");

    if (comptime @hasField(T, "unrecognized")) {
        return .unrecognized;
    } else {
        return error.Mismatch;
    }
}

pub fn encode(
    comptime T: type,
    writer: *Writer,
    value: *const T,
    options: EncodeOptions,
) EncodeErrorType(T)!void {
    const height = comptime traits_of(T, 0).height;

    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    comptime assert(height <= depth_max);
    assert(!writer.string_open);
    assert(!writer.done);
    assert(writer.depth + height <= depth_max);

    value_encode(T, 0, writer, value, &options) catch |err| return @errorCast(err);
}

fn value_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(depth_valid(T, depth));
    assert(!writer.string_open);

    switch (comptime shape_of(T)) {
        .adapted => try adapted_encode(T, writer, value),
        .boolean => try writer.boolean(value.*),
        .choice => try choice_encode(T, depth + 1, writer, value, options),
        .entry => @compileError("an entry is encoded only inside a map"),
        .enumeration => try writer.string(try enumeration_text(T, value)),
        .float => try float_encode(T, writer, value),
        .integer => try integer_encode(T, writer, value),
        .map => try map_encode(T, depth + 1, writer, value, options),
        .object => try object_encode(T, depth + 1, writer, value, options),
        .optional => try optional_encode(T, depth + 1, writer, value, options),
        .raw => try raw_encode(T, writer, value),
        .sequence => try sequence_encode(T, depth + 1, writer, value, options),
        .string => try writer.string(value.*),
    }
}

fn adapted_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(shape_of(T) == .adapted);
    assert(!writer.string_open);
    assert(!writer.done);

    comptime assert(@typeInfo(AdaptedErrorType(T)) == .error_set);

    const depth = writer.depth;
    const keyed = writer.frame == .object_value;

    try T.json_encode(value, writer);

    assert(writer.depth == depth);
    assert(!writer.string_open);
    if (depth == 0) assert(writer.done);
    if (keyed) assert(writer.frame == .object_members);
}

fn enumeration_text(comptime T: type, value: *const T) Writer.ValueError![]const u8 {
    comptime assert(@typeInfo(T) == .@"enum");
    comptime names_check(T);

    switch (value.*) {
        inline else => |tag| {
            if (comptime std.mem.eql(u8, @tagName(tag), "unrecognized")) {
                return error.EnumerationUnrecognized;
            } else {
                return comptime name_of(T, @tagName(tag));
            }
        },
    }
}

fn enumeration_check(comptime T: type, value: *const T) Writer.ValueError!void {
    switch (comptime shape_of(T)) {
        .enumeration => {
            if (comptime @hasField(T, "unrecognized")) {
                if (value.* == .unrecognized) return error.EnumerationUnrecognized;
            }
        },
        .optional => {
            const Child = @typeInfo(T).optional.child;
            if (comptime shape_of(Child) != .enumeration) return;
            if (comptime !@hasField(Child, "unrecognized")) return;

            if (value.*) |child| {
                if (child == .unrecognized) return error.EnumerationUnrecognized;
            }
        },
        .adapted, .boolean, .choice, .entry, .float, .integer, .map, .object, .raw => {},
        .sequence, .string => {},
    }
}

fn float_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(@typeInfo(T) == .float);
    assert(!writer.string_open);

    if (@bitSizeOf(T) > 64) @compileError("the float type " ++ @typeName(T) ++ " is too wide");

    if (!std.math.isFinite(value.*)) return writer.float(@floatCast(value.*));

    try writer_module.float_finite_write(writer, T, value.*);
}

fn integer_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(@typeInfo(T) == .int);
    assert(!writer.string_open);

    const integer = @typeInfo(T).int;

    if (integer.bits > 64) @compileError("the integer type " ++ @typeName(T) ++ " is too wide");

    switch (integer.signedness) {
        .signed => try writer.integer(value.*),
        .unsigned => try writer.unsigned(value.*),
    }
}

fn optional_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .optional);
    comptime assert(depth_valid(T, depth));

    const Child = @typeInfo(T).optional.child;

    if (value.*) |*child| {
        try value_encode(Child, depth + 1, writer, child, options);
    } else {
        try writer.null_value();
    }
}

fn raw_encode(comptime T: type, writer: *Writer, value: *const T) Writer.Error!void {
    comptime assert(shape_of(T) == .raw);
    assert(value.text.len <= input_bytes_max);

    if (value.text.len == 0) return writer.null_value();

    try writer.raw(value.text);
}

fn object_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .object);
    comptime assert(depth_valid(T, depth));
    comptime names_check(T);

    const structure = @typeInfo(T).@"struct";

    try writer.object_begin();

    inline for (structure.field_names, structure.field_types, 0..) |name, Field, index| {
        if (!member_omitted(T, index, value, options)) {
            const field = &@field(value, name);

            try enumeration_check(Field, field);
            try key_encode(comptime name_of(T, name), writer);
            try value_encode(Field, depth + 1, writer, field, options);
        }
    }

    try writer.object_end();
}

fn key_encode(comptime name: []const u8, writer: *Writer) std.Io.Writer.Error!void {
    comptime assert(name.len <= input_bytes_max);
    assert(!writer.string_open);

    const quoted = "\"" ++ name ++ "\"";

    if (comptime !string.verbatim_is(name)) return writer.key(name);

    if (comptime quoted.len + 2 > writer_module.KeyMember.length_max) {
        return writer_module.key_escaped_write(writer, quoted, true);
    }

    const member = comptime writer_module.KeyMember.of(quoted);

    try writer_module.key_member_write(writer, &member);
}

fn member_omitted(
    comptime T: type,
    comptime index: usize,
    value: *const T,
    options: *const EncodeOptions,
) bool {
    const structure = @typeInfo(T).@"struct";

    comptime assert(index < structure.field_names.len);

    if (options.null_members == .emitted) return false;
    if (comptime structure.field_attrs[index].default_value_ptr == null) return false;

    return switch (comptime shape_of(structure.field_types[index])) {
        .optional => @field(value, structure.field_names[index]) == null,
        .raw => @field(value, structure.field_names[index]).text.len == 0,
        .adapted, .boolean, .choice, .entry, .enumeration, .float, .integer, .map => false,
        .object, .sequence, .string => false,
    };
}

const sequence_encode = if (structural.functions_aligned)
    sequence_encode_aligned
else
    sequence_encode_unaligned;

fn sequence_encode_aligned(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) align(64) Writer.Error!void {
    comptime assert(shape_of(T) == .sequence);
    comptime assert(depth_valid(T, depth));
    assert(value.len <= input_bytes_max);

    return sequence_encode_body(T, depth, writer, value, options);
}

fn sequence_encode_unaligned(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .sequence);
    comptime assert(depth_valid(T, depth));
    assert(value.len <= input_bytes_max);

    return sequence_encode_body(T, depth, writer, value, options);
}

inline fn sequence_encode_body(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .sequence);
    comptime assert(depth_valid(T, depth));
    assert(value.len <= input_bytes_max);

    const Element = @typeInfo(T).pointer.child;

    try writer.array_begin();

    for (value.*) |*item| try value_encode(Element, depth + 1, writer, item, options);

    try writer.array_end();
}

fn map_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .map);
    comptime assert(depth_valid(T, depth));
    assert(value.len <= input_bytes_max);

    const Value = @FieldType(@typeInfo(T).pointer.child, "value");

    try writer.object_begin();

    for (value.*) |*entry| {
        try enumeration_check(Value, &entry.value);
        try writer.key(entry.key);
        try value_encode(Value, depth + 1, writer, &entry.value, options);
    }

    try writer.object_end();
}

fn choice_encode(
    comptime T: type,
    comptime depth: u32,
    writer: *Writer,
    value: *const T,
    options: *const EncodeOptions,
) Writer.Error!void {
    comptime assert(shape_of(T) == .choice);
    comptime assert(depth_valid(T, depth));

    switch (value.*) {
        inline else => |*payload| {
            const Payload = @TypeOf(payload.*);

            if (Payload == void) {
                try writer.null_value();
            } else {
                try value_encode(Payload, depth + 1, writer, payload, options);
            }
        },
    }
}

const testing = std.testing;

const test_region_bytes: u32 = 64 * 1024;
const test_decode_options: DecodeOptions = .{ .diagnostic = null };
const test_encode_options: EncodeOptions = .{ .null_members = .omitted };

const test_writer_options: Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

const TestProtocol = enum {
    sctp,
    tcp,
    udp,
    unrecognized,

    pub const json = .{ .sctp = "sctp", .tcp = "tcp", .udp = "udp" };
};

const TestPort = struct {
    port_private: ?u16 = null,
    port_public: ?u16 = null,
    protocol: ?TestProtocol = null,

    pub const json = .{
        .port_private = "PrivatePort",
        .port_public = "PublicPort",
        .protocol = "Type",
    };
};

const TestContainer = struct {
    created: ?i64 = null,
    detail: ?Raw = null,
    id: ?[]const u8 = null,
    labels: ?[]const EntryType([]const u8) = null,
    names: ?[]const []const u8 = null,
    ports: ?[]const TestPort = null,
    processes: ?[]const []const []const u8 = null,
    ratio: ?f64 = null,
    running: ?bool = null,
    volumes: ?[]const EntryType(Empty) = null,

    pub const json = .{
        .created = "Created",
        .detail = "Detail",
        .id = "Id",
        .labels = "Labels",
        .names = "Names",
        .ports = "Ports",
        .processes = "Processes",
        .ratio = "Ratio",
        .running = "Running",
        .volumes = "Volumes",
    };
};

const TestValue = union(enum) {
    count: i64,
    flag: bool,
    label: []const u8,
    list: []const u32,
    none,
    record: TestPort,
};

const TestLoose = union(enum) {
    count: u32,
    other: Raw,
};

const TestTicket = struct {
    id: u64,
    owner: ?[]const u8,
    port: u16 = 8080,
    state: TestValue,

    pub const json = .{ .owner = "Owner" };
};

const TestColor = enum {
    member_00,
    member_01,
    member_02,
    member_03,
    member_04,
    member_05,
    member_06,
    member_07,
    member_08,
    member_09,
    member_10,
    member_11,
    member_12,
    member_13,
    member_14,
    member_15,
    member_16,
    member_17,
    member_18,
    member_19,
    member_20,
    member_21,
    member_22,
    member_23,
    member_24,
    member_25,
    member_26,
    member_27,
    member_28,
    member_29,
    member_30,
    member_31,

    pub const json = .{
        .member_00 = "Member00",
        .member_01 = "Member01",
        .member_02 = "Member02",
        .member_03 = "Member03",
        .member_04 = "Member04",
        .member_05 = "Member05",
        .member_06 = "Member06",
        .member_07 = "Member07",
        .member_08 = "Member08",
        .member_09 = "Member09",
        .member_10 = "Member10",
        .member_11 = "Member11",
        .member_12 = "Member12",
        .member_13 = "Member13",
        .member_14 = "Member14",
        .member_15 = "Member15",
        .member_16 = "Member16",
        .member_17 = "Member17",
        .member_18 = "Member18",
        .member_19 = "Member19",
        .member_20 = "Member20",
        .member_21 = "Member21",
        .member_22 = "Member22",
        .member_23 = "Member23",
        .member_24 = "Member24",
        .member_25 = "Member25",
        .member_26 = "Member26",
        .member_27 = "Member27",
        .member_28 = "Member28",
        .member_29 = "Member29",
        .member_30 = "Member30",
        .member_31 = "Member31",
    };
};

const TestWide = struct {
    color: TestColor = .member_00,
    field_00: u8 = 0,
    field_01: u8 = 1,
    field_02: u8 = 2,
    field_03: u8 = 3,
    field_04: u8 = 4,
    field_05: u8 = 5,
    field_06: u8 = 6,
    field_07: u8 = 7,
    field_08: u8 = 8,
    field_09: u8 = 9,
    field_10: u8 = 10,
    field_11: u8 = 11,
    field_12: u8 = 12,
    field_13: u8 = 13,
    field_14: u8 = 14,
    field_15: u8 = 15,
    field_16: u8 = 16,
    field_17: u8 = 17,
    field_18: u8 = 18,
    field_19: u8 = 19,
    field_20: u8 = 20,
    field_21: u8 = 21,
    field_22: u8 = 22,
    field_23: u8 = 23,
    field_24: u8 = 24,
    field_25: u8 = 25,
    field_26: u8 = 26,
    field_27: u8 = 27,
    field_28: u8 = 28,
    field_29: u8 = 29,
    field_30: u8 = 30,
    field_31: u8 = 31,

    pub const json = .{
        .field_00 = "Field00",
        .field_01 = "Field01",
        .field_02 = "Field02",
        .field_03 = "Field03",
        .field_04 = "Field04",
        .field_05 = "Field05",
        .field_06 = "Field06",
        .field_07 = "Field07",
        .field_08 = "Field08",
        .field_09 = "Field09",
        .field_10 = "Field10",
        .field_11 = "Field11",
        .field_12 = "Field12",
        .field_13 = "Field13",
        .field_14 = "Field14",
        .field_15 = "Field15",
        .field_16 = "Field16",
        .field_17 = "Field17",
        .field_18 = "Field18",
        .field_19 = "Field19",
        .field_20 = "Field20",
        .field_21 = "Field21",
        .field_22 = "Field22",
        .field_23 = "Field23",
        .field_24 = "Field24",
        .field_25 = "Field25",
        .field_26 = "Field26",
        .field_27 = "Field27",
        .field_28 = "Field28",
        .field_29 = "Field29",
        .field_30 = "Field30",
        .field_31 = "Field31",
    };
};

const TestRegion = struct {
    buffer: [test_region_bytes]u8 align(region_module.alignment_bytes),
    region: Region,

    fn init(test_region: *TestRegion) void {
        assert(test_region.buffer.len == test_region_bytes);

        test_region.region = .init(&test_region.buffer);

        assert(test_region.region.used == 0);
    }
};

const TestSink = struct {
    buffer: [1024]u8,
    sink: std.Io.Writer,
    writer: Writer,

    fn init(test_sink: *TestSink, options: Writer.Options) void {
        assert(options.indent >= 1);
        assert(test_sink.buffer.len > 0);

        test_sink.sink = .fixed(&test_sink.buffer);
        test_sink.writer = .init(&test_sink.sink, options);
    }
};

fn test_region_create() !*TestRegion {
    const result = try testing.allocator.create(TestRegion);

    result.init();

    assert(result.region.used == 0);

    return result;
}

fn test_encoded(
    comptime T: type,
    test_sink: *TestSink,
    value: *const T,
    options: *const EncodeOptions,
) ![]const u8 {
    assert(test_sink.buffer.len > 0);

    test_sink.init(test_writer_options);

    try encode(T, &test_sink.writer, value, options.*);

    test_sink.writer.finish();

    return test_sink.sink.buffered();
}

test "a document decodes into the model and unknown members are skipped" {
    const input =
        \\{"Id": "8dfafdbc3a40", "Names": ["/boring_feynman"], "Created": 1367854155,
        \\ "Unknown": {"Nested": [1, 2, {"Deep": null}]}, "Running": true, "Ratio": 0.25,
        \\ "Ports": [{"PrivatePort": 2222, "PublicPort": 3333, "Type": "tcp"},
        \\ {"PrivatePort": 80, "Type": "quic"}], "Labels": {"com.example.vendor": "Acme é"},
        \\ "Processes": [["root", "13642"], []], "Detail": {"a": [true]},
        \\ "Volumes": {"/data": {}}}
    ;

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var container: TestContainer = undefined;

    try decode(TestContainer, &test_region.region, input, &container, test_decode_options);

    try testing.expectEqualStrings("8dfafdbc3a40", container.id.?);
    try testing.expectEqualStrings("/boring_feynman", container.names.?[0]);
    try testing.expectEqual(@as(i64, 1367854155), container.created.?);
    try testing.expect(container.running.?);
    try testing.expectEqual(@as(f64, 0.25), container.ratio.?);
    try testing.expectEqual(@as(usize, 2), container.ports.?.len);
    try testing.expectEqual(@as(u16, 3333), container.ports.?[0].port_public.?);
    try testing.expectEqual(TestProtocol.tcp, container.ports.?[0].protocol.?);
    try testing.expectEqual(@as(?u16, null), container.ports.?[1].port_public);
    try testing.expectEqual(TestProtocol.unrecognized, container.ports.?[1].protocol.?);
    try testing.expectEqualStrings("com.example.vendor", container.labels.?[0].key);
    try testing.expectEqualStrings("Acme \u{e9}", container.labels.?[0].value);
    try testing.expectEqualStrings("13642", container.processes.?[0][1]);
    try testing.expectEqual(@as(usize, 0), container.processes.?[1].len);
    try testing.expectEqualStrings("{\"a\": [true]}", container.detail.?.text);
    try testing.expectEqualStrings("/data", container.volumes.?[0].key);
    try testing.expectEqual(test_region_bytes, @backingInt(test_region.region.mark()));
}

test "escaped member names and enumeration values still match their fields" {
    const input =
        \\{"\u0049d": "x", "Run\u006eing": true, "Ports": [{"\u0054ype": "\u0074cp"}]}
    ;

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var container: TestContainer = undefined;

    try decode(TestContainer, &test_region.region, input, &container, test_decode_options);

    try testing.expectEqualStrings("x", container.id.?);
    try testing.expect(container.running.?);
    try testing.expectEqual(TestProtocol.tcp, container.ports.?[0].protocol.?);
}

test "ragged nested arrays keep their order through the decoding stack" {
    const input = "[[1, 2, 3], [], [4], [5, 6, 7, 8, 9], [10, 11]]";

    const expected = [_][]const u32{
        &.{ 1, 2, 3 },
        &.{},
        &.{4},
        &.{ 5, 6, 7, 8, 9 },
        &.{ 10, 11 },
    };

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var rows: []const []const u32 = undefined;

    try decode([]const []const u32, &test_region.region, input, &rows, test_decode_options);

    try testing.expectEqual(expected.len, rows.len);

    for (expected, rows) |row_expected, row| try testing.expectEqualSlices(u32, row_expected, row);

    try testing.expectEqual(test_region_bytes, @backingInt(test_region.region.mark()));
}

test "null and absent members leave the defaults in place" {
    const input =
        \\{"Id": null, "Names": null, "Ports": [null, {"Type": null}]}
    ;

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var container: TestContainer = undefined;

    try decode(TestContainer, &test_region.region, input, &container, test_decode_options);

    try testing.expectEqual(@as(?[]const u8, null), container.id);
    try testing.expectEqual(@as(?[]const []const u8, null), container.names);
    try testing.expectEqual(@as(?bool, null), container.running);
    try testing.expectEqual(@as(usize, 2), container.ports.?.len);
    try testing.expectEqual(@as(?TestProtocol, null), container.ports.?[0].protocol);
    try testing.expectEqual(@as(?TestProtocol, null), container.ports.?[1].protocol);
}

test "a member of the wrong type is a mismatch rather than a silent default" {
    const inputs = [_][]const u8{
        "{\"Created\": \"yesterday\"}",
        "{\"Running\": 1}",
        "{\"Names\": \"one\"}",
        "{\"Ports\": [{\"PrivatePort\": 70000}]}",
        "{\"Labels\": [\"a\"]}",
        "{\"Ratio\": 1e400}",
        "[]",
    };

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    for (inputs) |input| {
        test_region.init();

        var container: TestContainer = undefined;

        const decoded = decode(TestContainer, &test_region.region, input, &container, .{
            .diagnostic = null,
        });

        try testing.expectError(error.Mismatch, decoded);
    }
}

const TestFailure = struct {
    column: u32,
    err: DecodeError,
    member: []const u8 = "",
};

fn test_failure_expect(
    comptime T: type,
    input: []const u8,
    options: DecodeOptions,
    expected: TestFailure,
) !void {
    assert(input.len > 0);
    assert(options.diagnostic == null);
    assert(@errorName(expected.err).len > 0);
    assert(expected.column >= 1);

    var buffer: [512]u8 = undefined;
    var region: Region = .init(&buffer);
    var diagnostic: Diagnostic = undefined;
    var target: T = undefined;
    var traced = options;

    traced.diagnostic = &diagnostic;

    const position: Position = .{ .line = 1, .column = expected.column };

    try testing.expectError(expected.err, decode(T, &region, input, &target, traced));
    try testing.expectEqual(position, diagnostic.position);
    try testing.expectEqualStrings(expected.member, diagnostic.member);
}

test "null into a slice that is not optional is a mismatch at the null" {
    const Lists = []const []const u16;
    const Table = []const EntryType([]const u16);

    const list_null: TestFailure = .{ .column = 7, .err = error.Mismatch };
    const table_null: TestFailure = .{ .column = 17, .err = error.Mismatch };
    const root_null: TestFailure = .{ .column = 1, .err = error.Mismatch };
    const table_input = "{\"a\": [1], \"b\": null}";

    try test_failure_expect(Lists, "[[1], null]", test_decode_options, list_null);
    try test_failure_expect(Table, table_input, test_decode_options, table_null);
    try test_failure_expect([]const u16, "null", test_decode_options, root_null);

    var buffer: [512]u8 = undefined;
    var region: Region = .init(&buffer);
    var names: []const []const u8 = undefined;

    try decode([]const []const u8, &region, "[\"a\", null]", &names, test_decode_options);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("", names[1]);

    var optional: []const ?[]const u16 = undefined;

    try decode([]const ?[]const u16, &region, "[null, [2]]", &optional, test_decode_options);
    try testing.expectEqual(@as(?[]const u16, null), optional[0]);

    const Defaulted = struct { ports: []const u16 = &.{8080} };
    var defaulted: Defaulted = undefined;

    try decode(Defaulted, &region, "{\"ports\": null}", &defaulted, test_decode_options);
    try testing.expectEqualSlices(u16, &.{8080}, defaulted.ports);
}

test "a mismatch is reported at the value and an unknown member at its key" {
    const Server = struct { port: u16 = 0 };
    const extra = "{\"port\": 1, \"extra\": 2}";
    const refused: DecodeOptions = .{ .diagnostic = null, .unknown_members = .refused };

    const escaped = "[{\"h\\u006f\": 1}]";
    const at_value: TestFailure = .{ .column = 10, .err = error.Mismatch };
    const at_item: TestFailure = .{ .column = 5, .err = error.Mismatch };
    const unknown: TestFailure = .{ .column = 13, .err = error.MemberUnknown, .member = "extra" };
    const raw: TestFailure = .{ .column = 3, .err = error.MemberUnknown, .member = "h\\u006f" };

    try test_failure_expect(Server, "{\"port\": \"80\"}", test_decode_options, at_value);
    try test_failure_expect(Server, "{\"port\": {\"a\": 1}}", test_decode_options, at_value);
    try test_failure_expect([]const u16, "[1, \"x\"]", test_decode_options, at_item);
    try test_failure_expect(Server, extra, refused, unknown);
    try test_failure_expect([]const Server, escaped, refused, raw);

    var buffer: [512]u8 = undefined;
    var region: Region = .init(&buffer);
    var server: Server = undefined;
    var empty: Empty = undefined;

    try decode(Server, &region, extra, &server, test_decode_options);
    try testing.expectEqual(@as(u16, 1), server.port);
    try decode(Server, &region, "{\"port\": 2}", &server, refused);
    try testing.expectEqual(@as(u16, 2), server.port);
    try decode(Empty, &region, "{\"any\": [1]}", &empty, refused);
}

test "the encode error set names only what the type can raise" {
    const Color = enum { blue, unrecognized };
    const Plain = struct { flags: []const bool, name: []const u8, port: ?u16 };
    const Open = struct { color: Color, ratios: []const f32 };
    const Chosen = union(enum) { number: f64, text: []const u8, value: Raw };

    try testing.expect(EncodeErrorType(Plain) == error{WriteFailed});
    try testing.expect(EncodeErrorType([]const EntryType(Plain)) == error{WriteFailed});

    const OpenError = error{ EnumerationUnrecognized, FloatNonFinite, WriteFailed };
    const ChosenError = error{ DepthExceeded, FloatNonFinite, RawMalformed, WriteFailed };

    try testing.expect(EncodeErrorType(Open) == OpenError);
    try testing.expect(EncodeErrorType(Chosen) == ChosenError);

    const Deep = []const []const []const u8;

    try testing.expectEqual(@as(u32, 2), comptime traits_of(Deep, 0).height);
    try testing.expectEqual(@as(u32, 2), comptime traits_of(Plain, 0).height);
    try testing.expectEqual(@as(u32, 0), comptime traits_of(Chosen, 0).height);
}

test "the encode error set and region size of a type with thousands of members compile" {
    const names = comptime names: {
        @setEvalBranchQuota(50_000);

        var result: [64][]const u8 = undefined;

        for (&result, 0..) |*name, index| name.* = std.fmt.comptimePrint("field_{d}", .{index});

        break :names result;
    };

    const attributes: std.lang.Type.Struct.FieldAttributes = .{
        .@"align" = null,
        .@"comptime" = false,
        .default_value_ptr = null,
    };

    const Inner = @Struct(.auto, null, &names, &@splat(?f64), &@splat(attributes));
    const Wide = @Struct(.auto, null, &names, &@splat(Inner), &@splat(attributes));
    const WideError = error{ FloatNonFinite, WriteFailed };

    try testing.expect(EncodeErrorType(Wide) == WideError);
    try testing.expect(EncodeErrorType([]const Wide) == WideError);
    try testing.expect(region_bytes_max(Wide, 64) >= 64);
}

test "a document larger than the region is refused and the region is restored" {
    var buffer: [64]u8 align(region_module.alignment_bytes) = undefined;
    var region: Region = .init(&buffer);
    var names: []const []const u8 = undefined;

    const input = "[\"a\", \"b\", \"c\", \"d\", \"e\"]";
    const decoded = decode([]const []const u8, &region, input, &names, test_decode_options);

    try testing.expectError(error.RegionFull, decoded);
    try testing.expectEqual(@as(u32, 0), region.used);
    try testing.expectEqual(@as(u32, 64), region.top);
}

test "an escaped string longer than the whole region is RegionFull, not a crash" {
    var buffer: [32]u8 = undefined;
    var region: Region = .init(&buffer);
    var text: []const u8 = undefined;
    var input: [82]u8 = @splat('n');

    for (0..40) |index| input[1 + 2 * index] = '\\';

    input[0] = '"';
    input[81] = '"';

    const result = decode([]const u8, &region, &input, &text, test_decode_options);

    try testing.expectError(error.RegionFull, result);
    try testing.expectEqual(@as(u32, 0), region.used);
}

test "a failed decode restores both ends of the region" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    const region = &test_region.region;

    _ = try region.reserve(u8, 10);

    const used = region.used;
    const top = region.top;

    var container: TestContainer = undefined;

    const input =
        \\{"Id": "a\u00e9", "Names": ["x", "y"], "Labels": {"k\u00e9": "v"}, "Ports": [{"Type": 1}]}
    ;

    const decoded = decode(TestContainer, region, input, &container, test_decode_options);

    try testing.expectError(error.Mismatch, decoded);
    try testing.expectEqual(used, region.used);
    try testing.expectEqual(top, region.top);
}

test "encoding then decoding reproduces the value, and the encoding is valid JSON" {
    const labels = [_]EntryType([]const u8){
        .{ .key = "quote\"key", .value = "line\nbreak" },
        .{ .key = "plain", .value = "" },
    };

    const ports = [_]TestPort{
        .{ .port_private = 80, .port_public = null, .protocol = .udp },
        .{},
    };

    const original = TestContainer{
        .created = -42,
        .detail = .{ .text = "{\"a\":[1,2]}" },
        .id = "\u{1f600}\x01",
        .labels = &labels,
        .names = &.{ "/a", "/b" },
        .ports = &ports,
        .processes = &.{ &.{ "root", "1" }, &.{} },
        .ratio = 0.5,
        .running = false,
        .volumes = &.{.{ .key = "/data", .value = .{} }},
    };

    var test_sink: TestSink = undefined;

    const encoded = try test_encoded(TestContainer, &test_sink, &original, &test_encode_options);

    try testing.expect(try std.json.validate(testing.allocator, encoded));

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var decoded: TestContainer = undefined;

    try decode(TestContainer, &test_region.region, encoded, &decoded, test_decode_options);
    try testing.expectEqualDeep(original, decoded);
}

test "floats encode in the ECMAScript form and round trip" {
    const values = [_]f64{
        0.25,
        100,
        1000,
        70000,
        1e300,
        5e-324,
        -0.0,
        123456789.125,
        1.7976931348623157e308,
    };

    const texts = [_][]const u8{
        "0.25",
        "100",
        "1000",
        "70000",
        "1e+300",
        "5e-324",
        "-0",
        "123456789.125",
        "",
    };

    for (values, texts) |value, text| {
        var test_sink: TestSink = undefined;

        const encoded = try test_encoded(f64, &test_sink, &value, &test_encode_options);

        if (text.len > 0) try testing.expectEqualStrings(text, encoded);

        try testing.expect(try std.json.validate(testing.allocator, encoded));

        const parsed = try std.fmt.parseFloat(f64, encoded);

        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(parsed)));
    }
}

test "an f32 encodes in its own shortest form" {
    const values = [_]f32{ 0.1, 3.4028235e38, 1e-45, 16777216 };
    const texts = [_][]const u8{ "0.1", "3.4028235e+38", "1e-45", "16777216" };

    for (values, texts) |value, text| {
        var test_sink: TestSink = undefined;

        const encoded = try test_encoded(f32, &test_sink, &value, &test_encode_options);

        try testing.expectEqualStrings(text, encoded);
    }
}

test "decimal notation writes a float at any magnitude without an exponent" {
    const values = [_]f64{ 1e21, 1.5e-7, 70000 };
    const texts = [_][]const u8{ "1000000000000000000000", "0.00000015", "70000" };

    var options = test_writer_options;

    options.notation = .decimal;

    for (values, texts) |value, text| {
        var test_sink: TestSink = undefined;

        test_sink.init(options);

        try encode(f64, &test_sink.writer, &value, test_encode_options);

        test_sink.writer.finish();

        try testing.expectEqualStrings(text, test_sink.sink.buffered());
    }

    const single: f32 = 1e21;
    var test_sink: TestSink = undefined;

    test_sink.init(options);

    try encode(f32, &test_sink.writer, &single, test_encode_options);
    try testing.expectEqualStrings("1000000000000000000000", test_sink.sink.buffered());
}

test "a null inside a free-form value is kept as raw text and round trips" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var values: []const Raw = undefined;

    const input = "[null, {\"a\": null}, 1]";

    try decode([]const Raw, &test_region.region, input, &values, test_decode_options);

    try testing.expectEqualStrings("null", values[0].text);
    try testing.expectEqualStrings("{\"a\": null}", values[1].text);

    var test_sink: TestSink = undefined;

    const encoded = try test_encoded([]const Raw, &test_sink, &values, &test_encode_options);

    try testing.expectEqualStrings("[null,{\"a\": null},1]", encoded);
}

test "absent optional members are omitted from the encoding unless nulls are emitted" {
    var test_sink: TestSink = undefined;
    const port = TestPort{ .port_private = 22 };
    const omitted = try test_encoded(TestPort, &test_sink, &port, &test_encode_options);

    try testing.expectEqualStrings("{\"PrivatePort\":22}", omitted);

    const emitted_options: EncodeOptions = .{ .null_members = .emitted };
    const emitted = try test_encoded(TestPort, &test_sink, &port, &emitted_options);
    const expected = "{\"PrivatePort\":22,\"PublicPort\":null,\"Type\":null}";

    try testing.expectEqualStrings(expected, emitted);
}

test "a union picks its variant by the kind of the token and encodes its payload" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    const inputs = [_][]const u8{ "true", "-3", "\"x\"", "[1,2]", "{\"PrivatePort\":1}", "null" };
    const tags = [_]std.meta.Tag(TestValue){ .flag, .count, .label, .list, .record, .none };

    for (inputs, tags) |input, tag| {
        var value: TestValue = undefined;

        try decode(TestValue, &test_region.region, input, &value, test_decode_options);
        try testing.expectEqual(tag, std.meta.activeTag(value));

        var test_sink: TestSink = undefined;

        const encoded = try test_encoded(TestValue, &test_sink, &value, &test_encode_options);

        try testing.expectEqualStrings(input, encoded);
    }
}

test "a Raw variant catches every kind that no other variant claims" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var value: TestLoose = undefined;

    try decode(TestLoose, &test_region.region, "7", &value, test_decode_options);
    try testing.expectEqual(@as(u32, 7), value.count);

    const others = [_][]const u8{ "\"x\"", "[1, {}]", "{\"a\": 1}", "null", "false" };

    for (others) |input| {
        try decode(TestLoose, &test_region.region, input, &value, test_decode_options);
        try testing.expectEqualStrings(input, value.other.text);
    }
}

test "a union whose variants claim one kind still encodes, because only decode needs the table" {
    const Size = union(enum) {
        big: u64,
        small: u8,
    };

    var test_sink: TestSink = undefined;
    const size: Size = .{ .small = 7 };
    const encoded = try test_encoded(Size, &test_sink, &size, &test_encode_options);

    try testing.expectEqualStrings("7", encoded);
}

test "an enumeration without an unrecognized member refuses a name it does not list" {
    const Color = enum {
        blue,
        red,

        pub const json = .{ .red = "Red" };
    };

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var color: Color = undefined;

    try decode(Color, &test_region.region, "\"Red\"", &color, test_decode_options);
    try testing.expectEqual(Color.red, color);
    try decode(Color, &test_region.region, "\"blue\"", &color, test_decode_options);
    try testing.expectEqual(Color.blue, color);

    for ([_][]const u8{ "\"red\"", "\"green\"", "null" }) |input| {
        const decoded = decode(Color, &test_region.region, input, &color, test_decode_options);

        try testing.expectError(error.Mismatch, decoded);
    }

    var test_sink: TestSink = undefined;

    const encoded = try test_encoded(Color, &test_sink, &color, &test_encode_options);

    try testing.expectEqualStrings("\"blue\"", encoded);
}

test "a token kind that no variant claims is a mismatch" {
    const Narrow = union(enum) {
        count: u32,
        flag: bool,
    };

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var value: Narrow = undefined;

    for ([_][]const u8{ "\"x\"", "[]", "{}", "null" }) |input| {
        const decoded = decode(Narrow, &test_region.region, input, &value, test_decode_options);

        try testing.expectError(error.Mismatch, decoded);
    }
}

test "a required member that is missing is MemberMissing" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var ticket: TestTicket = undefined;

    const Missing = struct {
        column: u32,
        input: []const u8,
        member: []const u8,
    };

    const missing = [_]Missing{
        .{ .column = 27, .input = "{\"Owner\": \"a\", \"state\": 1}", .member = "id" },
        .{ .column = 22, .input = "{\"id\": 1, \"state\": 1}", .member = "Owner" },
        .{ .column = 35, .input = "{\"id\": 1, \"Owner\": \"a\", \"port\": 2}", .member = "state" },
        .{ .column = 3, .input = "{}", .member = "id" },
    };

    const region = &test_region.region;

    for (missing) |case| {
        var diagnostic: Diagnostic = undefined;

        const decoded = decode(TestTicket, region, case.input, &ticket, .{
            .diagnostic = &diagnostic,
        });

        try testing.expectError(error.MemberMissing, decoded);
        try testing.expectEqualStrings(case.member, diagnostic.member);
        try testing.expectEqual(Position{ .column = case.column, .line = 1 }, diagnostic.position);
    }

    const complete = "{\"id\": 1, \"Owner\": \"a\", \"state\": 2}";

    try decode(TestTicket, region, complete, &ticket, test_decode_options);

    try testing.expectEqual(@as(u64, 1), ticket.id);
    try testing.expectEqual(@as(u16, 8080), ticket.port);
    try testing.expectEqual(@as(i64, 2), ticket.state.count);
}

test "null keeps a declared default, nulls a required optional, and refuses a required value" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var ticket: TestTicket = undefined;

    const input = "{\"id\": 3, \"Owner\": null, \"port\": 1, \"port\": null, \"state\": null}";

    try decode(TestTicket, &test_region.region, input, &ticket, test_decode_options);

    try testing.expectEqual(@as(u16, 8080), ticket.port);
    try testing.expectEqual(@as(?[]const u8, null), ticket.owner);
    try testing.expectEqual(TestValue.none, ticket.state);

    const refused = "{\"id\": null, \"Owner\": null, \"state\": null}";
    const decoded = decode(TestTicket, &test_region.region, refused, &ticket, test_decode_options);

    try testing.expectError(error.Mismatch, decoded);

    const top = decode(TestTicket, &test_region.region, "null", &ticket, test_decode_options);

    try testing.expectError(error.Mismatch, top);
}

test "an unlisted field is named by its Zig name and a required optional null is written" {
    var test_sink: TestSink = undefined;
    const ticket: TestTicket = .{ .id = 9, .owner = null, .state = .{ .flag = true } };
    const encoded = try test_encoded(TestTicket, &test_sink, &ticket, &test_encode_options);
    const expected = "{\"id\":9,\"Owner\":null,\"port\":8080,\"state\":true}";

    try testing.expectEqualStrings(expected, encoded);
}

test "duplicate keys resolve to the last value in members and maps" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var port: TestPort = undefined;

    const repeated = "{\"PrivatePort\": 1, \"PrivatePort\": 2}";

    try decode(TestPort, &test_region.region, repeated, &port, test_decode_options);

    try testing.expectEqual(@as(u16, 2), port.port_private.?);

    var map: []const EntryType(u32) = undefined;

    const input = "{\"a\": 1, \"b\": 2, \"a\": 3, \"c\": 4, \"b\": 5, \"a\": 6}";

    try decode([]const EntryType(u32), &test_region.region, input, &map, test_decode_options);

    try testing.expectEqual(@as(usize, 3), map.len);
    try testing.expectEqualStrings("a", map[0].key);
    try testing.expectEqual(@as(u32, 6), map[0].value);
    try testing.expectEqualStrings("b", map[1].key);
    try testing.expectEqual(@as(u32, 5), map[1].value);
    try testing.expectEqualStrings("c", map[2].key);
    try testing.expectEqual(@as(u32, 4), map[2].value);
}

test "an unrecognized enumeration fails before its member key is written" {
    var test_sink: TestSink = undefined;
    const port: TestPort = .{ .port_private = 1, .protocol = .unrecognized };

    test_sink.init(test_writer_options);

    const encoded = encode(TestPort, &test_sink.writer, &port, test_encode_options);

    try testing.expectError(error.EnumerationUnrecognized, encoded);
    try testing.expectEqualStrings("{\"PrivatePort\":1", test_sink.sink.buffered());

    const protocol: TestProtocol = .unrecognized;

    test_sink.init(test_writer_options);

    const alone = encode(TestProtocol, &test_sink.writer, &protocol, test_encode_options);

    try testing.expectError(error.EnumerationUnrecognized, alone);
    try testing.expectEqual(@as(usize, 0), test_sink.sink.buffered().len);
}

test "an empty Raw is written as null and omitted as a member that has a default" {
    const Holder = struct {
        detail: Raw = .{},
        kept: Raw,
    };

    var test_sink: TestSink = undefined;
    const holder: Holder = .{ .kept = .{} };
    const omitted = try test_encoded(Holder, &test_sink, &holder, &test_encode_options);

    try testing.expectEqualStrings("{\"kept\":null}", omitted);

    const emitted_options: EncodeOptions = .{ .null_members = .emitted };
    const emitted = try test_encoded(Holder, &test_sink, &holder, &emitted_options);

    try testing.expectEqualStrings("{\"detail\":null,\"kept\":null}", emitted);
}

test "a non-finite float follows the writer policy" {
    var test_sink: TestSink = undefined;
    const value: f32 = std.math.inf(f32);

    test_sink.init(test_writer_options);

    const refused = encode(f32, &test_sink.writer, &value, test_encode_options);

    try testing.expectError(error.FloatNonFinite, refused);

    var nulled = test_writer_options;

    nulled.non_finite = .null_value;

    test_sink.init(nulled);

    try encode(f32, &test_sink.writer, &value, test_encode_options);
    try testing.expectEqualStrings("null", test_sink.sink.buffered());
}

test shape_of {
    try testing.expectEqual(Shape.object, shape_of(TestPort));
    try testing.expectEqual(Shape.map, shape_of([]const EntryType(u32)));
    try testing.expectEqual(Shape.choice, shape_of(TestValue));
    try testing.expectEqual(Shape.raw, shape_of(Raw));
    try testing.expectEqual(Shape.string, shape_of([]const u8));
}

test default_of {
    try testing.expectEqual(@as(u16, 0), default_of(u16));
    try testing.expectEqual(@as(?bool, null), default_of(?bool));
    try testing.expectEqual(TestProtocol.unrecognized, default_of(TestProtocol));
    try testing.expectEqualDeep(TestPort{}, default_of(TestPort));
}

test EntryType {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    const Labels = []const EntryType([]const u8);

    var labels: Labels = undefined;

    try decode(Labels, &test_region.region, "{\"tier\": \"edge\"}", &labels, test_decode_options);

    try testing.expectEqualStrings("tier", labels[0].key);
    try testing.expectEqualStrings("edge", labels[0].value);
}

test Raw {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var raw: Raw = undefined;

    try decode(Raw, &test_region.region, " {\"any\": [1, \"shape\"]} ", &raw, test_decode_options);

    try testing.expectEqualStrings("{\"any\": [1, \"shape\"]}", raw.text);
}

test Empty {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var volumes: []const EntryType(Empty) = undefined;

    const input = "{\"/data\": {\"ignored\": true}, \"/logs\": {}}";

    try decode([]const EntryType(Empty), &test_region.region, input, &volumes, test_decode_options);

    try testing.expectEqual(@as(usize, 2), volumes.len);
    try testing.expectEqualStrings("/logs", volumes[1].key);
}

test Rename {
    const Mount = struct {
        destination: []const u8,
        read_write: bool = false,

        pub const json = .{ .read_write = "RW" };
        pub const json_rename = .pascal;
    };

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var mount: Mount = undefined;

    const input = "{\"Destination\": \"/data\", \"RW\": true}";

    try decode(Mount, &region, input, &mount, .{ .diagnostic = null, .unknown_members = .refused });

    try testing.expectEqualStrings("/data", mount.destination);
    try testing.expect(mount.read_write);

    var sink_buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);
    var writer: Writer = .init(&sink, test_writer_options);

    try encode(Mount, &writer, &mount, .{ .null_members = .omitted });
    writer.finish();

    try testing.expectEqualStrings("{\"Destination\":\"/data\",\"RW\":true}", sink.buffered());
}

const TestUsage = struct {
    exec_cachemount: u64 = 0,
    source_git_checkout: u64 = 0,

    pub fn json_rename(comptime name: []const u8) []const u8 {
        comptime assert(name.len > 0);

        comptime var dotted: [name.len]u8 = name[0..name.len].*;

        for (&dotted) |*byte| {
            if (byte.* == '_') byte.* = '.';
        }

        const result = dotted;

        return &result;
    }
};

const TestLevel = enum {
    debug_trace,
    warning_only,
    unrecognized,

    pub const json = .{ .warning_only = "warn" };
    pub const json_rename = .kebab;
};

const TestRecord = struct {
    log_level: TestLevel,
    usage: TestUsage = .{},

    pub const json_rename = .camel;
};

test "a json entry wins over json_rename, which renames only the type's own members" {
    var buffer: [512]u8 = undefined;
    var region: Region = .init(&buffer);
    var record: TestRecord = undefined;

    const input = "{\"logLevel\": \"debug-trace\", \"usage\": {\"source.git.checkout\": 7}}";

    const refused: DecodeOptions = .{ .diagnostic = null, .unknown_members = .refused };

    try decode(TestRecord, &region, input, &record, refused);

    try testing.expectEqual(TestLevel.debug_trace, record.log_level);
    try testing.expectEqual(@as(u64, 7), record.usage.source_git_checkout);

    var level: TestLevel = undefined;

    try decode(TestLevel, &region, "\"warn\"", &level, test_decode_options);
    try testing.expectEqual(TestLevel.warning_only, level);

    try decode(TestLevel, &region, "\"warning-only\"", &level, test_decode_options);
    try testing.expectEqual(TestLevel.unrecognized, level);

    var test_sink: TestSink = undefined;
    const encoded = try test_encoded(TestRecord, &test_sink, &record, &test_encode_options);
    const expected = "{\"logLevel\":\"debug-trace\",\"usage\":" ++
        "{\"exec.cachemount\":0,\"source.git.checkout\":7}}";

    try testing.expectEqualStrings(expected, encoded);

    var diagnostic: Diagnostic = undefined;
    const missing = decode(TestRecord, &region, "{\"log_level\": \"debug-trace\"}", &record, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.MemberMissing, missing);
    try testing.expectEqualStrings("logLevel", diagnostic.member);
}

const TestDuration = struct {
    seconds: u32,

    pub const json_shape: Shape = .adapted;

    pub fn json_decode(text: []const u8) MismatchError!TestDuration {
        assert(text.len <= input_bytes_max);

        if (text.len < 2) return error.Mismatch;
        if (text[text.len - 1] != 's') return error.Mismatch;

        const digits = text[0 .. text.len - 1];
        const seconds = std.fmt.parseInt(u32, digits, 10) catch return error.Mismatch;

        return .{ .seconds = seconds };
    }

    pub fn json_encode(duration: *const TestDuration, writer: *Writer) Writer.Error!void {
        assert(!writer.string_open);

        var digits: [16]u8 = undefined;

        const length = std.fmt.printInt(&digits, duration.seconds, 10, .lower, .{
            .alignment = .right,
            .fill = ' ',
            .precision = null,
            .width = null,
        });

        try writer.string_begin();
        try writer.string_part(digits[0..length]);
        try writer.string_part("s");
        try writer.string_end();
    }
};

const TestRange = struct {
    first: i32,
    last: i32,

    pub const json_shape: Shape = .adapted;

    pub fn json_decode(pair: []const i32) MismatchError!TestRange {
        assert(pair.len <= input_bytes_max);

        if (pair.len != 2) return error.Mismatch;

        return .{ .first = pair[0], .last = pair[1] };
    }

    pub fn json_encode(range: *const TestRange, writer: *Writer) Writer.Error!void {
        assert(!writer.string_open);

        try writer.array_begin();
        try writer.integer(range.first);
        try writer.integer(range.last);
        try writer.array_end();
    }
};

const TestEvent = struct {
    at: TestDuration,
    history: []const TestDuration = &.{},
    span: ?TestRange = null,
    previous: ?TestDuration = null,
};

test "an adapted type decodes and encodes itself, inside optionals and slices too" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    const input = "{\"at\": \"90s\", \"history\": [\"1s\", \"20s\"], \"span\": [3, -4], " ++
        "\"previous\": null}";

    var event: TestEvent = undefined;

    try decode(TestEvent, &test_region.region, input, &event, test_decode_options);

    try testing.expectEqual(@as(u32, 90), event.at.seconds);
    try testing.expectEqual(@as(usize, 2), event.history.len);
    try testing.expectEqual(@as(u32, 20), event.history[1].seconds);
    try testing.expectEqual(TestRange{ .first = 3, .last = -4 }, event.span.?);
    try testing.expectEqual(@as(?TestDuration, null), event.previous);

    var test_sink: TestSink = undefined;
    const encoded = try test_encoded(TestEvent, &test_sink, &event, &test_encode_options);
    const expected = "{\"at\":\"90s\",\"history\":[\"1s\",\"20s\"],\"span\":[3,-4]}";

    try testing.expectEqualStrings(expected, encoded);

    var decoded: TestEvent = undefined;

    try decode(TestEvent, &test_region.region, encoded, &decoded, test_decode_options);
    try testing.expectEqualDeep(event, decoded);
    try testing.expect(EncodeErrorType(TestEvent) == Writer.Error);
}

test "a refusal by the adapter is a mismatch at the start of the adapted value" {
    const at_value: TestFailure = .{ .column = 8, .err = error.Mismatch };
    const at_array: TestFailure = .{ .column = 22, .err = error.Mismatch };
    const missing: TestFailure = .{ .column = 3, .err = error.MemberMissing, .member = "at" };
    const triple = "{\"at\": \"1s\", \"span\": [1, 2, 3]}";

    try test_failure_expect(TestEvent, "{\"at\": \"90m\"}", test_decode_options, at_value);
    try test_failure_expect(TestEvent, "{\"at\": 90}", test_decode_options, at_value);
    try test_failure_expect(TestEvent, "{\"at\": null}", test_decode_options, at_value);
    try test_failure_expect(TestEvent, triple, test_decode_options, at_array);
    try test_failure_expect(TestEvent, "{}", test_decode_options, missing);
}

test encode {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,
        tags: ?[]const []const u8 = null,

        pub const json = .{ .host = "Host" };
    };

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_writer_options);
    const server: Server = .{ .host = "localhost" };

    try encode(Server, &writer, &server, .{ .null_members = .omitted });

    writer.finish();

    try testing.expectEqualStrings("{\"Host\":\"localhost\",\"port\":8080}", sink.buffered());
}

test decode {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,

        pub const json = .{ .host = "Host" };
    };

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var server: Server = undefined;

    try decode(Server, &region, "{\"Host\": \"localhost\", \"port\": null}", &server, .{
        .diagnostic = null,
    });

    try testing.expectEqualStrings("localhost", server.host);
    try testing.expectEqual(@as(u16, 8080), server.port);

    var diagnostic: Diagnostic = undefined;

    const refused = decode(Server, &region, "{\"Host\": \"x\",\n \"port\": }", &server, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.Malformed, refused);
    try testing.expectEqual(@as(u32, 2), diagnostic.position.line);

    const missing = decode(Server, &region, "{\"port\": 80}", &server, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.MemberMissing, missing);
    try testing.expectEqualStrings("Host", diagnostic.member);
}

test decode_relaxed {
    const Settings = struct {
        ratio: f64,
        retries: u8 = 3,
        tags: []const []const u8,
    };

    const input =
        \\// editor settings
        \\{
        \\    "ratio": -Infinity, /* unbounded */
        \\    "tags": ["a", "b",],
        \\}
    ;

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var settings: Settings = undefined;

    try decode_relaxed(Settings, &region, input, &settings, .{ .diagnostic = null });

    try testing.expectEqual(-std.math.inf(f64), settings.ratio);
    try testing.expectEqual(@as(u8, 3), settings.retries);
    try testing.expectEqual(@as(usize, 2), settings.tags.len);
    const strict = decode(Settings, &region, input, &settings, .{ .diagnostic = null });

    try testing.expectError(error.Malformed, strict);

    var diagnostic: Diagnostic = undefined;

    const spelled = "{\"ratio\": 1, \"retries\": nan, \"tags\": []}";

    const refused = decode_relaxed(Settings, &region, spelled, &settings, .{
        .diagnostic = &diagnostic,
    });

    try testing.expectError(error.Mismatch, refused);
    try testing.expectEqual(Position{ .column = 25, .line = 1 }, diagnostic.position);
}

test "relaxed decoding reads every spelling into a float, keeps raw text, and refuses overflow" {
    const Values = struct {
        items: []const f64,
        raw: Raw,
    };

    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    const input = "{\"items\": [NaN, inf, -INFINITY, 2.5], \"raw\": [1, /* c */ nan]}";
    var values: Values = undefined;

    try decode_relaxed(Values, &test_region.region, input, &values, test_decode_options);

    try testing.expectEqual(@as(usize, 4), values.items.len);
    try testing.expect(std.math.isNan(values.items[0]));
    try testing.expectEqual(std.math.inf(f64), values.items[1]);
    try testing.expectEqual(-std.math.inf(f64), values.items[2]);
    try testing.expectEqual(@as(f64, 2.5), values.items[3]);
    try testing.expectEqualStrings("[1, /* c */ nan]", values.raw.text);

    var sink_buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);
    var writer: Writer = .init(&sink, test_writer_options);
    const encoded = encode(Raw, &writer, &values.raw, .{ .null_members = .omitted });

    try testing.expectError(error.RawMalformed, encoded);

    var single: f32 = undefined;

    try decode_relaxed(f32, &test_region.region, "-inf", &single, test_decode_options);
    try testing.expectEqual(-std.math.inf(f32), single);

    var double: f64 = undefined;

    const region = &test_region.region;
    const overflow = decode_relaxed(f64, region, "1e999", &double, test_decode_options);

    try testing.expectError(error.Mismatch, overflow);
}

test "a type naming thirty or more members encodes and decodes" {
    const test_region = try test_region_create();
    defer testing.allocator.destroy(test_region);

    var test_sink: TestSink = undefined;
    const wide: TestWide = .{ .color = .member_31, .field_05 = 205, .field_31 = 231 };
    const encoded = try test_encoded(TestWide, &test_sink, &wide, &test_encode_options);

    var decoded: TestWide = undefined;

    try decode(TestWide, &test_region.region, encoded, &decoded, test_decode_options);

    try testing.expect(std.mem.find(u8, encoded, "\"Field31\":231") != null);
    try testing.expect(std.mem.find(u8, encoded, "\"color\":\"Member31\"") != null);
    try testing.expectEqual(wide, decoded);
}

test "member names written once at comptime match the runtime key path in each layout and sink" {
    const Members = struct {
        alpha: u32 = 1,
        quoted: u32 = 2,
        unicode: u32 = 3,
        member_name_too_long_for_one_chunk: u32 = 4,
        beta: u32 = 5,

        pub const json = .{ .quoted = "q\"t", .unicode = "caf\u{e9}", .beta = "b" };
    };

    const structure = @typeInfo(Members).@"struct";
    const value: Members = .{};

    for ([_]Writer.Layout{ .compact, .pretty }) |layout| {
        for (std.enums.values(Writer.UTF8)) |utf8| {
            const options: Writer.Options = .{ .layout = layout, .utf8 = utf8 };

            var expected_buffer: [512]u8 = undefined;
            var expected_sink: std.Io.Writer = .fixed(&expected_buffer);
            var expected_writer: Writer = .init(&expected_sink, options);

            try expected_writer.object_begin();

            inline for (structure.field_names) |name| {
                try expected_writer.key(comptime name_of(Members, name));
                try expected_writer.unsigned(@field(value, name));
            }

            try expected_writer.object_end();
            expected_writer.finish();

            const expected = expected_sink.buffered();
            var buffer: [600]u8 = undefined;

            for (0..48) |slack| {
                var sink: std.Io.Writer = .fixed(buffer[0 .. expected.len + slack]);
                var writer: Writer = .init(&sink, options);

                try encode(Members, &writer, &value, test_encode_options);
                writer.finish();

                try testing.expectEqualStrings(expected, sink.buffered());
            }

            for (0..expected.len) |length| {
                var sink: std.Io.Writer = .fixed(buffer[0..length]);
                var writer: Writer = .init(&sink, options);
                const refused = encode(Members, &writer, &value, test_encode_options);

                try testing.expectError(error.WriteFailed, refused);
            }
        }
    }
}
