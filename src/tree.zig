const std = @import("std");

const document_module = @import("document.zig");
const number_module = @import("number.zig");
const patch_module = @import("patch.zig");
const pointer_module = @import("pointer.zig");
const storage_module = @import("storage.zig");
const string_module = @import("string.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Capacity = storage_module.Capacity;
const Document = document_module.Document;
const DocumentNode = document_module.Node;
const DocumentRecord = storage_module.Record;
const Position = tokenizer_module.Position;
const Writer = writer_module.Writer;

const depth_max = tokenizer_module.depth_max;
const chunk_bytes: u32 = 32;
const clean_flag: u32 = 1 << 30;
const detached_flag: u32 = 1 << 31;
const float_bytes_max = number_module.float_bytes_max;
const input_bytes_max = tokenizer_module.input_bytes_max;
const integer_bytes_max = number_module.integer_bytes_max;
const link_kind_shift = storage_module.link_kind_shift;
const link_target_mask = storage_module.link_target_mask;
const node_count_limit = storage_module.node_count_limit;
const none: u32 = link_target_mask;
const owner_flags: u32 = clean_flag | detached_flag;
const root_index: u32 = 0;
const text_bytes_limit = storage_module.text_bytes_limit;

comptime {
    assert(@sizeOf(Record) == 16);
    assert(@bitSizeOf(Record.Kind) + @as(u32, link_kind_shift) == 32);
    assert(none == node_count_limit);
    assert(detached_flag > link_target_mask);
    assert(clean_flag > link_target_mask);
    assert(clean_flag & detached_flag == 0);
    assert(float_bytes_max > integer_bytes_max);
}

pub const Tree = struct {
    node_count: u32,
    records: []Record,
    text: []u8,
    text_count: u32,

    pub const CapacityError = error{
        DepthExceeded,
        NodesExhausted,
        TextExhausted,
    };

    pub const ConflictError = error{
        PathMissing,
        TestFailed,
    };

    pub const Content = union(enum) {
        array,
        boolean: bool,
        copy: Copy,
        float: f64,
        integer: i64,
        null_value,
        number: []const u8,
        object,
        string: []const u8,
        unsigned: u64,

        pub const Copy = struct {
            document: *const Document,
            node: DocumentNode,
        };
    };

    pub const EditError = CapacityError || ValueError;

    pub const Entries = struct {
        cursor: u32,
        remaining: u32,
        tree: *const Tree,

        pub const Entry = struct {
            key: Node,
            value: Node,
        };

        pub fn next(iterator: *Entries) ?Entry {
            assert(@as(u64, iterator.remaining) * 2 < iterator.tree.node_count);
            if (iterator.remaining > 0) assert(iterator.cursor < iterator.tree.node_count);

            if (iterator.remaining == 0) return null;

            const records = iterator.tree.records;
            const key = iterator.cursor;
            const value = records[key].sibling();

            iterator.cursor = records[value].sibling();
            iterator.remaining -= 1;

            assert(records[key].kind() == .key);
            assert(records[value].parent() == records[key].parent());

            return .{ .key = @fromBackingInt(key), .value = @fromBackingInt(value) };
        }
    };

    pub const Items = struct {
        cursor: u32,
        remaining: u32,
        tree: *const Tree,

        pub fn next(iterator: *Items) ?Node {
            assert(iterator.remaining < iterator.tree.node_count);
            if (iterator.remaining > 0) assert(iterator.cursor < iterator.tree.node_count);

            if (iterator.remaining == 0) return null;

            const child = iterator.cursor;

            iterator.cursor = iterator.tree.records[child].sibling();
            iterator.remaining -= 1;

            assert(iterator.tree.records[child].kind() != .key);

            return @fromBackingInt(child);
        }
    };

    pub const Kind = Document.Kind;

    pub const Node = enum(u32) { _ };
    pub const PatchError = error{PatchMalformed};

    pub const PatchOptions = struct {
        diagnostic: ?*Position = null,
    };

    pub const Storage = struct {
        records: []Record,
        text: []u8,

        pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Storage {
            assert(capacity.node_count_max > 0);
            assert(capacity.node_count_max <= node_count_limit);
            assert(capacity.text_bytes_max <= text_bytes_limit);

            const records = try gpa.alloc(Record, capacity.node_count_max);
            errdefer gpa.free(records);

            const text = try gpa.alloc(u8, capacity.text_bytes_max);
            return .{ .records = records, .text = text };
        }

        pub fn deinit(storage: *Storage, gpa: std.mem.Allocator) void {
            assert(storage.records.len > 0);
            assert(storage.records.len <= node_count_limit);
            assert(storage.text.len <= text_bytes_limit);

            gpa.free(storage.records);
            gpa.free(storage.text);

            storage.* = undefined;
        }
    };

    pub const ValueError = error{
        NumberInvalid,
        Utf8Invalid,
    };

    pub fn StorageType(comptime capacity: Capacity) type {
        comptime assert(capacity.node_count_max > 0);
        comptime assert(capacity.node_count_max <= node_count_limit);
        comptime assert(capacity.text_bytes_max <= text_bytes_limit);

        return struct {
            records: [capacity.node_count_max]Record,
            text: [capacity.text_bytes_max]u8,

            const Fixed = @This();

            pub fn storage(fixed: *Fixed) Storage {
                assert(fixed.records.len == capacity.node_count_max);
                assert(fixed.text.len == capacity.text_bytes_max);

                return .{ .records = &fixed.records, .text = &fixed.text };
            }
        };
    }

    pub fn init(tree: *Tree, storage: Storage) void {
        assert(storage.records.len > 0);
        assert(storage.records.len <= node_count_limit);
        assert(storage.text.len <= text_bytes_limit);

        tree.* = .{
            .node_count = 1,
            .records = storage.records,
            .text = storage.text,
            .text_count = 0,
        };

        tree.records[root_index] = .{
            .link = link_of(.null_value, root_index),
            .owner = none,
            .size = 0,
            .target = 0,
        };

        assert(tree.kind_of(tree.root()) == .null_value);
    }

    pub fn root(tree: *const Tree) Node {
        assert(tree.node_count > 0);
        assert(tree.records[root_index].parent() == none);

        return @fromBackingInt(root_index);
    }

    pub fn kind_of(tree: *const Tree, node: Node) Kind {
        assert(@backingInt(node) < tree.node_count);

        const result: Kind = switch (tree.record_of(node).kind()) {
            .array => .array,
            .false_value, .true_value => .boolean,
            .key, .string => .string,
            .null_value => .null_value,
            .number => .number,
            .object => .object,
        };

        return result;
    }

    pub fn count_of(tree: *const Tree, node: Node) u32 {
        assert(@backingInt(node) < tree.node_count);

        const record = tree.record_of(node);

        const result = switch (record.kind()) {
            .array, .object => record.size,
            .false_value, .key, .null_value, .number, .string, .true_value => 0,
        };

        assert(result < tree.node_count);

        return result;
    }

    pub fn member(tree: *const Tree, object: Node, key: []const u8) ?Node {
        assert(@backingInt(object) < tree.node_count);
        assert(key.len <= input_bytes_max);

        const record = tree.record_of(object);
        if (record.kind() != .object) return null;

        const first = tree.child_first(record);
        var cursor = first;
        var result: ?Node = null;

        for (0..record.size) |_| {
            const value = tree.records[cursor].sibling();

            if (tree.text_equal(cursor, key)) result = @fromBackingInt(value);

            cursor = tree.records[value].sibling();
        }

        assert(cursor == first);

        return result;
    }

    pub fn item(tree: *const Tree, array: Node, index: u32) ?Node {
        assert(@backingInt(array) < tree.node_count);
        assert(@min(index, tree.count_of(array)) < tree.node_count);

        const record = tree.record_of(array);
        if (record.kind() != .array) return null;
        if (index >= record.size) return null;

        const result = tree.child_at(record, index);

        assert(tree.records[result].parent() == @backingInt(array));

        return @fromBackingInt(result);
    }

    pub fn entries(tree: *const Tree, object: Node) Entries {
        assert(@backingInt(object) < tree.node_count);

        const record = tree.record_of(object);
        const count = if (record.kind() == .object) record.size else 0;

        return .{ .cursor = tree.child_first(record), .remaining = count, .tree = tree };
    }

    pub fn items(tree: *const Tree, array: Node) Items {
        assert(@backingInt(array) < tree.node_count);

        const record = tree.record_of(array);
        const count = if (record.kind() == .array) record.size else 0;

        return .{ .cursor = tree.child_first(record), .remaining = count, .tree = tree };
    }

    pub fn path_find(tree: *const Tree, start: Node, segments: []const []const u8) ?Node {
        assert(@backingInt(start) < tree.node_count);
        assert(segments.len <= input_bytes_max);

        return pointer_module.path_find(Tree, tree, start, segments);
    }

    pub fn pointer_find(tree: *const Tree, start: Node, pointer: []const u8) ?Node {
        assert(@backingInt(start) < tree.node_count);
        assert(pointer.len <= input_bytes_max);

        return pointer_module.pointer_find(Tree, tree, start, pointer);
    }

    pub fn text_of(tree: *const Tree, node: Node) ?[]const u8 {
        assert(@backingInt(node) < tree.node_count);

        const record = tree.record_of(node);

        switch (record.kind()) {
            .key, .string => {},
            .array, .false_value, .null_value, .number, .object, .true_value => return null,
        }

        assert(record.target + record.size <= tree.text_count);

        return tree.text[record.target..][0..record.size];
    }

    pub fn text_is(tree: *const Tree, node: Node, text: []const u8) bool {
        assert(@backingInt(node) < tree.node_count);
        assert(text.len <= input_bytes_max);

        if (tree.kind_of(node) != .string) return false;
        return tree.text_equal(@backingInt(node), text);
    }

    pub fn boolean_of(tree: *const Tree, node: Node) ?bool {
        assert(@backingInt(node) < tree.node_count);

        const result: ?bool = switch (tree.record_of(node).kind()) {
            .false_value => false,
            .true_value => true,
            .array, .key, .null_value, .number, .object, .string => null,
        };

        if (result != null) assert(tree.kind_of(node) == .boolean);

        return result;
    }

    pub fn integer_of(tree: *const Tree, node: Node) ?i64 {
        assert(@backingInt(node) < tree.node_count);

        const text = tree.number_text_of(node) orelse return null;
        return number_module.integer_of_text(text);
    }

    pub fn unsigned_of(tree: *const Tree, node: Node) ?u64 {
        assert(@backingInt(node) < tree.node_count);

        const text = tree.number_text_of(node) orelse return null;
        return number_module.unsigned_of_text(text);
    }

    pub fn float_of(tree: *const Tree, node: Node) ?f64 {
        assert(@backingInt(node) < tree.node_count);

        const text = tree.number_text_of(node) orelse return null;
        return number_module.float_of_text(text);
    }

    pub fn set(tree: *Tree, object: Node, key: []const u8, content: Content) EditError!Node {
        assert(tree.record_of(object).kind() == .object);
        assert(key.len <= input_bytes_max);
        assert(content_bytes(&content) <= input_bytes_max);

        if (!std.unicode.utf8ValidateSlice(key)) return error.Utf8Invalid;

        if (tree.member(object, key)) |value| {
            try tree.replace(value, content);

            return value;
        }

        const container = @backingInt(object);
        const value = try tree.value_create(.{ .key = key, .parent = container }, &content);

        tree.segment_append(container, .{ .first = value - 1, .last = value });

        assert(tree.records[container].target == value);
        assert(tree.records[value - 1].kind() == .key);

        return @fromBackingInt(value);
    }

    pub fn append(tree: *Tree, array: Node, content: Content) EditError!Node {
        assert(tree.record_of(array).kind() == .array);
        assert(content_bytes(&content) <= input_bytes_max);

        const container = @backingInt(array);
        const value = try tree.value_create(.{ .key = null, .parent = container }, &content);

        tree.segment_append(container, .{ .first = value, .last = value });

        assert(tree.records[container].target == value);

        return @fromBackingInt(value);
    }

    pub fn insert(tree: *Tree, array: Node, index: u32, content: Content) EditError!Node {
        assert(tree.record_of(array).kind() == .array);
        assert(index <= tree.record_of(array).size);
        assert(content_bytes(&content) <= input_bytes_max);

        const record = tree.record_of(array);
        const container = @backingInt(array);
        const value = try tree.value_create(.{ .key = null, .parent = container }, &content);
        const segment: Segment = .{ .first = value, .last = value };

        if (index == record.size) {
            tree.segment_append(container, segment);
        } else {
            const predecessor = if (index == 0) record.target else tree.child_at(record, index - 1);

            tree.segment_insert(predecessor, segment);
        }

        assert(tree.child_at(record, index) == value);

        return @fromBackingInt(value);
    }

    pub fn replace(tree: *Tree, node: Node, content: Content) EditError!void {
        assert(tree.record_of(node).kind() != .key);
        assert(content_bytes(&content) <= input_bytes_max);

        const index = @backingInt(node);
        const parent = tree.records[index].parent();
        const level = if (parent == none) 0 else tree.level_of(parent);
        const placement: Placement = .{ .index = index, .level = level };

        const fields = switch (content) {
            .copy => |*copy| try tree.copy_replace(placement, copy),
            .array, .boolean, .float, .integer, .null_value, .number, .object, .string => fields: {
                break :fields try tree.scalar_replace(level, &content);
            },
            .unsigned => try tree.scalar_replace(level, &content),
        };

        tree.children_detach(index);
        tree.fields_store(index, fields);

        assert(tree.records[index].kind() == fields.kind);
    }

    pub fn remove(tree: *Tree, node: Node) void {
        assert(@backingInt(node) != root_index);
        assert(tree.record_of(node).kind() != .key);

        const index = @backingInt(node);
        const found = tree.segment_find(index);

        tree.segment_unlink(found.predecessor, found.segment);
        tree.children_detach(index);

        tree.records[found.segment.first].owner |= detached_flag;
        tree.records[index].owner |= detached_flag;

        assert(!tree.records[index].attached());
    }

    pub fn patch(
        tree: *Tree,
        document: *const Document,
        operations: DocumentNode,
        options: PatchOptions,
    ) (CapacityError || ConflictError || PatchError)!void {
        comptime assert(@sizeOf(@TypeOf(options)) <= 16);
        assert(tree.node_count > 0);
        assert(@backingInt(operations) < document.node_count);

        return patch_module.patch(tree, document, operations, options);
    }

    pub fn merge_patch(
        tree: *Tree,
        target: Node,
        document: *const Document,
        changes: DocumentNode,
    ) CapacityError!void {
        assert(tree.record_of(target).kind() != .key);
        assert(@backingInt(changes) < document.node_count);

        return patch_module.merge_patch(tree, target, document, changes);
    }

    pub fn write(
        tree: *const Tree,
        sink: *std.Io.Writer,
        options: Writer.Options,
    ) std.Io.Writer.Error!void {
        assert(tree.node_count > 0);
        assert(options.indent >= 1);

        var writer: Writer = .init(sink, options);

        walk_write(tree.records, tree.text, &writer, root_index) catch |err| switch (err) {
            error.DepthExceeded => unreachable,
            error.WriteFailed => return error.WriteFailed,
        };

        writer.finish();
    }

    pub fn node_write(
        tree: *const Tree,
        writer: *Writer,
        node: Node,
    ) (Writer.CapacityError || std.Io.Writer.Error)!void {
        assert(tree.record_of(node).kind() != .key);
        assert(writer.depth <= depth_max);

        const index = @backingInt(node);
        if (writer.depth + tree.height_of(index) > depth_max) return error.DepthExceeded;

        try walk_write(tree.records, tree.text, writer, index);
    }

    fn record_of(tree: *const Tree, node: Node) *const Record {
        assert(@backingInt(node) < tree.node_count);
        assert(tree.node_count <= tree.records.len);

        const result = &tree.records[@backingInt(node)];

        assert(result.attached());

        return result;
    }

    fn child_first(tree: *const Tree, record: *const Record) u32 {
        assert(tree.node_count <= tree.records.len);

        if (record.child_count() == 0) return none;

        const result = tree.records[record.target].sibling();

        assert(result < tree.node_count);

        return result;
    }

    fn child_at(tree: *const Tree, record: *const Record, position: u32) u32 {
        assert(record.kind() == .array);
        assert(position < record.size);

        if (position + 1 == record.size) return record.target;

        var cursor = tree.child_first(record);

        for (0..position) |_| cursor = tree.records[cursor].sibling();

        assert(cursor < tree.node_count);

        return cursor;
    }

    fn text_equal(tree: *const Tree, index: u32, text: []const u8) bool {
        assert(index < tree.node_count);
        assert(text.len <= input_bytes_max);

        const record = &tree.records[index];

        assert(record.target + record.size <= tree.text_count);

        if (record.size != text.len) return false;
        return std.mem.eql(u8, tree.text[record.target..][0..record.size], text);
    }

    fn number_text_of(tree: *const Tree, node: Node) ?[]const u8 {
        assert(@backingInt(node) < tree.node_count);

        const record = tree.record_of(node);
        if (record.kind() != .number) return null;

        const result = tree.text[record.target..][0..record.size];

        assert(result.len > 0);

        return result;
    }

    fn level_of(tree: *const Tree, container: u32) u32 {
        assert(container < tree.node_count);
        assert(container_is(tree.records[container].kind()));

        var cursor = container;
        var result: u32 = 0;

        for (0..depth_max + 1) |_| {
            if (cursor == none) break;

            result += 1;
            cursor = tree.records[cursor].parent();
        }

        assert(cursor == none);
        assert(result <= depth_max);

        return result;
    }

    fn height_of(tree: *const Tree, index: u32) u32 {
        assert(index < tree.node_count);
        assert(tree.records[index].attached());

        if (!container_is(tree.records[index].kind())) return 0;

        var walk: Walk = undefined;
        var result: u32 = 1;

        tree.walk_start(&walk, index);

        for (0..tree.node_count) |_| {
            const step = tree.walk_next(&walk) orelse break;

            if (container_is(tree.records[step.index].kind())) {
                result = @max(result, step.depth + 1);
            }
        }

        assert(walk.depth == 0);
        assert(result <= depth_max);

        return result;
    }

    fn capacity_check(tree: *const Tree, need: Need) CapacityError!void {
        assert(need.depth <= depth_max + 1);
        assert(tree.node_count <= tree.records.len);
        assert(tree.text_count <= tree.text.len);

        if (need.depth > depth_max) return error.DepthExceeded;
        if (need.node_count > tree.records.len - tree.node_count) return error.NodesExhausted;
        if (need.text_bytes > tree.text.len - tree.text_count) return error.TextExhausted;
    }

    fn value_create(tree: *Tree, create: Create, content: *const Content) EditError!u32 {
        assert(create.parent < tree.node_count);
        assert(container_is(tree.records[create.parent].kind()));

        const level = tree.level_of(create.parent);

        switch (content.*) {
            .copy => |*copy| return tree.copy_create(create, level, copy),
            .array, .boolean, .float, .integer, .null_value, .number, .object, .string => {},
            .unsigned => {},
        }

        var buffer: [float_bytes_max]u8 = undefined;
        const scalar = try scalar_of(content, &buffer);
        const key_bytes: u64 = if (create.key) |key| key.len + 2 else 0;

        try tree.capacity_check(.{
            .depth = level + @intFromBool(container_is(scalar.kind)),
            .node_count = 1 + @as(u32, @intFromBool(create.key != null)),
            .text_bytes = key_bytes + scalar_bytes(&scalar),
        });

        if (create.key) |key| tree.key_store(create.parent, key);

        const fields = tree.scalar_store(&scalar);
        const value = tree.node_count;

        tree.records[value] = .{
            .link = link_of(fields.kind, none),
            .owner = create.parent | clean_bits(fields.clean),
            .size = fields.size,
            .target = fields.target,
        };

        tree.node_count += 1;

        assert(value < tree.node_count);

        return value;
    }

    fn copy_create(
        tree: *Tree,
        create: Create,
        level: u32,
        copy: *const Content.Copy,
    ) CapacityError!u32 {
        assert(create.parent < tree.node_count);
        assert(level <= depth_max);
        assert(@backingInt(copy.node) < copy.document.node_count);

        const source = @backingInt(copy.node);
        const key_count: u32 = @intFromBool(create.key != null);
        const key_bytes: u32 = if (create.key) |key| @intCast(key.len + 2) else 0;
        const source_count = subtree_count(copy.document, source);
        const value = tree.node_count + key_count;

        try tree.capacity_check(.{
            .depth = level,
            .node_count = key_count + source_count,
            .text_bytes = key_bytes,
        });

        var build: Build = .{
            .child_base = value + 1,
            .level = level,
            .records = tree.records,
            .root = value,
            .source_first = source + 1,
            .text = tree.text,
            .text_count = tree.text_count + key_bytes,
        };

        const fields = try copy_build(&build, copy.document, source);

        if (create.key) |key| tree.key_store(create.parent, key);

        tree.records[value] = .{
            .link = link_of(fields.kind, none),
            .owner = create.parent | clean_bits(fields.clean),
            .size = fields.size,
            .target = fields.target,
        };

        tree.node_count = value + source_count;
        tree.text_count = build.text_count;

        assert(value < tree.node_count);

        return value;
    }

    fn copy_replace(
        tree: *Tree,
        placement: Placement,
        copy: *const Content.Copy,
    ) CapacityError!Fields {
        assert(placement.index < tree.node_count);
        assert(placement.level <= depth_max);
        assert(@backingInt(copy.node) < copy.document.node_count);

        const source = @backingInt(copy.node);
        const source_count = subtree_count(copy.document, source);

        try tree.capacity_check(.{
            .depth = placement.level,
            .node_count = source_count - 1,
            .text_bytes = 0,
        });

        var build: Build = .{
            .child_base = tree.node_count,
            .level = placement.level,
            .records = tree.records,
            .root = placement.index,
            .source_first = source + 1,
            .text = tree.text,
            .text_count = tree.text_count,
        };

        const fields = try copy_build(&build, copy.document, source);

        tree.node_count += source_count - 1;
        tree.text_count = build.text_count;

        return fields;
    }

    fn scalar_replace(tree: *Tree, level: u32, content: *const Content) EditError!Fields {
        assert(level <= depth_max);
        assert(content.* != .copy);

        var buffer: [float_bytes_max]u8 = undefined;
        const scalar = try scalar_of(content, &buffer);

        try tree.capacity_check(.{
            .depth = level + @intFromBool(container_is(scalar.kind)),
            .node_count = 0,
            .text_bytes = scalar_bytes(&scalar),
        });

        return tree.scalar_store(&scalar);
    }

    fn scalar_store(tree: *Tree, scalar: *const Scalar) Fields {
        assert(scalar_bytes(scalar) <= tree.text.len - tree.text_count);
        assert(scalar.kind != .key);

        const length: u32 = @intCast(scalar.text.len);

        return switch (scalar.kind) {
            .array, .object => .{ .clean = false, .kind = scalar.kind, .size = 0, .target = none },
            .false_value, .null_value, .true_value => .{
                .clean = false,
                .kind = scalar.kind,
                .size = 0,
                .target = 0,
            },
            .key => unreachable,
            .number => .{
                .clean = false,
                .kind = .number,
                .size = length,
                .target = tree.text_store(scalar.text),
            },
            .string => .{
                .clean = scalar.clean,
                .kind = .string,
                .size = length,
                .target = tree.quoted_store(scalar.text),
            },
        };
    }

    fn key_store(tree: *Tree, parent: u32, key: []const u8) void {
        assert(parent < tree.node_count);
        assert(key.len + 2 <= tree.text.len - tree.text_count);

        const index = tree.node_count;

        tree.records[index] = .{
            .link = link_of(.key, index + 1),
            .owner = parent | clean_bits(string_module.escape_free(key)),
            .size = @intCast(key.len),
            .target = tree.quoted_store(key),
        };

        tree.node_count += 1;
    }

    fn key_token_store(tree: *Tree, parent: u32, token: []const u8) u32 {
        assert(parent < tree.node_count);
        assert(token_bytes(token) <= tree.text.len - tree.text_count);

        const index = tree.node_count;
        const offset = tree.text_count + 1;
        const key = pointer_module.token_unescape(token, tree.text[offset..]);

        tree.text[offset - 1] = '"';
        tree.text[offset + key.len] = '"';
        tree.text_count += @intCast(key.len + 2);

        tree.records[index] = .{
            .link = link_of(.key, index + 1),
            .owner = parent | clean_bits(string_module.escape_free(key)),
            .size = @intCast(key.len),
            .target = offset,
        };

        tree.node_count += 1;

        assert(std.unicode.utf8ValidateSlice(key));
        assert(offset + key.len < tree.text_count);

        return index;
    }

    fn text_store(tree: *Tree, bytes: []const u8) u32 {
        assert(bytes.len <= tree.text.len - tree.text_count);
        assert(tree.text_count <= tree.text.len);

        const offset = tree.text_count;

        @memcpy(tree.text[offset..][0..bytes.len], bytes);
        tree.text_count += @intCast(bytes.len);

        return offset;
    }

    fn quoted_store(tree: *Tree, bytes: []const u8) u32 {
        assert(bytes.len + 2 <= tree.text.len - tree.text_count);
        assert(tree.text_count <= tree.text.len);

        const offset = tree.text_count + 1;

        tree.text[offset - 1] = '"';
        @memcpy(tree.text[offset..][0..bytes.len], bytes);
        tree.text[offset + bytes.len] = '"';
        tree.text_count += @intCast(bytes.len + 2);

        assert(offset + bytes.len < tree.text_count);

        return offset;
    }

    fn fields_store(tree: *Tree, index: u32, fields: Fields) void {
        assert(index < tree.node_count);
        assert(fields.kind != .key);

        const record = &tree.records[index];

        record.link = link_of(fields.kind, record.sibling());
        record.owner = (record.owner & ~clean_flag) | clean_bits(fields.clean);
        record.size = fields.size;
        record.target = fields.target;
    }

    fn segment_append(tree: *Tree, container: u32, segment: Segment) void {
        assert(container < tree.node_count);
        assert(tree.records[segment.last].parent() == container);

        const record = &tree.records[container];

        assert(container_is(record.kind()));

        if (record.size == 0) {
            tree.records[segment.last].sibling_set(segment.first);
        } else {
            const tail = &tree.records[record.target];

            tree.records[segment.last].sibling_set(tail.sibling());
            tail.sibling_set(segment.first);
        }

        record.target = segment.last;
        record.size += 1;
    }

    fn segment_insert(tree: *Tree, predecessor: u32, segment: Segment) void {
        assert(predecessor < tree.node_count);
        assert(tree.records[segment.first].parent() == tree.records[predecessor].parent());

        const container = &tree.records[tree.records[predecessor].parent()];

        assert(container.size > 0);

        tree.records[segment.last].sibling_set(tree.records[predecessor].sibling());
        tree.records[predecessor].sibling_set(segment.first);
        container.size += 1;
    }

    fn segment_find(tree: *const Tree, value: u32) Found {
        assert(value < tree.node_count);
        assert(value != root_index);

        const container = &tree.records[tree.records[value].parent()];
        const object = container.kind() == .object;

        assert(container.size > 0);

        var predecessor = container.target;
        var cursor = tree.child_first(container);

        for (0..container.size) |_| {
            const last = if (object) tree.records[cursor].sibling() else cursor;
            const segment: Segment = .{ .first = cursor, .last = last };
            if (last == value) return .{ .predecessor = predecessor, .segment = segment };

            predecessor = last;
            cursor = tree.records[last].sibling();
        }

        unreachable;
    }

    fn segment_unlink(tree: *Tree, predecessor: u32, segment: Segment) void {
        assert(predecessor < tree.node_count);
        assert(segment.first < tree.node_count);

        const container = &tree.records[tree.records[segment.first].parent()];

        assert(container.size > 0);
        assert(tree.records[predecessor].sibling() == segment.first);

        if (container.size == 1) {
            container.target = none;
        } else {
            const following = tree.records[segment.last].sibling();

            tree.records[predecessor].sibling_set(following);

            if (container.target == segment.last) container.target = predecessor;
        }

        container.size -= 1;
    }

    fn children_detach(tree: *Tree, container: u32) void {
        assert(container < tree.node_count);
        assert(tree.records[container].attached());

        var walk: Walk = undefined;

        tree.walk_start(&walk, container);

        for (0..tree.node_count) |_| {
            const step = tree.walk_next(&walk) orelse return;

            tree.records[step.index].owner |= detached_flag;
        }

        unreachable;
    }

    fn walk_start(tree: *const Tree, walk: *Walk, container: u32) void {
        assert(container < tree.node_count);
        assert(tree.node_count <= tree.records.len);

        walk.depth = 0;

        tree.walk_push(walk, container);
    }

    fn walk_push(tree: *const Tree, walk: *Walk, container: u32) void {
        assert(container < tree.node_count);
        assert(walk.depth <= depth_max);

        const record = &tree.records[container];
        const count = record.child_count();
        if (count == 0) return;

        assert(walk.depth < depth_max);

        walk.frames[walk.depth] = .{
            .container = container,
            .cursor = tree.child_first(record),
            .remaining = count,
        };

        walk.depth += 1;
    }

    fn walk_next(tree: *const Tree, walk: *Walk) ?Step {
        assert(walk.depth <= depth_max);
        assert(tree.node_count <= tree.records.len);

        for (0..depth_max + 1) |_| {
            if (walk.depth == 0) return null;

            const frame = &walk.frames[walk.depth - 1];

            if (frame.remaining == 0) {
                walk.depth -= 1;

                continue;
            }

            const child = frame.cursor;
            const step: Step = .{ .depth = walk.depth, .index = child, .parent = frame.container };

            frame.cursor = tree.records[child].sibling();
            frame.remaining -= 1;

            tree.walk_push(walk, child);

            return step;
        }

        unreachable;
    }
};

pub fn TreeType(comptime capacity: Capacity) type {
    comptime assert(capacity.node_count_max > 0);
    comptime assert(capacity.node_count_max <= node_count_limit);

    return struct {
        storage: Tree.StorageType(capacity),
        tree: Tree,

        const Fixed = @This();

        pub fn init(fixed: *Fixed) void {
            fixed.tree.init(fixed.storage.storage());
        }

        pub fn root(fixed: *const Fixed) Tree.Node {
            return fixed.tree.root();
        }

        pub fn kind_of(fixed: *const Fixed, node: Tree.Node) Tree.Kind {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.kind_of(node);
        }

        pub fn count_of(fixed: *const Fixed, node: Tree.Node) u32 {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.count_of(node);
        }

        pub fn member(fixed: *const Fixed, object: Tree.Node, key: []const u8) ?Tree.Node {
            assert(@backingInt(object) < fixed.tree.node_count);
            assert(key.len <= input_bytes_max);

            return fixed.tree.member(object, key);
        }

        pub fn item(fixed: *const Fixed, array: Tree.Node, index: u32) ?Tree.Node {
            assert(@backingInt(array) < fixed.tree.node_count);
            assert(@min(index, fixed.tree.count_of(array)) < fixed.tree.node_count);

            return fixed.tree.item(array, index);
        }

        pub fn entries(fixed: *const Fixed, object: Tree.Node) Tree.Entries {
            assert(@backingInt(object) < fixed.tree.node_count);

            return fixed.tree.entries(object);
        }

        pub fn items(fixed: *const Fixed, array: Tree.Node) Tree.Items {
            assert(@backingInt(array) < fixed.tree.node_count);

            return fixed.tree.items(array);
        }

        pub fn path_find(
            fixed: *const Fixed,
            start: Tree.Node,
            segments: []const []const u8,
        ) ?Tree.Node {
            assert(@backingInt(start) < fixed.tree.node_count);
            assert(segments.len <= input_bytes_max);

            return fixed.tree.path_find(start, segments);
        }

        pub fn pointer_find(fixed: *const Fixed, start: Tree.Node, pointer: []const u8) ?Tree.Node {
            assert(@backingInt(start) < fixed.tree.node_count);
            assert(pointer.len <= input_bytes_max);

            return fixed.tree.pointer_find(start, pointer);
        }

        pub fn text_of(fixed: *const Fixed, node: Tree.Node) ?[]const u8 {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.text_of(node);
        }

        pub fn text_is(fixed: *const Fixed, node: Tree.Node, text: []const u8) bool {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(text.len <= input_bytes_max);

            return fixed.tree.text_is(node, text);
        }

        pub fn boolean_of(fixed: *const Fixed, node: Tree.Node) ?bool {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.boolean_of(node);
        }

        pub fn integer_of(fixed: *const Fixed, node: Tree.Node) ?i64 {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.integer_of(node);
        }

        pub fn unsigned_of(fixed: *const Fixed, node: Tree.Node) ?u64 {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.unsigned_of(node);
        }

        pub fn float_of(fixed: *const Fixed, node: Tree.Node) ?f64 {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.float_of(node);
        }

        pub fn set(
            fixed: *Fixed,
            object: Tree.Node,
            key: []const u8,
            content: Tree.Content,
        ) Tree.EditError!Tree.Node {
            assert(@backingInt(object) < fixed.tree.node_count);
            assert(key.len <= input_bytes_max);
            assert(content_bytes(&content) <= input_bytes_max);

            return fixed.tree.set(object, key, content);
        }

        pub fn append(
            fixed: *Fixed,
            array: Tree.Node,
            content: Tree.Content,
        ) error{
            DepthExceeded,
            NodesExhausted,
            NumberInvalid,
            TextExhausted,
            Utf8Invalid,
        }!Tree.Node {
            assert(@backingInt(array) < fixed.tree.node_count);
            assert(content_bytes(&content) <= input_bytes_max);

            return try fixed.tree.append(array, content);
        }

        pub fn insert(
            fixed: *Fixed,
            array: Tree.Node,
            index: u32,
            content: Tree.Content,
        ) error{
            DepthExceeded,
            NodesExhausted,
            NumberInvalid,
            TextExhausted,
            Utf8Invalid,
        }!Tree.Node {
            assert(@backingInt(array) < fixed.tree.node_count);
            assert(index <= fixed.tree.count_of(array));
            assert(content_bytes(&content) <= input_bytes_max);

            return try fixed.tree.insert(array, index, content);
        }

        pub fn replace(fixed: *Fixed, node: Tree.Node, content: Tree.Content) Tree.EditError!void {
            assert(@backingInt(node) < fixed.tree.node_count);
            assert(content_bytes(&content) <= input_bytes_max);

            return fixed.tree.replace(node, content);
        }

        pub fn remove(fixed: *Fixed, node: Tree.Node) void {
            assert(@backingInt(node) < fixed.tree.node_count);

            fixed.tree.remove(node);
        }

        pub fn patch(
            fixed: *Fixed,
            document: *const Document,
            operations: DocumentNode,
            options: Tree.PatchOptions,
        ) (Tree.CapacityError || Tree.ConflictError || Tree.PatchError)!void {
            comptime assert(@sizeOf(@TypeOf(options)) <= 16);
            assert(fixed.tree.node_count > 0);
            assert(@backingInt(operations) < document.node_count);

            return fixed.tree.patch(document, operations, options);
        }

        pub fn merge_patch(
            fixed: *Fixed,
            target: Tree.Node,
            document: *const Document,
            changes: DocumentNode,
        ) Tree.CapacityError!void {
            assert(@backingInt(target) < fixed.tree.node_count);
            assert(@backingInt(changes) < document.node_count);

            return fixed.tree.merge_patch(target, document, changes);
        }

        pub fn write(
            fixed: *const Fixed,
            sink: *std.Io.Writer,
            options: Writer.Options,
        ) std.Io.Writer.Error!void {
            assert(options.indent >= 1);

            return fixed.tree.write(sink, options);
        }

        pub fn node_write(
            fixed: *const Fixed,
            writer: *Writer,
            node: Tree.Node,
        ) (Writer.CapacityError || std.Io.Writer.Error)!void {
            assert(@backingInt(node) < fixed.tree.node_count);

            return fixed.tree.node_write(writer, node);
        }
    };
}

const Build = struct {
    child_base: u32,
    level: u32,
    records: []Record,
    root: u32,
    source_first: u32,
    text: []u8,
    text_count: u32,
};

const BuildFrame = struct {
    container: Container,
    end: u32,
    first: u32,
    last: u32,
    target: u32,
};

const Clone = struct {
    depth: u32,
    frames: [depth_max]CloneFrame,
    next: u32,
};

const CloneFrame = struct {
    cursor: u32,
    first: u32,
    parent: u32,
    remaining: u32,
    slot: u32,
};

const Copier = struct {
    child_base: u32,
    decoded: []const u8,
    depth: u32,
    frames: [depth_max]BuildFrame,
    level: u32,
    records: []Record,
    source: []const u8,
    source_first: u32,
    sources: []const DocumentRecord,
    text: []u8,
    text_count: u32,
    top: BuildFrame,
};

const Container = enum {
    array,
    object,
};

const Create = struct {
    key: ?[]const u8,
    parent: u32,
};

pub const Cut = struct {
    found: Found,
    last: bool,
    orphan: Orphan,
};

pub const Destination = union(enum) {
    item: Item,
    member: Member,
    value: Tree.Node,

    pub const Item = struct {
        array: Tree.Node,
        index: u32,
    };

    pub const Member = struct {
        object: Tree.Node,
        token: []const u8,
    };
};

const Fields = struct {
    clean: bool,
    kind: Record.Kind,
    size: u32,
    target: u32,
};

const Found = struct {
    predecessor: u32,
    segment: Segment,
};

const Need = struct {
    depth: u32,
    node_count: u32,
    text_bytes: u64,
};

pub const Orphan = struct {
    level: u32,
    node: Tree.Node,
};

const Piece = struct {
    clean: bool,
    size: u32,
    target: u32,
};

const Placement = struct {
    index: u32,
    level: u32,
};

const Record = struct {
    link: u32,
    owner: u32,
    size: u32,
    target: u32,

    const Kind = enum(u3) {
        null_value,
        false_value,
        true_value,
        number,
        string,
        key,
        array,
        object,
    };

    fn kind(record: *const Record) Kind {
        assert(record.owner & ~owner_flags <= none);

        const result: Kind = @fromBackingInt(@as(u3, @intCast(record.link >> link_kind_shift)));

        if (result == .key) assert(record.parent() != none);

        return result;
    }

    fn sibling(record: *const Record) u32 {
        assert(record.owner & ~owner_flags <= none);

        const result = record.link & link_target_mask;

        assert(result <= none);

        return result;
    }

    fn sibling_set(record: *Record, index: u32) void {
        assert(index < none);
        assert(record.owner & ~owner_flags <= none);

        record.link = (record.link & ~link_target_mask) | index;
    }

    fn parent(record: *const Record) u32 {
        assert(record.owner & ~owner_flags <= none);
        assert(record.link >> link_kind_shift <= @backingInt(Kind.object));

        return record.owner & link_target_mask;
    }

    fn clean(record: *const Record) bool {
        assert(record.owner & ~owner_flags <= none);
        assert(record.link >> link_kind_shift <= @backingInt(Kind.object));

        return record.owner & clean_flag != 0;
    }

    fn attached(record: *const Record) bool {
        assert(record.owner & ~owner_flags <= none);
        assert(record.link >> link_kind_shift <= @backingInt(Kind.object));

        return record.owner & detached_flag == 0;
    }

    fn child_count(record: *const Record) u32 {
        assert(record.owner & ~owner_flags <= none);

        const result = switch (record.kind()) {
            .array => record.size,
            .object => 2 * record.size,
            .false_value, .key, .null_value, .number, .string, .true_value => 0,
        };

        if (result > 0) assert(record.target < none);

        return result;
    }
};

const Scalar = struct {
    clean: bool,
    kind: Record.Kind,
    text: []const u8,
};

const Segment = struct {
    first: u32,
    last: u32,
};

const Slot = struct {
    index: u32,
    sibling: u32,
};

const Step = struct {
    depth: u32,
    index: u32,
    parent: u32,
};

const Visit = struct {
    depth: *u32,
    frames: *[depth_max]WriteFrame,
    index: u32,
};

const Walk = struct {
    depth: u32,
    frames: [depth_max]WalkFrame,
};

const WalkError = Writer.CapacityError || std.Io.Writer.Error;

const WalkFrame = struct {
    container: u32,
    cursor: u32,
    remaining: u32,
};

const WriteFrame = struct {
    container: Container,
    cursor: u32,
    remaining: u32,
};

pub fn audit(tree: *const Tree) void {
    assert(tree.node_count > 0);
    assert(tree.node_count <= tree.records.len);
    assert(tree.text_count <= tree.text.len);
    assert(tree.records[root_index].attached());
    assert(tree.records[root_index].parent() == none);

    record_audit(tree, root_index);

    var walk: Walk = undefined;
    var reached: u32 = 1;

    tree.walk_start(&walk, root_index);

    for (0..tree.node_count) |_| {
        const step = tree.walk_next(&walk) orelse break;
        const record = &tree.records[step.index];

        assert(record.attached());
        assert(record.parent() == step.parent);

        if (container_is(record.kind())) assert(step.depth + 1 <= depth_max);

        record_audit(tree, step.index);
        reached += 1;
    }

    var attached_count: u32 = 0;

    for (tree.records[0..tree.node_count]) |*record| {
        attached_count += @intFromBool(record.attached());
    }

    assert(walk.depth == 0);
    assert(attached_count == reached);
}

fn record_audit(tree: *const Tree, index: u32) void {
    assert(index < tree.node_count);
    assert(tree.records[index].attached());

    const record = &tree.records[index];

    if (record.clean()) assert(record.kind() == .key or record.kind() == .string);

    switch (record.kind()) {
        .array, .object => list_audit(tree, index),
        .false_value, .null_value, .true_value => assert(record.size == 0),
        .key, .string => {
            const inner = tree.text[record.target..][0..record.size];

            assert(record.target + record.size < tree.text_count);
            assert(tree.text[record.target - 1] == '"');
            assert(tree.text[record.target + record.size] == '"');
            assert(std.unicode.utf8ValidateSlice(inner));

            if (record.clean()) assert(string_module.escape_free(inner));
        },
        .number => {
            assert(record.target + record.size <= tree.text_count);
            assert(number_module.grammar_is(tree.text[record.target..][0..record.size]));
        },
    }
}

fn list_audit(tree: *const Tree, container: u32) void {
    assert(container < tree.node_count);
    assert(container_is(tree.records[container].kind()));

    const record = &tree.records[container];
    const count = record.child_count();
    const object = record.kind() == .object;

    if (count == 0) return assert(record.target == none);

    const first = tree.records[record.target].sibling();
    var cursor = first;

    for (0..count) |position| {
        const child = &tree.records[cursor];
        const key_expected = object and position % 2 == 0;

        if (position > 0) assert(cursor != first);
        if (position + 1 == count) assert(cursor == record.target);

        assert(child.parent() == container);
        assert((child.kind() == .key) == key_expected);

        cursor = child.sibling();
    }

    assert(cursor == first);
}

pub fn member_token_add(
    tree: *Tree,
    object: Tree.Node,
    token: []const u8,
    content: *const Tree.Content,
) Tree.CapacityError!Tree.Node {
    assert(tree.record_of(object).kind() == .object);
    assert(std.mem.findScalar(u8, token, '/') == null);

    const container = @backingInt(object);
    const key = tree.node_count;
    const text_count = tree.text_count;

    try tree.capacity_check(.{ .depth = 0, .node_count = 1, .text_bytes = token_bytes(token) });

    _ = tree.key_token_store(container, token);

    const value = tree.value_create(.{ .key = null, .parent = container }, content) catch |err| {
        tree.node_count = key;
        tree.text_count = text_count;

        return capacity_error_of(err);
    };

    tree.segment_append(container, .{ .first = key, .last = value });

    assert(value == key + 1);
    assert(tree.records[container].target == value);

    return @fromBackingInt(value);
}

pub fn subtree_copy(tree: *Tree, node: Tree.Node) Tree.CapacityError!Orphan {
    assert(tree.record_of(node).kind() != .key);
    assert(tree.node_count <= tree.records.len);

    const source = @backingInt(node);
    const base = tree.node_count;
    const record = &tree.records[source];

    try tree.capacity_check(.{ .depth = 0, .node_count = 1, .text_bytes = 0 });

    tree.records[base] = .{
        .link = link_of(record.kind(), base),
        .owner = (record.owner & clean_flag) | none,
        .size = record.size,
        .target = record.target,
    };

    var clone: Clone = .{ .depth = 0, .frames = undefined, .next = base + 1 };

    try clone_push(tree, &clone, record, base);
    try clone_walk(tree, &clone);

    tree.node_count = clone.next;

    assert(clone.depth == 0);
    assert(tree.records[base].kind() == record.kind());

    const parent = record.parent();
    const level = if (parent == none) 0 else tree.level_of(parent);

    return .{ .level = level, .node = @fromBackingInt(base) };
}

fn clone_walk(tree: *Tree, clone: *Clone) Tree.CapacityError!void {
    assert(clone.depth <= 1);
    assert(clone.next <= tree.records.len);

    for (0..2 * tree.node_count + 1) |_| {
        if (clone.depth == 0) return;

        const frame = &clone.frames[clone.depth - 1];

        if (frame.remaining == 0) {
            clone.depth -= 1;

            continue;
        }

        const source = frame.cursor;
        const target = frame.slot;
        const record = &tree.records[source];

        frame.cursor = record.sibling();
        frame.remaining -= 1;
        frame.slot += 1;

        const sibling = if (frame.remaining == 0) frame.first else target + 1;

        tree.records[target] = .{
            .link = link_of(record.kind(), sibling),
            .owner = (record.owner & clean_flag) | frame.parent,
            .size = record.size,
            .target = record.target,
        };

        try clone_push(tree, clone, record, target);
    }

    unreachable;
}

fn clone_push(
    tree: *Tree,
    clone: *Clone,
    record: *const Record,
    target: u32,
) Tree.CapacityError!void {
    assert(tree.records[target].kind() == record.kind());
    assert(clone.depth <= depth_max);

    const count = record.child_count();
    if (count == 0) return;
    if (count > tree.records.len - clone.next) return error.NodesExhausted;

    assert(clone.depth < depth_max);

    const first = clone.next;

    clone.next += count;
    tree.records[target].target = first + count - 1;

    clone.frames[clone.depth] = .{
        .cursor = tree.records[record.target].sibling(),
        .first = first,
        .parent = target,
        .remaining = count,
        .slot = first,
    };

    clone.depth += 1;
}

pub fn subtree_discard(tree: *Tree, orphan: Orphan) void {
    assert(@backingInt(orphan.node) < tree.node_count);
    assert(tree.records[@backingInt(orphan.node)].parent() == none);

    tree.node_count = @backingInt(orphan.node);

    assert(tree.node_count > 0);
}

pub fn subtree_link(
    tree: *Tree,
    orphan: Orphan,
    destination: Destination,
) Tree.CapacityError!void {
    assert(@backingInt(orphan.node) != root_index);
    assert(tree.records[@backingInt(orphan.node)].attached());
    if (destination == .value) assert(destination.value != orphan.node);

    const parent = switch (destination) {
        .item => |item| @backingInt(item.array),
        .member => |member| @backingInt(member.object),
        .value => |value| tree.record_of(value).parent(),
    };

    if (parent != none) assert(container_is(tree.records[parent].kind()));

    const level = if (parent == none) 0 else tree.level_of(parent);

    if (level > orphan.level) {
        if (level + tree.height_of(@backingInt(orphan.node)) > depth_max) {
            return error.DepthExceeded;
        }
    }

    switch (destination) {
        .item => |item| item_link(tree, item, orphan),
        .member => |member| try member_link(tree, member, orphan),
        .value => |value| transplant(tree, value, orphan),
    }
}

fn item_link(tree: *Tree, item: Destination.Item, orphan: Orphan) void {
    assert(tree.record_of(item.array).kind() == .array);
    assert(item.index <= tree.record_of(item.array).size);
    assert(tree.records[@backingInt(orphan.node)].attached());

    const index = @backingInt(orphan.node);
    const container = @backingInt(item.array);
    const record = &tree.records[container];
    const segment: Segment = .{ .first = index, .last = index };

    tree.records[index].owner = (tree.records[index].owner & owner_flags) | container;

    if (item.index == record.size) {
        tree.segment_append(container, segment);
    } else if (item.index == 0) {
        tree.segment_insert(record.target, segment);
    } else {
        tree.segment_insert(tree.child_at(record, item.index - 1), segment);
    }

    assert(tree.child_at(record, item.index) == index);
}

fn member_link(
    tree: *Tree,
    member: Destination.Member,
    orphan: Orphan,
) Tree.CapacityError!void {
    assert(tree.record_of(member.object).kind() == .object);
    assert(std.mem.findScalar(u8, member.token, '/') == null);
    assert(tree.records[@backingInt(orphan.node)].attached());

    const index = @backingInt(orphan.node);
    const container = @backingInt(member.object);
    const text_bytes = token_bytes(member.token);

    try tree.capacity_check(.{ .depth = 0, .node_count = 1, .text_bytes = text_bytes });

    const key = tree.key_token_store(container, member.token);

    tree.records[key].sibling_set(index);
    tree.records[index].owner = (tree.records[index].owner & owner_flags) | container;

    tree.segment_append(container, .{ .first = key, .last = index });

    assert(tree.records[container].target == index);
}

fn transplant(tree: *Tree, value: Tree.Node, orphan: Orphan) void {
    assert(value != orphan.node);
    assert(tree.record_of(value).kind() != .key);

    const target = @backingInt(value);
    const source = @backingInt(orphan.node);

    tree.children_detach(target);

    const record = &tree.records[source];
    const count = record.child_count();
    var cursor = tree.child_first(record);

    for (0..count) |_| {
        const child = &tree.records[cursor];

        child.owner = (child.owner & owner_flags) | target;
        cursor = child.sibling();
    }

    tree.fields_store(target, .{
        .clean = record.clean(),
        .kind = record.kind(),
        .size = record.size,
        .target = record.target,
    });

    record.owner |= detached_flag;

    assert(!tree.records[source].attached());
    assert(tree.records[target].kind() == record.kind());
}

pub fn subtree_restore(tree: *Tree, cut: *const Cut) void {
    assert(@backingInt(cut.orphan.node) == cut.found.segment.last);
    assert(tree.records[cut.found.segment.last].attached());

    const segment = cut.found.segment;
    const container = tree.records[segment.last].parent();

    if (segment.first != segment.last) tree.records[segment.first].owner &= ~detached_flag;

    if (cut.last) {
        tree.segment_append(container, segment);
    } else {
        tree.segment_insert(cut.found.predecessor, segment);
    }

    assert(tree.records[container].size > 0);
}

pub fn subtree_unlink(tree: *Tree, node: Tree.Node) Cut {
    assert(@backingInt(node) != root_index);
    assert(tree.record_of(node).kind() != .key);

    const index = @backingInt(node);
    const parent = tree.records[index].parent();
    const level = tree.level_of(parent);
    const found = tree.segment_find(index);
    const last = tree.records[parent].target == index;

    tree.segment_unlink(found.predecessor, found.segment);

    if (found.segment.first != index) tree.records[found.segment.first].owner |= detached_flag;

    assert(found.segment.last == index);
    assert(tree.records[index].attached());

    return .{ .found = found, .last = last, .orphan = .{ .level = level, .node = node } };
}

pub fn capacity_error_of(err: Tree.EditError) Tree.CapacityError {
    assert(err != error.NumberInvalid);
    assert(err != error.Utf8Invalid);

    return switch (err) {
        error.DepthExceeded => error.DepthExceeded,
        error.NodesExhausted => error.NodesExhausted,
        error.NumberInvalid, error.Utf8Invalid => unreachable,
        error.TextExhausted => error.TextExhausted,
    };
}

pub fn number_text(tree: *const Tree, node: Tree.Node) []const u8 {
    assert(tree.record_of(node).kind() == .number);

    const result = tree.number_text_of(node) orelse unreachable;

    assert(result.len > 0);

    return result;
}

fn token_bytes(token: []const u8) u64 {
    assert(token.len <= input_bytes_max);
    assert(std.mem.findScalar(u8, token, '/') == null);

    return token.len - std.mem.countScalar(u8, token, '~') + 2;
}

fn container_is(kind: Record.Kind) bool {
    assert(@backingInt(Record.Kind.array) + 1 == @backingInt(Record.Kind.object));
    assert(@backingInt(kind) <= @backingInt(Record.Kind.object));

    return @backingInt(kind) >= @backingInt(Record.Kind.array);
}

fn clean_bits(clean: bool) u32 {
    assert(clean_flag > link_target_mask);
    assert(clean_flag & detached_flag == 0);

    return if (clean) clean_flag else 0;
}

fn scalar_bytes(scalar: *const Scalar) u64 {
    assert(scalar.text.len <= input_bytes_max);
    assert(scalar.kind != .key);

    return switch (scalar.kind) {
        .number => scalar.text.len,
        .string => scalar.text.len + 2,
        .array, .false_value, .key, .null_value, .object, .true_value => 0,
    };
}

fn link_of(kind: Record.Kind, sibling: u32) u32 {
    assert(sibling <= link_target_mask);
    assert(@backingInt(kind) <= @backingInt(Record.Kind.object));

    const result = @as(u32, @backingInt(kind)) << link_kind_shift | sibling;

    assert(result & link_target_mask == sibling);

    return result;
}

fn content_bytes(content: *const Tree.Content) u64 {
    assert(@sizeOf(Tree.Content) <= 32);

    const result: u64 = switch (content.*) {
        .number, .string => |text| text.len,
        .array, .boolean, .copy, .float, .integer, .null_value, .object, .unsigned => 0,
    };

    if (result > 0) assert(content.* == .number or content.* == .string);

    return result;
}

fn scalar_of(content: *const Tree.Content, buffer: *[float_bytes_max]u8) Tree.ValueError!Scalar {
    assert(content.* != .copy);
    assert(buffer.len > integer_bytes_max);

    const result: Scalar = switch (content.*) {
        .array => .{ .clean = false, .kind = .array, .text = "" },
        .boolean => |value| .{
            .clean = false,
            .kind = if (value) .true_value else .false_value,
            .text = "",
        },
        .copy => unreachable,
        .float => |value| .{ .clean = false, .kind = .number, .text = float_text(value, buffer) },
        .integer => |value| .{
            .clean = false,
            .kind = .number,
            .text = integer_text(value, buffer),
        },
        .null_value => .{ .clean = false, .kind = .null_value, .text = "" },
        .number => |text| number: {
            if (!number_module.grammar_is(text)) return error.NumberInvalid;

            break :number .{ .clean = false, .kind = .number, .text = text };
        },
        .object => .{ .clean = false, .kind = .object, .text = "" },
        .string => |text| string: {
            if (!std.unicode.utf8ValidateSlice(text)) return error.Utf8Invalid;

            const clean = string_module.escape_free(text);

            break :string .{ .clean = clean, .kind = .string, .text = text };
        },
        .unsigned => |value| .{
            .clean = false,
            .kind = .number,
            .text = number_module.integer_format(value, buffer[0..integer_bytes_max]),
        },
    };

    if (result.kind == .number) assert(number_module.grammar_is(result.text));

    return result;
}

fn float_text(value: f64, buffer: *[float_bytes_max]u8) []const u8 {
    assert(buffer.len == float_bytes_max);

    assert(@intFromBool(std.math.signbit(value)) + number_module.float_unsigned_bytes_max <=
        buffer.len);

    if (!std.math.isFinite(value)) return number_module.spelling_of(value);
    return number_module.float_format(f64, value, buffer);
}

fn integer_text(value: i64, buffer: *[float_bytes_max]u8) []const u8 {
    assert(buffer.len >= integer_bytes_max + 1);
    assert(std.math.log10_int(@abs(value) | 1) + 2 <= buffer.len);

    const end = integer_bytes_max + 1;
    const digits = number_module.integer_format(@abs(value), buffer[1..end]);
    const start = end - digits.len - @intFromBool(value < 0);

    if (value < 0) buffer[start] = '-';

    return buffer[start..end];
}

fn subtree_count(document: *const Document, source: u32) u32 {
    assert(source < document.node_count);
    assert(document.node_count <= document.storage.records.len);

    const record = &document.storage.records[source];

    const result = switch (record.kind()) {
        .array, .object => record.target() - source,
        .false_value, .null_value, .number, .string, .string_escaped, .true_value => 1,
    };

    assert(result >= 1);
    assert(source + result <= document.node_count);

    return result;
}

fn copy_build(build: *Build, document: *const Document, source: u32) Tree.CapacityError!Fields {
    assert(source < document.node_count);
    assert(build.source_first == source + 1);

    const record = &document.storage.records[source];

    return switch (record.kind()) {
        .array => container_build(build, document, record, .array),
        .false_value => .{ .clean = false, .kind = .false_value, .size = 0, .target = 0 },
        .null_value => .{ .clean = false, .kind = .null_value, .size = 0, .target = 0 },
        .number, .string, .string_escaped => text_build(build, document, record),
        .object => container_build(build, document, record, .object),
        .true_value => .{ .clean = false, .kind = .true_value, .size = 0, .target = 0 },
    };
}

fn text_build(
    build: *Build,
    document: *const Document,
    record: *const DocumentRecord,
) Tree.CapacityError!Fields {
    assert(record.start < record.end);
    assert(record.end <= document.source.len);

    var copier: Copier = undefined;

    copier.decoded = document.storage.text;
    copier.source = document.source;
    copier.text = build.text;
    copier.text_count = build.text_count;

    const piece = try piece_copy(&copier, record);
    const kind: Record.Kind = if (record.kind() == .number) .number else .string;

    build.text_count = copier.text_count;

    return .{ .clean = piece.clean, .kind = kind, .size = piece.size, .target = piece.target };
}

fn container_build(
    build: *Build,
    document: *const Document,
    record: *const DocumentRecord,
    comptime container: Container,
) Tree.CapacityError!Fields {
    assert(build.level <= depth_max);
    assert(build.source_first <= record.target());

    const kind: Record.Kind = if (container == .array) .array else .object;

    if (build.level + 1 > depth_max) return error.DepthExceeded;
    if (record.size == 0) return .{ .clean = false, .kind = kind, .size = 0, .target = none };

    const last = try children_copy(build, document, .{
        .container = container,
        .end = record.target(),
        .first = build.child_base,
        .last = none,
        .target = build.root,
    });

    assert(last >= build.child_base);
    assert(last < build.records.len);

    return .{ .clean = false, .kind = kind, .size = record.size, .target = last };
}

const children_copy = if (structural.functions_aligned)
    children_copy_aligned
else
    children_copy_unaligned;

noinline fn children_copy_aligned(
    build: *Build,
    document: *const Document,
    root: BuildFrame,
) align(64) Tree.CapacityError!u32 {
    assert(root.end > build.source_first);
    assert(root.first == build.child_base);

    return children_copy_body(build, document, root);
}

noinline fn children_copy_unaligned(
    build: *Build,
    document: *const Document,
    root: BuildFrame,
) Tree.CapacityError!u32 {
    assert(root.end > build.source_first);
    assert(root.first == build.child_base);

    return children_copy_body(build, document, root);
}

inline fn children_copy_body(
    build: *Build,
    document: *const Document,
    root: BuildFrame,
) Tree.CapacityError!u32 {
    assert(root.end > build.source_first);
    assert(root.first == build.child_base);

    var copier: Copier = .{
        .child_base = build.child_base,
        .decoded = document.storage.text,
        .depth = 1,
        .frames = undefined,
        .level = build.level,
        .records = build.records,
        .source = document.source,
        .source_first = build.source_first,
        .sources = document.storage.records[0..document.node_count],
        .text = build.text,
        .text_count = build.text_count,
        .top = root,
    };

    var index = build.source_first;

    for (0..root.end - build.source_first) |_| {
        if (index == root.end) break;

        copier_close(&copier, index);

        if (copier.top.container == .object) {
            try copier_key(&copier, index);

            index += 1;
        }

        try copier_value(&copier, index);

        index += 1;
    }

    copier_close(&copier, index);

    assert(index == root.end);
    assert(copier.depth == 1);

    build.text_count = copier.text_count;

    return copier.top.last;
}

inline fn copier_close(copier: *Copier, index: u32) void {
    assert(copier.depth >= 1);
    assert(index <= copier.top.end);

    for (0..depth_max) |_| {
        if (copier.top.end != index) return;
        if (copier.depth == 1) return;

        copier.records[copier.top.target].target = copier.top.last;
        copier.depth -= 1;
        copier.top = copier.frames[copier.depth - 1];
    }
}

inline fn copier_key(copier: *Copier, index: u32) Tree.CapacityError!void {
    assert(index >= copier.source_first);
    assert(copier.top.container == .object);

    const target = copier.child_base + (index - copier.source_first);
    const slot: Slot = .{ .index = target, .sibling = target + 1 };

    try copier_piece(copier, &copier.sources[index], slot, .key);
}

inline fn copier_value(copier: *Copier, index: u32) Tree.CapacityError!void {
    assert(index >= copier.source_first);
    assert(index < copier.top.end);

    const record = &copier.sources[index];
    const target = copier.child_base + (index - copier.source_first);
    const following = sibling_of(record, index);
    const top = &copier.top;
    const next = copier.child_base + (following - copier.source_first);
    const sibling = if (following == top.end) top.first else next;
    const slot: Slot = .{ .index = target, .sibling = sibling };

    top.last = target;

    switch (record.kind()) {
        .array => try copier_container(copier, record, slot, .array),
        .false_value => copier_literal(copier, slot, .false_value),
        .null_value => copier_literal(copier, slot, .null_value),
        .number => try copier_piece(copier, record, slot, .number),
        .object => try copier_container(copier, record, slot, .object),
        .string, .string_escaped => try copier_piece(copier, record, slot, .string),
        .true_value => copier_literal(copier, slot, .true_value),
    }
}

inline fn copier_container(
    copier: *Copier,
    record: *const DocumentRecord,
    slot: Slot,
    comptime container: Container,
) Tree.CapacityError!void {
    assert(copier.depth >= 1);
    assert(slot.index < copier.records.len);

    if (copier.level + copier.depth + 1 > depth_max) return error.DepthExceeded;

    const kind: Record.Kind = if (container == .array) .array else .object;

    copier.records[slot.index] = .{
        .link = link_of(kind, slot.sibling),
        .owner = copier.top.target,
        .size = record.size,
        .target = none,
    };

    if (record.size == 0) return;

    assert(copier.depth < depth_max);

    copier.frames[copier.depth - 1] = copier.top;
    copier.depth += 1;

    copier.top = .{
        .container = container,
        .end = record.target(),
        .first = slot.index + 1,
        .last = none,
        .target = slot.index,
    };
}

inline fn copier_literal(copier: *Copier, slot: Slot, comptime kind: Record.Kind) void {
    comptime assert(@backingInt(kind) < @backingInt(Record.Kind.number));
    assert(slot.index < copier.records.len);

    copier.records[slot.index] = .{
        .link = link_of(kind, slot.sibling),
        .owner = copier.top.target,
        .size = 0,
        .target = 0,
    };
}

inline fn copier_piece(
    copier: *Copier,
    record: *const DocumentRecord,
    slot: Slot,
    comptime kind: Record.Kind,
) Tree.CapacityError!void {
    comptime assert(kind == .key or kind == .number or kind == .string);
    assert(slot.index < copier.records.len);

    const piece = try piece_copy(copier, record);

    copier.records[slot.index] = .{
        .link = link_of(kind, slot.sibling),
        .owner = copier.top.target | clean_bits(piece.clean),
        .size = piece.size,
        .target = piece.target,
    };
}

inline fn piece_copy(copier: *Copier, record: *const DocumentRecord) Tree.CapacityError!Piece {
    assert(record.start < record.end);
    assert(record.end <= copier.source.len);

    const length = record.end - record.start;

    switch (record.kind()) {
        .number => {
            const offset = try span_copy(copier, record);
            return .{ .clean = false, .size = length, .target = offset };
        },
        .string => {
            const offset = try span_copy(copier, record);
            return .{ .clean = true, .size = length - 2, .target = offset + 1 };
        },
        .string_escaped => return decoded_copy(copier, record),
        .array, .false_value, .null_value, .object, .true_value => unreachable,
    }
}

inline fn span_copy(copier: *Copier, record: *const DocumentRecord) Tree.CapacityError!u32 {
    assert(record.end <= copier.source.len);
    assert(copier.text_count <= copier.text.len);

    const length = record.end - record.start;
    if (length > copier.text.len - copier.text_count) return error.TextExhausted;

    const offset = copier.text_count;
    const origin = copier.source[record.start..];
    const target = copier.text[offset..];

    copier.text_count += length;

    if (length <= chunk_bytes) {
        if (origin.len >= chunk_bytes) {
            if (target.len >= chunk_bytes) {
                target[0..chunk_bytes].* = origin[0..chunk_bytes].*;

                return offset;
            }
        }
    }

    @memcpy(target[0..length], origin[0..length]);

    return offset;
}

noinline fn decoded_copy(copier: *Copier, record: *const DocumentRecord) Tree.CapacityError!Piece {
    assert(record.kind() == .string_escaped);
    assert(copier.text_count <= copier.text.len);

    const decoded = copier.decoded[record.target()..][0..record.size];
    if (decoded.len + 2 > copier.text.len - copier.text_count) return error.TextExhausted;

    const offset = copier.text_count + 1;

    copier.text[offset - 1] = '"';
    @memcpy(copier.text[offset..][0..decoded.len], decoded);
    copier.text[offset + decoded.len] = '"';
    copier.text_count += record.size + 2;

    return .{ .clean = string_module.escape_free(decoded), .size = record.size, .target = offset };
}

inline fn sibling_of(record: *const DocumentRecord, index: u32) u32 {
    assert(record.start < record.end);
    assert(index < link_target_mask);

    return switch (record.kind()) {
        .array, .object => record.target(),
        .false_value, .null_value, .number, .string, .string_escaped, .true_value => index + 1,
    };
}

const walk_write = if (structural.functions_aligned)
    walk_write_aligned
else
    walk_write_unaligned;

noinline fn walk_write_aligned(
    records: []const Record,
    text: []const u8,
    writer: *Writer,
    start: u32,
) align(64) WalkError!void {
    assert(start < records.len);
    assert(text.len <= text_bytes_limit);

    return walk_write_body(records, text, writer, start);
}

noinline fn walk_write_unaligned(
    records: []const Record,
    text: []const u8,
    writer: *Writer,
    start: u32,
) WalkError!void {
    assert(start < records.len);
    assert(text.len <= text_bytes_limit);

    return walk_write_body(records, text, writer, start);
}

inline fn walk_write_body(
    records: []const Record,
    text: []const u8,
    writer: *Writer,
    start: u32,
) WalkError!void {
    assert(start < records.len);
    assert(text.len <= text_bytes_limit);

    var frames: [depth_max]WriteFrame = undefined;
    var depth: u32 = 0;
    var visit: Visit = .{ .depth = &depth, .frames = &frames, .index = start };

    try value_write(records, text, writer, visit);

    for (0..2 * records.len + 1) |_| {
        if (depth == 0) return;

        const frame = &frames[depth - 1];

        if (frame.remaining == 0) {
            switch (frame.container) {
                .array => try writer.array_end(),
                .object => try writer.object_end(),
            }

            depth -= 1;

            continue;
        }

        var child = frame.cursor;

        frame.remaining -= 1;

        if (frame.container == .object) {
            try key_write(writer, &records[child], text);

            child = records[child].sibling();
        }

        frame.cursor = records[child].sibling();
        visit.index = child;

        try value_write(records, text, writer, visit);
    }

    unreachable;
}

inline fn value_write(
    records: []const Record,
    text: []const u8,
    writer: *Writer,
    visit: Visit,
) WalkError!void {
    assert(visit.index < records.len);
    assert(text.len <= text_bytes_limit);

    const record = &records[visit.index];

    switch (record.kind()) {
        .array => {
            try writer.array_begin();

            visit_push(records, visit, .array);
        },
        .false_value => try writer.boolean(false),
        .key => unreachable,
        .null_value => try writer.null_value(),
        .number => try writer_module.number_text_write(writer, text_at(records, text, visit.index)),
        .object => {
            try writer.object_begin();

            visit_push(records, visit, .object);
        },
        .string => try string_write(writer, record, text),
        .true_value => try writer.boolean(true),
    }
}

inline fn visit_push(records: []const Record, visit: Visit, container: Container) void {
    assert(visit.index < records.len);
    assert(visit.depth.* < depth_max);

    const record = &records[visit.index];
    const first = if (record.size == 0) none else records[record.target].sibling();

    visit.frames[visit.depth.*] = .{
        .container = container,
        .cursor = first,
        .remaining = record.size,
    };

    visit.depth.* += 1;
}

inline fn text_at(records: []const Record, text: []const u8, index: u32) []const u8 {
    assert(index < records.len);
    assert(records[index].target + records[index].size <= text.len);

    return text[records[index].target..][0..records[index].size];
}

inline fn key_write(writer: *Writer, record: *const Record, text: []const u8) WalkError!void {
    assert(record.kind() == .key);
    assert(record.target + record.size < text.len);

    if (record.clean()) {
        if (writer.options.utf8 == .trusted) {
            return writer_module.key_escaped_write(writer, quoted_of(record, text), true);
        }
    }

    try writer.key(text[record.target..][0..record.size]);
}

inline fn string_write(writer: *Writer, record: *const Record, text: []const u8) WalkError!void {
    assert(record.kind() == .string);
    assert(record.target + record.size < text.len);

    if (record.clean()) {
        if (writer.options.utf8 == .trusted) {
            return writer_module.string_escaped_write(writer, quoted_of(record, text), true);
        }
    }

    try writer.string(text[record.target..][0..record.size]);
}

inline fn quoted_of(record: *const Record, text: []const u8) []const u8 {
    assert(record.target > 0);
    assert(record.target + record.size < text.len);

    const result = text[record.target - 1 ..][0 .. record.size + 2];

    assert(result[0] == '"');
    assert(result[result.len - 1] == '"');

    return result;
}

const testing = std.testing;

const test_options_compact: Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

const TestDocument = document_module.DocumentType(.{
    .node_count_max = 256,
    .text_bytes_max = 1024,
});

const TestTree = TreeType(.{ .node_count_max = 256, .text_bytes_max = 1024 });

const TestPair = struct {
    document: TestDocument,
    tree: TestTree,
};

fn test_pair_create() !*TestPair {
    const result = try testing.allocator.create(TestPair);

    result.tree.init();

    assert(result.tree.tree.node_count == 1);
    assert(result.tree.storage.records.len == 256);

    return result;
}

fn test_copy(pair: *TestPair, source: []const u8) !void {
    assert(source.len > 0);
    assert(source.len <= input_bytes_max);

    try pair.document.parse(source);

    const copy: Tree.Content.Copy = .{
        .document = &pair.document.document,
        .node = pair.document.root(),
    };

    try pair.tree.replace(pair.tree.root(), .{ .copy = copy });
}

fn test_expect(tree: *const Tree, expected: []const u8) !void {
    assert(expected.len > 0);
    assert(tree.node_count > 0);

    audit(tree);

    var buffer: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, test_options_compact);
    try testing.expectEqualStrings(expected, sink.buffered());
}

