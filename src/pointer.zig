const std = @import("std");

const document_module = @import("document.zig");
const string = @import("string.zig");
const tokenizer_module = @import("tokenizer.zig");
const tree_module = @import("tree.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Position = tokenizer_module.Position;
const Token = tokenizer_module.Token;
const TokenizerType = tokenizer_module.TokenizerType;

const depth_max = tokenizer_module.depth_max;
const index_digits_max: u32 = 10;
const input_bytes_max = tokenizer_module.input_bytes_max;

comptime {
    assert(std.math.log10_int(@as(u64, std.math.maxInt(u32))) + 1 == index_digits_max);
}

pub const Candidate = struct {
    key: []const u8,
    token: []const u8,
};

const Cursor = struct {
    target: []u8,
    used: u32,
};

const Frame = struct {
    array: bool,
    count: u32,
    key: []const u8,
    keyed: bool,
};

const Spot = enum {
    container,
    member,
    pending,
};

const Walk = struct {
    depth: u32,
    frames: [depth_max]Frame,
};

fn NodeType(comptime Source: type) type {
    return @TypeOf(Source.root(undefined));
}

pub fn ParentType(comptime Source: type) type {
    return union(enum) {
        found: Found,
        malformed,
        missing,
        root,

        pub const Found = struct {
            parent: NodeType(Source),
            token: []const u8,
        };
    };
}

pub fn index_of(text: []const u8) ?u32 {
    assert(text.len < std.math.maxInt(u32));

    if (text.len == 0) return null;
    if (text.len > index_digits_max) return null;
    if (text[0] == '0') return if (text.len == 1) 0 else null;

    var result: u64 = 0;

    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        result = result * 10 + (byte - '0');
    }

    if (result > std.math.maxInt(u32)) return null;

    assert(result > 0);

    return @intCast(result);
}

pub fn path_find(
    comptime Source: type,
    source: *const Source,
    start: NodeType(Source),
    segments: []const []const u8,
) ?NodeType(Source) {
    assert(segments.len < std.math.maxInt(u32));
    assert(@backingInt(start) < source.node_count);

    var node = start;

    for (segments) |segment| {
        node = segment_step(Source, source, node, segment) orelse return null;
    }

    if (segments.len == 0) assert(node == start);

    return node;
}

pub fn pointer_find(
    comptime Source: type,
    source: *const Source,
    start: NodeType(Source),
    pointer: []const u8,
) ?NodeType(Source) {
    assert(pointer.len < std.math.maxInt(u32));
    assert(@backingInt(start) < source.node_count);

    if (pointer.len == 0) return start;
    if (!pointer_valid(pointer)) return null;

    assert(pointer[0] == '/');

    var node = start;
    var token_start: u32 = 1;

    for (0..pointer.len) |_| {
        const token_end: u32 = @intCast(std.mem.findScalarPos(u8, pointer, token_start, '/') orelse
            pointer.len);

        node = token_step(Source, source, node, pointer[token_start..token_end]) orelse return null;

        if (token_end == pointer.len) return node;

        token_start = token_end + 1;
    }

    unreachable;
}

pub fn pointer_at(input: []const u8, position: Position, target: []u8) ?[]const u8 {
    assert(input.len <= input_bytes_max);
    assert(position.line >= 1);
    assert(target.len < std.math.maxInt(u32));

    const index = index_of_position(input, position);
    var tokenizer: TokenizerType(.relaxed) = .init(input);
    var walk: Walk = .{ .depth = 0, .frames = undefined };

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch return walk_write(&walk, .pending, target);
        const spot = walk_step(&walk, &tokenizer, token, index) orelse continue;

        return walk_write(&walk, spot, target);
    }

    unreachable;
}

fn index_of_position(input: []const u8, position: Position) u32 {
    assert(input.len <= input_bytes_max);
    assert(position.line >= 1);

    var line: u32 = 1;
    var start: u32 = 0;

    for (input, 0..) |byte, index| {
        if (line == position.line) break;

        if (byte == '\n') {
            line += 1;
            start = @intCast(index + 1);
        }
    }

    const reached = line == position.line;
    const offset: u64 = if (reached) @as(u64, start) + (position.column -| 1) else input.len;
    const result: u32 = @intCast(@min(offset, input.len));

    assert(result <= input.len);

    return result;
}

