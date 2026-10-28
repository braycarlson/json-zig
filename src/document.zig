const std = @import("std");

const number_module = @import("number.zig");
const pointer_module = @import("pointer.zig");
const scalar_module = @import("scalar.zig");
const storage_module = @import("storage.zig");
const string = @import("string.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Capacity = storage_module.Capacity;
const Chunk = @Vector(lane_count, u8);
const Event = tokenizer_module.Event;
const Mask = @Int(.unsigned, lane_count);
const Position = tokenizer_module.Position;
const Record = storage_module.Record;
const Storage = storage_module.Storage;
const StorageType = storage_module.StorageType;
const Syntax = tokenizer_module.Syntax;
const Tokenizer = tokenizer_module.Tokenizer;
const TokenizerType = tokenizer_module.TokenizerType;
const Writer = writer_module.Writer;

const backend_default: Backend = if (simd_enabled) .simd else .scalar;
const backend_scalar_bytes_max: u32 = 256;
const container_none: u32 = std.math.maxInt(u32);
const depth_max = tokenizer_module.depth_max;
const input_bytes_max = tokenizer_module.input_bytes_max;
const lane_count = tokenizer_module.lane_count;
const link_of = storage_module.link_of;
const node_count_limit = storage_module.node_count_limit;
const simd_enabled = std.simd.suggestVectorLength(u8) != null;
const text_bytes_limit = storage_module.text_bytes_limit;

comptime {
    assert(lane_count == 16 or lane_count == 32);
    assert(depth_max <= std.math.maxInt(u8));
    assert(node_count_limit < container_none);
}

pub const Backend = enum {
    scalar,
    simd,
};

pub const Node = enum(u32) { _ };

pub const Document = struct {
    depth: u32,
    diagnostic: Position,
    indexer: structural.Indexer,
    indices: structural.Indices,
    node_count: u32,
    source: []const u8,
    storage: Storage,
    text_count: u32,
    tokenizer: Tokenizer,

    pub const CapacityError = error{
        DepthExceeded,
        NodesExhausted,
        TextExhausted,
    };

    pub const Error = CapacityError || SyntaxError;

    pub const Kind = enum {
        array,
        boolean,
        null_value,
        number,
        object,
        string,
    };

    pub const SyntaxError = error{Malformed};

    pub const member = if (structural.functions_aligned) member_aligned else member_unaligned;

    pub fn parse(document: *Document, storage: Storage, source: []const u8) Error!void {
        assert(source.len <= input_bytes_max);
        assert(storage.records.len > 0);
        assert(storage.records.len <= node_count_limit);
        assert(storage.text.len <= text_bytes_limit);
        assert(disjoint(&storage, source));

        try document.build(.strict, .fast, &document.tokenizer, storage, source);
    }

    pub fn parse_relaxed(document: *Document, storage: Storage, source: []const u8) Error!void {
        assert(source.len <= input_bytes_max);
        assert(storage.records.len > 0);
        assert(storage.records.len <= node_count_limit);
        assert(storage.text.len <= text_bytes_limit);
        assert(disjoint(&storage, source));

        var tokenizer: TokenizerType(.relaxed) = undefined;

        tokenizer_module.tokenizer_reset(.relaxed, &tokenizer, source);

        try document.build(.relaxed, .exact, &tokenizer, storage, source);
    }

    pub fn root(document: *const Document) Node {
        assert(document.node_count > 0);
        assert(document.node_count <= document.storage.records.len);

        return @fromBackingInt(0);
    }

    pub fn kind_of(document: *const Document, node: Node) Kind {
        assert(@backingInt(node) < document.node_count);

        const result: Kind = switch (document.record_of(node).kind()) {
            .array => .array,
            .false_value, .true_value => .boolean,
            .null_value => .null_value,
            .number => .number,
            .object => .object,
            .string, .string_escaped => .string,
        };

        return result;
    }

    pub fn count_of(document: *const Document, node: Node) u32 {
        assert(@backingInt(node) < document.node_count);

        const record = document.record_of(node);

        const result = switch (record.kind()) {
            .array, .object => record.size,
            .false_value, .null_value, .number, .string, .string_escaped, .true_value => 0,
        };

        assert(result < document.node_count);

        return result;
    }

    noinline fn member_aligned(
        document: *const Document,
        object: Node,
        key: []const u8,
    ) align(64) ?Node {
        assert(@backingInt(object) < document.node_count);
        assert(key.len <= input_bytes_max);

        return member_body(document, object, key);
    }

    noinline fn member_unaligned(
        document: *const Document,
        object: Node,
        key: []const u8,
    ) ?Node {
        assert(@backingInt(object) < document.node_count);
        assert(key.len <= input_bytes_max);

        return member_body(document, object, key);
    }

    inline fn member_body(
        document: *const Document,
        object: Node,
        key: []const u8,
    ) ?Node {
        assert(@backingInt(object) < document.node_count);
        assert(key.len <= input_bytes_max);

        const record = document.record_of(object);
        if (record.kind() != .object) return null;

        var cursor = @backingInt(object) + 1;
        var result: ?Node = null;

        for (0..record.size) |_| {
            if (document.text_equal(cursor, key)) result = @fromBackingInt(cursor + 1);

            cursor = document.sibling_of(cursor + 1);
        }

        assert(cursor == record.target());

        return result;
    }

    pub fn item(document: *const Document, array: Node, index: u32) ?Node {
        assert(@backingInt(array) < document.node_count);
        assert(@min(index, document.count_of(array)) < document.node_count);

        const record = document.record_of(array);
        if (record.kind() != .array) return null;
        if (index >= record.size) return null;

        var cursor = @backingInt(array) + 1;

        for (0..index) |_| cursor = document.sibling_of(cursor);

        assert(cursor < record.target());

        return @fromBackingInt(cursor);
    }

    pub fn path_find(document: *const Document, start: Node, segments: []const []const u8) ?Node {
        assert(@backingInt(start) < document.node_count);
        assert(segments.len <= input_bytes_max);

        return pointer_module.path_find(Document, document, start, segments);
    }

    pub fn pointer_find(document: *const Document, start: Node, pointer: []const u8) ?Node {
        assert(@backingInt(start) < document.node_count);
        assert(pointer.len <= input_bytes_max);

        return pointer_module.pointer_find(Document, document, start, pointer);
    }

    pub fn entries(document: *const Document, object: Node) Entries {
        assert(@backingInt(object) < document.node_count);

        const record = document.record_of(object);
        const count = if (record.kind() == .object) record.size else 0;

        return .{ .cursor = @backingInt(object) + 1, .document = document, .remaining = count };
    }

    pub fn items(document: *const Document, array: Node) Items {
        assert(@backingInt(array) < document.node_count);

        const record = document.record_of(array);
        const count = if (record.kind() == .array) record.size else 0;

        return .{ .cursor = @backingInt(array) + 1, .document = document, .remaining = count };
    }

    pub fn text_of(document: *const Document, node: Node) ?[]const u8 {
        assert(@backingInt(node) < document.node_count);

        const record = document.record_of(node);

        const result = switch (record.kind()) {
            .string => document.source[record.start + 1 .. record.end - 1],
            .string_escaped => document.storage.text[record.target()..][0..record.size],
            .array, .false_value, .null_value, .number, .object, .true_value => return null,
        };

        assert(result.len < record.end - record.start);

        return result;
    }

    pub fn text_is(document: *const Document, node: Node, text: []const u8) bool {
        assert(@backingInt(node) < document.node_count);
        assert(text.len <= input_bytes_max);

        if (document.kind_of(node) != .string) return false;
        return document.text_equal(@backingInt(node), text);
    }

    pub fn boolean_of(document: *const Document, node: Node) ?bool {
        assert(@backingInt(node) < document.node_count);

        const result: ?bool = switch (document.record_of(node).kind()) {
            .false_value => false,
            .true_value => true,
            .array, .null_value, .number, .object, .string, .string_escaped => null,
        };

        if (result != null) assert(document.kind_of(node) == .boolean);

        return result;
    }

    pub fn integer_of(document: *const Document, node: Node) ?i64 {
        assert(@backingInt(node) < document.node_count);

        const text = document.number_text_of(node) orelse return null;
        return number_module.integer_of_text(text);
    }

    pub fn unsigned_of(document: *const Document, node: Node) ?u64 {
        assert(@backingInt(node) < document.node_count);

        const text = document.number_text_of(node) orelse return null;
        return number_module.unsigned_of_text(text);
    }

    pub fn float_of(document: *const Document, node: Node) ?f64 {
        assert(@backingInt(node) < document.node_count);

        const text = document.number_text_of(node) orelse return null;
        return number_module.float_of_text(text);
    }

    pub fn source_of(document: *const Document, node: Node) []const u8 {
        assert(@backingInt(node) < document.node_count);

        const record = document.record_of(node);
        const result = document.source[record.start..record.end];

        assert(result.len > 0);

        return result;
    }

    pub fn position_of(document: *const Document, node: Node) Position {
        assert(@backingInt(node) < document.node_count);

        const start = document.record_of(node).start;
        const result = tokenizer_module.position_of(document.source, start);

        assert(result.line >= 1);
        assert(result.column >= 1);

        return result;
    }

    pub fn write(
        document: *const Document,
        sink: *std.Io.Writer,
        options: Writer.Options,
    ) std.Io.Writer.Error!void {
        assert(document.node_count > 0);
        assert(document.depth <= depth_max);
        assert(options.indent >= 1);

        var writer: Writer = .init(sink, options);

        document.node_write(&writer, document.root()) catch |err| switch (err) {
            error.DepthExceeded => unreachable,
            error.WriteFailed => return error.WriteFailed,
        };

        writer.finish();
    }

    pub fn node_write(
        document: *const Document,
        writer: *Writer,
        node: Node,
    ) (Writer.CapacityError || std.Io.Writer.Error)!void {
        assert(@backingInt(node) < document.node_count);
        assert(writer.depth <= depth_max);

        try document.depth_check(writer, node);

        var walk: Walk = .{
            .depth = 0,
            .frames = undefined,
            .order = .source,
            .scratch = &.{},
            .scratch_used = 0,
        };

        try document.walk_write(&walk, writer, node);
    }

    pub fn node_write_sorted(
        document: *const Document,
        scratch: []Node,
        writer: *Writer,
        node: Node,
    ) (Writer.CapacityError || std.Io.Writer.Error)!void {
        assert(@backingInt(node) < document.node_count);
        assert(scratch.len >= document.node_count);

        try document.depth_check(writer, node);

        var walk: Walk = .{
            .depth = 0,
            .frames = undefined,
            .order = .sorted,
            .scratch = scratch,
            .scratch_used = 0,
        };

        try document.walk_write(&walk, writer, node);
    }

    inline fn build(
        document: *Document,
        comptime syntax: Syntax,
        comptime path: Path,
        tokenizer: *TokenizerType(syntax),
        storage: Storage,
        source: []const u8,
    ) Error!void {
        comptime assert(@sizeOf(TokenizerType(syntax)) == @sizeOf(Tokenizer));
        assert(source.len <= input_bytes_max);
        assert(storage.records.len > 0);

        document.depth = 0;
        document.diagnostic = .{ .column = 0, .line = 0 };
        document.node_count = 0;
        document.source = source;
        document.storage = storage;
        document.text_count = 0;

        var builder: Builder = .{
            .cursor = builder_cursor_empty,
            .failure_index = 0,
            .frames = undefined,
            .records = storage.records,
            .source = source,
            .text = storage.text,
            .text_count = 0,
        };

        if (path == .fast) {
            comptime assert(syntax == .strict);

            const built = if (source.len < backend_scalar_bytes_max)
                document.build_attempt(.scalar, &builder)
            else
                document.build_attempt(backend_default, &builder);

            if (built) return;

            builder.cursor = builder_cursor_empty;
            builder.text_count = 0;

            tokenizer_module.tokenizer_reset(.strict, tokenizer, source);
        }

        document_build(syntax, tokenizer, &builder) catch |err| {
            document.diagnostic = tokenizer_module.position_of(source, builder.failure_index);

            return err;
        };

        document.depth = builder.cursor.depth_seen;
        document.node_count = builder.cursor.node_count;
        document.text_count = builder.text_count;

        assert(document.node_count > 0);
        assert(document.depth <= depth_max);
    }

    inline fn build_attempt(
        document: *Document,
        comptime backend: Backend,
        builder: *Builder,
    ) bool {
        assert(builder.cursor.node_count == 0);
        assert(builder.text_count == 0);

        if (backend == .simd) {
            document.indexer = .empty;

            if (!document_build_fast(&document.indexer, &document.indices, builder)) return false;

            document.depth = builder.cursor.depth_seen;
            document.node_count = builder.cursor.node_count;
            document.text_count = builder.text_count;

            return true;
        }

        const records = builder.records;
        const built = scalar_module.build(builder.source, records, builder.text) orelse {
            return false;
        };

        document.depth = built.depth_seen;
        document.node_count = built.node_count;
        document.text_count = built.text_count;

        return true;
    }

    fn record_of(document: *const Document, node: Node) *const Record {
        assert(@backingInt(node) < document.node_count);
        assert(document.node_count <= document.storage.records.len);

        return &document.storage.records[@backingInt(node)];
    }

    fn depth_check(
        document: *const Document,
        writer: *const Writer,
        node: Node,
    ) Writer.CapacityError!void {
        assert(@backingInt(node) < document.node_count);
        assert(writer.depth <= depth_max);

        if (writer.depth + document.depth <= depth_max) return;
        if (writer.depth + document.height_of(@backingInt(node)) <= depth_max) return;
        return error.DepthExceeded;
    }

    fn height_of(document: *const Document, index: u32) u32 {
        assert(index < document.node_count);
        assert(document.depth <= depth_max);

        switch (document.storage.records[index].kind()) {
            .array, .object => {},
            .false_value, .null_value, .number, .string, .string_escaped, .true_value => return 0,
        }

        const end = document.sibling_of(index);
        var ends: [depth_max]u32 = undefined;
        var open: u32 = 0;
        var result: u32 = 1;

        for (index + 1..end) |child| {
            for (0..open) |_| {
                if (ends[open - 1] > child) break;

                open -= 1;
            }

            switch (document.storage.records[child].kind()) {
                .array, .object => {
                    assert(open + 1 < depth_max);

                    ends[open] = document.sibling_of(@intCast(child));
                    open += 1;
                    result = @max(result, open + 1);
                },
                .false_value, .null_value, .number, .string, .string_escaped, .true_value => {},
            }
        }

        assert(result <= document.depth);

        return result;
    }

    fn sibling_of(document: *const Document, index: u32) u32 {
        assert(index < document.node_count);

        const record = &document.storage.records[index];

        const result = switch (record.kind()) {
            .array, .object => record.target(),
            .false_value, .null_value, .number, .string, .string_escaped, .true_value => index + 1,
        };

        assert(result > index);
        assert(result <= document.node_count);

        return result;
    }

    fn text_equal(document: *const Document, index: u32, text: []const u8) bool {
        assert(index < document.node_count);
        assert(text.len <= input_bytes_max);

        const record = &document.storage.records[index];

        const length = switch (record.kind()) {
            .string => record.end - record.start - 2,
            .string_escaped => record.size,
            .array, .false_value, .null_value, .number, .object, .true_value => unreachable,
        };

        if (length != text.len) return false;
        return std.mem.eql(u8, document.text_of(@fromBackingInt(index)).?, text);
    }

    fn number_text_of(document: *const Document, node: Node) ?[]const u8 {
        assert(@backingInt(node) < document.node_count);

        const record = document.record_of(node);
        if (record.kind() != .number) return null;

        const result = document.source[record.start..record.end];

        assert(result[0] == '-' or std.ascii.isAlphanumeric(result[0]));

        return result;
    }

    fn walk_write(
        document: *const Document,
        walk: *Walk,
        writer: *Writer,
        node: Node,
    ) WalkError!void {
        assert(@backingInt(node) < document.node_count);
        assert(writer.depth <= depth_max);

        switch (writer.options.utf8) {
            .ascii, .bmp => try document.walk_policy_write(false, walk, writer, node),
            .checked, .trusted => try document.walk_policy_write(true, walk, writer, node),
        }
    }

    fn walk_policy_write(
        document: *const Document,
        comptime verbatim: bool,
        walk: *Walk,
        writer: *Writer,
        node: Node,
    ) WalkError!void {
        assert(@backingInt(node) < document.node_count);
        assert(writer.depth <= depth_max);
        assert(walk.depth == 0);

        try document.value_write(verbatim, walk, writer, @backingInt(node));

        for (0..2 * document.node_count + 1) |_| {
            if (walk.depth == 0) return;

            const frame = &walk.frames[walk.depth - 1];

            if (frame.remaining == 0) {
                switch (frame.container) {
                    .array => try writer.array_end(),
                    .object => try writer.object_end(),
                }

                walk.depth -= 1;
                walk.scratch_used = frame.scratch_start;

                continue;
            }

            frame.remaining -= 1;

            switch (frame.container) {
                .array => {
                    const child = frame.cursor;

                    frame.cursor = document.sibling_of(child);

                    try document.value_write(verbatim, walk, writer, child);
                },
                .object => {
                    const key = document.key_next(walk, frame);

                    try writer_module.key_escaped_write(writer, document.source_of(key), verbatim);
                    try document.value_write(verbatim, walk, writer, @backingInt(key) + 1);
                },
            }
        }

        unreachable;
    }

    fn key_next(document: *const Document, walk: *const Walk, frame: *WalkFrame) Node {
        assert(frame.container == .object);
        assert(frame.cursor < document.node_count);

        if (walk.order == .source) {
            const key: Node = @fromBackingInt(frame.cursor);

            frame.cursor = document.sibling_of(frame.cursor + 1);

            return key;
        }

        const key = walk.scratch[frame.cursor];

        frame.cursor += 1;

        assert(document.kind_of(key) == .string);

        return key;
    }

    inline fn value_write(
        document: *const Document,
        comptime verbatim: bool,
        walk: *Walk,
        writer: *Writer,
        index: u32,
    ) WalkError!void {
        assert(index < document.node_count);
        assert(walk.depth <= depth_max);

        const node: Node = @fromBackingInt(index);
        const record = document.record_of(node);

        switch (record.kind()) {
            .array => {
                try writer.array_begin();

                walk.push(.{
                    .container = .array,
                    .cursor = index + 1,
                    .remaining = record.size,
                    .scratch_start = walk.scratch_used,
                });
            },
            .object => {
                try writer.object_begin();
                document.object_push(walk, index);
            },
            .false_value => try writer.boolean(false),
            .null_value => try writer.null_value(),
            .number => try writer_module.number_text_write(writer, document.source_of(node)),
            .string, .string_escaped => {
                try writer_module.string_escaped_write(writer, document.source_of(node), verbatim);
            },
            .true_value => try writer.boolean(true),
        }
    }

    fn object_push(document: *const Document, walk: *Walk, index: u32) void {
        assert(index < document.node_count);
        assert(walk.depth < depth_max);

        const record = &document.storage.records[index];

        var frame: WalkFrame = .{
            .container = .object,
            .cursor = index + 1,
            .remaining = record.size,
            .scratch_start = walk.scratch_used,
        };

        if (walk.order == .sorted) {
            const keys = walk.scratch[walk.scratch_used..][0..record.size];

            frame.cursor = walk.scratch_used;
            frame.remaining = document.keys_sort(index, keys);
            walk.scratch_used += frame.remaining;
        }

        walk.push(frame);
    }

    fn keys_sort(document: *const Document, object: u32, keys: []Node) u32 {
        assert(object < document.node_count);
        assert(keys.len == document.storage.records[object].size);

        var cursor = object + 1;

        for (keys) |*key| {
            key.* = @fromBackingInt(cursor);
            cursor = document.sibling_of(cursor + 1);
        }

        std.sort.block(Node, keys, document, key_less);

        var count: u32 = 0;

        for (keys, 0..) |key, position| {
            if (position + 1 < keys.len) {
                if (!document.key_less(key, keys[position + 1])) continue;
            }

            keys[count] = key;
            count += 1;
        }

        assert(count <= keys.len);
        if (keys.len > 0) assert(count > 0);

        return count;
    }

    fn key_less(document: *const Document, left: Node, right: Node) bool {
        assert(@backingInt(left) < document.node_count);
        assert(@backingInt(right) < document.node_count);

        const order = std.mem.order(u8, document.text_of(left).?, document.text_of(right).?);
        return order == .lt;
    }
};

pub const Entries = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub const Entry = struct {
        key: Node,
        value: Node,
    };

    pub fn next(entries: *Entries) ?Entry {
        assert(entries.cursor <= entries.document.node_count);
        assert(entries.remaining <= @divFloor(entries.document.node_count - entries.cursor, 2));

        if (entries.remaining == 0) return null;

        const key = entries.cursor;

        entries.cursor = entries.document.sibling_of(key + 1);
        entries.remaining -= 1;

        assert(entries.document.kind_of(@fromBackingInt(key)) == .string);

        return .{ .key = @fromBackingInt(key), .value = @fromBackingInt(key + 1) };
    }
};