fn test_unchanged(tree: *const Tree, before: []const u8, counts: [2]u32) !void {
    assert(before.len > 0);
    assert(counts[0] > 0);

    try testing.expectEqual(counts[0], tree.node_count);
    try testing.expectEqual(counts[1], tree.text_count);
    try test_expect(tree, before);
}

const TestEdit = union(enum) {
    append: Tree.Content,
    insert: Tree.Content,
    replace: Tree.Content,
    set: TestMember,
};

const TestMember = struct {
    content: Tree.Content,
    key: []const u8,
};

const TestRefusal = struct {
    edit: TestEdit,
    expected: Tree.EditError,
    target: Tree.Node,
};

fn test_edit(tree: *Tree, target: Tree.Node, edit: *const TestEdit) Tree.EditError!void {
    assert(@backingInt(target) < tree.node_count);
    assert(tree.records[@backingInt(target)].attached());

    switch (edit.*) {
        .append => |content| _ = try tree.append(target, content),
        .insert => |content| _ = try tree.insert(target, 0, content),
        .replace => |content| try tree.replace(target, content),
        .set => |change| _ = try tree.set(target, change.key, change.content),
    }
}

fn test_refusals(tree: *Tree, refusals: []const TestRefusal) !void {
    assert(refusals.len > 0);
    assert(tree.node_count > 0);

    for (refusals) |*refusal| {
        const result = test_edit(tree, refusal.target, &refusal.edit);

        try testing.expectError(refusal.expected, result);
    }
}