fn walk_step(
    walk: *Walk,
    tokenizer: *const TokenizerType(.relaxed),
    token: Token,
    index: u32,
) ?Spot {
    assert(walk.depth <= depth_max);
    assert(index <= tokenizer.input.len);
    if (token == .key) assert(walk.depth > 0);

    const end = tokenizer.index;

    switch (token) {
        .end => {
            assert(walk.depth == 0);

            return .container;
        },
        .key => |raw| {
            if (index + 1 < tokenizer.key_start) return .container;

            walk_key(walk, raw);

            if (index < end) return .member;
        },
        .array_begin, .object_begin => {
            if (index < tokenizer.value_start) return .container;

            walk_push(walk, token == .array_begin);
        },
        .array_end, .object_end => {
            if (index <= end) return .container;

            walk_pop(walk);
        },
        .boolean, .null_value, .number, .string => {
            if (index < tokenizer.value_start) return .container;
            if (index < end) return .member;

            walk_done(walk);
        },
    }

    return null;
}

fn walk_key(walk: *Walk, raw: []const u8) void {
    assert(walk.depth > 0);
    assert(!walk.frames[walk.depth - 1].array);
    assert(raw.len <= input_bytes_max);

    const frame = &walk.frames[walk.depth - 1];

    frame.key = raw;
    frame.keyed = true;
}

fn walk_push(walk: *Walk, array: bool) void {
    assert(walk.depth < depth_max);

    if (walk.depth > 0) {
        const parent = &walk.frames[walk.depth - 1];

        assert(parent.array or parent.keyed);
    }

    walk.frames[walk.depth] = .{ .array = array, .count = 0, .key = "", .keyed = false };
    walk.depth += 1;
}

fn walk_pop(walk: *Walk) void {
    assert(walk.depth > 0);
    assert(walk.depth <= depth_max);

    walk.depth -= 1;

    walk_done(walk);
}

fn walk_done(walk: *Walk) void {
    assert(walk.depth <= depth_max);

    if (walk.depth == 0) return;

    const frame = &walk.frames[walk.depth - 1];

    if (frame.array) {
        frame.count += 1;
    } else {
        assert(frame.keyed);

        frame.keyed = false;
    }
}

fn walk_write(walk: *const Walk, spot: Spot, target: []u8) ?[]const u8 {
    assert(walk.depth <= depth_max);
    assert(target.len < std.math.maxInt(u32));

    const count = switch (spot) {
        .container => walk.depth -| 1,
        .member => walk.depth,
        .pending => pending_count(walk),
    };

    var cursor: Cursor = .{ .target = target, .used = 0 };

    for (walk.frames[0..count]) |*frame| {
        if (!segment_write(&cursor, frame)) return null;
    }

    assert(cursor.used <= target.len);

    return target[0..cursor.used];
}

fn pending_count(walk: *const Walk) u32 {
    assert(walk.depth <= depth_max);

    if (walk.depth == 0) return 0;

    const top = &walk.frames[walk.depth - 1];
    var result = walk.depth;

    if (!top.array) {
        if (!top.keyed) result -= 1;
    }

    assert(result + 1 >= walk.depth);

    return result;
}

fn segment_write(cursor: *Cursor, frame: *const Frame) bool {
    assert(cursor.used <= cursor.target.len);
    assert(frame.array or frame.keyed);

    if (cursor.used == cursor.target.len) return false;

    cursor.target[cursor.used] = '/';
    cursor.used += 1;

    if (frame.array) return digits_write(cursor, frame.count);
    return key_write(cursor, frame.key);
}

