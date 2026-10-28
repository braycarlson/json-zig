const std = @import("std");
const assert = std.debug.assert;

const codec = @import("codec.zig");
const document_module = @import("document.zig");
const pointer_module = @import("pointer.zig");
const region_module = @import("region.zig");
const rename_module = @import("rename.zig");
const storage_module = @import("storage.zig");
const stream_module = @import("stream.zig");
const string = @import("string.zig");
const structural_module = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");
const tree_module = @import("tree.zig");
const writer_module = @import("writer.zig");

pub const Capacity = storage_module.Capacity;
pub const CapacityError = codec.CapacityError;
pub const DecodeError = codec.DecodeError;
pub const DecodeOptions = codec.DecodeOptions;
pub const Diagnostic = codec.Diagnostic;
pub const Document = document_module.Document;
pub const DocumentType = document_module.DocumentType;
pub const Empty = codec.Empty;
pub const EncodeErrorType = codec.EncodeErrorType;
pub const EncodeOptions = codec.EncodeOptions;
pub const Entries = document_module.Entries;
pub const EntryType = codec.EntryType;

pub const Error = DecodeError ||
    Document.Error ||
    std.mem.Allocator.Error ||
    Stream.Error ||
    Tokenizer.Error ||
    Tree.CapacityError ||
    Tree.ConflictError ||
    Tree.PatchError ||
    Tree.ValueError ||
    UnescapeError ||
    Writer.Error;

pub const Items = document_module.Items;
pub const MismatchError = codec.MismatchError;
pub const Node = document_module.Node;
pub const Position = tokenizer_module.Position;
pub const Raw = codec.Raw;
pub const Region = region_module.Region;
pub const Rename = rename_module.Rename;
pub const Shape = codec.Shape;
pub const Storage = storage_module.Storage;
pub const StorageType = storage_module.StorageType;
pub const Stream = stream_module.Stream;
pub const StreamType = stream_module.StreamType;
pub const Syntax = tokenizer_module.Syntax;
pub const SyntaxError = codec.SyntaxError;
pub const Token = tokenizer_module.Token;
pub const Tokenizer = tokenizer_module.Tokenizer;
pub const TokenizerType = tokenizer_module.TokenizerType;
pub const Tree = tree_module.Tree;
pub const TreeType = tree_module.TreeType;
pub const UnescapeError = string.UnescapeError;
pub const Writer = writer_module.Writer;

pub const decode = codec.decode;
pub const decode_relaxed = codec.decode_relaxed;
pub const default_of = codec.default_of;
pub const encode = codec.encode;

pub fn message(err: Error) []const u8 {
    assert(@errorName(err).len > 0);

    const result: []const u8 = switch (err) {
        error.BufferExhausted => "a token does not fit the reader's buffer",
        error.DepthExceeded => "nesting is deeper than the limit",
        error.EnumerationUnrecognized => "an unrecognized enumeration value cannot be written",
        error.FloatNonFinite => "a non-finite float cannot be written",
        error.Malformed => "malformed JSON",
        error.MemberMissing => "missing key",
        error.MemberUnknown => "unknown key",
        error.Mismatch => "the value does not match the field's type",
        error.NodesExhausted => "the document holds more nodes than its capacity",
        error.NumberInvalid => "invalid number",
        error.OutOfMemory => "out of memory",
        error.Overflow => "the unescaped text does not fit the buffer",
        error.PatchMalformed => "malformed JSON Patch operation",
        error.PathMissing => "the path does not exist",
        error.ReadFailed => "the input could not be read",
        error.RawMalformed => "raw text is not one JSON value",
        error.RegionFull => "the region is full",
        error.TestFailed => "a JSON Patch test operation failed",
        error.TextExhausted => "the document holds more text than its capacity",
        error.Utf8Invalid => "invalid UTF-8",
        error.WriteFailed => "the output could not be written",
    };

    assert(result.len > 0);

    return result;
}

pub const pointer_at = pointer_module.pointer_at;
pub const region_bytes_max = codec.region_bytes_max;
pub const rename = rename_module.rename;
pub const shape_of = codec.shape_of;
pub const unescape = string.unescape;

pub const limits = struct {
    pub const depth_max: u32 = tokenizer_module.depth_max;
    pub const input_bytes_max: u32 = tokenizer_module.input_bytes_max;
    pub const node_count_max: u32 = storage_module.node_count_limit;
    pub const text_bytes_max: u32 = storage_module.text_bytes_limit;
};