pub const Items = struct {
    cursor: u32,
    document: *const Document,
    remaining: u32,

    pub fn next(items: *Items) ?Node {
        assert(items.cursor <= items.document.node_count);
        assert(items.remaining <= items.document.node_count - items.cursor);

        if (items.remaining == 0) return null;

        const item = items.cursor;

        items.cursor = items.document.sibling_of(item);
        items.remaining -= 1;

        assert(items.cursor > item);

        return @fromBackingInt(item);
    }
};

pub fn DocumentType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.node_count_max <= node_count_limit);

    return struct {
        document: Document,
        storage: StorageType(capacity),

        const Fixed = @This();

        pub fn parse(fixed: *Fixed, source: []const u8) Document.Error!void {
            assert(source.len <= input_bytes_max);
            assert(fixed.storage.records.len == capacity.node_count_max);

            return @call(.always_inline, Document.parse, .{
                &fixed.document,
                fixed.storage.storage(),
                source,
            });
        }

        pub fn parse_relaxed(fixed: *Fixed, source: []const u8) Document.Error!void {
            assert(source.len <= input_bytes_max);
            assert(fixed.storage.records.len == capacity.node_count_max);

            return fixed.document.parse_relaxed(fixed.storage.storage(), source);
        }

        pub fn diagnostic(fixed: *const Fixed) Position {
            return fixed.document.diagnostic;
        }

        pub fn root(fixed: *const Fixed) Node {
            return fixed.document.root();
        }

        pub fn kind_of(fixed: *const Fixed, node: Node) Document.Kind {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.kind_of(node);
        }

        pub fn count_of(fixed: *const Fixed, node: Node) u32 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.count_of(node);
        }

        pub fn member(fixed: *const Fixed, object: Node, key: []const u8) ?Node {
            assert(@backingInt(object) < fixed.document.node_count);
            assert(key.len <= input_bytes_max);

            return fixed.document.member(object, key);
        }

        pub fn item(fixed: *const Fixed, array: Node, index: u32) ?Node {
            assert(@backingInt(array) < fixed.document.node_count);
            assert(@min(index, fixed.document.count_of(array)) < fixed.document.node_count);

            return fixed.document.item(array, index);
        }

        pub fn path_find(fixed: *const Fixed, start: Node, segments: []const []const u8) ?Node {
            assert(@backingInt(start) < fixed.document.node_count);
            assert(segments.len <= input_bytes_max);

            return fixed.document.path_find(start, segments);
        }

        pub fn pointer_find(fixed: *const Fixed, start: Node, pointer: []const u8) ?Node {
            assert(@backingInt(start) < fixed.document.node_count);
            assert(pointer.len <= input_bytes_max);

            return fixed.document.pointer_find(start, pointer);
        }

        pub fn entries(fixed: *const Fixed, object: Node) Entries {
            assert(@backingInt(object) < fixed.document.node_count);

            return fixed.document.entries(object);
        }

        pub fn items(fixed: *const Fixed, array: Node) Items {
            assert(@backingInt(array) < fixed.document.node_count);

            return fixed.document.items(array);
        }

        pub fn text_of(fixed: *const Fixed, node: Node) ?[]const u8 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.text_of(node);
        }

        pub fn text_is(fixed: *const Fixed, node: Node, text: []const u8) bool {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(text.len <= input_bytes_max);

            return fixed.document.text_is(node, text);
        }

        pub fn boolean_of(fixed: *const Fixed, node: Node) ?bool {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.boolean_of(node);
        }

        pub fn integer_of(fixed: *const Fixed, node: Node) ?i64 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.integer_of(node);
        }

        pub fn unsigned_of(fixed: *const Fixed, node: Node) ?u64 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.unsigned_of(node);
        }

        pub fn float_of(fixed: *const Fixed, node: Node) ?f64 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.float_of(node);
        }

        pub fn source_of(fixed: *const Fixed, node: Node) []const u8 {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.source_of(node);
        }

        pub fn position_of(fixed: *const Fixed, node: Node) Position {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.position_of(node);
        }

        pub fn write(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: Writer.Options,
        ) std.Io.Writer.Error!void {
            assert(options.indent >= 1);

            return fixed.document.write(sink, options);
        }

        pub fn node_write(
            fixed: *const Fixed,
            writer: *Writer,
            node: Node,
        ) (Writer.CapacityError || std.Io.Writer.Error)!void {
            assert(@backingInt(node) < fixed.document.node_count);

            return fixed.document.node_write(writer, node);
        }

        pub fn node_write_sorted(
            fixed: *const Fixed,
            scratch: []Node,
            writer: *Writer,
            node: Node,
        ) (Writer.CapacityError || std.Io.Writer.Error)!void {
            assert(@backingInt(node) < fixed.document.node_count);
            assert(scratch.len >= fixed.document.node_count);

            return fixed.document.node_write_sorted(scratch, writer, node);
        }
    };
}