test Tree {
    var storage: Tree.Storage = try .init(testing.allocator, .{
        .node_count_max = 16,
        .text_bytes_max = 64,
    });

    defer storage.deinit(testing.allocator);

    var tree: Tree = undefined;

    tree.init(storage);

    try tree.replace(tree.root(), .object);

    const ports = try tree.set(tree.root(), "ports", .array);
    const last = try tree.append(ports, .{ .unsigned = 8080 });
    const first = try tree.insert(ports, 0, .{ .unsigned = 80 });
    const name = try tree.set(tree.root(), "name", .{ .string = "warbler" });
    var buffer: [128]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    try testing.expectEqualStrings("{\"ports\":[80,8080],\"name\":\"warbler\"}", sink.buffered());
    try testing.expectEqual(@as(?u64, 80), tree.unsigned_of(first));
    try testing.expectEqual(@as(?u64, 8080), tree.unsigned_of(last));
    try testing.expectEqualStrings("warbler", tree.text_of(name).?);

    const Changes = document_module.DocumentType(.{ .node_count_max = 16, .text_bytes_max = 64 });
    var changes: Changes = undefined;

    try changes.parse(
        \\{"name": null, "ports": [443], "tls": {"enabled": true}}
    );

    try tree.merge_patch(tree.root(), &changes.document, changes.root());

    sink = .fixed(&buffer);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    try testing.expectEqualStrings("{\"ports\":[443],\"tls\":{\"enabled\":true}}", sink.buffered());
}