pub const structural = struct {
    pub const Cursor = structural_module.Cursor;
    pub const Indexer = structural_module.Indexer;
    pub const Indices = structural_module.Indices;
    pub const index_escaped = structural_module.index_escaped;
    pub const index_position_mask = structural_module.index_position_mask;
    pub const lane_count = tokenizer_module.lane_count;
    pub const number_end = tokenizer_module.number_end;
    pub const scalar_ended = tokenizer_module.scalar_ended;
    pub const string_close_find = structural_module.string_close_find;
    pub const unescape_checked = string.unescape_checked;
    pub const utf8_valid = structural_module.utf8_valid;
};

test Tokenizer {
    var tokenizer: Tokenizer = .init("{\"name\": [true, 2]}");

    const expected = [_]Token{
        .object_begin,
        .{ .key = "name" },
        .array_begin,
        .{ .boolean = true },
        .{ .number = "2" },
        .array_end,
        .object_end,
        .end,
    };

    for (expected) |token_expected| {
        const token = try tokenizer.next();

        try std.testing.expectEqualDeep(token_expected, token);
    }

    try std.testing.expectEqual(@as(u32, 0), tokenizer.depth);

    var refused: Tokenizer = .init("[1,\n 2,]");

    for (0..3) |_| _ = try refused.next();

    const refusal = refused.next();

    try std.testing.expectError(error.Malformed, refusal);
    try std.testing.expectEqual(Position{ .column = 4, .line = 2 }, refused.diagnostic());
}

test TokenizerType {
    var tokenizer: TokenizerType(.relaxed) = .init("// limits\n[1, NaN, /* none */ -inf,]");

    const expected = [_]Token{
        .array_begin,
        .{ .number = "1" },
        .{ .number = "NaN" },
        .{ .number = "-inf" },
        .array_end,
        .end,
    };

    for (expected) |token_expected| {
        const token = try tokenizer.next();

        try std.testing.expectEqualDeep(token_expected, token);
    }
}

test Syntax {
    const Relaxed = TokenizerType(Syntax.relaxed);

    var relaxed: Relaxed = .init("{\"a\": 1,}");
    var strict: Tokenizer = .init("{\"a\": 1,}");

    for (0..3) |_| {
        _ = try relaxed.next();
        _ = try strict.next();
    }

    const token = try relaxed.next();
    const refused = strict.next();

    try std.testing.expectEqualDeep(Token.object_end, token);
    try std.testing.expectError(error.Malformed, refused);
    try std.testing.expect(Tokenizer == TokenizerType(.strict));
}

test Stream {
    const lines = "{\"id\": 1, \"tags\": [\"a\"]}\n{\"id\": 2}\r\n\n{\"id\": 3}\n";
    var source: std.Io.Reader = .fixed(lines);
    var window: [32]u8 = undefined;
    var limited = source.limited(.unlimited, &window);
    var stream: Stream = undefined;

    stream.init(&limited.interface, .{ .values = .sequence });

    var region_buffer: [256]u8 = undefined;
    var region: Region = .init(&region_buffer);
    var total: u32 = 0;

    for (0..4) |_| {
        const text = try stream.value_next();
        if (text.len == 0) break;

        var record: struct { id: u32 } = undefined;

        region.reset();

        try decode(@TypeOf(record), &region, text, &record, .{
            .diagnostic = null,
            .unknown_members = .ignored,
        });

        total += record.id;
    }

    const after = try stream.value_next();

    try std.testing.expectEqual(@as(u32, 6), total);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test StreamType {
    const input = "// settings\n[1, \"two\", /* three */ NaN,]";
    var source: std.Io.Reader = .fixed(input);
    var window: [16]u8 = undefined;
    var limited = source.limited(.unlimited, &window);
    var stream: StreamType(.relaxed) = undefined;

    stream.init(&limited.interface, .{ .values = .single });

    const expected = [_]Token{
        .array_begin,
        .{ .number = "1" },
        .{ .string = "two" },
        .{ .number = "NaN" },
        .array_end,
        .end,
    };

    for (expected) |token_expected| {
        const token = try stream.next();

        try std.testing.expectEqualDeep(token_expected, token);
    }

    var long_source: std.Io.Reader = .fixed("[\"longer than sixteen bytes\"]");
    var long_limited = long_source.limited(.unlimited, &window);
    var long: Stream = undefined;

    long.init(&long_limited.interface, .{ .values = .single });

    const begin = try long.next();
    const refused = long.next();

    try std.testing.expectEqualDeep(Token.array_begin, begin);
    try std.testing.expectError(error.BufferExhausted, refused);
    try std.testing.expectEqual(Position{ .column = 2, .line = 1 }, long.diagnostic());
}

test message {
    var region_buffer: [256]u8 = undefined;
    var region: Region = .init(&region_buffer);
    var diagnostic: Diagnostic = undefined;
    var target: struct { port: u16 } = undefined;

    const result = decode(@TypeOf(target), &region, "{\"port\": \"80\"}", &target, .{
        .diagnostic = &diagnostic,
    });

    const sentence = "the value does not match the field's type";

    try std.testing.expectError(error.Mismatch, result);
    try std.testing.expectEqualStrings(sentence, message(error.Mismatch));
    try std.testing.expectEqual(Position{ .line = 1, .column = 10 }, diagnostic.position);

    const names = @typeInfo(Error).error_set.error_names.?;

    inline for (names, 0..) |left, index| {
        const text = message(@field(Error, left));

        try std.testing.expect(text.len > 0);

        inline for (names[index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, text, message(@field(Error, right))));
        }
    }
}