fn digits_write(cursor: *Cursor, value: u32) bool {
    assert(cursor.used <= cursor.target.len);
    assert(value < input_bytes_max);

    var digits: [index_digits_max]u8 = undefined;
    var count: u32 = 0;
    var rest = value;

    for (0..index_digits_max) |_| {
        digits[index_digits_max - 1 - count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
        rest /= 10;

        if (rest == 0) break;
    }

    assert(rest == 0);

    if (cursor.target.len - cursor.used < count) return false;

    @memcpy(cursor.target[cursor.used..][0..count], digits[index_digits_max - count ..]);
    cursor.used += count;

    return true;
}

fn key_write(cursor: *Cursor, raw: []const u8) bool {
    assert(cursor.used <= cursor.target.len);
    assert(raw.len <= input_bytes_max);

    const free = cursor.target[cursor.used..];
    const text = string.unescape(raw, free) catch return false;
    const special_count = std.mem.countScalar(u8, text, '~') + std.mem.countScalar(u8, text, '/');
    const length = text.len + special_count;

    if (length > free.len) return false;

    var write: usize = length;

    for (0..text.len) |offset| {
        const byte = free[text.len - 1 - offset];

        switch (byte) {
            '~', '/' => {
                free[write - 2] = '~';
                free[write - 1] = if (byte == '~') '0' else '1';
                write -= 2;
            },
            else => {
                free[write - 1] = byte;
                write -= 1;
            },
        }
    }

    assert(write == 0);

    cursor.used += @intCast(length);

    return true;
}

pub fn parent_resolve(
    comptime Source: type,
    source: *const Source,
    pointer: []const u8,
) ParentType(Source) {
    assert(source.node_count > 0);
    assert(pointer.len < std.math.maxInt(u32));

    if (pointer.len == 0) return .root;
    if (!pointer_valid(pointer)) return .malformed;

    const last: u32 = @intCast(std.mem.findScalarLast(u8, pointer, '/') orelse unreachable);
    var node = source.root();
    var token_start: u32 = 1;

    for (0..pointer.len) |_| {
        if (token_start > last) break;

        const token_end: u32 = @intCast(std.mem.findScalarPos(u8, pointer, token_start, '/') orelse
            unreachable);

        const token = pointer[token_start..token_end];

        node = token_step(Source, source, node, token) orelse return .missing;
        token_start = token_end + 1;
    }

    assert(token_start == last + 1);

    return .{ .found = .{ .parent = node, .token = pointer[token_start..] } };
}

pub fn token_equal(candidate: Candidate) bool {
    assert(candidate.key.len < std.math.maxInt(u32));
    assert(candidate.token.len < std.math.maxInt(u32));

    const token = candidate.token;
    const tilde_count = std.mem.countScalar(u8, token, '~');
    if (candidate.key.len + tilde_count != token.len) return false;

    var cursor: u32 = 0;

    for (candidate.key) |byte| {
        var expected = token[cursor];

        cursor += 1;

        if (expected == '~') {
            expected = if (token[cursor] == '0') '~' else '/';
            cursor += 1;
        }

        if (byte != expected) return false;
    }

    assert(cursor == token.len);

    return true;
}

pub fn token_unescape(escaped: []const u8, target: []u8) []u8 {
    assert(std.mem.findScalar(u8, escaped, '/') == null);
    assert(escaped.len - std.mem.countScalar(u8, escaped, '~') <= target.len);

    var rest = escaped;
    var length: u32 = 0;

    for (0..escaped.len + 1) |_| {
        const tilde = std.mem.findScalar(u8, rest, '~') orelse break;

        assert(tilde + 1 < rest.len);
        assert(rest[tilde + 1] == '0' or rest[tilde + 1] == '1');

        @memcpy(target[length..][0..tilde], rest[0..tilde]);
        target[length + tilde] = if (rest[tilde + 1] == '0') '~' else '/';
        length += @intCast(tilde + 1);
        rest = rest[tilde + 2 ..];
    }

    @memcpy(target[length..][0..rest.len], rest);
    length += @intCast(rest.len);

    assert(length + std.mem.countScalar(u8, escaped, '~') == escaped.len);

    return target[0..length];
}

pub fn pointer_valid(pointer: []const u8) bool {
    assert(pointer.len > 0);
    assert(pointer.len < std.math.maxInt(u32));

    if (pointer[0] != '/') return false;

    for (pointer, 0..) |byte, index| {
        if (byte != '~') continue;
        if (index + 1 == pointer.len) return false;

        switch (pointer[index + 1]) {
            '0', '1' => {},
            else => return false,
        }
    }

    return true;
}

fn segment_step(
    comptime Source: type,
    source: *const Source,
    node: NodeType(Source),
    segment: []const u8,
) ?NodeType(Source) {
    assert(segment.len < std.math.maxInt(u32));
    assert(@backingInt(node) < source.node_count);

    return switch (source.kind_of(node)) {
        .array => source.item(node, index_of(segment) orelse return null),
        .object => source.member(node, segment),
        .boolean, .null_value, .number, .string => null,
    };
}

pub fn token_step(
    comptime Source: type,
    source: *const Source,
    node: NodeType(Source),
    token: []const u8,
) ?NodeType(Source) {
    assert(token.len < std.math.maxInt(u32));
    assert(@backingInt(node) < source.node_count);
    assert(std.mem.findScalar(u8, token, '/') == null);

    if (std.mem.findScalar(u8, token, '~') == null) {
        return segment_step(Source, source, node, token);
    }

    if (source.kind_of(node) != .object) return null;

    var entries = source.entries(node);
    var result: ?NodeType(Source) = null;

    for (0..source.count_of(node)) |_| {
        const entry = entries.next() orelse break;
        const candidate: Candidate = .{ .key = source.text_of(entry.key).?, .token = token };

        if (token_equal(candidate)) result = entry.value;
    }

    return result;
}

const testing = std.testing;

const TestDocument = document_module.DocumentType(.{ .node_count_max = 64, .text_bytes_max = 256 });
const TestTree = tree_module.TreeType(.{ .node_count_max = 64, .text_bytes_max = 256 });

const TestSources = struct {
    document: TestDocument,
    tree: TestTree,
};

const TestVector = struct {
    expected: ?[]const u8,
    pointer: []const u8,
};

fn test_sources_create(source: []const u8) !*TestSources {
    assert(source.len > 0);
    assert(source.len < 4096);

    const result = try testing.allocator.create(TestSources);
    errdefer testing.allocator.destroy(result);

    try result.document.parse(source);

    result.tree.init();

    const document = &result.document.document;

    try result.tree.replace(result.tree.root(), .{
        .copy = .{ .document = document, .node = document.root() },
    });

    return result;
}

fn test_written(comptime Source: type, source: *const Source, node: NodeType(Source)) ![]u8 {
    assert(source.node_count > 0);
    assert(@backingInt(node) < source.node_count);

    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer sink.deinit();

    var writer: writer_module.Writer = .init(&sink.writer, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    try source.node_write(&writer, node);

    writer.finish();

    return sink.toOwnedSlice();
}

fn test_vector_expect(comptime Source: type, source: *const Source, vector: TestVector) !void {
    assert(source.node_count > 0);
    assert(vector.pointer.len < 4096);

    const found = source.pointer_find(source.root(), vector.pointer);

    const expected = vector.expected orelse {
        try testing.expectEqual(@as(?NodeType(Source), null), found);

        return;
    };

    const node = found orelse return error.PointerUnresolved;
    const written = try test_written(Source, source, node);
    defer testing.allocator.free(written);

    try testing.expectEqualStrings(expected, written);
}

fn test_vectors_expect(source: []const u8, vectors: []const TestVector) !void {
    assert(source.len > 0);
    assert(vectors.len > 0);

    const sources = try test_sources_create(source);
    defer testing.allocator.destroy(sources);

    for (vectors) |vector| {
        try test_vector_expect(document_module.Document, &sources.document.document, vector);
        try test_vector_expect(tree_module.Tree, &sources.tree.tree, vector);
    }
}

test "the RFC 6901 section 5 pointers resolve as the RFC specifies" {
    const source =
        \\{"foo": ["bar", "baz"], "": 0, "a/b": 1, "c%d": 2, "e^f": 3, "g|h": 4,
        \\ "i\\j": 5, "k\"l": 6, " ": 7, "m~n": 8}
    ;

    const whole =
        \\{"foo":["bar","baz"],"":0,"a/b":1,"c%d":2,"e^f":3,"g|h":4,"i\\j":5,"k\"l":6," ":7,"m~n":8}
    ;

    const vectors = [_]TestVector{
        .{ .expected = whole, .pointer = "" },
        .{ .expected = "[\"bar\",\"baz\"]", .pointer = "/foo" },
        .{ .expected = "\"bar\"", .pointer = "/foo/0" },
        .{ .expected = "0", .pointer = "/" },
        .{ .expected = "1", .pointer = "/a~1b" },
        .{ .expected = "2", .pointer = "/c%d" },
        .{ .expected = "3", .pointer = "/e^f" },
        .{ .expected = "4", .pointer = "/g|h" },
        .{ .expected = "5", .pointer = "/i\\j" },
        .{ .expected = "6", .pointer = "/k\"l" },
        .{ .expected = "7", .pointer = "/ " },
        .{ .expected = "8", .pointer = "/m~0n" },
    };

    try test_vectors_expect(source, &vectors);
}

test "a malformed pointer resolves to nothing, as in the yyjson vectors" {
    const vectors = [_]TestVector{
        .{ .expected = null, .pointer = "a" },
        .{ .expected = null, .pointer = "~" },
        .{ .expected = null, .pointer = "/~" },
        .{ .expected = null, .pointer = "/a/~" },
        .{ .expected = null, .pointer = "/a/~2" },
        .{ .expected = null, .pointer = "/a/~/" },
        .{ .expected = null, .pointer = "/a/~~" },
        .{ .expected = null, .pointer = "/a~" },
        .{ .expected = "[1,2,3]", .pointer = "/a" },
    };

    try test_vectors_expect("{\"a\": [1, 2, 3]}", &vectors);
}

test "an array index follows the RFC 6901 rule, as in the yyjson vectors" {
    const indices = [_]TestVector{
        .{ .expected = null, .pointer = "/a/00" },
        .{ .expected = null, .pointer = "/a/01" },
        .{ .expected = null, .pointer = "/a/-1" },
        .{ .expected = null, .pointer = "/a/ 1" },
        .{ .expected = null, .pointer = "/a/+1" },
        .{ .expected = null, .pointer = "/a/1_0" },
        .{ .expected = null, .pointer = "/a/18446744073709551615" },
        .{ .expected = null, .pointer = "/a/4294967295" },
        .{ .expected = null, .pointer = "/a/-" },
        .{ .expected = null, .pointer = "/a/3" },
        .{ .expected = null, .pointer = "/a/" },
        .{ .expected = "1", .pointer = "/a/0" },
        .{ .expected = "3", .pointer = "/a/2" },
    };

    const nested = [_]TestVector{
        .{ .expected = null, .pointer = "/a/-/2" },
        .{ .expected = "4", .pointer = "/a/1/2" },
        .{ .expected = null, .pointer = "/a/0/2" },
        .{ .expected = null, .pointer = "/a/1/3" },
        .{ .expected = null, .pointer = "/a/1/b" },
    };

    const empty = [_]TestVector{
        .{ .expected = null, .pointer = "/0" },
        .{ .expected = null, .pointer = "/1" },
        .{ .expected = null, .pointer = "/" },
        .{ .expected = null, .pointer = "/-" },
    };

    try test_vectors_expect("{\"a\": [1, 2, 3]}", &indices);
    try test_vectors_expect("{\"a\": [1, [2, 3, 4]]}", &nested);
    try test_vectors_expect("[]", &empty);
}

test "a key token unescapes ~0 and ~1, and the last of a repeated key wins" {
    const escapes = [_]TestVector{
        .{ .expected = "1", .pointer = "/a~0b" },
        .{ .expected = null, .pointer = "/a~1b" },
        .{ .expected = "2", .pointer = "/c~1d" },
        .{ .expected = null, .pointer = "/c~0d" },
        .{ .expected = "3", .pointer = "/~01" },
        .{ .expected = "4", .pointer = "/a\x00bc" },
    };

    const repeated = [_]TestVector{
        .{ .expected = "2", .pointer = "/a" },
        .{ .expected = "{\"c\":1}", .pointer = "/b" },
        .{ .expected = "1", .pointer = "/b/c" },
        .{ .expected = null, .pointer = "/b/c/d" },
        .{ .expected = null, .pointer = "/b/d" },
        .{ .expected = null, .pointer = "/x" },
    };

    const source =
        \\{"a~b": 1, "c/d": 2, "~1": 3, "a\u0000bc": 4}
    ;

    try test_vectors_expect(source, &escapes);
    try test_vectors_expect("{\"a\": 1, \"a\": 2, \"b\": {\"c\": 1}}", &repeated);

    try test_vectors_expect("1", &.{
        .{ .expected = "1", .pointer = "" },
        .{ .expected = null, .pointer = "/" },
    });
}

test "path_find indexes arrays by the same rule and matches keys without unescaping" {
    const sources = try test_sources_create("{\"a\": [1, [2, 3, 4]], \"b/c\": {\"~0\": true}}");
    defer testing.allocator.destroy(sources);

    const Node = document_module.Node;
    const document = &sources.document.document;
    const root = document.root();
    const found = document.path_find(root, &.{ "a", "1", "2" }) orelse return error.Missing;
    const escaped = document.path_find(root, &.{ "b/c", "~0" }) orelse return error.Missing;

    try testing.expectEqual(@as(?i64, 4), document.integer_of(found));
    try testing.expectEqual(@as(?bool, true), document.boolean_of(escaped));
    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "a", "01" }));
    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "a", "-" }));
    try testing.expectEqual(@as(?Node, root), document.path_find(root, &.{}));
    try testing.expectEqual(@as(?Node, null), document.pointer_find(root, "/b~1c/~0"));
}