const Bounds = enum {
    checked,
    unchecked,
};

const Path = enum {
    exact,
    fast,
};

pub fn parse_attempt(
    comptime backend: Backend,
    document: *Document,
    storage: Storage,
    source: []const u8,
) bool {
    assert(source.len <= input_bytes_max);
    assert(storage.records.len > 0);
    assert(disjoint(&storage, source));

    var builder: Builder = .{
        .cursor = builder_cursor_empty,
        .failure_index = 0,
        .frames = undefined,
        .records = storage.records,
        .source = source,
        .text = storage.text,
        .text_count = 0,
    };

    document.source = source;
    document.storage = storage;

    const result = document.build_attempt(backend, &builder);

    if (result) assert(document.node_count > 0);

    return result;
}

pub fn parse_exact(document: *Document, storage: Storage, source: []const u8) Document.Error!void {
    assert(source.len <= input_bytes_max);
    assert(storage.records.len > 0);
    assert(disjoint(&storage, source));

    tokenizer_module.tokenizer_reset(.strict, &document.tokenizer, source);

    try document.build(.strict, .exact, &document.tokenizer, storage, source);
}

const Builder = struct {
    cursor: Cursor,
    failure_index: u32,
    frames: [depth_max]Frame,
    records: []Record,
    source: []const u8,
    text: []u8,
    text_count: u32,
};

pub const Comparison = struct {
    left: *const Document,
    right: *const Document,
};

const Container = enum {
    array,
    object,
};

const Cursor = struct {
    children: u32,
    container: u32,
    depth: u32,
    depth_seen: u32,
    node_count: u32,
};

const builder_cursor_empty: Cursor = .{
    .children = 0,
    .container = container_none,
    .depth = 0,
    .depth_seen = 0,
    .node_count = 0,
};

const Frame = struct {
    children: u32,
    container: u32,
};

const Order = enum {
    sorted,
    source,
};

const Role = enum {
    key,
    value,
};

const Span = struct {
    end: u64,
    start: u64,
};

const Walk = struct {
    depth: u32,
    frames: [depth_max]WalkFrame,
    order: Order,
    scratch: []Node,
    scratch_used: u32,

    fn push(walk: *Walk, frame: WalkFrame) void {
        assert(walk.depth < depth_max);
        assert(frame.scratch_start <= walk.scratch_used);

        walk.frames[walk.depth] = frame;
        walk.depth += 1;
    }
};

const WalkError = Writer.CapacityError || std.Io.Writer.Error;

const WalkFrame = struct {
    container: Container,
    cursor: u32,
    remaining: u32,
    scratch_start: u32,
};

pub fn structure_equal(comparison: Comparison) bool {
    assert(comparison.left.node_count > 0);
    assert(comparison.right.node_count > 0);

    const left = comparison.left;
    const right = comparison.right;
    if (left.node_count != right.node_count) return false;

    for (0..left.node_count) |index| {
        const node: Node = @fromBackingInt(@as(u32, @intCast(index)));
        const kind = left.kind_of(node);
        if (kind != right.kind_of(node)) return false;

        const equal = switch (kind) {
            .array, .object => left.count_of(node) == right.count_of(node),
            .boolean => left.boolean_of(node) == right.boolean_of(node),
            .null_value => true,
            .number => std.mem.eql(u8, left.source_of(node), right.source_of(node)),
            .string => std.mem.eql(u8, left.text_of(node).?, right.text_of(node).?),
        };

        if (!equal) return false;
    }

    return true;
}

fn document_build(
    comptime syntax: Syntax,
    tokenizer: *TokenizerType(syntax),
    builder: *Builder,
) Document.Error!void {
    comptime assert(@sizeOf(TokenizerType(syntax)) == @sizeOf(Tokenizer));
    assert(tokenizer.input.ptr == builder.source.ptr);
    assert(builder.cursor.node_count == 0);

    for (0..builder.source.len + 2) |_| {
        const events = tokenizer_module.events_take(syntax, tokenizer) catch |err| {
            builder.failure_index = tokenizer.index;

            return err;
        };

        if (builder.records.len - builder.cursor.node_count < events.len) {
            try events_build(builder, events, .checked);
        } else {
            try events_build(builder, events, .unchecked);
        }

        if (events[events.len - 1].kind == .end) {
            assert(builder.cursor.depth == 0);
            assert(builder.cursor.children == 1);

            return;
        }
    }

    unreachable;
}

const events_build = if (structural.functions_aligned)
    events_build_aligned
else
    events_build_unaligned;

noinline fn events_build_aligned(
    builder: *Builder,
    events: []const Event,
    comptime bounds: Bounds,
) align(64) Document.Error!void {
    assert(events.len > 0);
    assert(builder.cursor.depth <= depth_max);

    return events_build_body(builder, events, bounds);
}

noinline fn events_build_unaligned(
    builder: *Builder,
    events: []const Event,
    comptime bounds: Bounds,
) Document.Error!void {
    assert(events.len > 0);
    assert(builder.cursor.depth <= depth_max);

    return events_build_body(builder, events, bounds);
}

inline fn events_build_body(
    builder: *Builder,
    events: []const Event,
    comptime bounds: Bounds,
) Document.Error!void {
    assert(events.len > 0);
    assert(builder.cursor.depth <= depth_max);

    if (bounds == .unchecked) assert(events.len <= builder.records.len - builder.cursor.node_count);

    const records = builder.records;

    var cursor = builder.cursor;
    defer builder.cursor = cursor;

    for (events) |event| {
        if (bounds == .checked) try node_reserve(builder, cursor.node_count, event);

        switch (event.kind) {
            .array_begin => container_open(&cursor, &builder.frames, records, event, .array),
            .array_end => container_close(&cursor, &builder.frames, records, event, .array),
            .end => assert(cursor.depth == 0),
            .false_value => scalar_add(&cursor, records, event, .false_value),
            .key => try string_add(builder, &cursor, records, event, .key),
            .null_value => scalar_add(&cursor, records, event, .null_value),
            .number => scalar_add(&cursor, records, event, .number),
            .object_begin => container_open(&cursor, &builder.frames, records, event, .object),
            .object_end => container_close(&cursor, &builder.frames, records, event, .object),
            .string => try string_add(builder, &cursor, records, event, .value),
            .true_value => scalar_add(&cursor, records, event, .true_value),
        }
    }
}

const document_build_fast = if (structural.functions_aligned)
    document_build_fast_aligned
else
    document_build_fast_unaligned;

noinline fn document_build_fast_aligned(
    indexer: *structural.Indexer,
    indices: *structural.Indices,
    builder: *Builder,
) align(64) bool {
    assert(indexer.block_next == 0);
    assert(builder.cursor.node_count == 0);

    return document_build_fast_body(indexer, indices, builder);
}

noinline fn document_build_fast_unaligned(
    indexer: *structural.Indexer,
    indices: *structural.Indices,
    builder: *Builder,
) bool {
    assert(indexer.block_next == 0);
    assert(builder.cursor.node_count == 0);

    return document_build_fast_body(indexer, indices, builder);
}

inline fn document_build_fast_body(
    indexer: *structural.Indexer,
    indices: *structural.Indices,
    builder: *Builder,
) bool {
    assert(indexer.block_next == 0);
    assert(builder.cursor.node_count == 0);

    var decodes: Decodes = undefined;
    var walker: Walker = .init(indexer, indices, builder, &decodes);
    var phase: Phase = .start;

    for (0..@divFloor(builder.source.len, structural.block_bytes) + 3) |_| {
        if (!walker.decodes_flush()) return false;
        if (!walker.cursor.refill_ahead(walker.input, lookahead_min)) return false;

        const ahead = walker.cursor.ahead();
        const slots_free = walker.records.len - walker.nodes.node_count;
        const unchecked = ahead >= lookahead_min and slots_free >= ahead;
        const node_before = walker.nodes.node_count;
        const exit = switch (unchecked) {
            false => document_build_walk(&walker, .checked, .scalars, phase),
            true => switch (walker.mix) {
                inline else => |mix| document_build_walk(&walker, .unchecked, mix, phase),
            },
        };

        switch (exit.outcome) {
            .done => return walker.finish(),
            .failed => return false,
            .refill => phase = exit.phase,
        }

        walker.mix = walker.mix_sample(node_before);

        if (!unchecked) assert(!walker.cursor.exhausted);
    }

    return false;
}

const document_build_walk = if (structural.functions_aligned)
    document_build_walk_aligned
else
    document_build_walk_unaligned;

noinline fn document_build_walk_aligned(
    walker: *Walker,
    comptime bounds: Bounds,
    comptime mix: Mix,
    phase: Phase,
) align(4096) Exit {
    assert(walker.nodes.depth <= depth_max);

    if (bounds == .unchecked) {
        assert(walker.cursor.ahead() >= lookahead_min);
        assert(walker.records.len - walker.nodes.node_count >= walker.cursor.ahead());
    }

    var pass: Pass = .init(walker);
    defer pass.synchronize(walker);

    parse: switch (phase) {
        inline .array_next, .array_open, .object_next, .object_open => |member| {
            const closing: u8 = switch (member) {
                .array_next, .array_open => ']',
                else => '}',
            };
            const next = switch (member) {
                .array_next, .object_next => true,
                else => false,
            };

            if (pass.short(bounds)) return .{ .outcome = .refill, .phase = member };

            const byte = pass.advance(bounds) orelse return Exit.failed;
            const ended = if (next) byte != ',' else byte == closing;

            if (ended) {
                if (byte != closing) return Exit.failed;

                pass.container_end(if (closing == ']') .array else .object);

                continue :parse .member_end;
            }

            if (next) if (pass.advance(bounds) == null) return Exit.failed;
            if (closing == '}') if (!pass.key_add(bounds)) return Exit.failed;

            continue :parse .value;
        },
        .done => return .{ .outcome = .done, .phase = .done },
        .member_end => {
            if (pass.depth == 0) continue :parse .done;
            if (pass.container & container_object == 0) continue :parse .array_next;
            continue :parse .object_next;
        },
        .start => {
            if (pass.advance(bounds) == null) return Exit.failed;
            continue :parse .value;
        },
        .value => switch (pass.value_add(bounds, mix)) {
            .array => continue :parse .array_open,
            .failed => return Exit.failed,
            .object => continue :parse .object_open,
            .scalar => continue :parse .member_end,
        },
    }
}