test Capacity {
    const Small = DocumentType(.{ .node_count_max = 4, .text_bytes_max = 8 });

    const document = try std.testing.allocator.create(Small);
    defer std.testing.allocator.destroy(document);

    try document.parse("[1, 2, 3]");
    try std.testing.expectEqual(@as(u32, 3), document.count_of(document.root()));

    try std.testing.expectError(error.NodesExhausted, document.parse("[1, 2, 3, 4]"));
    try std.testing.expectError(error.TextExhausted, document.parse("[\"\\u0041 escaped text\"]"));
}

test CapacityError {
    const Ports = []const u16;
    const input = "[80, 443, 8080, 8443, 9000, 9090, 9443, 10000, 10443]";

    var small: [16]u8 align(16) = undefined;
    var region: Region = .init(&small);
    var ports: Ports = undefined;

    const refused = decode(Ports, &region, input, &ports, .{ .diagnostic = null });

    try std.testing.expectError(error.RegionFull, refused);

    const fault: CapacityError = error.RegionFull;

    try std.testing.expectEqualStrings("the region is full", message(fault));
}

test DecodeError {
    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var port: u16 = undefined;

    const cases = [_]struct { err: DecodeError, input: []const u8 }{
        .{ .err = error.Malformed, .input = "80 81" },
        .{ .err = error.Mismatch, .input = "70000" },
        .{ .err = error.Mismatch, .input = "\"80\"" },
    };

    for (cases) |case| {
        const result = decode(u16, &region, case.input, &port, .{ .diagnostic = null });

        try std.testing.expectError(case.err, result);
    }

    const syntax: SyntaxError = error.Malformed;
    const mismatch: MismatchError = error.Mismatch;
    const capacity: CapacityError = error.DepthExceeded;
    const errors = [_]DecodeError{ syntax, mismatch, capacity };

    try std.testing.expectEqual(@as(usize, 3), errors.len);
}

test DecodeOptions {
    const Server = struct { port: u16 };
    const input = "{\"port\": 80, \"debug\": true}";

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var server: Server = undefined;

    try decode(Server, &region, input, &server, .{
        .diagnostic = null,
        .unknown_members = .ignored,
    });

    try std.testing.expectEqual(@as(u16, 80), server.port);

    var diagnostic: Diagnostic = undefined;

    const refused = decode(Server, &region, input, &server, .{
        .diagnostic = &diagnostic,
        .unknown_members = .refused,
    });

    try std.testing.expectError(error.MemberUnknown, refused);
    try std.testing.expectEqualStrings("debug", diagnostic.member);
    try std.testing.expectEqual(Position{ .column = 14, .line = 1 }, diagnostic.position);
}

test Diagnostic {
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,

        pub const json = .{ .host = "Host" };
    };

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var server: Server = undefined;
    var diagnostic: Diagnostic = undefined;

    const missing = decode(Server, &region, "{\"port\": 80}", &server, .{
        .diagnostic = &diagnostic,
    });

    try std.testing.expectError(error.MemberMissing, missing);
    try std.testing.expectEqualStrings("Host", diagnostic.member);
    try std.testing.expectEqual(Position{ .column = 13, .line = 1 }, diagnostic.position);

    const mismatched = decode(Server, &region, "{\"Host\": 1}", &server, .{
        .diagnostic = &diagnostic,
    });

    try std.testing.expectError(error.Mismatch, mismatched);
    try std.testing.expectEqualStrings("", diagnostic.member);
    try std.testing.expectEqual(Position{ .column = 10, .line = 1 }, diagnostic.position);
}