test "an index is 0 or a digit run without a leading zero that fits in a u32" {
    try testing.expectEqual(@as(?u32, 0), index_of("0"));
    try testing.expectEqual(@as(?u32, 7), index_of("7"));
    try testing.expectEqual(@as(?u32, 1024), index_of("1024"));
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), index_of("4294967295"));

    const refused = [_][]const u8{
        "",
        "00",
        "01",
        "-1",
        "+1",
        "1_0",
        " 1",
        "1 ",
        "4294967296",
        "-",
        "a",
    };

    for (refused) |text| try testing.expectEqual(@as(?u32, null), index_of(text));
}

test "a token compares to a key with ~0 and ~1 translated as it goes" {
    const equal = [_]Candidate{
        .{ .key = "a/b", .token = "a~1b" },
        .{ .key = "a~b", .token = "a~0b" },
        .{ .key = "~1", .token = "~01" },
        .{ .key = "/", .token = "~1" },
        .{ .key = "", .token = "" },
        .{ .key = "plain", .token = "plain" },
    };

    const unequal = [_]Candidate{
        .{ .key = "a~b", .token = "a~1b" },
        .{ .key = "a", .token = "" },
        .{ .key = "", .token = "~0" },
        .{ .key = "ab", .token = "a~0" },
        .{ .key = "~", .token = "~1" },
    };

    for (equal) |candidate| try testing.expect(token_equal(candidate));
    for (unequal) |candidate| try testing.expect(!token_equal(candidate));
}