noinline fn document_build_walk_unaligned(
    walker: *Walker,
    comptime bounds: Bounds,
    comptime mix: Mix,
    phase: Phase,
) Exit {
    assert(walker.nodes.depth <= depth_max);

    if (bounds == .unchecked) {
        assert(walker.cursor.ahead() >= lookahead_min);
        assert(walker.records.len - walker.nodes.node_count >= walker.cursor.ahead());
    }

    var pass: Pass = .init(walker);
    defer pass.synchronize(walker);

    parse: switch (phase) {
        inline .array_next, .array_open, .object_next, .object_open => |member| {
            const closing: u8 = switch (member) {
                .array_next, .array_open => ']',
                else => '}',
            };
            const next = switch (member) {
                .array_next, .object_next => true,
                else => false,
            };

            if (pass.short(bounds)) return .{ .outcome = .refill, .phase = member };

            const byte = pass.advance(bounds) orelse return Exit.failed;
            const ended = if (next) byte != ',' else byte == closing;

            if (ended) {
                if (byte != closing) return Exit.failed;

                pass.container_end(if (closing == ']') .array else .object);

                continue :parse .member_end;
            }

            if (next) if (pass.advance(bounds) == null) return Exit.failed;
            if (closing == '}') if (!pass.key_add(bounds)) return Exit.failed;

            continue :parse .value;
        },
        .done => return .{ .outcome = .done, .phase = .done },
        .member_end => {
            if (pass.depth == 0) continue :parse .done;
            if (pass.container & container_object == 0) continue :parse .array_next;
            continue :parse .object_next;
        },
        .start => {
            if (pass.advance(bounds) == null) return Exit.failed;
            continue :parse .value;
        },
        .value => switch (pass.value_add(bounds, mix)) {
            .array => continue :parse .array_open,
            .failed => return Exit.failed,
            .object => continue :parse .object_open,
            .scalar => continue :parse .member_end,
        },
    }
}

const Decodes = [structural.index_capacity]u32;

const Exit = struct {
    outcome: Outcome,
    phase: Phase,

    const failed: Exit = .{ .outcome = .failed, .phase = .done };
};

const Mix = enum {
    scalars,
    strings,
};

const mix_sample_stride: u32 = 16;

const Outcome = enum {
    done,
    failed,
    refill,
};

const Phase = enum {
    array_next,
    array_open,
    done,
    member_end,
    object_next,
    object_open,
    start,
    value,
};

const Value = enum {
    array,
    failed,
    object,
    scalar,
};

const ValueClass = enum(u8) {
    string,
    array,
    false_value,
    invalid,
    negative,
    null_value,
    number,
    object,
    true_value,
};

const value_classes: [256]ValueClass = classes: {
    var table: [256]ValueClass = @splat(.invalid);

    for ('0'..'9' + 1) |digit| table[digit] = .number;

    table['"'] = .string;
    table['-'] = .negative;
    table['['] = .array;
    table['f'] = .false_value;
    table['n'] = .null_value;
    table['t'] = .true_value;
    table['{'] = .object;

    break :classes table;
};

const Extent = struct {
    end: u32,
    start: u32,
};

const container_object: u32 = 1 << 31;
const container_index_mask: u32 = container_object - 1;
const lookahead_min: u32 = 5;

comptime {
    assert(@offsetOf(Record, "size") == @offsetOf(Record, "link") + 4);
    assert(container_index_mask >= node_count_limit);
    assert(container_none & container_object != 0);
}

const Walker = struct {
    builder: *Builder,
    cursor: structural.Cursor,
    decode_count: u32,
    decodes: *Decodes,
    input: []const u8,
    mix: Mix,
    nodes: Cursor,
    records: []Record,

    fn init(
        indexer: *structural.Indexer,
        indices: *structural.Indices,
        builder: *Builder,
        decodes: *Decodes,
    ) Walker {
        assert(builder.cursor.node_count == 0);
        assert(builder.records.len > 0);

        return .{
            .builder = builder,
            .cursor = .{
                .count = 0,
                .exhausted = false,
                .failed = false,
                .indexer = indexer,
                .indices = indices,
                .position = 0,
            },
            .decode_count = 0,
            .decodes = decodes,
            .input = builder.source,
            .mix = .strings,
            .nodes = builder.cursor,
            .records = builder.records,
        };
    }

    fn mix_sample(walker: *const Walker, node_before: u32) Mix {
        assert(node_before <= walker.nodes.node_count);
        assert(walker.nodes.node_count <= walker.records.len);

        var samples: u32 = 0;
        var strings: u32 = 0;
        var node = node_before;

        for (0..@divFloor(walker.nodes.node_count - node_before, mix_sample_stride) + 1) |_| {
            if (node >= walker.nodes.node_count) break;

            const kind = walker.records[node].kind();

            samples += 1;
            strings += @intFromBool(kind == .string or kind == .string_escaped);
            node += mix_sample_stride;
        }

        return if (2 * strings >= samples) .strings else .scalars;
    }

    fn decodes_flush(walker: *Walker) bool {
        assert(walker.decode_count <= walker.decodes.len);
        assert(walker.decode_count <= walker.nodes.node_count);

        for (walker.decodes[0..walker.decode_count]) |node| {
            if (!escaped_decode_checked(walker.builder, &walker.records[node])) return false;
        }

        walker.decode_count = 0;

        return true;
    }

    fn finish(walker: *Walker) bool {
        assert(walker.nodes.depth == 0);
        assert(walker.nodes.children == 1);

        for (0..@divFloor(walker.input.len, structural.block_bytes) + 2) |_| {
            if (walker.cursor.ahead() != 0) return false;
            if (walker.cursor.exhausted) break;
            if (!walker.cursor.refill_ahead(walker.input, 1)) return false;
        } else return false;

        if (walker.cursor.failed) return false;
        if (!walker.decodes_flush()) return false;

        assert(walker.nodes.container == container_none);

        walker.builder.cursor = walker.nodes;

        return true;
    }
};

const Pass = struct {
    children: u32,
    container: u32,
    depth: u32,
    depth_seen: u32,
    input: []const u8,
    node: u32,
    position: u32,
    rest: []u32,
    rest_end: u64,
    rest_limit: u64,
    slots: []Record,
    slots_end: u64,
    walker: *Walker,

    fn init(walker: *Walker) Pass {
        assert(walker.cursor.position <= walker.cursor.count);
        assert(walker.nodes.node_count <= walker.records.len);

        const indices = walker.cursor.indices;
        const count = walker.cursor.count;
        const rest_end: u64 = @intFromPtr(&indices[0]) + count * @sizeOf(u32);
        const records = walker.records;
        const slots_end: u64 = @intFromPtr(records.ptr) + records.len * @sizeOf(Record);

        return .{
            .children = walker.nodes.children,
            .container = walker.nodes.container,
            .depth = walker.nodes.depth,
            .depth_seen = walker.nodes.depth_seen,
            .input = walker.input,
            .node = walker.nodes.node_count,
            .position = 0,
            .rest = indices[walker.cursor.position..count],
            .rest_end = rest_end,
            .rest_limit = rest_end - @as(u64, lookahead_min) * @sizeOf(u32),
            .slots = records[walker.nodes.node_count..],
            .slots_end = slots_end,
            .walker = walker,
        };
    }

    fn synchronize(pass: *const Pass, walker: *Walker) void {
        assert(@intFromPtr(pass.rest.ptr) <= pass.rest_end);
        assert(@intFromPtr(pass.slots.ptr) <= pass.slots_end);

        const remaining = @divExact(pass.rest_end - @intFromPtr(pass.rest.ptr), @sizeOf(u32));

        walker.cursor.position = @intCast(walker.cursor.count - remaining);
        walker.nodes.children = pass.children;
        walker.nodes.container = pass.container;
        walker.nodes.depth = pass.depth;
        walker.nodes.depth_seen = pass.depth_seen;
        walker.nodes.node_count = pass.node;
    }

    inline fn node_add(pass: *Pass, comptime kind: Record.Kind, extent: Extent) void {
        comptime assert(kind != .string_escaped);
        assert(extent.start < extent.end);

        const start = extent.start;
        const end = extent.end;

        if (std.debug.runtime_safety) assert(pass.slots.len > 0);

        const record = &pass.slots[0];
        const pair: *align(4) u64 = @ptrCast(&record.link);

        record.end = end;
        pair.* = comptime link_of(kind, 0);
        record.start = start;
        pass.node += 1;
        pass.slots = pass.slots[1..];

        assert(record.size == 0);
    }

    inline fn rest_done(pass: *const Pass) bool {
        assert(@intFromPtr(pass.rest.ptr) <= pass.rest_end);
        assert(@intFromPtr(pass.rest.ptr) >= @intFromPtr(&pass.walker.cursor.indices[0]));

        if (std.debug.runtime_safety) return pass.rest.len == 0;
        return @intFromPtr(pass.rest.ptr) == pass.rest_end;
    }

    inline fn slots_done(pass: *const Pass, comptime bounds: Bounds) bool {
        const done = if (std.debug.runtime_safety)
            pass.slots.len == 0
        else
            @intFromPtr(pass.slots.ptr) == pass.slots_end;

        if (bounds == .unchecked) assert(!done);

        return done and bounds == .checked;
    }

    inline fn short(pass: *const Pass, comptime bounds: Bounds) bool {
        assert(pass.depth <= depth_max);

        const rest_short = if (std.debug.runtime_safety)
            pass.rest.len < lookahead_min
        else
            @intFromPtr(pass.rest.ptr) > pass.rest_limit;

        if (bounds == .checked) return rest_short and !pass.walker.cursor.exhausted;
        return rest_short;
    }

    inline fn advance(pass: *Pass, comptime bounds: Bounds) ?u8 {
        if (bounds == .checked) {
            if (pass.rest_done()) return null;
        }

        if (std.debug.runtime_safety) assert(pass.rest.len > 0);
        assert(pass.rest[0] & structural.index_escaped == 0);

        pass.position = pass.rest[0];
        pass.rest = pass.rest[1..];

        return pass.input[pass.position];
    }

    inline fn peek(pass: *const Pass, comptime bounds: Bounds) u32 {
        if (bounds == .checked) {
            if (pass.rest_done()) return pass.walker.cursor.entry_exhausted(pass.input);
        }

        if (std.debug.runtime_safety) assert(pass.rest.len > 0);

        return pass.rest[0];
    }

    inline fn key_add(pass: *Pass, comptime bounds: Bounds) bool {
        assert(pass.depth > 0);
        assert(pass.position < pass.input.len);

        if (pass.input[pass.position] != '"') return false;
        if (pass.slots_done(.checked)) return false;
        if (pass.text_add(bounds) != .scalar) return false;

        const colon = pass.advance(bounds) orelse return false;
        if (colon != ':') return false;
        return pass.advance(bounds) != null;
    }

    inline fn value_add(pass: *Pass, comptime bounds: Bounds, comptime mix: Mix) Value {
        assert(pass.position < pass.input.len);
        assert(pass.depth <= depth_max);

        if (pass.slots_done(bounds)) return .failed;

        const class = value_classes[pass.input[pass.position]];

        if (mix == .strings) {
            if (class == .string) {
                @branchHint(.likely);

                return pass.text_add(bounds);
            }
        }

        return switch (class) {
            .array => pass.container_begin(.array),
            .false_value => pass.literal_add(.false_value),
            .invalid => .failed,
            .negative => pass.number_add(true),
            .null_value => pass.literal_add(.null_value),
            .number => pass.number_add(false),
            .object => pass.container_begin(.object),
            .string => pass.text_add(bounds),
            .true_value => pass.literal_add(.true_value),
        };
    }

    inline fn container_begin(pass: *Pass, comptime kind: Record.Kind) Value {
        comptime assert(kind == .array or kind == .object);
        if (std.debug.runtime_safety) assert(pass.slots.len > 0);
        assert(pass.position < pass.input.len);

        if (pass.depth == depth_max) return .failed;

        const node = pass.node;

        pass.walker.builder.frames[pass.depth] = .{
            .children = pass.children + 1,
            .container = pass.container,
        };

        pass.node_add(kind, .{ .end = pass.position + 1, .start = pass.position });
        pass.children = 0;
        pass.container = if (kind == .object) node | container_object else node;
        pass.depth += 1;
        pass.depth_seen = @max(pass.depth_seen, pass.depth);

        return if (kind == .object) .object else .array;
    }

    inline fn container_end(pass: *Pass, comptime kind: Record.Kind) void {
        comptime assert(kind == .array or kind == .object);
        assert(pass.depth > 0);
        assert(pass.position < pass.input.len);

        const record = &pass.walker.records[pass.container & container_index_mask];

        assert(record.kind() == kind);
        assert(pass.position >= record.start);

        record.end = pass.position + 1;
        record.link |= pass.node;
        record.size = if (kind == .object) @divExact(pass.children, 2) else pass.children;

        const frames = &pass.walker.builder.frames;

        pass.depth -= 1;
        pass.children = frames[pass.depth].children;
        pass.container = frames[pass.depth].container;
    }

    inline fn text_add(pass: *Pass, comptime bounds: Bounds) Value {
        assert(pass.input[pass.position] == '"');
        if (std.debug.runtime_safety) assert(pass.slots.len > 0);

        const open = pass.position;
        const entry = pass.peek(bounds);
        const before = entry & structural.index_position_mask;
        const close = structural.string_close_find(pass.input, before);
        if (close <= open) return .failed;

        if (entry & structural.index_escaped != 0) {
            @branchHint(.unlikely);

            pass.decode_defer();
        }

        pass.node_add(.string, .{ .end = close + 1, .start = open });
        pass.children += 1;

        return .scalar;
    }

    fn decode_defer(pass: *Pass) void {
        assert(@intFromPtr(pass.rest.ptr) <= pass.rest_end);
        assert(pass.walker.decode_count < pass.walker.decodes.len);

        const walker = pass.walker;

        if (!pass.rest_done()) {
            assert(pass.rest[0] & structural.index_escaped != 0);

            pass.rest[0] &= structural.index_position_mask;
        }

        walker.decodes[walker.decode_count] = pass.node;
        walker.decode_count += 1;
    }

    inline fn literal_add(pass: *Pass, comptime kind: Record.Kind) Value {
        comptime assert(kind == .false_value or kind == .null_value or kind == .true_value);
        if (std.debug.runtime_safety) assert(pass.slots.len > 0);
        assert(pass.position < pass.input.len);

        const text = comptime switch (kind) {
            .false_value => "false",
            .null_value => "null",
            .true_value => "true",
            else => unreachable,
        };

        const rest = pass.input[pass.position..];
        if (rest.len < text.len) return .failed;

        const word = std.mem.readInt(u32, rest[0..4], .little);
        if (word != comptime std.mem.readInt(u32, text[0..4], .little)) return .failed;
        if (text.len == 5) if (rest[4] != text[4]) return .failed;

        const end = pass.position + @as(u32, text.len);
        if (!tokenizer_module.scalar_ended(pass.input, end)) return .failed;

        pass.scalar_add(kind, end);

        return .scalar;
    }

    inline fn number_add(pass: *Pass, comptime negative: bool) Value {
        if (std.debug.runtime_safety) assert(pass.slots.len > 0);
        assert(pass.position < pass.input.len);

        const input = pass.input;
        const start = pass.position;
        const end = tokenizer_module.number_end(input, start, negative) catch return .failed;
        if (!tokenizer_module.scalar_ended(input, end)) return .failed;

        pass.scalar_add(.number, end);

        return .scalar;
    }

    inline fn scalar_add(pass: *Pass, comptime kind: Record.Kind, end: u32) void {
        comptime assert(kind != .array);
        comptime assert(kind != .object);
        assert(end > pass.position);

        pass.node_add(kind, .{ .end = end, .start = pass.position });
        pass.children += 1;
    }
};