test EncodeOptions {
    const Server = struct {
        host: []const u8,
        port: ?u16 = null,
    };

    const server: Server = .{ .host = "localhost" };
    var buffer: [64]u8 = undefined;

    var omitted_sink: std.Io.Writer = .fixed(&buffer);
    var omitted: Writer = .init(&omitted_sink, test_writer_options);

    try encode(Server, &omitted, &server, .{ .null_members = .omitted });
    omitted.finish();

    try std.testing.expectEqualStrings("{\"host\":\"localhost\"}", omitted_sink.buffered());

    var emitted_sink: std.Io.Writer = .fixed(&buffer);
    var emitted: Writer = .init(&emitted_sink, test_writer_options);

    try encode(Server, &emitted, &server, .{ .null_members = .emitted });
    emitted.finish();

    try std.testing.expectEqualStrings(
        "{\"host\":\"localhost\",\"port\":null}",
        emitted_sink.buffered(),
    );
}

test Error {
    var tokenizer: Tokenizer = .init("[1,]");

    for (0..2) |_| _ = try tokenizer.next();

    var empty: [0]u8 = undefined;
    const tokenized = tokenizer.next();
    const unescaped = unescape("\\x", &empty);

    const failures = [_]Error{
        if (tokenized) |_| return error.TokenAccepted else |err| err,
        if (unescaped) |_| return error.EscapeAccepted else |err| err,
        error.NodesExhausted,
        error.WriteFailed,
    };

    for (failures) |failure| try std.testing.expect(message(failure).len > 0);

    try std.testing.expectEqual(@as(Error, error.Malformed), failures[0]);
    try std.testing.expectEqual(@as(Error, error.Malformed), failures[1]);
}

test MismatchError {
    const Size = struct { height: i32, width: i32 };

    var buffer: [256]u8 = undefined;
    var region: Region = .init(&buffer);
    var size: Size = undefined;

    const cases = [_]struct { err: MismatchError, input: []const u8 }{
        .{ .err = error.MemberMissing, .input = "{\"height\": 1}" },
        .{ .err = error.MemberUnknown, .input = "{\"height\": 1, \"width\": 2, \"depth\": 3}" },
        .{ .err = error.Mismatch, .input = "{\"height\": 1, \"width\": 2.5}" },
    };

    for (cases) |case| {
        const result = decode(Size, &region, case.input, &size, .{
            .diagnostic = null,
            .unknown_members = .refused,
        });

        try std.testing.expectError(case.err, result);
    }
}

test Node {
    const Small = DocumentType(.{ .node_count_max = 16, .text_bytes_max = 16 });

    const document = try std.testing.allocator.create(Small);
    defer std.testing.allocator.destroy(document);

    try document.parse("{\"name\": \"warbler\", \"ports\": [8080, 8443]}");

    const root: Node = document.root();
    const ports = document.member(root, "ports") orelse return error.PortsMissing;
    const second = document.item(ports, 1) orelse return error.PortMissing;

    try std.testing.expectEqual(Document.Kind.array, document.kind_of(ports));
    try std.testing.expectEqual(@as(?i64, 8443), document.integer_of(second));
    try std.testing.expectEqual(@as(?Node, null), document.item(ports, 2));
}

test Position {
    const Small = DocumentType(.{ .node_count_max = 16, .text_bytes_max = 16 });

    const document = try std.testing.allocator.create(Small);
    defer std.testing.allocator.destroy(document);

    try document.parse("{\n  \"ports\": [\n    8080\n  ]\n}");

    const ports = document.member(document.root(), "ports") orelse return error.PortsMissing;
    const port = document.item(ports, 0) orelse return error.PortMissing;

    const opened: Position = .{ .column = 1, .line = 1 };
    const listed: Position = .{ .column = 5, .line = 3 };

    try std.testing.expectEqual(opened, document.position_of(document.root()));
    try std.testing.expectEqual(listed, document.position_of(port));

    try std.testing.expectError(error.Malformed, document.parse("[\n  1,\n  ]"));
    try std.testing.expectEqual(Position{ .column = 3, .line = 3 }, document.diagnostic());
}