const TestParent = struct {
    expected: Expected,
    pointer: []const u8,

    const Expected = union(enum) {
        found: Found,
        malformed,
        missing,
        root,
    };

    const Found = struct {
        parent: []const u8,
        token: []const u8,
    };
};

fn test_parent_expect(comptime Source: type, source: *const Source, vector: TestParent) !void {
    assert(source.node_count > 0);
    assert(vector.pointer.len < 4096);

    const resolved = parent_resolve(Source, source, vector.pointer);

    switch (vector.expected) {
        .found => |expected| {
            const found = switch (resolved) {
                .found => |found| found,
                .malformed, .missing, .root => return error.ParentUnresolved,
            };

            const parent = source.pointer_find(source.root(), expected.parent) orelse
                return error.ParentMissing;

            try testing.expectEqual(parent, found.parent);
            try testing.expectEqualStrings(expected.token, found.token);
        },
        .malformed => try testing.expect(resolved == .malformed),
        .missing => try testing.expect(resolved == .missing),
        .root => try testing.expect(resolved == .root),
    }
}

test "parent_resolve splits a pointer into its parent node and its last escaped token" {
    const vectors = [_]TestParent{
        .{ .expected = .root, .pointer = "" },
        .{ .expected = .malformed, .pointer = "a" },
        .{ .expected = .malformed, .pointer = "/a~2" },
        .{ .expected = .malformed, .pointer = "/a/b~" },
        .{ .expected = .missing, .pointer = "/x/y" },
        .{ .expected = .missing, .pointer = "/a/5/x" },
        .{ .expected = .missing, .pointer = "/a/-/x" },
        .{ .expected = .missing, .pointer = "/a/01/x" },
        .{ .expected = .missing, .pointer = "/n/x/y" },
        .{ .expected = .{ .found = .{ .parent = "", .token = "a" } }, .pointer = "/a" },
        .{ .expected = .{ .found = .{ .parent = "", .token = "" } }, .pointer = "/" },
        .{ .expected = .{ .found = .{ .parent = "", .token = "x" } }, .pointer = "/x" },
        .{ .expected = .{ .found = .{ .parent = "/a", .token = "-" } }, .pointer = "/a/-" },
        .{ .expected = .{ .found = .{ .parent = "/a", .token = "9" } }, .pointer = "/a/9" },
        .{ .expected = .{ .found = .{ .parent = "/a/1", .token = "b" } }, .pointer = "/a/1/b" },
        .{ .expected = .{ .found = .{ .parent = "/m~0n", .token = "~1" } }, .pointer = "/m~0n/~1" },
        .{ .expected = .{ .found = .{ .parent = "/n", .token = "x" } }, .pointer = "/n/x" },
    };

    const sources = try test_sources_create("{\"a\": [1, {\"b\": 2}], \"m~n\": {}, \"n\": 3}");
    defer testing.allocator.destroy(sources);

    for (vectors) |vector| {
        try test_parent_expect(document_module.Document, &sources.document.document, vector);
        try test_parent_expect(tree_module.Tree, &sources.tree.tree, vector);
    }
}