fn node_reserve(builder: *Builder, node_count: u32, event: Event) Document.CapacityError!void {
    assert(node_count <= builder.records.len);
    assert(event.end <= builder.source.len);

    switch (event.kind) {
        .array_end, .end, .object_end => return,
        .array_begin, .false_value, .key, .null_value, .number, .object_begin => {},
        .string, .true_value => {},
    }

    if (node_count < builder.records.len) return;

    builder.failure_index = if (event.kind == .key) event.start - 1 else event.start;

    return error.NodesExhausted;
}

inline fn container_open(
    cursor: *Cursor,
    frames: *[depth_max]Frame,
    records: []Record,
    event: Event,
    comptime kind: Record.Kind,
) void {
    comptime assert(kind == .array or kind == .object);
    assert(cursor.depth < depth_max);
    assert(cursor.node_count < records.len);
    assert(event.start < event.end);

    frames[cursor.depth] = .{ .children = cursor.children + 1, .container = cursor.container };

    records[cursor.node_count] = .{
        .end = event.end,
        .link = comptime link_of(kind, 0),
        .size = 0,
        .start = event.start,
    };

    cursor.children = 0;
    cursor.container = cursor.node_count;
    cursor.depth += 1;
    cursor.depth_seen = @max(cursor.depth_seen, cursor.depth);
    cursor.node_count += 1;
}

inline fn container_close(
    cursor: *Cursor,
    frames: *const [depth_max]Frame,
    records: []Record,
    event: Event,
    comptime kind: Record.Kind,
) void {
    comptime assert(kind == .array or kind == .object);
    assert(cursor.depth > 0);
    assert(cursor.container < cursor.node_count);
    assert(cursor.node_count <= records.len);
    assert(event.end > records[cursor.container].start);

    const record = &records[cursor.container];

    record.end = event.end;
    record.link |= cursor.node_count;
    record.size = if (kind == .object) @divExact(cursor.children, 2) else cursor.children;

    cursor.depth -= 1;
    cursor.children = frames[cursor.depth].children;
    cursor.container = frames[cursor.depth].container;
}

inline fn scalar_add(
    cursor: *Cursor,
    records: []Record,
    event: Event,
    comptime kind: Record.Kind,
) void {
    comptime assert(kind != .array);
    comptime assert(kind != .object);
    assert(cursor.node_count < records.len);
    assert(event.start < event.end);

    records[cursor.node_count] = .{
        .end = event.end,
        .link = comptime link_of(kind, 0),
        .size = 0,
        .start = event.start,
    };

    cursor.children += 1;
    cursor.node_count += 1;
}

inline fn string_add(
    builder: *Builder,
    cursor: *Cursor,
    records: []Record,
    event: Event,
    comptime role: Role,
) Document.CapacityError!void {
    assert(cursor.node_count < records.len);
    assert(event.start < event.end);

    const record = &records[cursor.node_count];

    record.* = .{
        .end = event.end,
        .link = comptime link_of(.string, 0),
        .size = 0,
        .start = if (role == .key) event.start - 1 else event.start,
    };

    if (backslash_present(builder.source, record)) try escaped_decode(builder, record);

    cursor.children += 1;
    cursor.node_count += 1;
}

noinline fn escaped_decode(builder: *Builder, record: *Record) Document.CapacityError!void {
    assert(record.start + 2 < record.end);
    assert(builder.text_count <= builder.text.len);

    const raw = builder.source[record.start + 1 .. record.end - 1];

    if (builder.text_count + raw.len > builder.text.len) {
        builder.failure_index = record.start;

        return error.TextExhausted;
    }

    const available = builder.text[builder.text_count..];

    const size: u32 = if (available.len >= raw.len + lane_count)
        string.unescape_validated(builder.source[record.start + 1 ..], @intCast(raw.len), available)
    else
        unescape_bounded(raw, available[0..raw.len]);

    record.link = link_of(.string_escaped, builder.text_count);
    record.size = size;
    builder.text_count += record.size;

    assert(record.size > 0);
    assert(record.size < raw.len);
}

const escaped_decode_checked = if (structural.functions_aligned)
    escaped_decode_checked_aligned
else
    escaped_decode_checked_unaligned;

noinline fn escaped_decode_checked_aligned(builder: *Builder, record: *Record) align(4096) bool {
    assert(record.start + 2 < record.end);
    assert(builder.text_count <= builder.text.len);

    return escaped_decode_checked_body(builder, record);
}

noinline fn escaped_decode_checked_unaligned(builder: *Builder, record: *Record) bool {
    assert(record.start + 2 < record.end);
    assert(builder.text_count <= builder.text.len);

    return escaped_decode_checked_body(builder, record);
}

inline fn escaped_decode_checked_body(builder: *Builder, record: *Record) bool {
    assert(record.start + 2 < record.end);
    assert(builder.text_count <= builder.text.len);

    const raw = builder.source[record.start + 1 .. record.end - 1];
    if (builder.text_count + raw.len > builder.text.len) return false;

    const available = builder.text[builder.text_count..];
    const window = builder.source[record.start + 1 ..];
    const length: u32 = @intCast(raw.len);

    const size: u32 = if (available.len >= raw.len + lane_count)
        string.unescape_checked(window, length, available) orelse return false
    else
        unescape_bounded_checked(raw, available[0..raw.len]) orelse return false;

    record.link = link_of(.string_escaped, builder.text_count);
    record.size = size;
    builder.text_count += size;

    assert(size > 0);
    assert(size < raw.len);

    return true;
}

fn unescape_bounded_checked(raw: []const u8, target: []u8) ?u32 {
    assert(target.len == raw.len);
    assert(raw.len <= input_bytes_max);

    const decoded = string.unescape(raw, target) catch return null;

    assert(decoded.len <= raw.len);

    return @intCast(decoded.len);
}

fn unescape_bounded(raw: []const u8, target: []u8) u32 {
    assert(target.len == raw.len);
    assert(raw.len <= input_bytes_max);

    const decoded = string.unescape(raw, target) catch |err| switch (err) {
        error.Malformed => unreachable,
        error.Overflow => unreachable,
    };

    return @intCast(decoded.len);
}

inline fn backslash_present(source: []const u8, record: *const Record) bool {
    assert(record.start + 2 <= record.end);
    assert(record.end <= source.len);

    const end = record.end - 1;
    var index = record.start + 1;

    for (0..@divFloor(end - index, lane_count) + 1) |_| {
        if (index >= end) return false;

        const chunk = chunk_at(source, index);
        const backslashes: Mask = @bitCast(chunk == @as(Chunk, @splat('\\')));
        if (backslashes & lanes_valid(end - index) != 0) return true;

        index += lane_count;
    }

    return false;
}

inline fn chunk_at(source: []const u8, index: u32) Chunk {
    assert(index < source.len);
    assert(source.len <= input_bytes_max);

    if (source.len - index >= lane_count) return source[index..][0..lane_count].*;

    var bytes: [lane_count]u8 = @splat(0);

    @memcpy(bytes[0 .. source.len - index], source[index..]);

    return bytes;
}

inline fn lanes_valid(remaining: u32) Mask {
    assert(remaining > 0);
    assert(remaining <= input_bytes_max);

    const lanes: u64 = (@as(u64, 1) << @intCast(@min(remaining, lane_count))) - 1;
    return @truncate(lanes);
}

fn disjoint(storage: *const Storage, source: []const u8) bool {
    assert(storage.records.len <= node_count_limit);
    assert(source.len <= input_bytes_max);

    if (source.len == 0) return true;

    const start: u64 = @intFromPtr(source.ptr);
    const span: Span = .{ .end = start + source.len, .start = start };
    if (!span_avoided(span, std.mem.sliceAsBytes(storage.records))) return false;
    return span_avoided(span, storage.text);
}

fn span_avoided(span: Span, bytes: []const u8) bool {
    assert(span.start < span.end);
    assert(bytes.len <= @as(u64, @sizeOf(Record)) * node_count_limit);

    if (bytes.len == 0) return true;

    const start: u64 = @intFromPtr(bytes.ptr);
    if (start + bytes.len <= span.start) return true;
    return span.end <= start;
}

const testing = std.testing;