test Shape {
    const Celsius = struct {
        tenths: i32,

        pub const json_shape: Shape = .adapted;

        pub fn json_decode(degrees: f64) MismatchError!@This() {
            if (!std.math.isFinite(degrees)) return error.Mismatch;

            return .{ .tenths = @intFromFloat(@round(degrees * 10)) };
        }

        pub fn json_encode(celsius: *const @This(), writer: *Writer) Writer.Error!void {
            assert(!writer.string_open);

            try writer.float(@as(f64, @floatFromInt(celsius.tenths)) / 10);
        }
    };

    try std.testing.expectEqual(Shape.adapted, shape_of(Celsius));
    try std.testing.expectEqual(Shape.raw, shape_of(Raw));
    try std.testing.expectEqual(Shape.map, shape_of([]const EntryType(u8)));

    var buffer: [64]u8 = undefined;
    var region: Region = .init(&buffer);
    var readings: []const Celsius = undefined;

    try decode([]const Celsius, &region, "[21.5, -3]", &readings, .{ .diagnostic = null });

    try std.testing.expectEqual(@as(i32, 215), readings[0].tenths);
    try std.testing.expectEqual(@as(i32, -30), readings[1].tenths);

    var sink_buffer: [32]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&sink_buffer);
    var writer: Writer = .init(&sink, test_writer_options);

    try encode([]const Celsius, &writer, &readings, .{ .null_members = .omitted });
    writer.finish();

    try std.testing.expectEqualStrings("[21.5,-3]", sink.buffered());
}

test SyntaxError {
    const inputs = [_][]const u8{ "[1,]", "{\"a\" 1}", "tru", "\"\\q\"", "" };

    for (inputs) |input| {
        var tokenizer: Tokenizer = .init(input);

        const failed: bool = for (0..input.len + 1) |_| {
            const token = tokenizer.next() catch |err| {
                const fault: SyntaxError = switch (err) {
                    error.Malformed => error.Malformed,
                    error.DepthExceeded => return error.DepthUnexpected,
                };

                try std.testing.expectEqualStrings("malformed JSON", message(fault));

                break true;
            };

            if (token == .end) break false;
        } else false;

        try std.testing.expect(failed);
    }
}

test Token {
    var tokenizer: Tokenizer = .init("{\"caf\\u00e9\": \"line\\nbreak\"}");

    _ = try tokenizer.next();

    const key = try tokenizer.next();
    const value = try tokenizer.next();

    try std.testing.expectEqualStrings("caf\\u00e9", key.key);
    try std.testing.expectEqualStrings("line\\nbreak", value.string);

    var buffer: [16]u8 = undefined;

    try std.testing.expectEqualStrings("caf\u{e9}", try unescape(key.key, &buffer));
    try std.testing.expectEqualStrings("line\nbreak", try unescape(value.string, &buffer));
}

test UnescapeError {
    var buffer: [4]u8 = undefined;

    try std.testing.expectEqualStrings("a\tb", try unescape("a\\tb", &buffer));
    try std.testing.expectError(error.Overflow, unescape("abcdef", &buffer));
    try std.testing.expectError(error.Malformed, unescape("\\u12", &buffer));
    try std.testing.expectError(error.Malformed, unescape("\\ud800", &buffer));

    const fault: UnescapeError = error.Overflow;

    const sentence = "the unescaped text does not fit the buffer";

    try std.testing.expectEqualStrings(sentence, message(fault));
}

test structural {
    const input = "{\"a\": [1, \"b\\n\"]}";

    var indexer: structural.Indexer = .empty;
    var indices: structural.Indices = undefined;
    var cursor: structural.Cursor = .{
        .count = 0,
        .exhausted = false,
        .failed = false,
        .indexer = &indexer,
        .indices = &indices,
        .position = 0,
    };

    const expected = [_]u32{ 0, 1, 4, 6, 7, 8, 10, 15 | structural.index_escaped, 16 };

    for (expected) |entry| {
        const found = cursor.next(input);

        try std.testing.expectEqual(@as(?u32, entry), found);
    }

    const after = cursor.next(input);

    try std.testing.expectEqual(@as(?u32, null), after);
    try std.testing.expect(cursor.exhausted);
    try std.testing.expect(!cursor.failed);
    try std.testing.expectEqual(@as(u32, 14), structural.string_close_find(input, 15));

    const numbers = "-12.5e3, 7";
    const escaped = "a\\nb\\u00e9";

    var target: [escaped.len + structural.lane_count]u8 = undefined;

    const end = try structural.number_end(numbers, 0, true);
    const written = structural.unescape_checked(escaped, escaped.len, &target).?;

    try std.testing.expectEqual(@as(u32, 7), end);
    try std.testing.expect(structural.scalar_ended(numbers, end));
    try std.testing.expect(!structural.scalar_ended(numbers, end - 1));
    try std.testing.expectEqualStrings("a\nb\u{e9}", target[0..written]);
    try std.testing.expect(structural.utf8_valid("caf\xc3\xa9"));
    try std.testing.expect(!structural.utf8_valid("\xed\xa0\x80"));
}