test TreeType {
    const Config = TreeType(.{ .node_count_max = 64, .text_bytes_max = 512 });
    const Source = document_module.DocumentType(.{ .node_count_max = 64, .text_bytes_max = 512 });
    const config = try testing.allocator.create(Config);
    defer testing.allocator.destroy(config);

    const source = try testing.allocator.create(Source);
    defer testing.allocator.destroy(source);

    try source.parse(
        \\{"name": "warbler", "ports": [8080, 8443], "tls": {"enabled": false}}
    );

    config.init();

    try config.replace(config.root(), .{
        .copy = .{ .document = &source.document, .node = source.root() },
    });

    const enabled = config.pointer_find(config.root(), "/tls/enabled") orelse return error.Missing;
    const ports = config.member(config.root(), "ports") orelse return error.PortsMissing;
    const first = config.item(ports, 0) orelse return error.PortMissing;

    try config.replace(enabled, .{ .boolean = true });

    const added = try config.append(ports, .{ .unsigned = 9090 });

    try testing.expectEqual(@as(?u64, 9090), config.unsigned_of(added));

    config.remove(first);

    const changes = try testing.allocator.create(Source);
    defer testing.allocator.destroy(changes);

    try changes.parse(
        \\[{"op": "test", "path": "/name", "value": "warbler"},
        \\ {"op": "add", "path": "/ports/-", "value": 9443},
        \\ {"op": "remove", "path": "/tls/missing"}]
    );

    var position: Position = .{ .column = 0, .line = 0 };
    const patched = config.patch(&changes.document, changes.root(), .{ .diagnostic = &position });

    try testing.expectError(error.PathMissing, patched);
    try testing.expectEqual(@as(u32, 3), position.line);

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try config.write(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    const expected =
        "{\"name\":\"warbler\",\"ports\":[8443,9090,9443],\"tls\":{\"enabled\":true}}";

    try testing.expectEqualStrings(expected, sink.buffered());
    try testing.expectEqual(@as(?u64, 9090), config.unsigned_of(added));
    try testing.expectEqual(@as(?bool, true), config.boolean_of(enabled));
}

test "a new tree holds a null root, and each accessor tolerates a node of the wrong kind" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_expect(tree, "null");
    try test_copy(pair, "[null, true, 1.5, \"s\", [], {}]");

    var items = tree.items(tree.root());

    for (0..6) |_| {
        const node = items.next() orelse return error.ItemMissing;
        const kind = tree.kind_of(node);

        if (kind != .object) try testing.expectEqual(@as(?Tree.Node, null), tree.member(node, "a"));
        if (kind != .object) try testing.expectEqual(@as(u32, 0), tree.entries(node).remaining);
        if (kind != .array) try testing.expectEqual(@as(u32, 0), tree.items(node).remaining);
        if (kind != .array) try testing.expectEqual(@as(?Tree.Node, null), tree.item(node, 0));
        if (kind != .boolean) try testing.expectEqual(@as(?bool, null), tree.boolean_of(node));
        if (kind != .number) try testing.expectEqual(@as(?f64, null), tree.float_of(node));
        if (kind != .number) try testing.expectEqual(@as(?i64, null), tree.integer_of(node));
        if (kind != .number) try testing.expectEqual(@as(?u64, null), tree.unsigned_of(node));
        if (kind != .string) try testing.expect(!tree.text_is(node, "s"));

        try testing.expectEqual(@as(u32, 0), tree.count_of(node));
    }

    const after = items.next();

    try testing.expectEqual(@as(?Tree.Node, null), after);
    try testing.expectEqual(@as(?Tree.Node, null), tree.item(tree.root(), 6));
}