const test_options_compact: Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

const TestDocument = DocumentType(.{ .node_count_max = 4096, .text_bytes_max = 4096 });

fn test_document_create() !*TestDocument {
    const result = try testing.allocator.create(TestDocument);

    assert(result.storage.records.len == 4096);
    assert(result.storage.text.len == 4096);

    return result;
}

fn test_capacity_parse(fixed: *TestDocument, capacity: Capacity, source: []const u8) !void {
    assert(capacity.node_count_max <= fixed.storage.records.len);
    assert(capacity.text_bytes_max <= fixed.storage.text.len);
    assert(source.len <= input_bytes_max);

    const storage = fixed.storage.storage();

    const view: Storage = .{
        .records = storage.records[0..capacity.node_count_max],
        .text = storage.text[0..capacity.text_bytes_max],
    };

    try fixed.document.parse(view, source);
}

fn test_written(document: *const Document, options: Writer.Options, buffer: []u8) ![]const u8 {
    assert(buffer.len > 0);
    assert(options.indent >= 1);

    var sink: std.Io.Writer = .fixed(buffer);

    try document.write(&sink, options);

    return sink.buffered();
}

const TestEscape = struct {
    length: u32,
    offset: u32,
};

fn test_escape_expect(fixed: *TestDocument, escape: TestEscape) !void {
    assert(escape.offset <= escape.length);
    assert(escape.length <= 80);

    const length = escape.length;
    const offset = escape.offset;

    var source: [168]u8 = undefined;
    var expected: [80]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&source);

    @memset(expected[0..length], 'a');

    if (offset < length) expected[offset] = '\n';

    try sink.writeAll("[\"");

    for (expected[0..length]) |byte| try sink.writeAll(if (byte == 'a') "a" else "\\n");

    try sink.writeAll("\",\"\\\\\"]");
    try fixed.parse(sink.buffered());

    const escaped = offset < length;
    const first: Node = @fromBackingInt(1);
    const kind: Record.Kind = if (escaped) .string_escaped else .string;

    try testing.expectEqualStrings(expected[0..length], fixed.text_of(first).?);
    try testing.expectEqual(kind, fixed.document.record_of(first).kind());

    const content_length = length + @intFromBool(escaped);

    try fixed.parse(sink.buffered()[1 .. content_length + 3]);
    try testing.expectEqualStrings(expected[0..length], fixed.text_of(fixed.root()).?);
}

test DocumentType {
    const Message = DocumentType(.{ .node_count_max = 64, .text_bytes_max = 256 });
    const message = try testing.allocator.create(Message);
    defer testing.allocator.destroy(message);

    try message.parse(
        \\{"id": 7, "method": "textDocument/hover",
        \\ "params": {"position": {"line": 3}, "uris": ["file:///a.zig", "file:///b.zig"]}}
    );

    const root = message.root();
    const method = message.member(root, "method") orelse return error.MethodMissing;
    const path = [_][]const u8{ "params", "position", "line" };
    const line = message.path_find(root, &path) orelse return error.LineMissing;
    const segments = [_][]const u8{ "params", "uris", "0" };
    const first = message.path_find(root, &segments) orelse return error.UriMissing;
    const uris = message.pointer_find(root, "/params/uris") orelse return error.UrisMissing;
    const second = message.item(uris, 1) orelse return error.UriMissing;

    try testing.expectEqualStrings("textDocument/hover", message.text_of(method).?);
    try testing.expectEqual(@as(?i64, 3), message.integer_of(line));
    try testing.expectEqualStrings("file:///a.zig", message.text_of(first).?);
    try testing.expectEqualStrings("file:///b.zig", message.text_of(second).?);
    try testing.expectEqual(@as(?Node, null), message.item(uris, 2));
    try testing.expectError(error.Malformed, message.parse("{\"id\": 7,\n \"method\": }"));
    try testing.expectEqual(Position{ .column = 12, .line = 2 }, message.diagnostic());

    try message.parse_relaxed("// request\n{\"id\": 8, /* no params */}");

    const id = message.member(message.root(), "id") orelse return error.IdMissing;

    try testing.expectEqual(@as(?i64, 8), message.integer_of(id));
    try testing.expectError(error.Malformed, message.parse_relaxed("{\"id\": 8 /* open"));
    try testing.expectEqual(Position{ .column = 10, .line = 1 }, message.diagnostic());
}

test Document {
    var storage: Storage = try .init(testing.allocator, .{
        .node_count_max = 16,
        .text_bytes_max = 64,
    });

    defer storage.deinit(testing.allocator);

    const document = try testing.allocator.create(Document);
    defer testing.allocator.destroy(document);

    try document.parse(storage, "{\"ports\": [8000, 8001, 8002]}");

    const ports = document.member(document.root(), "ports") orelse return error.PortsMissing;
    var items = document.items(ports);
    var total: u64 = 0;

    for (0..document.count_of(ports)) |_| {
        const item = items.next() orelse break;

        total += document.unsigned_of(item) orelse return error.PortInvalid;
    }

    const after = items.next();
    const root = document.root();
    const last = document.item(ports, 2) orelse return error.PortMissing;
    const middle = document.path_find(root, &.{ "ports", "1" }) orelse return error.PortMissing;
    const first = document.pointer_find(root, "/ports/0") orelse return error.PortMissing;

    try testing.expectEqual(@as(u64, 24003), total);
    try testing.expectEqual(@as(?Node, null), after);
    try testing.expectEqual(@as(?u64, 8002), document.unsigned_of(last));
    try testing.expectEqual(@as(?u64, 8001), document.unsigned_of(middle));
    try testing.expectEqual(@as(?u64, 8000), document.unsigned_of(first));

    try document.parse_relaxed(storage, "{\"ratio\": NaN, \"ports\": [8000,],}");

    const ratio = document.member(document.root(), "ratio") orelse return error.RatioMissing;

    try testing.expect(std.math.isNan(document.float_of(ratio).?));
    try testing.expectEqual(@as(u32, 1), document.count_of(document.member(root, "ports").?));
}

test Entries {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("{\"host\": \"localhost\", \"tags\": [\"a\", \"b\"], \"port\": 80}");

    const root = document.root();
    var entries = document.entries(root);
    var names: [3][]const u8 = undefined;

    for (0..document.count_of(root)) |index| {
        const entry = entries.next() orelse break;

        names[index] = document.text_of(entry.key).?;
    }

    const after = entries.next();

    try testing.expectEqualStrings("host", names[0]);
    try testing.expectEqualStrings("tags", names[1]);
    try testing.expectEqualStrings("port", names[2]);
    try testing.expectEqual(@as(?Entries.Entry, null), after);
}

test Items {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("[[1, 2], {\"a\": [3]}, \"x\"]");

    const root = document.root();
    var items = document.items(root);
    var kinds: [3]Document.Kind = undefined;

    for (0..document.count_of(root)) |index| {
        const item = items.next() orelse break;

        kinds[index] = document.kind_of(item);
    }

    const after = items.next();

    try testing.expectEqualSlices(Document.Kind, &.{ .array, .object, .string }, &kinds);
    try testing.expectEqual(@as(?Node, null), after);
}

test "a repeated key resolves to its last value through member and path_find" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse(
        \\{"a": 1, "b": {"c": "x"}, "a": 2, "\u0061": 3, "b": {"c": "y", "c": "z"}}
    );

    const root = document.root();
    const last = document.member(root, "a") orelse return error.MemberMissing;
    const nested = document.path_find(root, &.{ "b", "c" }) orelse return error.PathMissing;

    try testing.expectEqual(@as(?i64, 3), document.integer_of(last));
    try testing.expectEqualStrings("z", document.text_of(nested).?);
    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "b", "missing" }));
    try testing.expectEqual(@as(?Node, null), document.path_find(root, &.{ "a", "c" }));
    try testing.expectEqual(@as(?Node, root), document.path_find(root, &.{}));
    try testing.expectEqual(@as(?Node, null), document.member(root, ""));
    try testing.expectEqual(@as(u32, 5), document.count_of(root));
}

test "an iterator yields exactly its remaining count and stays empty afterwards" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("{\"a\": [1, [2, [3]], {\"b\": {}}], \"c\": {\"d\": [4]}, \"e\": 5}");

    const root = document.root();
    const array = document.member(root, "a") orelse return error.MemberMissing;
    var entries = document.entries(root);
    var items = document.items(array);
    var values: [3]Node = undefined;
    var children: [3]Node = undefined;

    for (&values) |*value| value.* = (entries.next() orelse return error.EntryMissing).value;
    for (&children) |*child| child.* = items.next() orelse return error.ItemMissing;

    for (0..2) |_| {
        const entry_after = entries.next();
        const item_after = items.next();

        try testing.expectEqual(@as(?Entries.Entry, null), entry_after);
        try testing.expectEqual(@as(?Node, null), item_after);
    }

    try testing.expectEqual(@as(u32, 0), entries.remaining);
    try testing.expectEqual(@as(u32, 0), items.remaining);
    try testing.expectEqual(@as(?i64, 5), document.integer_of(values[2]));
    try testing.expectEqual(Document.Kind.object, document.kind_of(values[1]));
    try testing.expectEqual(Document.Kind.object, document.kind_of(children[2]));
    try testing.expectEqual(@as(u32, 2), document.count_of(children[1]));
}

test "each accessor tolerates a node of the wrong kind, and text_of decodes escapes" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("[null, true, 1.5, \"s\", [], {}]");

    var items = document.items(document.root());

    for (0..6) |_| {
        const node = items.next() orelse return error.ItemMissing;
        const kind = document.kind_of(node);

        if (kind != .object) try testing.expectEqual(@as(?Node, null), document.member(node, "a"));
        if (kind != .object) try testing.expectEqual(@as(u32, 0), document.entries(node).remaining);
        if (kind != .array) try testing.expectEqual(@as(u32, 0), document.items(node).remaining);
        if (kind != .boolean) try testing.expectEqual(@as(?bool, null), document.boolean_of(node));
        if (kind != .number) try testing.expectEqual(@as(?f64, null), document.float_of(node));
        if (kind != .number) try testing.expectEqual(@as(?i64, null), document.integer_of(node));
        if (kind != .number) try testing.expectEqual(@as(?u64, null), document.unsigned_of(node));
        if (kind != .string) try testing.expect(!document.text_is(node, "s"));

        try testing.expectEqual(@as(u32, 0), document.count_of(node));
    }

    const long: [40]u8 = @splat('x');
    const source = "[\"plain\", \"a\\nb\", \"\\u00e9\\ud83d\\ude00\", \"\", \"" ++ long ++ "\\/\"]";

    try document.parse(source);

    const expected = [_][]const u8{ "plain", "a\nb", "\u{e9}\u{1f600}", "", long ++ "/" };

    items = document.items(document.root());

    for (expected) |text| {
        const node = items.next() orelse return error.ItemMissing;

        try testing.expectEqualStrings(text, document.text_of(node).?);
        try testing.expect(document.text_is(node, text));
        try testing.expect(!document.text_is(node, "plai"));
    }

    try testing.expectEqual(@as(u32, 3 + 6 + 41), document.document.text_count);
}

test "the backslash scan finds an escape at every offset and stops at the closing quote" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    for (0..81) |length| {
        for (0..length + 1) |offset| {
            const escape: TestEscape = .{ .length = @intCast(length), .offset = @intCast(offset) };

            try test_escape_expect(document, escape);
        }
    }
}

test "an escaped key matches its decoded text and keeps its quotes in the source" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("{\"k\\u0065y\": \"v\\n\", \"plain\": 1}");

    const root = document.root();
    const value = document.member(root, "key") orelse return error.MemberMissing;
    var entries = document.entries(root);
    const entry = entries.next() orelse return error.EntryMissing;

    try testing.expectEqualStrings("key", document.text_of(entry.key).?);
    try testing.expectEqualStrings("\"k\\u0065y\"", document.source_of(entry.key));
    try testing.expectEqualStrings("\"v\\n\"", document.source_of(value));
    try testing.expectEqualStrings("v\n", document.text_of(value).?);
    try testing.expectEqual(@as(?Node, null), document.member(root, "k\\u0065y"));
}

