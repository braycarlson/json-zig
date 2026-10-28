const std = @import("std");

const document_module = @import("document.zig");
const storage_module = @import("storage.zig");
const string = @import("string.zig");
const tokenizer_module = @import("tokenizer.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Backend = document_module.Backend;
const Document = document_module.Document;
const Node = document_module.Node;
const ObjectMap = std.json.ObjectMap;
const Prng = std.Random.DefaultPrng;
const Record = storage_module.Record;
const Storage = storage_module.Storage;
const Tokenizer = tokenizer_module.Tokenizer;
const Value = std.json.Value;
const Writer = writer_module.Writer;

const codepoint_count_max: u32 = 8;
const depth_generate_max: u32 = 6;
const escaped_expansion_max: u32 = 3;
const index_text_bytes_max: u32 = 12;
const input_bytes_max: u32 = 16 * 1024;
const mutation_count_max: u32 = 4;
const output_bytes_max: u32 = 4 * 1024 * 1024;
const output_line_bytes_max: u32 = 2 + 16 * (depth_generate_max + mutation_count_max);
const pointer_bytes_max: u32 = 4096;
const pointer_depth_max: u32 = 8;
const pointer_slack_bytes: u32 = 8;
const pointer_walk_count: u32 = 4;
const reference_bytes_min: u32 = 1024 * 1024;
const run_bytes_max: u32 = 70;
const width_max: u32 = 6;
const width_wide_max: u32 = 160;

comptime {
    assert(depth_generate_max + mutation_count_max < tokenizer_module.depth_max);
    assert(output_bytes_max >= input_bytes_max * output_line_bytes_max);
    assert(width_wide_max > width_max);
    assert(pointer_bytes_max > pointer_depth_max * (2 * (run_bytes_max + 4 * codepoint_count_max)));
}

const escapes = [_][]const u8{
    "\\\"",
    "\\\\",
    "\\/",
    "\\b",
    "\\f",
    "\\n",
    "\\r",
    "\\t",
    "\\u0000",
    "\\u00e9",
    "\\u20ac",
    "\\ud83d\\ude00",
};

const keys = [_][]const u8{
    "\"a\"",
    "\"\\u0061\"",
    "\"b\"",
    "\"\"",
    "\"caf\u{e9}\"",
    "\"caf\\u00e9\"",
    "\"a/b\"",
    "\"m~n\"",
    "\"~1\"",
    "\"/\"",
    "\"\\u002f~0\"",
    "\"a key longer than one chunk of thirty-two bytes\"",
    "\"a key longer than one chunk of thirty-two byte\\u0073\"",
};

const mutation_alphabet = "{}[]:,\"\\ -+.eE0123456789tfnaulrsx\x00\x1f\xc3\xed\xa0\xff";

const numbers = [_][]const u8{
    "0",
    "-0",
    "1",
    "-1",
    "0.5",
    "-0.0",
    "1e2",
    "2.5E-3",
    "1e400",
    "-1e400",
    "1e-400",
    "9223372036854775807",
    "-9223372036854775808",
    "9223372036854775808",
    "18446744073709551615",
    "18446744073709551616",
    "123456789012345678901234567890",
};

const whitespace = [_][]const u8{ "", "", "", " ", "\n", "\t", "\r\n", "  " };

const Frame = struct {
    first: bool,
    object: bool,
    remaining: u32,
};

const Pair = struct {
    node: Node,
    value: *const Value,
};

const PointerStep = struct {
    next: ?u32,
};

const PointerWalk = struct {
    expected: ?u32,
    length: u32,
    segment_count: u32,
};

pub const PointerScratch = struct {
    indices: [pointer_depth_max][index_text_bytes_max]u8,
    pointer: [pointer_bytes_max + pointer_slack_bytes]u8,
    segments: [pointer_depth_max][]const u8,
};

pub const State = struct {
    compact: [escaped_expansion_max * input_bytes_max]u8,
    documents: [2]Document,
    input: [input_bytes_max]u8,
    pairs: [input_bytes_max]Pair,
    pointers: PointerScratch,
    pretty: [output_bytes_max]u8,
    records: [2][input_bytes_max]Record,
    rewrite: [escaped_expansion_max * input_bytes_max]u8,
    scratch: [input_bytes_max]Node,
    text: [2][input_bytes_max]u8,
};

const Verdict = struct {
    failure: ?Tokenizer.Error,
    index: u32,
};

pub fn event(state: *State, prng: *Prng, reference: []u8) !void {
    assert(reference.len >= reference_bytes_min);
    assert(state.input.len == input_bytes_max);

    const input = input_generate(state, prng) catch |err| switch (err) {
        error.WriteFailed => return,
        else => return err,
    };

    const verdict = verdict_of(input);
    const document = &state.documents[0];
    const capacity = @max(input.len, 1);

    const storage: Storage = .{
        .records = state.records[0][0..capacity],
        .text = state.text[0][0..input.len],
    };

    const parsed = document.parse(storage, input);
    const failure: ?Document.Error = if (parsed) |_| null else |err| err;

    try exact_check(state, input, failure);

    if (failure) |err| return refusal_check(document, &verdict, err);

    if (verdict.failure != null) return error.DocumentAccepted;

    var allocator: std.heap.FixedBufferAllocator = .init(reference);

    const value = std.json.parseFromSliceLeaky(Value, allocator.allocator(), input, .{
        .duplicate_field_behavior = .use_last,
        .ignore_unknown_fields = false,
        .max_value_len = null,
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch return error.ReferenceRefused;

    try walk_compare(state, document, &value);
    try pointers_check(Document, document, prng, &state.pointers);
    try round_trips_check(state, prng, &value);
}

fn exact_check(state: *State, input: []const u8, failure: ?Document.Error) !void {
    assert(input.len <= input_bytes_max);
    if (failure == null) assert(state.documents[0].node_count > 0);
    if (failure != null) assert(state.documents[0].node_count == 0);

    const fast = &state.documents[0];
    const exact = &state.documents[1];
    const capacity = @max(input.len, 1);

    const storage: Storage = .{
        .records = state.records[1][0..capacity],
        .text = state.text[1][0..input.len],
    };

    const reparsed = document_module.parse_exact(exact, storage, input);

    if (failure) |err| {
        if (reparsed) |_| return error.ExactAccepted else |other| {
            if (err != other) return error.ExactErrorDisagreement;
        }

        const diagnostic_equal = std.meta.eql(fast.diagnostic, exact.diagnostic);
        if (!diagnostic_equal) return error.ExactDiagnosticDisagreement;
        const scalar_accepted = document_module.parse_attempt(.scalar, exact, storage, input);
        if (scalar_accepted) return error.ScalarAccepted;
        const simd_accepted = document_module.parse_attempt(.simd, exact, storage, input);
        if (simd_accepted) return error.SimdAccepted;

        return;
    }

    reparsed catch return error.ExactRefused;

    if (fast.node_count != exact.node_count) return error.ExactNodeCountDisagreement;
    if (fast.depth != exact.depth) return error.ExactDepthDisagreement;
    if (fast.text_count != exact.text_count) return error.ExactTextCountDisagreement;

    const fast_records = std.mem.sliceAsBytes(fast.storage.records[0..fast.node_count]);
    const exact_records = std.mem.sliceAsBytes(exact.storage.records[0..exact.node_count]);
    if (!std.mem.eql(u8, fast_records, exact_records)) return error.ExactRecordDisagreement;

    const fast_text = fast.storage.text[0..fast.text_count];
    const exact_text = exact.storage.text[0..exact.text_count];
    if (!std.mem.eql(u8, fast_text, exact_text)) return error.ExactTextDisagreement;

    try backend_check(.simd, fast, exact, storage, input);
    try backend_check(.scalar, fast, exact, storage, input);
}

const Disagreement = enum {
    depth,
    node_count,
    records,
    refused,
    text,
    text_count,
};

fn backend_check(
    comptime backend: Backend,
    fast: *const Document,
    other: *Document,
    storage: Storage,
    input: []const u8,
) !void {
    comptime assert(@backingInt(backend) < std.enums.values(Backend).len);
    assert(fast.node_count > 0);
    assert(input.len <= input_bytes_max);
    assert(storage.text.len >= input.len);

    const found = backend_disagreement(backend, fast, other, storage, input) orelse return;

    std.debug.print("{s} backend disagreement: {s}\n", .{ @tagName(backend), @tagName(found) });

    return error.BackendDisagreement;
}

fn backend_disagreement(
    comptime backend: Backend,
    fast: *const Document,
    other: *Document,
    storage: Storage,
    input: []const u8,
) ?Disagreement {
    comptime assert(@backingInt(backend) < std.enums.values(Backend).len);
    assert(fast.node_count > 0);
    assert(input.len <= input_bytes_max);
    assert(storage.text.len >= input.len);

    if (!document_module.parse_attempt(backend, other, storage, input)) return .refused;
    if (other.node_count != fast.node_count) return .node_count;
    if (other.depth != fast.depth) return .depth;
    if (other.text_count != fast.text_count) return .text_count;

    const fast_records = std.mem.sliceAsBytes(fast.storage.records[0..fast.node_count]);
    const other_records = std.mem.sliceAsBytes(storage.records[0..other.node_count]);
    if (!std.mem.eql(u8, fast_records, other_records)) return .records;

    const fast_text = fast.storage.text[0..fast.text_count];
    const other_text = storage.text[0..other.text_count];
    if (!std.mem.eql(u8, fast_text, other_text)) return .text;
    return null;
}

fn NodeType(comptime Source: type) type {
    return @TypeOf(Source.root(undefined));
}

pub fn pointers_check(
    comptime Source: type,
    source: *const Source,
    prng: *Prng,
    scratch: *PointerScratch,
) !void {
    assert(source.node_count > 0);
    assert(scratch.pointer.len == pointer_bytes_max + pointer_slack_bytes);

    for (0..pointer_walk_count) |_| {
        const walk = try pointer_walk(Source, source, prng, scratch);

        try pointer_expect(Source, source, scratch, &walk);
    }
}

fn pointer_walk(
    comptime Source: type,
    source: *const Source,
    prng: *Prng,
    scratch: *PointerScratch,
) !PointerWalk {
    assert(source.node_count > 0);
    assert(pointer_depth_max <= scratch.segments.len);

    var node = source.root();
    var walk: PointerWalk = .{ .expected = @backingInt(node), .length = 0, .segment_count = 0 };

    for (0..pointer_depth_max) |_| {
        if (source.count_of(node) == 0) break;
        if (prng.random().uintLessThan(u32, 4) == 0) break;

        const step = switch (source.kind_of(node)) {
            .array => try index_step(Source, source, prng, scratch, &walk, node),
            .object => key_step(Source, source, prng, scratch, &walk, node),
            .boolean, .null_value, .number, .string => unreachable,
        };

        const next = step.next orelse break;

        node = @fromBackingInt(next);
    }

    assert(walk.segment_count <= pointer_depth_max);

    return walk;
}

fn index_step(
    comptime Source: type,
    source: *const Source,
    prng: *Prng,
    scratch: *PointerScratch,
    walk: *PointerWalk,
    array: NodeType(Source),
) !PointerStep {
    assert(source.kind_of(array) == .array);
    assert(walk.segment_count < pointer_depth_max);

    const count = source.count_of(array);
    const random = prng.random();
    const index = random.uintAtMost(u32, count);
    var items = source.items(array);
    var expected: ?NodeType(Source) = null;

    for (0..count) |position| {
        const child = items.next() orelse return error.ItemMissing;

        if (position == index) expected = child;
    }

    if (source.item(array, index) != expected) return error.ItemDisagreement;

    const buffer = &scratch.indices[walk.segment_count];

    const token = switch (random.uintLessThan(u32, 8)) {
        0 => "-",
        1 => try std.mem.print(buffer, "0{d}", .{index}),
        else => try std.mem.print(buffer, "{d}", .{index}),
    };

    if (!std.mem.eql(u8, token, "0")) {
        if (token[0] == '-') expected = null;
        if (token[0] == '0') expected = null;
    }

    pointer_append(scratch, walk, token);
    walk.expected = if (expected) |child| @backingInt(child) else null;

    return .{ .next = walk.expected };
}

fn key_step(
    comptime Source: type,
    source: *const Source,
    prng: *Prng,
    scratch: *PointerScratch,
    walk: *PointerWalk,
    object: NodeType(Source),
) PointerStep {
    assert(source.kind_of(object) == .object);
    assert(walk.segment_count < pointer_depth_max);

    const position = prng.random().uintLessThan(u32, source.count_of(object));
    var entries = source.entries(object);
    var key: []const u8 = "";

    for (0..position + 1) |_| {
        const entry = entries.next() orelse return .{ .next = null };

        key = source.text_of(entry.key).?;
    }

    if (walk.length + 1 + 2 * key.len > pointer_bytes_max) return .{ .next = null };

    const expected = source.member(object, key) orelse unreachable;

    pointer_append(scratch, walk, key);
    walk.expected = @backingInt(expected);

    return .{ .next = walk.expected };
}

fn pointer_append(scratch: *PointerScratch, walk: *PointerWalk, text: []const u8) void {
    assert(walk.length + 1 + 2 * text.len <= pointer_bytes_max);
    assert(walk.segment_count < pointer_depth_max);

    const pointer = scratch.pointer[1..];

    pointer[walk.length] = '/';
    walk.length += 1;

    for (text) |byte| {
        const escaped: []const u8 = switch (byte) {
            '/' => "~1",
            '~' => "~0",
            else => &.{byte},
        };

        @memcpy(pointer[walk.length..][0..escaped.len], escaped);
        walk.length += @intCast(escaped.len);
    }

    scratch.segments[walk.segment_count] = text;
    walk.segment_count += 1;
}

fn pointer_expect(
    comptime Source: type,
    source: *const Source,
    scratch: *PointerScratch,
    walk: *const PointerWalk,
) !void {
    assert(walk.length <= pointer_bytes_max);
    assert(walk.segment_count <= pointer_depth_max);

    const pointer = scratch.pointer[1..][0..walk.length];
    const found = source.pointer_find(source.root(), pointer);
    const found_path = source.path_find(source.root(), scratch.segments[0..walk.segment_count]);
    const expected: ?NodeType(Source) = if (walk.expected) |index| @fromBackingInt(index) else null;
    if (found != expected) return error.PointerDisagreement;
    if (found_path != expected) return error.PathDisagreement;

    scratch.pointer[0] = 'x';

    const unanchored = source.pointer_find(source.root(), scratch.pointer[0 .. walk.length + 1]);

    @memcpy(scratch.pointer[1 + walk.length ..][0..2], "~2");

    const escape_invalid = source.pointer_find(source.root(), pointer.ptr[0 .. walk.length + 2]);
    const tilde_last = source.pointer_find(source.root(), pointer.ptr[0 .. walk.length + 1]);

    if (unanchored != null) return error.MalformedResolved;
    if (escape_invalid != null) return error.MalformedResolved;
    if (tilde_last != null) return error.MalformedResolved;
}

fn verdict_of(input: []const u8) Verdict {
    assert(input.len <= input_bytes_max);

    var tokenizer: Tokenizer = .init(input);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch |err| {
            return .{ .failure = err, .index = tokenizer.index };
        };

        if (token == .end) return .{ .failure = null, .index = tokenizer.index };
    }

    unreachable;
}

fn refusal_check(document: *const Document, verdict: *const Verdict, err: Document.Error) !void {
    assert(document.node_count == 0);
    assert(document.source.len <= input_bytes_max);
    assert(err != error.NodesExhausted);
    assert(err != error.TextExhausted);

    const failure = verdict.failure orelse return error.DocumentRefused;
    if (!std.mem.eql(u8, @errorName(err), @errorName(failure))) return error.ErrorDisagreement;

    const position = tokenizer_module.position_of(document.source, verdict.index);
    if (position.line != document.diagnostic.line) return error.DiagnosticDisagreement;
    if (position.column != document.diagnostic.column) return error.DiagnosticDisagreement;
}

fn walk_compare(state: *State, document: *const Document, root: *const Value) !void {
    assert(document.node_count > 0);
    assert(document.node_count <= state.pairs.len);

    state.pairs[0] = .{ .node = document.root(), .value = root };

    var count: u32 = 1;

    for (0..document.node_count + 1) |_| {
        if (count == 0) return;

        count -= 1;

        try pair_compare(state, document, state.pairs[count], &count);
    }

    return error.WalkUnbounded;
}

fn pair_compare(state: *State, document: *const Document, pair: Pair, count: *u32) !void {
    assert(@backingInt(pair.node) < document.node_count);
    assert(count.* < state.pairs.len);

    const kind = document.kind_of(pair.node);

    switch (pair.value.*) {
        .array => |*array| {
            if (kind != .array) return error.WalkDisagreement;
            if (document.count_of(pair.node) != array.items.len) return error.WalkDisagreement;

            var items = document.items(pair.node);

            for (array.items) |*item| {
                const node = items.next() orelse return error.WalkDisagreement;

                state.pairs[count.*] = .{ .node = node, .value = item };
                count.* += 1;
            }
        },
        .bool => |flag| {
            const boolean = document.boolean_of(pair.node) orelse return error.WalkDisagreement;
            if (boolean != flag) return error.WalkDisagreement;
        },
        .float, .integer => unreachable,
        .null => if (kind != .null_value) return error.WalkDisagreement,
        .number_string => |text| {
            const source = document.source_of(pair.node);

            if (kind != .number) return error.WalkDisagreement;
            if (!std.mem.eql(u8, text, source)) return error.WalkDisagreement;
        },
        .object => |*object| try object_compare(state, document, pair.node, object, count),
        .string => |text| {
            const actual = document.text_of(pair.node) orelse return error.WalkDisagreement;
            if (!std.mem.eql(u8, text, actual)) return error.WalkDisagreement;
        },
    }
}

fn object_compare(
    state: *State,
    document: *const Document,
    object: Node,
    reference: *const ObjectMap,
    count: *u32,
) !void {
    assert(@backingInt(object) < document.node_count);
    assert(count.* < state.pairs.len);

    if (document.kind_of(object) != .object) return error.WalkDisagreement;
    if (try unique_count(document, object) != reference.count()) return error.WalkDisagreement;

    var iterator = reference.iterator();

    for (0..reference.count()) |_| {
        const entry = iterator.next() orelse return error.EntryMissing;
        const node = document.member(object, entry.key_ptr.*) orelse return error.WalkDisagreement;

        state.pairs[count.*] = .{ .node = node, .value = entry.value_ptr };
        count.* += 1;
    }
}

fn unique_count(document: *const Document, object: Node) !u32 {
    assert(@backingInt(object) < document.node_count);
    assert(document.kind_of(object) == .object);

    var entries = document.entries(object);
    var result: u32 = 0;

    for (0..document.count_of(object)) |_| {
        const entry = entries.next() orelse return error.EntryMissing;

        const last = document.member(object, document.text_of(entry.key).?) orelse {
            return error.MemberMissing;
        };

        if (last == entry.value) result += 1;
    }

    assert(result <= document.count_of(object));

    return result;
}

fn round_trips_check(state: *State, prng: *Prng, value: *const Value) !void {
    assert(state.documents[0].node_count > 0);
    assert(state.compact.len == escaped_expansion_max * input_bytes_max);

    const options_sorted = options_random(prng);
    var options = options_sorted;

    options.layout = .compact;

    const compact = try written(&state.documents[0], &options, &state.compact);

    try reparse_check(state, compact);

    const rewrite = try written(&state.documents[1], &options, &state.rewrite);
    if (!std.mem.eql(u8, compact, rewrite)) return error.RewriteDisagreement;

    options.layout = .pretty;

    try reparse_check(state, try written(&state.documents[0], &options, &state.pretty));
    try sorted_check(state, &options_sorted, value);
}

fn options_random(prng: *Prng) Writer.Options {
    const random = prng.random();

    const result: Writer.Options = .{
        .indent = random.intRangeAtMost(u8, 1, 16),
        .layout = if (random.boolean()) .compact else .pretty,
        .non_finite = .refused,
        .notation = if (random.boolean()) .decimal else .ecmascript,
        .utf8 = random.enumValue(Writer.UTF8),
    };

    assert(result.indent >= 1);
    assert(result.indent <= 16);

    return result;
}

fn written(document: *const Document, options: *const Writer.Options, buffer: []u8) ![]const u8 {
    assert(document.node_count > 0);
    assert(buffer.len >= input_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try document.write(&sink, options.*);

    return sink.buffered();
}

fn reparse_check(state: *State, output: []const u8) !void {
    assert(output.len > 0);
    assert(state.documents[0].node_count > 0);

    try state.documents[1].parse(storage_second(state), output);

    const comparison: document_module.Comparison = .{
        .left = &state.documents[0],
        .right = &state.documents[1],
    };

    if (!document_module.structure_equal(comparison)) return error.RoundTripDisagreement;
}

fn storage_second(state: *State) Storage {
    assert(state.records[1].len == input_bytes_max);
    assert(state.text[1].len == input_bytes_max);

    return .{ .records = &state.records[1], .text = &state.text[1] };
}

fn sorted_check(state: *State, options: *const Writer.Options, value: *const Value) !void {
    assert(state.documents[0].node_count <= state.scratch.len);
    assert(options.indent >= 1);

    const document = &state.documents[0];
    const scratch = state.scratch[0..document.node_count];
    var sink: std.Io.Writer = .fixed(&state.pretty);
    var writer: Writer = .init(&sink, options.*);

    try document.node_write_sorted(scratch, &writer, document.root());

    writer.finish();

    const sorted = &state.documents[1];

    try sorted.parse(storage_second(state), sink.buffered());
    try walk_compare(state, sorted, value);
    try order_check(sorted);
}

fn order_check(document: *const Document) !void {
    assert(document.node_count > 0);
    assert(document.node_count <= input_bytes_max);

    for (0..document.node_count) |index| {
        const node: Node = @fromBackingInt(@as(u32, @intCast(index)));
        if (document.kind_of(node) != .object) continue;

        var entries = document.entries(node);
        var previous: []const u8 = "";

        for (0..document.count_of(node)) |position| {
            const entry = entries.next() orelse return error.EntryMissing;
            const key = document.text_of(entry.key).?;

            if (position > 0) {
                if (std.mem.order(u8, previous, key) != .lt) return error.OrderDisagreement;
            }

            previous = key;
        }
    }
}

fn input_generate(state: *State, prng: *Prng) ![]const u8 {
    assert(state.input.len == input_bytes_max);
    assert(mutation_count_max < input_bytes_max);

    var sink: std.Io.Writer = .fixed(state.input[0 .. input_bytes_max - mutation_count_max]);

    try document_generate(prng, &sink);

    var length: u32 = @intCast(sink.end);

    if (prng.random().boolean()) length = input_mutate(prng, &state.input, length);

    assert(length <= input_bytes_max);

    return state.input[0..length];
}

pub fn document_generate(prng: *Prng, sink: *std.Io.Writer) !void {
    assert(sink.end == 0);
    assert(sink.buffer.len > 0);

    var frames: [depth_generate_max]Frame = undefined;
    var depth: u32 = 0;

    try whitespace_write(prng, sink);
    try value_generate(&frames, prng, sink, &depth);

    for (0..input_bytes_max) |_| {
        if (depth == 0) break;

        const frame = &frames[depth - 1];

        if (frame.remaining == 0) {
            try whitespace_write(prng, sink);
            try sink.writeByte(if (frame.object) '}' else ']');

            depth -= 1;

            continue;
        }

        if (!frame.first) try sink.writeByte(',');

        frame.first = false;
        frame.remaining -= 1;

        try whitespace_write(prng, sink);

        if (frame.object) try key_write(prng, sink);

        try value_generate(&frames, prng, sink, &depth);
    }

    assert(depth == 0);

    try whitespace_write(prng, sink);
}

fn value_generate(
    frames: *[depth_generate_max]Frame,
    prng: *Prng,
    sink: *std.Io.Writer,
    depth: *u32,
) !void {
    assert(depth.* <= depth_generate_max);
    assert(sink.end <= sink.buffer.len);

    const random = prng.random();
    const choice_count: u32 = if (depth.* == depth_generate_max) 5 else 7;
    var choice = random.uintLessThan(u32, choice_count);

    if (depth.* == 0) {
        if (random.uintLessThan(u32, 4) > 0) choice = random.intRangeAtMost(u32, 5, 6);
    }

    switch (choice) {
        0 => try sink.writeAll(if (random.boolean()) "true" else "false"),
        1 => try sink.writeAll("null"),
        2 => try number_write(prng, sink),
        3, 4 => try string_write(prng, sink),
        5, 6 => {
            const object = choice == 6;
            const wide = random.uintLessThan(u32, 16) == 0;

            frames[depth.*] = .{
                .first = true,
                .object = object,
                .remaining = random.uintAtMost(u32, if (wide) width_wide_max else width_max),
            };

            depth.* += 1;

            try sink.writeByte(if (object) '{' else '[');
        },
        else => unreachable,
    }
}

fn key_write(prng: *Prng, sink: *std.Io.Writer) !void {
    assert(sink.end <= sink.buffer.len);
    assert(keys.len > 0);

    const random = prng.random();

    if (random.uintLessThan(u32, 4) == 0) {
        try string_write(prng, sink);
    } else {
        try sink.writeAll(keys[random.uintLessThan(u32, keys.len)]);
    }

    try whitespace_write(prng, sink);
    try sink.writeByte(':');
    try whitespace_write(prng, sink);
}

fn number_write(prng: *Prng, sink: *std.Io.Writer) !void {
    assert(sink.end <= sink.buffer.len);
    assert(numbers.len > 0);

    const random = prng.random();

    switch (random.uintLessThan(u32, 4)) {
        0 => try sink.writeAll(numbers[random.uintLessThan(u32, numbers.len)]),
        1 => try sink.print("{d}", .{random.int(i64)}),
        2 => try sink.print("{d}", .{random.int(u64)}),
        3 => try sink.print("{d}.{d}e{d}", .{
            random.int(i16),
            random.int(u16),
            random.intRangeAtMost(i32, -400, 400),
        }),
        else => unreachable,
    }
}

fn string_write(prng: *Prng, sink: *std.Io.Writer) !void {
    assert(sink.end <= sink.buffer.len);
    assert(escapes.len > 0);

    const random = prng.random();
    const count = random.uintAtMost(u32, codepoint_count_max);
    const run_position = random.uintAtMost(u32, count);
    const run_wide = random.uintLessThan(u32, 4) == 0;
    const run_length = if (run_wide) random.uintAtMost(u32, run_bytes_max) else 0;

    try sink.writeByte('"');

    for (0..count + 1) |position| {
        if (position == run_position) try sink.splatByteAll('w', run_length);
        if (position == count) break;

        if (random.uintLessThan(u32, 4) == 0) {
            try sink.writeAll(escapes[random.uintLessThan(u32, escapes.len)]);
        } else {
            var buffer: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(codepoint_random(prng), &buffer);

            try string.escape_write(sink, buffer[0..length], .trusted);
        }
    }

    try sink.writeByte('"');
}

fn codepoint_random(prng: *Prng) u21 {
    assert(std.unicode.utf8ValidCodepoint(0x10ffff));
    assert(!std.unicode.utf8ValidCodepoint(0xd800));

    const random = prng.random();

    const result: u21 = switch (random.uintLessThan(u32, 5)) {
        0 => random.intRangeAtMost(u21, 0x20, 0x7e),
        1 => random.uintLessThan(u21, 0x20),
        2 => random.intRangeAtMost(u21, 0x80, 0x7ff),
        3 => random.intRangeAtMost(u21, 0xe000, 0xffff),
        4 => random.intRangeAtMost(u21, 0x10000, 0x10ffff),
        else => unreachable,
    };

    assert(std.unicode.utf8ValidCodepoint(result));

    return result;
}

fn whitespace_write(prng: *Prng, sink: *std.Io.Writer) !void {
    assert(sink.end <= sink.buffer.len);
    assert(whitespace.len > 0);

    try sink.writeAll(whitespace[prng.random().uintLessThan(u32, whitespace.len)]);
}

fn input_mutate(prng: *Prng, input: *[input_bytes_max]u8, length: u32) u32 {
    assert(length + mutation_count_max <= input.len);
    assert(mutation_alphabet.len > 0);

    const random = prng.random();
    var result = length;

    for (0..random.uintAtMost(u32, mutation_count_max)) |_| {
        const position = random.uintAtMost(u32, result);
        const replacement = mutation_alphabet[random.uintLessThan(u32, mutation_alphabet.len)];

        switch (random.uintLessThan(u32, 3)) {
            0 => {
                const tail = input[position..result];

                std.mem.copyBackwards(u8, input[position + 1 ..][0..tail.len], tail);
                input[position] = replacement;
                result += 1;
            },
            1 => {
                if (position == result) continue;

                const tail = input[position + 1 .. result];

                std.mem.copyForwards(u8, input[position..][0..tail.len], tail);
                result -= 1;
            },
            2 => {
                if (position == result) continue;

                input[position] = replacement;
            },
            else => unreachable,
        }
    }

    assert(result <= length + mutation_count_max);

    return result;
}