test "set replaces the last matching key in place and appends a new key at the end" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_copy(pair, "{\"a\": 1, \"b\": {\"c\": [2]}, \"a\": 3}");

    const root = tree.root();
    const last = tree.member(root, "a") orelse return error.MemberMissing;
    const nested = tree.member(root, "b") orelse return error.MemberMissing;
    const replaced = try tree.set(root, "a", .{ .integer = -9 });
    const added = try tree.set(root, "d", .null_value);
    const inner = try tree.set(nested, "c", .{ .string = "x\"y" });

    try testing.expectEqual(last, replaced);
    try testing.expectEqual(@as(?i64, -9), tree.integer_of(last));
    try testing.expectEqual(Tree.Kind.null_value, tree.kind_of(added));
    try testing.expectEqualStrings("x\"y", tree.text_of(inner).?);
    try test_expect(tree, "{\"a\":1,\"b\":{\"c\":\"x\\\"y\"},\"a\":-9,\"d\":null}");

    var entries = tree.entries(root);
    const first = entries.next() orelse return error.EntryMissing;

    try testing.expectEqual(Tree.Kind.string, tree.kind_of(first.key));
    try testing.expectEqualStrings("a", tree.text_of(first.key).?);
    try testing.expect(tree.text_is(first.key, "a"));
    try testing.expectEqual(@as(?i64, 1), tree.integer_of(first.value));
}