test "the number accessors meet their edges exactly" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    const Case = struct { []const u8, ?i64, ?u64, ?f64 };

    const cases = [_]Case{
        .{ "0", 0, 0, 0 },
        .{ "-0", 0, 0, -0.0 },
        .{ "9223372036854775807", std.math.maxInt(i64), std.math.maxInt(i64), 0x1p63 },
        .{ "-9223372036854775808", std.math.minInt(i64), null, -0x1p63 },
        .{ "9223372036854775808", null, 1 << 63, 0x1p63 },
        .{ "18446744073709551615", null, std.math.maxInt(u64), 0x1p64 },
        .{ "18446744073709551616", null, null, 0x1p64 },
        .{ "1.5", null, null, 1.5 },
        .{ "1e2", null, null, 100 },
        .{ "-1", -1, null, -1 },
        .{ "1e400", null, null, null },
        .{ "-1e400", null, null, null },
        .{ "1e-400", null, null, 0 },
        .{ "2.5E-3", null, null, 0.0025 },
    };

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try sink.writeByte('[');

    for (cases, 0..) |case, index| {
        if (index > 0) try sink.writeByte(',');

        try sink.writeAll(case[0]);
    }

    try sink.writeByte(']');
    try document.parse(sink.buffered());

    var items = document.items(document.root());

    for (cases) |case| {
        const node = items.next() orelse return error.ItemMissing;

        try testing.expectEqualStrings(case[0], document.source_of(node));
        try testing.expectEqual(case[1], document.integer_of(node));
        try testing.expectEqual(case[2], document.unsigned_of(node));
        try testing.expectEqual(case[3], document.float_of(node));
    }
}

test "source_of spans the whole node and position_of names its first byte" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("{\n  \"list\": [1, {\"a\": null}],\n\t\"text\": \"x\\ty\"\n}");

    const root = document.root();
    const list = document.member(root, "list") orelse return error.MemberMissing;
    const text = document.member(root, "text") orelse return error.MemberMissing;
    const inner = document.path_find(list, &.{}) orelse return error.PathMissing;
    var entries = document.entries(root);
    const first = entries.next() orelse return error.EntryMissing;

    try testing.expectEqualStrings("[1, {\"a\": null}]", document.source_of(list));
    try testing.expectEqualStrings("\"x\\ty\"", document.source_of(text));
    try testing.expectEqualStrings("\"list\"", document.source_of(first.key));
    try testing.expectEqual(list, inner);
    try testing.expectEqual(Position{ .column = 1, .line = 1 }, document.position_of(root));
    try testing.expectEqual(Position{ .column = 3, .line = 2 }, document.position_of(first.key));
    try testing.expectEqual(Position{ .column = 11, .line = 2 }, document.position_of(list));
    try testing.expectEqual(Position{ .column = 10, .line = 3 }, document.position_of(text));
}

test "capacity is refused one node or one text byte short and accepted at the exact size" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    const source = "{\"a\": [1, 2, {\"b\": null}], \"c\": \"\\n\\t\"}";

    try test_capacity_parse(document, .{ .node_count_max = 10, .text_bytes_max = 4 }, source);
    try testing.expectEqual(@as(u32, 10), document.document.node_count);
    try testing.expectEqual(@as(u32, 2), document.document.text_count);

    const nodes_short: Capacity = .{ .node_count_max = 9, .text_bytes_max = 4 };
    const nodes = test_capacity_parse(document, nodes_short, source);

    try testing.expectError(error.NodesExhausted, nodes);
    try testing.expectEqual(@as(u32, 0), document.document.node_count);
    try testing.expectEqual(Position{ .column = 33, .line = 1 }, document.diagnostic());

    const text_short: Capacity = .{ .node_count_max = 10, .text_bytes_max = 3 };
    const text = test_capacity_parse(document, text_short, source);

    try testing.expectError(error.TextExhausted, text);
    try testing.expectEqual(Position{ .column = 33, .line = 1 }, document.diagnostic());

    const empty_key = "{\"\": [\"\\u00e9\"]}";

    try test_capacity_parse(document, .{ .node_count_max = 4, .text_bytes_max = 6 }, empty_key);
    try testing.expectEqualStrings("\u{e9}", document.text_of(@fromBackingInt(3)).?);

    const key_short: Capacity = .{ .node_count_max = 1, .text_bytes_max = 6 };
    const keys = test_capacity_parse(document, key_short, empty_key);

    try testing.expectError(error.NodesExhausted, keys);
    try testing.expectEqual(Position{ .column = 2, .line = 1 }, document.diagnostic());
}

test "a long document refills its batches and runs out of nodes in the last one" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    const count = 1500;
    var buffer: [8 * count + 2]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try sink.writeByte('[');

    for (0..count) |index| {
        if (index > 0) try sink.writeByte(',');

        try sink.writeAll(if (index % 3 == 0) "{\"k\":1}" else "\"s\\n\"");
    }

    try sink.writeByte(']');

    const source = sink.buffered();
    const node_count = 1 + count + @divExact(count, 3) * 2;
    const exact: Capacity = .{ .node_count_max = node_count, .text_bytes_max = 2 * count };

    try test_capacity_parse(document, exact, source);
    try testing.expectEqual(@as(u32, node_count), document.document.node_count);
    try testing.expectEqual(@as(u32, count), document.count_of(document.root()));

    var items = document.items(document.root());

    for (0..count) |index| {
        const item = items.next() orelse return error.ItemMissing;
        const kind: Document.Kind = if (index % 3 == 0) .object else .string;

        try testing.expectEqual(kind, document.kind_of(item));
    }

    const short: Capacity = .{ .node_count_max = node_count - 1, .text_bytes_max = 2 * count };

    try testing.expectError(error.NodesExhausted, test_capacity_parse(document, short, source));
    try testing.expectEqual(@as(u32, 0), document.document.node_count);
}

const test_boundary_templates = [_][]const u8{
    "\"\\\"\"",
    "\"\\\\\"",
    "\"\\\\\\\"\"",
    "\"\\u00e9\"",
    "\"\\ud83d\\ude00\"",
    "\"\\ud83d\"",
    "\"\\ude00\"",
    "\"\\x\"",
    "\"\\u12\"",
    "\"\xc3\xa9\"",
    "\"\xe2\x82\xac\"",
    "\"\xf0\x9f\x98\x80\"",
    "\"\xc3\"",
    "\"\xed\xa0\x80\"",
    "\"\x01\"",
    "\"\t\"",
    "\"abc",
    "\"a\\n",
    "\"\"",
    "-12.5e+3",
    "-",
    "01",
    "1.",
    "1e",
    "tru",
    "true",
    "nulll",
    "false",
    "[[]]",
    "{}",
    "{\"k\":\"v\"}",
    "\"a\" \"b\"",
    "1 2",
    "\\",
    "\xff",
    "\x0c",
    "1\"x\"",
};

const TestPair = struct {
    exact: TestDocument,
    fast: TestDocument,
};

fn test_fast_exact_agree(pair: *TestPair, source: []const u8, capacity: Capacity) !void {
    assert(source.len <= input_bytes_max);
    assert(capacity.node_count_max <= pair.fast.storage.records.len);
    assert(capacity.text_bytes_max <= pair.fast.storage.text.len);

    const fast_storage = pair.fast.storage.storage();
    const exact_storage = pair.exact.storage.storage();

    const fast_view: Storage = .{
        .records = fast_storage.records[0..capacity.node_count_max],
        .text = fast_storage.text[0..capacity.text_bytes_max],
    };

    const exact_view: Storage = .{
        .records = exact_storage.records[0..capacity.node_count_max],
        .text = exact_storage.text[0..capacity.text_bytes_max],
    };

    const fast = &pair.fast.document;
    const exact = &pair.exact.document;
    const fast_result = fast.parse(fast_view, source);
    const exact_result = parse_exact(exact, exact_view, source);

    if (exact_result) |_| {
        try fast_result;

        if (capacity.node_count_max >= source.len) {
            try testing.expect(parse_attempt(.simd, &pair.fast.document, fast_view, source));
        }
    } else |err| {
        try testing.expectError(err, fast_result);
        try testing.expectEqual(exact.diagnostic, fast.diagnostic);
        try testing.expect(!parse_attempt(.scalar, fast, fast_view, source));

        return;
    }

    try test_documents_equal(.{ .left = exact, .right = fast });
    try testing.expect(parse_attempt(.simd, fast, fast_view, source));
    try test_documents_equal(.{ .left = exact, .right = fast });
    try testing.expect(parse_attempt(.scalar, fast, fast_view, source));
    try test_documents_equal(.{ .left = exact, .right = fast });
}

fn test_documents_equal(comparison: Comparison) !void {
    assert(comparison.left.node_count > 0);
    assert(comparison.left.node_count <= comparison.left.storage.records.len);

    const expected = comparison.left;
    const actual = comparison.right;

    try testing.expectEqual(expected.node_count, actual.node_count);
    try testing.expectEqual(expected.depth, actual.depth);
    try testing.expectEqual(expected.text_count, actual.text_count);

    const expected_records = expected.storage.records[0..expected.node_count];
    const actual_records = actual.storage.records[0..actual.node_count];

    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(expected_records),
        std.mem.sliceAsBytes(actual_records),
    );

    const expected_text = expected.storage.text[0..expected.text_count];
    const actual_text = actual.storage.text[0..actual.text_count];

    try testing.expectEqualStrings(expected_text, actual_text);
}

test "the fast path agrees with the exact path for every construct at every block offset" {
    const pair = try testing.allocator.create(TestPair);
    defer testing.allocator.destroy(pair);

    const roomy: Capacity = .{ .node_count_max = 4096, .text_bytes_max = 4096 };
    const prefixes = [_][]const u8{ "[", "{\"key\":" };
    const suffixes = [_][]const u8{ "]", "}" };

    var buffer: [256]u8 = undefined;

    for (test_boundary_templates) |template| {
        for (prefixes, suffixes) |prefix, suffix| {
            for (0..2 * structural.block_bytes + 8) |offset| {
                var sink: std.Io.Writer = .fixed(&buffer);

                try sink.writeAll(prefix);
                try sink.splatByteAll(' ', offset);
                try sink.writeAll(template);
                try sink.writeAll(suffix);
                try test_fast_exact_agree(pair, sink.buffered(), roomy);

                const tight: Capacity = .{ .node_count_max = 2, .text_bytes_max = 1 };

                try test_fast_exact_agree(pair, sink.buffered(), tight);
                try test_fast_exact_agree(pair, sink.buffered()[0 .. sink.end - 1], roomy);
            }
        }
    }
}

fn test_repeated(comptime text: []const u8, comptime count: u32) [text.len * count]u8 {
    comptime assert(text.len > 0);
    comptime assert(count > 0);

    var result: [text.len * count]u8 = undefined;

    for (0..count) |index| @memcpy(result[index * text.len ..][0..text.len], text);

    return result;
}

test "every path agrees with the exact path on tokens longer than the scalar margin" {
    const pair = try testing.allocator.create(TestPair);
    defer testing.allocator.destroy(pair);

    const roomy: Capacity = .{ .node_count_max = 4096, .text_bytes_max = 4096 };
    const digits: [150]u8 = @splat('7');
    const zeros: [90]u8 = @splat('0');
    const spaces: [100]u8 = @splat(' ');
    const letters: [200]u8 = @splat('s');
    const cyrillic = comptime test_repeated("\xd0\x9b\xd0\xb5\xd0\xbe\xd0\xbd", 12);
    const japanese = comptime test_repeated("\xe3\x81\x82\xe3\x81\x84", 15);

    const tokens = [_][]const u8{
        &digits,
        "-0." ++ &digits,
        "1e" ++ &digits,
        "1." ++ &zeros ++ "1E-" ++ &digits,
        "\"" ++ &letters ++ "\"",
        "\"" ++ &cyrillic ++ " " ++ &cyrillic ++ "\"",
        "\"" ++ &japanese ++ "x" ++ &japanese ++ "\"",
        "\"" ++ &letters ++ "\\n" ++ &letters ++ "\\u00e9\"",
        "{\"k\":" ++ &spaces ++ "1}",
        "[\n" ++ &spaces ++ "1,\n" ++ &spaces ++ "2\n]",
        "[\t\r\n" ++ &spaces ++ "\t1]",
        "\"" ++ &letters ++ "\xc3\"",
        "\"" ++ &letters ++ "\\",
        &digits ++ "x",
    };

    var buffer: [1024]u8 = undefined;

    for (tokens) |token| {
        for (0..96) |offset| {
            var sink: std.Io.Writer = .fixed(&buffer);

            try sink.writeAll("[");
            try sink.splatByteAll(' ', offset);
            try sink.writeAll(token);
            try sink.writeAll(",\"tail\"]");
            try test_fast_exact_agree(pair, sink.buffered(), roomy);
            try test_fast_exact_agree(pair, sink.buffered()[0 .. sink.end - 9], roomy);
        }
    }
}