test "token_unescape inverts the escape of every key and agrees with token_equal" {
    const keys = [_][]const u8{ "", "plain", "a/b", "a~b", "~1", "/~", "~~//", "caf\u{e9}~0" };
    var escaped_buffer: [32]u8 = undefined;
    var target: [32]u8 = undefined;

    for (keys) |key| {
        var length: u32 = 0;

        for (key) |byte| {
            const escaped: []const u8 = switch (byte) {
                '/' => "~1",
                '~' => "~0",
                else => &.{byte},
            };

            @memcpy(escaped_buffer[length..][0..escaped.len], escaped);
            length += @intCast(escaped.len);
        }

        const token = escaped_buffer[0..length];

        try testing.expectEqualStrings(key, token_unescape(token, &target));
        try testing.expect(token_equal(.{ .key = key, .token = token }));
    }
}

const TestPending = struct {
    length: u32,
    node: document_module.Node,
    pointer: [256]u8,
};

fn test_segment_append(
    pending: *TestPending,
    parent: *const TestPending,
    segment: []const u8,
) void {
    assert(parent.length + 1 + 2 * segment.len <= pending.pointer.len);
    assert(parent.length <= parent.pointer.len);

    @memcpy(pending.pointer[0..parent.length], parent.pointer[0..parent.length]);
    pending.pointer[parent.length] = '/';

    var length: u32 = parent.length + 1;

    for (segment) |byte| {
        const escaped: []const u8 = switch (byte) {
            '/' => "~1",
            '~' => "~0",
            else => &.{byte},
        };

        @memcpy(pending.pointer[length..][0..escaped.len], escaped);
        length += @intCast(escaped.len);
    }

    pending.length = length;
}