test "append and insert place an item at each position and keep each handle" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try tree.replace(tree.root(), .array);

    const root = tree.root();
    const middle = try tree.insert(root, 0, .{ .integer = 2 });
    const front = try tree.insert(root, 0, .{ .integer = 0 });
    const back = try tree.append(root, .{ .integer = 4 });
    const second = try tree.insert(root, 1, .{ .integer = 1 });
    const fourth = try tree.insert(root, 3, .{ .integer = 3 });
    const end = try tree.insert(root, 5, .{ .integer = 5 });
    const handles = [_]Tree.Node{ front, second, middle, fourth, back, end };

    try test_expect(tree, "[0,1,2,3,4,5]");

    for (handles, 0..) |handle, index| {
        try testing.expectEqual(@as(?i64, @intCast(index)), tree.integer_of(handle));
        try testing.expectEqual(@as(?Tree.Node, handle), tree.item(root, @intCast(index)));
    }

    const empty = try tree.insert(root, 6, .array);
    const only = try tree.insert(empty, 0, .{ .string = "only" });

    try testing.expectEqual(@as(?Tree.Node, only), tree.item(empty, 0));
    try test_expect(tree, "[0,1,2,3,4,5,[\"only\"]]");
}

test "remove unlinks the first, middle, last, and only member or item" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_copy(pair, "{\"a\": [0, 1, 2, 3], \"b\": {\"x\": 1}, \"c\": true, \"d\": null}");

    const root = tree.root();
    const array = tree.member(root, "a") orelse return error.MemberMissing;

    tree.remove(tree.item(array, 0) orelse return error.ItemMissing);
    try test_expect(tree, "{\"a\":[1,2,3],\"b\":{\"x\":1},\"c\":true,\"d\":null}");

    tree.remove(tree.item(array, 2) orelse return error.ItemMissing);
    try test_expect(tree, "{\"a\":[1,2],\"b\":{\"x\":1},\"c\":true,\"d\":null}");

    tree.remove(tree.item(array, 1) orelse return error.ItemMissing);
    tree.remove(tree.item(array, 0) orelse return error.ItemMissing);
    try test_expect(tree, "{\"a\":[],\"b\":{\"x\":1},\"c\":true,\"d\":null}");

    const object = tree.member(root, "b") orelse return error.MemberMissing;

    tree.remove(tree.member(object, "x") orelse return error.MemberMissing);
    tree.remove(tree.member(root, "c") orelse return error.MemberMissing);
    try test_expect(tree, "{\"a\":[],\"b\":{},\"d\":null}");

    tree.remove(tree.member(root, "d") orelse return error.MemberMissing);
    tree.remove(array);
    try test_expect(tree, "{\"b\":{}}");

    tree.remove(object);
    try test_expect(tree, "{}");

    const added = try tree.set(root, "e", .{ .integer = 1 });

    try testing.expectEqual(@as(?Tree.Node, added), tree.member(root, "e"));
    try test_expect(tree, "{\"e\":1}");
}