test "the fast path agrees with the exact path across index refills" {
    const pair = try testing.allocator.create(TestPair);
    defer testing.allocator.destroy(pair);

    const count = 1400;
    const roomy: Capacity = .{ .node_count_max = 4096, .text_bytes_max = 4096 };

    var buffer: [4 * count + 2]u8 = undefined;

    for ([_]u8{ '1', '"', 'x', '}' }) |intruder| {
        for (0..96) |step| {
            var sink: std.Io.Writer = .fixed(&buffer);

            try sink.writeByte('[');

            for (0..count) |index| {
                if (index > 0) try sink.writeByte(',');

                const broken = index == 440 + step * 2;

                try sink.writeAll(if (broken) &.{intruder} else "7");
            }

            try sink.writeByte(']');
            try test_fast_exact_agree(pair, sink.buffered(), roomy);

            const node_count_max = 470 + @as(u32, @intCast(step)) * 2;
            const short: Capacity = .{ .node_count_max = node_count_max, .text_bytes_max = 0 };

            try test_fast_exact_agree(pair, sink.buffered(), short);
        }
    }
}

test "the fast path accepts a long document at its exact node capacity and refuses one short" {
    const pair = try testing.allocator.create(TestPair);
    defer testing.allocator.destroy(pair);

    const count = 1800;
    const elements = [_][]const u8{ "7", "\"s\"", "{\"k\":[true]}" };

    var buffer: [16 * count + 2]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try sink.writeByte('[');

    for (0..count) |index| {
        if (index > 0) try sink.writeByte(',');

        try sink.writeAll(elements[index % elements.len]);
    }

    try sink.writeByte(']');

    const source = sink.buffered();
    const node_count = 1 + @divExact(count, elements.len) * 6;
    const records = pair.fast.storage.storage().records;
    const exact: Storage = .{ .records = records[0..node_count], .text = &.{} };
    const short: Storage = .{ .records = records[0 .. node_count - 1], .text = &.{} };

    try testing.expect(parse_attempt(.simd, &pair.fast.document, exact, source));
    try testing.expect(!parse_attempt(.simd, &pair.fast.document, short, source));

    const capacity_exact: Capacity = .{ .node_count_max = node_count, .text_bytes_max = 0 };
    const capacity_short: Capacity = .{ .node_count_max = node_count - 1, .text_bytes_max = 0 };

    try test_fast_exact_agree(pair, source, capacity_exact);
    try test_fast_exact_agree(pair, source, capacity_short);
}

test "a refused document reports the position the tokenizer failed at" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    const deep: [tokenizer_module.depth_max + 1]u8 = @splat('[');
    const late: [2000]u8 = @splat(' ');

    const inputs = [_][]const u8{
        "",
        "  ",
        "{\"a\" 1}",
        "[1,\n 2,\n x]",
        "{\"a\": [1, 2}",
        "\"\\x\"",
        "[1] 2",
        &deep,
        "[" ++ late ++ "1, 2, }",
    };

    for (inputs) |input| {
        var tokenizer: Tokenizer = .init(input);

        const expected = for (0..input.len + 2) |_| {
            const token = tokenizer.next() catch |err| break err;

            assert(token != .end);
        } else unreachable;

        try testing.expectError(expected, document.parse(input));

        const position = tokenizer_module.position_of(input, tokenizer.index);

        try testing.expectEqual(position, document.diagnostic());
        try testing.expectEqual(@as(u32, 0), document.document.node_count);
    }
}

test "write output matches serde byte for byte and parses back to the same structure" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    const again = try test_document_create();
    defer testing.allocator.destroy(again);

    try document.parse(
        \\ { "name" : "caf\u00e9" , "list" : [ 1 , -2.5e3 , true , null , [ ] , { } ] ,
        \\   "nested" : { "k" : "\n" } }
    );

    const compact =
        \\{"name":"caf\u00e9","list":[1,-2.5e3,true,null,[],{}],"nested":{"k":"\n"}}
    ;

    const pretty =
        \\{
        \\    "name": "caf\u00e9",
        \\    "list": [
        \\        1,
        \\        -2.5e3,
        \\        true,
        \\        null,
        \\        [],
        \\        {}
        \\    ],
        \\    "nested": {
        \\        "k": "\n"
        \\    }
        \\}
    ;

    var buffer: [512]u8 = undefined;
    var rewritten: [512]u8 = undefined;
    var options = test_options_compact;

    try testing.expectEqualStrings(compact, try test_written(&document.document, options, &buffer));
    try again.parse(try test_written(&document.document, options, &buffer));
    try testing.expect(structure_equal(.{ .left = &document.document, .right = &again.document }));
    try testing.expectEqualStrings(compact, try test_written(&again.document, options, &rewritten));

    options.layout = .pretty;
    options.indent = 4;

    try testing.expectEqualStrings(pretty, try test_written(&document.document, options, &buffer));
    try again.parse(try test_written(&document.document, options, &buffer));
    try testing.expect(structure_equal(.{ .left = &document.document, .right = &again.document }));
}

test "node_write copies a subtree into a writer mid-document and refuses one too deep" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("{\"list\": [1, \"a\\u0062\", {}], \"nested\": {\"k\": [true]}}");

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);
    const root = document.root();

    try writer.object_begin();
    try writer.key("copy");
    try document.node_write(&writer, document.member(root, "nested") orelse return error.Missing);
    try writer.key("list");
    try document.node_write(&writer, document.member(root, "list") orelse return error.Missing);
    try writer.object_end();

    writer.finish();

    const expected = "{\"copy\":{\"k\":[true]},\"list\":[1,\"a\\u0062\",{}]}";

    try testing.expectEqualStrings(expected, sink.buffered());

    sink = .fixed(&buffer);
    writer = .init(&sink, test_options_compact);

    for (0..depth_max - 2) |_| try writer.array_begin();

    try testing.expectError(error.DepthExceeded, document.node_write(&writer, root));
    try testing.expectEqual(@as(usize, depth_max - 2), sink.buffered().len);

    const scalar = document.path_find(root, &.{ "list", "missing" });

    try testing.expectEqual(@as(?Node, null), scalar);
}

test "node_write measures the subtree it writes, not the whole document" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse("{\"deep\": [[{\"k\": [1]}], 2], \"flat\": [1, [], {}], \"scalar\": 3}");

    const root = document.root();

    const cases = [_]struct { []const u8, u32 }{
        .{ "deep", 4 },
        .{ "flat", 2 },
        .{ "scalar", 0 },
    };

    var buffer: [512]u8 = undefined;
    var scratch: [64]Node = undefined;

    for (cases) |case| {
        const node = document.member(root, case[0]) orelse return error.Missing;

        for ([_]bool{ false, true }) |sorted| {
            for ([_]u32{ 0, 1 }) |excess| {
                var sink: std.Io.Writer = .fixed(&buffer);
                var writer: Writer = .init(&sink, test_options_compact);
                const open = depth_max + excess - @max(case[1], 1);

                for (0..open) |_| try writer.array_begin();

                const result = if (sorted)
                    document.node_write_sorted(&scratch, &writer, node)
                else
                    document.node_write(&writer, node);

                if (excess == 0) {
                    try result;
                } else if (case[1] == 0) {
                    try result;
                } else {
                    try testing.expectError(error.DepthExceeded, result);
                }
            }
        }
    }
}

test "node_write_sorted orders members by decoded bytes and keeps the last of each key" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    try document.parse(
        \\{"b": 1, "a": {"z": 0, "y": [{"d": 1, "c": 2}]}, "\u0062": 3, "é": 4, "e": 5,
        \\ "a": {"x": true, "w": []}}
    );

    const expected =
        \\{"a":{"w":[],"x":true},"\u0062":3,"e":5,"é":4}
    ;

    const nested =
        \\{"y":[{"c":2,"d":1}],"z":0}
    ;

    const scratch = try testing.allocator.alloc(Node, document.document.node_count);
    defer testing.allocator.free(scratch);

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);

    try document.node_write_sorted(scratch, &writer, document.root());

    writer.finish();

    try testing.expectEqualStrings(expected, sink.buffered());

    var entries = document.entries(document.root());
    const number = (entries.next() orelse return error.EntryMissing).value;
    const object = (entries.next() orelse return error.EntryMissing).value;

    sink = .fixed(&buffer);
    writer = .init(&sink, test_options_compact);

    try writer.array_begin();
    try document.node_write_sorted(scratch, &writer, number);
    try document.node_write_sorted(scratch, &writer, object);
    try writer.array_end();

    writer.finish();

    try testing.expectEqualStrings("[1," ++ nested ++ "]", sink.buffered());
}

test "a relaxed document reads non-finite numbers, keeps comments in source_of, and writes" {
    const document = try test_document_create();
    defer testing.allocator.destroy(document);

    const source = "\xef\xbb\xbf// settings\n" ++
        "{\"limits\": [Infinity, -inf, nan, 1e999, 7 /* last */,],\n" ++
        " \"name\": \"box\", /* trailing */}";

    try document.parse_relaxed(source);

    const root = document.root();
    const limits = document.member(root, "limits") orelse return error.LimitsMissing;

    const values = [_]Node{
        document.item(limits, 0).?,
        document.item(limits, 1).?,
        document.item(limits, 2).?,
        document.item(limits, 3).?,
        document.item(limits, 4).?,
    };

    try testing.expectEqual(@as(u32, 5), document.count_of(limits));
    try testing.expectEqual(@as(?f64, std.math.inf(f64)), document.float_of(values[0]));
    try testing.expectEqual(@as(?f64, -std.math.inf(f64)), document.float_of(values[1]));
    try testing.expect(std.math.isNan(document.float_of(values[2]).?));
    try testing.expectEqual(@as(?f64, null), document.float_of(values[3]));
    try testing.expectEqual(@as(?f64, 7), document.float_of(values[4]));
    try testing.expectEqual(@as(?i64, null), document.integer_of(values[0]));
    try testing.expectEqual(@as(?u64, null), document.unsigned_of(values[2]));
    try testing.expectEqualStrings("-inf", document.source_of(values[1]));

    try testing.expectEqualStrings(
        "[Infinity, -inf, nan, 1e999, 7 /* last */,]",
        document.source_of(limits),
    );

    try testing.expectEqual(Position{ .column = 1, .line = 2 }, document.position_of(root));

    var buffer: [256]u8 = undefined;
    var options = test_options_compact;
    const nulled = try test_written(&document.document, options, &buffer);

    try testing.expectEqualStrings(
        "{\"limits\":[null,null,null,1e999,7],\"name\":\"box\"}",
        nulled,
    );

    options.non_finite = .literal;

    const literal = try test_written(&document.document, options, &buffer);

    try testing.expectEqualStrings(
        "{\"limits\":[Infinity,-Infinity,NaN,1e999,7],\"name\":\"box\"}",
        literal,
    );

    const reparsed = try test_document_create();
    defer testing.allocator.destroy(reparsed);

    try reparsed.parse_relaxed(literal);
    try testing.expectEqual(@as(?f64, -std.math.inf(f64)), reparsed.float_of(@fromBackingInt(4)));
    try testing.expectError(error.Malformed, reparsed.parse(literal));
}