test region_bytes_max {
    const Ports = []const u16;
    const input = "[80, 443, 8080]";
    var region_buffer: [region_bytes_max(Ports, input.len)]u8 = undefined;
    var region: Region = .init(&region_buffer);
    var ports: Ports = undefined;

    try decode(Ports, &region, input, &ports, .{ .diagnostic = null, .unknown_members = .refused });
    try std.testing.expectEqualSlices(u16, &.{ 80, 443, 8080 }, ports);
}

test EncodeErrorType {
    const Plain = struct { name: []const u8, port: u16 };
    const Measured = struct { name: []const u8, ratio: f64 };

    try std.testing.expect(EncodeErrorType(Plain) == error{WriteFailed});
    try std.testing.expect(EncodeErrorType(Measured) == error{ FloatNonFinite, WriteFailed });
    const RawError = error{ DepthExceeded, RawMalformed, WriteFailed };

    try std.testing.expect(EncodeErrorType(Raw) == RawError);
}

test limits {
    const opens: [limits.depth_max + 1]u8 = @splat('[');
    const closes: [limits.depth_max + 1]u8 = @splat(']');
    const deepest = opens[1..] ++ "1" ++ closes[1..];
    const deeper = opens ++ "1" ++ closes;

    for (std.enums.values(TestReader)) |reader| {
        try test_nesting_read(reader, deepest);
        try std.testing.expectError(error.DepthExceeded, test_nesting_read(reader, deeper));
    }

    var buffer: [deepest.len]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    var writer: Writer = .init(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    for (0..limits.depth_max) |_| try writer.array_begin();

    try std.testing.expectError(error.DepthExceeded, writer.array_begin());
    try writer.integer(1);

    for (0..limits.depth_max) |_| try writer.array_end();

    writer.finish();

    try std.testing.expectEqualStrings(deepest, sink.buffered());
}

const test_writer_options: Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

const TestReader = enum {
    decode,
    decode_relaxed,
    document,
    document_relaxed,
    stream,
    tokenizer_relaxed,
};

fn test_nesting_read(reader: TestReader, input: []const u8) !void {
    assert(input.len > 0);
    assert(input.len <= 2 * limits.depth_max + 3);

    var document: DocumentType(.{ .node_count_max = 256, .text_bytes_max = 512 }) = undefined;
    var region_buffer: [64]u8 = undefined;
    var region: Region = .init(&region_buffer);
    var raw: Raw = .{};
    const options: DecodeOptions = .{ .diagnostic = null, .unknown_members = .refused };
    var tokenizer: TokenizerType(.relaxed) = .init(input);

    switch (reader) {
        .decode => try decode(Raw, &region, input, &raw, options),
        .decode_relaxed => try decode_relaxed(Raw, &region, input, &raw, options),
        .document => try document.parse(input),
        .document_relaxed => try document.parse_relaxed(input),
        .stream => {
            var source: std.Io.Reader = .fixed(input);
            var stream: Stream = undefined;

            stream.init(&source, .{ .values = .single });
            raw.text = try stream.value_next();
        },
        .tokenizer_relaxed => {
            for (0..input.len + 1) |_| {
                if (try tokenizer.next() == .end) break;
            }
        },
    }

    switch (reader) {
        .decode, .decode_relaxed, .stream => {
            try std.testing.expectEqualStrings(input, raw.text);
        },
        .document, .document_relaxed => {
            try std.testing.expectEqual(limits.depth_max, document.document.depth);
        },
        .tokenizer_relaxed => try std.testing.expectEqual(0, tokenizer.depth),
    }
}