test "replace keeps the handle and detaches the old children" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_copy(pair, "{\"list\": [1, [2, {\"k\": \"v\"}]], \"flag\": false}");

    const root = tree.root();
    const list = tree.member(root, "list") orelse return error.MemberMissing;

    try tree.replace(list, .{ .string = "flat" });
    try test_expect(tree, "{\"list\":\"flat\",\"flag\":false}");
    try testing.expectEqualStrings("flat", tree.text_of(list).?);

    try tree.replace(list, .object);

    const key = try tree.set(list, "k", .{ .float = 0.25 });

    try test_expect(tree, "{\"list\":{\"k\":0.25},\"flag\":false}");
    try testing.expectEqual(@as(?f64, 0.25), tree.float_of(key));

    try tree.replace(root, .null_value);
    try test_expect(tree, "null");

    try test_copy(pair, "[\"again\"]");
    try test_expect(tree, "[\"again\"]");
}

test "a copy keeps duplicate keys, decoded text, and number text" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    const source =
        \\{"k\u0065y": "a\nb", "key": [1, 2.5E3, -0, true, false, null, {}, []],
        \\ "key": "\ud83d\ude00\/"}
    ;

    try test_copy(pair, source);

    const expected = "{\"key\":\"a\\nb\",\"key\":[1,2.5E3,-0,true,false,null,{},[]]," ++
        "\"key\":\"\u{1f600}/\"}";

    try test_expect(tree, expected);

    const root = tree.root();
    const last = tree.member(root, "key") orelse return error.MemberMissing;

    try testing.expectEqualStrings("\u{1f600}/", tree.text_of(last).?);
    try testing.expectEqual(@as(u32, 3), tree.count_of(root));

    const document = &pair.document.document;
    const array = document.path_find(document.root(), &.{"key"}) orelse return error.Missing;
    const middle = document.item(document.root(), 0);

    try testing.expectEqual(@as(?DocumentNode, null), middle);
    try testing.expectEqual(Document.Kind.string, document.kind_of(array));

    var entries = document.entries(document.root());
    const skipped = entries.next() orelse return error.EntryMissing;
    const list = (entries.next() orelse return error.EntryMissing).value;
    const copied = try tree.set(root, "copy", .{ .copy = .{ .document = document, .node = list } });
    const number = tree.item(copied, 1) orelse return error.ItemMissing;

    try testing.expectEqualStrings("key", document.text_of(skipped.key).?);
    try testing.expectEqual(@as(u32, 8), tree.count_of(copied));
    try testing.expectEqual(@as(?f64, 2500), tree.float_of(number));
    try testing.expectEqual(@as(?i64, null), tree.integer_of(number));
}

test "a value error leaves the tree unchanged" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_copy(pair, "{\"a\": [1]}");

    const root = tree.root();
    const array = tree.member(root, "a") orelse return error.MemberMissing;

    const refusals = [_]TestRefusal{
        .{
            .edit = .{ .set = .{ .content = .null_value, .key = "\xff" } },
            .expected = error.Utf8Invalid,
            .target = root,
        },
        .{
            .edit = .{ .set = .{ .content = .{ .string = "\xc3" }, .key = "b" } },
            .expected = error.Utf8Invalid,
            .target = root,
        },
        .{
            .edit = .{ .set = .{ .content = .{ .string = "\xed\xa0\x80" }, .key = "a" } },
            .expected = error.Utf8Invalid,
            .target = root,
        },
        .{
            .edit = .{ .append = .{ .string = "\x80" } },
            .expected = error.Utf8Invalid,
            .target = array,
        },
        .{
            .edit = .{ .insert = .{ .string = "\xf8" } },
            .expected = error.Utf8Invalid,
            .target = array,
        },
        .{
            .edit = .{ .replace = .{ .string = "\xc0\xaf" } },
            .expected = error.Utf8Invalid,
            .target = array,
        },
    };

    const numbers = [_][]const u8{ "", "-", "01", "+1", "1.", ".5", "1e", "0x1", "nan1", "1 " };
    const counts = [2]u32{ tree.node_count, tree.text_count };

    try test_refusals(tree, &refusals);

    for (numbers) |text| {
        const number: Tree.Content = .{ .number = text };

        const number_refusals = [_]TestRefusal{
            .{ .edit = .{ .append = number }, .expected = error.NumberInvalid, .target = array },
            .{ .edit = .{ .replace = number }, .expected = error.NumberInvalid, .target = array },
            .{
                .edit = .{ .set = .{ .content = number, .key = "a" } },
                .expected = error.NumberInvalid,
                .target = root,
            },
        };

        try test_refusals(tree, &number_refusals);
    }

    try test_unchanged(tree, "{\"a\":[1]}", counts);
}