fn test_located_expect(
    document: *const document_module.Document,
    node: document_module.Node,
    expected: []const u8,
) !void {
    assert(@backingInt(node) < document.node_count);
    assert(expected.len < 256);

    var buffer: [256]u8 = undefined;
    const position = document.position_of(node);
    const found = pointer_at(document.source, position, &buffer) orelse return error.PointerLong;

    try testing.expectEqualStrings(expected, found);
}

fn test_pointers_expect(source: []const u8) !void {
    assert(source.len > 0);
    assert(source.len < 4096);

    const sources = try test_sources_create(source);
    defer testing.allocator.destroy(sources);

    const document = &sources.document.document;
    const pending = try testing.allocator.alloc(TestPending, document.node_count + 1);
    defer testing.allocator.free(pending);

    pending[0] = .{ .length = 0, .node = document.root(), .pointer = undefined };

    var count: u32 = 1;

    for (0..document.node_count + 1) |_| {
        if (count == 0) break;

        count -= 1;

        const current = pending[count];
        const prefix = current.pointer[0..current.length];

        try test_located_expect(document, current.node, prefix);
        try testing.expectEqual(current.node, document.pointer_find(document.root(), prefix).?);

        switch (document.kind_of(current.node)) {
            .array => {
                var items = document.items(current.node);

                for (0..document.count_of(current.node)) |index| {
                    const item = items.next() orelse break;
                    var digits: [index_digits_max]u8 = undefined;
                    const segment = try std.mem.print(&digits, "{d}", .{index});

                    test_segment_append(&pending[count], &current, segment);
                    pending[count].node = item;
                    count += 1;
                }
            },
            .object => {
                var entries = document.entries(current.node);

                for (0..document.count_of(current.node)) |_| {
                    const member = entries.next() orelse break;
                    const child = &pending[count];

                    test_segment_append(child, &current, document.text_of(member.key).?);
                    child.node = member.value;
                    count += 1;

                    try test_located_expect(document, member.key, child.pointer[0..child.length]);
                }
            },
            .boolean, .null_value, .number, .string => {},
        }
    }

    try testing.expectEqual(@as(u32, 0), count);
}