test "each capacity error leaves the tree unchanged" {
    const Small = TreeType(.{ .node_count_max = 7, .text_bytes_max = 12 });
    const small = try testing.allocator.create(Small);
    defer testing.allocator.destroy(small);

    const source = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(source);

    small.init();
    try source.parse("[[1, 2], 3, 4]");

    const tree = &small.tree;

    try tree.replace(tree.root(), .object);

    const array = try tree.set(tree.root(), "abc", .array);
    const filled = try tree.append(array, .{ .string = "defg" });

    try testing.expectEqual(@as(usize, 3), tree.records.len - tree.node_count);
    try testing.expectEqual(@as(usize, 1), tree.text.len - tree.text_count);
    try testing.expectEqualStrings("defg", tree.text_of(filled).?);

    const document = &source.document;
    const inner = source.item(source.root(), 0) orelse return error.ItemMissing;
    const whole: Tree.Content = .{ .copy = .{ .document = document, .node = source.root() } };
    const part: Tree.Content = .{ .copy = .{ .document = document, .node = inner } };

    const refusals = [_]TestRefusal{
        .{
            .edit = .{ .append = .{ .string = "hi" } },
            .expected = error.TextExhausted,
            .target = array,
        },
        .{
            .edit = .{ .replace = .{ .unsigned = 10 } },
            .expected = error.TextExhausted,
            .target = array,
        },
        .{ .edit = .{ .append = whole }, .expected = error.NodesExhausted, .target = array },
        .{ .edit = .{ .replace = whole }, .expected = error.NodesExhausted, .target = array },
        .{ .edit = .{ .append = part }, .expected = error.TextExhausted, .target = array },
        .{
            .edit = .{ .set = .{ .content = .null_value, .key = "xy" } },
            .expected = error.TextExhausted,
            .target = tree.root(),
        },
        .{
            .edit = .{ .set = .{ .content = part, .key = "" } },
            .expected = error.NodesExhausted,
            .target = tree.root(),
        },
    };

    const counts = [2]u32{ tree.node_count, tree.text_count };

    try test_refusals(tree, &refusals);
    try test_unchanged(tree, "{\"abc\":[\"defg\"]}", counts);

    const fitted = try tree.append(array, .{ .integer = 7 });

    try testing.expectEqual(@as(?i64, 7), tree.integer_of(fitted));
    try test_expect(tree, "{\"abc\":[\"defg\",7]}");
}

test "nesting past depth_max is refused for every way of adding a container" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;
    var deepest = tree.root();

    try tree.replace(deepest, .array);

    for (0..depth_max - 1) |_| deepest = try tree.append(deepest, .array);

    try pair.document.parse("[[1]]");

    const scalar = try tree.append(deepest, .{ .integer = 7 });
    const document = &pair.document.document;
    const copy: Tree.Content = .{ .copy = .{ .document = document, .node = document.root() } };

    const refusals = [_]TestRefusal{
        .{ .edit = .{ .append = .array }, .expected = error.DepthExceeded, .target = deepest },
        .{ .edit = .{ .insert = .object }, .expected = error.DepthExceeded, .target = deepest },
        .{ .edit = .{ .replace = .object }, .expected = error.DepthExceeded, .target = scalar },
        .{ .edit = .{ .append = copy }, .expected = error.DepthExceeded, .target = deepest },
        .{ .edit = .{ .replace = copy }, .expected = error.DepthExceeded, .target = deepest },
    };

    var expected: [2 * depth_max + 1]u8 = undefined;

    @memset(expected[0..depth_max], '[');
    expected[depth_max] = '7';

    @memset(expected[depth_max + 1 ..], ']');

    const counts = [2]u32{ tree.node_count, tree.text_count };

    try test_refusals(tree, &refusals);
    try test_unchanged(tree, &expected, counts);

    const parent: Tree.Node = @fromBackingInt(tree.records[@backingInt(deepest)].parent());

    try tree.replace(parent, copy);

    const one = tree.pointer_find(parent, "/0/0") orelse return error.ItemMissing;

    try testing.expectEqual(@as(?i64, 1), tree.integer_of(one));

    audit(tree);
}

test "a copy into a fresh tree needs exactly the document's nodes and quoted text" {
    const source = "{\"a\": [1, \"\\u00e9\"], \"b\": {\"c\": null}}";
    const Exact = TreeType(.{ .node_count_max = 9, .text_bytes_max = 14 });
    const NodesShort = TreeType(.{ .node_count_max = 8, .text_bytes_max = 14 });
    const TextShort = TreeType(.{ .node_count_max = 9, .text_bytes_max = 13 });
    const document = try testing.allocator.create(TestDocument);
    defer testing.allocator.destroy(document);

    const exact = try testing.allocator.create(Exact);
    defer testing.allocator.destroy(exact);

    const nodes_short = try testing.allocator.create(NodesShort);
    defer testing.allocator.destroy(nodes_short);

    const text_short = try testing.allocator.create(TextShort);
    defer testing.allocator.destroy(text_short);

    try document.parse(source);
    try testing.expectEqual(@as(u32, 9), document.document.node_count);

    exact.init();
    nodes_short.init();
    text_short.init();

    const copy: Tree.Content = .{
        .copy = .{ .document = &document.document, .node = document.root() },
    };

    const nodes_refused = nodes_short.replace(nodes_short.root(), copy);
    const text_refused = text_short.replace(text_short.root(), copy);

    try exact.replace(exact.root(), copy);
    try testing.expectError(error.NodesExhausted, nodes_refused);
    try testing.expectError(error.TextExhausted, text_refused);
    try testing.expectEqual(@as(u32, 14), exact.tree.text_count);
    try test_expect(&exact.tree, "{\"a\":[1,\"\u{e9}\"],\"b\":{\"c\":null}}");
    try test_expect(&nodes_short.tree, "null");
    try test_expect(&text_short.tree, "null");
}

test "numbers keep their text and a non-finite float writes as null" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;
    const root = tree.root();

    const contents = [_]Tree.Content{
        .{ .integer = std.math.minInt(i64) },
        .{ .integer = std.math.maxInt(i64) },
        .{ .unsigned = std.math.maxInt(u64) },
        .{ .float = 0.1 },
        .{ .float = 1e21 },
        .{ .float = -0.0 },
        .{ .float = std.math.nan(f64) },
        .{ .float = std.math.inf(f64) },
        .{ .float = -std.math.inf(f64) },
        .{ .number = "1.50" },
        .{ .number = "-Infinity" },
        .{ .number = "nan" },
    };

    const expected = "[-9223372036854775808,9223372036854775807,18446744073709551615," ++
        "0.1,1e+21,-0,null,null,null,1.50,null,null]";

    try tree.replace(root, .array);

    for (contents) |content| _ = try tree.append(root, content);

    try test_expect(tree, expected);

    const minimum = tree.item(root, 0) orelse return error.ItemMissing;
    const not_a_number = tree.item(root, 6) orelse return error.ItemMissing;
    const infinity = tree.item(root, 7) orelse return error.ItemMissing;
    const nan_read = tree.float_of(not_a_number) orelse return error.FloatMissing;

    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), tree.integer_of(minimum));
    try testing.expect(std.math.isNan(nan_read));
    try testing.expectEqual(@as(?f64, std.math.inf(f64)), tree.float_of(infinity));
    try testing.expectEqual(@as(?i64, null), tree.integer_of(infinity));

    const decimal = tree.item(root, 9) orelse return error.ItemMissing;
    const negative = tree.item(root, 10) orelse return error.ItemMissing;

    try testing.expectEqual(@as(?f64, 1.5), tree.float_of(decimal));
    try testing.expectEqual(@as(?i64, null), tree.integer_of(decimal));
    try testing.expectEqual(@as(?f64, -std.math.inf(f64)), tree.float_of(negative));
}

test "a copy of a relaxed document keeps its spellings and writes them canonically under literal" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try pair.document.parse_relaxed("[inf, /* c */ -NAN, 2,]");

    const copy: Tree.Content.Copy = .{
        .document = &pair.document.document,
        .node = pair.document.root(),
    };

    try tree.replace(tree.root(), .{ .copy = copy });
    try test_expect(tree, "[null,null,2]");

    var buffer: [64]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var options = test_options_compact;

    options.non_finite = .literal;

    try tree.write(&sink, options);
    try testing.expectEqualStrings("[Infinity,NaN,2]", sink.buffered());

    const first = tree.item(tree.root(), 0) orelse return error.ItemMissing;

    try testing.expectEqual(@as(?f64, std.math.inf(f64)), tree.float_of(first));
}

test "node_write copies a subtree into a writer mid-document and refuses one too deep" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_copy(pair, "{\"list\": [1, \"a\\u0062\", {}], \"nested\": {\"k\": [true]}}");

    var buffer: [512]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var writer: Writer = .init(&sink, test_options_compact);
    const root = tree.root();
    const list = tree.member(root, "list") orelse return error.Missing;
    const nested = tree.member(root, "nested") orelse return error.Missing;

    try writer.object_begin();
    try writer.key("copy");
    try tree.node_write(&writer, nested);
    try writer.key("list");
    try tree.node_write(&writer, list);
    try writer.object_end();

    writer.finish();

    const expected = "{\"copy\":{\"k\":[true]},\"list\":[1,\"ab\",{}]}";

    try testing.expectEqualStrings(expected, sink.buffered());

    sink = .fixed(&buffer);
    writer = .init(&sink, test_options_compact);

    for (0..depth_max - 2) |_| try writer.array_begin();

    const refused = tree.node_write(&writer, root);

    try testing.expectError(error.DepthExceeded, refused);
    try testing.expectEqual(@as(usize, depth_max - 2), sink.buffered().len);

    try tree.node_write(&writer, list);
    try testing.expectEqualStrings("[1,\"ab\",{}]", sink.buffered()[depth_max - 2 ..]);
}

test "entries and items yield exactly their count and stay empty afterwards" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    try test_copy(pair, "{\"a\": [1, [2, [3]], {\"b\": {}}], \"c\": {\"d\": [4]}, \"e\": 5}");

    const root = tree.root();
    const array = tree.member(root, "a") orelse return error.MemberMissing;
    var entries = tree.entries(root);
    var items = tree.items(array);
    var values: [3]Tree.Node = undefined;
    var children: [3]Tree.Node = undefined;

    for (&values) |*value| value.* = (entries.next() orelse return error.EntryMissing).value;
    for (&children) |*child| child.* = items.next() orelse return error.ItemMissing;

    for (0..2) |_| {
        const entry_after = entries.next();
        const item_after = items.next();

        try testing.expectEqual(@as(?Tree.Entries.Entry, null), entry_after);
        try testing.expectEqual(@as(?Tree.Node, null), item_after);
    }

    try testing.expectEqual(@as(?i64, 5), tree.integer_of(values[2]));
    try testing.expectEqual(Tree.Kind.object, tree.kind_of(values[1]));
    try testing.expectEqual(Tree.Kind.object, tree.kind_of(children[2]));
    try testing.expectEqual(@as(u32, 2), tree.count_of(children[1]));
    try testing.expectEqual(@as(?Tree.Node, children[1]), tree.path_find(root, &.{ "a", "1" }));
    try testing.expectEqual(@as(?Tree.Node, children[2]), tree.pointer_find(root, "/a/2"));
}

test "a string writes the same bytes whether it is copied verbatim or escaped" {
    const pair = try test_pair_create();
    defer testing.allocator.destroy(pair);

    const tree = &pair.tree.tree;

    const source =
        \\{"plain": "abc", "k\u0065y": "caf\u00e9\/", "esc": "a\nb\"c\\", "emoji": "\ud83d\ude00"}
    ;

    try test_copy(pair, source);

    const trusted = "{\"plain\":\"abc\",\"key\":\"caf\u{e9}/\",\"esc\":\"a\\nb\\\"c\\\\\"," ++
        "\"emoji\":\"\u{1f600}\"}";

    try test_expect(tree, trusted);

    var buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);
    var options = test_options_compact;

    options.utf8 = .bmp;

    try tree.write(&sink, options);

    const bmp = "{\"plain\":\"abc\",\"key\":\"caf\u{e9}/\",\"esc\":\"a\\nb\\\"c\\\\\"," ++
        "\"emoji\":\"\\ud83d\\ude00\"}";

    try testing.expectEqualStrings(bmp, sink.buffered());

    const root = tree.root();
    const plain = tree.member(root, "plain") orelse return error.MemberMissing;
    const escaped = tree.member(root, "esc") orelse return error.MemberMissing;
    const emoji = tree.member(root, "emoji") orelse return error.MemberMissing;
    const user = try tree.set(root, "user", .{ .string = "tab\there" });

    try tree.replace(plain, .{ .string = "x\"y" });
    try tree.replace(escaped, .{ .string = "clean" });
    try tree.replace(emoji, .{ .integer = 5 });

    const edited = "{\"plain\":\"x\\\"y\",\"key\":\"caf\u{e9}/\",\"esc\":\"clean\"," ++
        "\"emoji\":5,\"user\":\"tab\\there\"}";

    try testing.expectEqualStrings("tab\there", tree.text_of(user).?);
    try test_expect(tree, edited);
}