test pointer_at {
    const source =
        \\{"servers": [{"host": "a", "port": 80},
        \\ {"host": "b", "port": "x"}]}
    ;

    var buffer: [64]u8 = undefined;
    const port: Position = .{ .column = 24, .line = 2 };

    try testing.expectEqualStrings("/servers/1/port", pointer_at(source, port, &buffer).?);
    try testing.expectEqual(@as(?[]const u8, null), pointer_at(source, port, buffer[0..8]));
}

test "pointer_at names every value and key of a document by the pointer that finds it" {
    const sources = [_][]const u8{
        "{\"foo\": [\"bar\", \"baz\"], \"\": 0, \"a/b\": 1, \"c%d\": 2, \"e^f\": 3, \"g|h\": 4, " ++
            "\"i\\\\j\": 5, \"k\\\"l\": 6, \" \": 7, \"m~n\": 8}",
        "[1, [2, [3, {\"x\": [4, 5]}]],\n {\"y\\u00e9\": null, " ++
            "\"z\": [true, false, {}], \"w\": []}]",
        "  \"just a string\"  ",
        "-1.5e3",
        "{\"a\\/b\": {\"c~d\": 1, \"~/~\": [{}]}, \"\\u0041\": 2}",
        "[[[[[[[[\"deep\"]]]]]]]]",
        "{\r\n  \"crlf\": [\r\n    1,\r\n    2\r\n  ]\r\n}",
    };

    for (sources) |source| try test_pointers_expect(source);
}

test "pointer_at names the open member or element where a document stops being well formed" {
    const Case = struct {
        expected: []const u8,
        source: []const u8,
    };

    const cases = [_]Case{
        .{ .expected = "/a", .source = "{\"a\": }" },
        .{ .expected = "/a/2", .source = "{\"a\": [1, 2,, 3]}" },
        .{ .expected = "", .source = "{x}" },
        .{ .expected = "/list/0/k", .source = "{\"list\": [{\"k\": tru}]}" },
        .{ .expected = "", .source = "[1] 2" },
    };

    for (cases) |case| {
        const sources = test_sources_create(case.source);
        const failure = sources catch |err| switch (err) {
            error.Malformed => {
                var document: TestDocument = undefined;

                try testing.expectError(error.Malformed, document.parse(case.source));

                var buffer: [64]u8 = undefined;
                const found = pointer_at(case.source, document.diagnostic(), &buffer).?;

                try testing.expectEqualStrings(case.expected, found);

                continue;
            },
            else => return err,
        };

        testing.allocator.destroy(failure);

        return error.SourceAccepted;
    }
}

test "pointer_at reads a position past a closing bracket as the container that bracket closed" {
    const source = "{\"a\": {\"b\": 1}, \"c\": [2, {\"d\": 3}]}";

    var buffer: [64]u8 = undefined;
    const after_a: Position = .{ .column = 15, .line = 1 };
    const after_d: Position = .{ .column = 34, .line = 1 };
    const past_end: Position = .{ .column = 99, .line = 9 };

    try testing.expectEqualStrings("/a", pointer_at(source, after_a, &buffer).?);
    try testing.expectEqualStrings("/c/1", pointer_at(source, after_d, &buffer).?);
    try testing.expectEqualStrings("", pointer_at(source, past_end, &buffer).?);
}
