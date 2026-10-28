const std = @import("std");

const document_module = @import("document.zig");
const number_module = @import("number.zig");
const pointer_module = @import("pointer.zig");
const tokenizer_module = @import("tokenizer.zig");
const tree_module = @import("tree.zig");

const assert = std.debug.assert;

const Destination = tree_module.Destination;
const Document = document_module.Document;
const DocumentNode = document_module.Node;
const Error = Tree.CapacityError || Tree.ConflictError || Tree.PatchError;
const Tree = tree_module.Tree;

const depth_max = tokenizer_module.depth_max;
const input_bytes_max = tokenizer_module.input_bytes_max;

const ArrayCursor = struct {
    left: Tree.Items,
    right: document_module.Items,
};

const Change = struct {
    path: []const u8,
    value: DocumentNode,
};

const EqualFrame = union(enum) {
    array: ArrayCursor,
    object: ObjectCursor,
};

const EqualStep = union(enum) {
    done,
    mismatch,
    pair: Pair,
};

const MergeFrame = struct {
    entries: document_module.Entries,
    target: Tree.Node,
};

const ObjectCursor = struct {
    left: Tree.Entries,
    left_object: Tree.Node,
    lockstep: bool,
    right: document_module.Entries,
    right_object: DocumentNode,
};

const Operation = union(Verb) {
    add: Change,
    copy: Transfer,
    move: Transfer,
    remove: []const u8,
    replace: Change,
    @"test": Change,
};

const Pair = struct {
    node: Tree.Node,
    value: DocumentNode,
};

const Transfer = struct {
    from: []const u8,
    path: []const u8,
};

const Verb = enum {
    add,
    copy,
    move,
    remove,
    replace,
    @"test",
};

pub fn patch(
    tree: *Tree,
    document: *const Document,
    operations: DocumentNode,
    options: Tree.PatchOptions,
) Error!void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(tree.node_count > 0);
    assert(@backingInt(operations) < document.node_count);

    if (document.kind_of(operations) != .array) {
        failure_report(document, operations, options);

        return error.PatchMalformed;
    }

    var items = document.items(operations);

    for (0..document.count_of(operations) + 1) |_| {
        const operation = items.next() orelse return;

        operation_run(tree, document, operation) catch |err| {
            failure_report(document, operation, options);

            return err;
        };
    }

    unreachable;
}

pub fn merge_patch(
    tree: *Tree,
    target: Tree.Node,
    document: *const Document,
    changes: DocumentNode,
) Tree.CapacityError!void {
    assert(@backingInt(target) < tree.node_count);
    assert(@backingInt(changes) < document.node_count);

    const copy: Tree.Content = .{ .copy = .{ .document = document, .node = changes } };
    if (document.kind_of(changes) != .object) return content_replace(tree, target, copy);

    if (tree.kind_of(target) != .object) try content_replace(tree, target, .object);

    var frames: [depth_max]MergeFrame = undefined;
    var depth: u32 = 1;

    frames[0] = .{ .entries = document.entries(changes), .target = target };

    for (0..2 * document.node_count + 1) |_| {
        if (depth == 0) return;

        const frame = &frames[depth - 1];

        const entry = frame.entries.next() orelse {
            depth -= 1;

            continue;
        };

        const key = document.text_of(entry.key).?;
        const value: Tree.Content = .{ .copy = .{ .document = document, .node = entry.value } };

        switch (document.kind_of(entry.value)) {
            .array, .boolean, .number, .string => {
                _ = try member_set(tree, frame.target, key, value);
            },
            .null_value => members_remove(tree, frame.target, key),
            .object => {
                assert(depth < depth_max);

                frames[depth] = .{
                    .entries = document.entries(entry.value),
                    .target = try object_ensure(tree, frame.target, key),
                };

                depth += 1;
            },
        }
    }

    unreachable;
}

fn failure_report(document: *const Document, node: DocumentNode, options: Tree.PatchOptions) void {
    comptime assert(@sizeOf(@TypeOf(options)) <= 16);
    assert(@backingInt(node) < document.node_count);

    if (options.diagnostic) |diagnostic| diagnostic.* = document.position_of(node);
}

fn operation_run(tree: *Tree, document: *const Document, node: DocumentNode) Error!void {
    assert(@backingInt(node) < document.node_count);
    assert(tree.node_count > 0);

    const operation = try operation_parse(document, node);

    switch (operation) {
        .add => |change| try add_apply(tree, document, change),
        .copy => |transfer| try copy_apply(tree, transfer),
        .move => |transfer| try move_apply(tree, transfer),
        .remove => |path| try remove_apply(tree, path),
        .replace => |change| try replace_apply(tree, document, change),
        .@"test" => |change| try test_apply(tree, document, change),
    }
}

fn operation_parse(document: *const Document, node: DocumentNode) Tree.PatchError!Operation {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count > 0);

    if (document.kind_of(node) != .object) return error.PatchMalformed;

    const name = string_member(document, node, "op") orelse return error.PatchMalformed;
    const verb = std.meta.stringToEnum(Verb, name) orelse return error.PatchMalformed;
    const path = string_member(document, node, "path") orelse return error.PatchMalformed;

    try pointer_check(path);

    return switch (verb) {
        .add => .{ .add = try change_of(document, node, path) },
        .copy => .{ .copy = try transfer_of(document, node, path) },
        .move => .{ .move = try transfer_of(document, node, path) },
        .remove => .{ .remove = path },
        .replace => .{ .replace = try change_of(document, node, path) },
        .@"test" => .{ .@"test" = try change_of(document, node, path) },
    };
}

fn change_of(
    document: *const Document,
    node: DocumentNode,
    path: []const u8,
) Tree.PatchError!Change {
    assert(document.kind_of(node) == .object);
    assert(path.len <= input_bytes_max);

    const value = document.member(node, "value") orelse return error.PatchMalformed;
    return .{ .path = path, .value = value };
}

fn transfer_of(
    document: *const Document,
    node: DocumentNode,
    path: []const u8,
) Tree.PatchError!Transfer {
    assert(document.kind_of(node) == .object);
    assert(path.len <= input_bytes_max);

    const from = string_member(document, node, "from") orelse return error.PatchMalformed;

    try pointer_check(from);

    return .{ .from = from, .path = path };
}

fn string_member(document: *const Document, object: DocumentNode, key: []const u8) ?[]const u8 {
    assert(document.kind_of(object) == .object);
    assert(key.len > 0);

    const value = document.member(object, key) orelse return null;
    return document.text_of(value);
}

fn pointer_check(pointer: []const u8) Tree.PatchError!void {
    assert(pointer.len <= input_bytes_max);

    if (pointer.len == 0) return;
    if (!pointer_module.pointer_valid(pointer)) return error.PatchMalformed;

    assert(pointer[0] == '/');
}

fn add_apply(tree: *Tree, document: *const Document, change: Change) Error!void {
    assert(@backingInt(change.value) < document.node_count);
    assert(change.path.len <= input_bytes_max);

    const destination = try destination_resolve(tree, change.path);
    const content: Tree.Content = .{ .copy = .{ .document = document, .node = change.value } };

    switch (destination) {
        .item => |item| {
            _ = tree.insert(item.array, item.index, content) catch |err| switch (err) {
                error.DepthExceeded => return error.DepthExceeded,
                error.NodesExhausted => return error.NodesExhausted,
                error.NumberInvalid, error.Utf8Invalid => unreachable,
                error.TextExhausted => return error.TextExhausted,
            };
        },
        .member => |member| {
            _ = try tree_module.member_token_add(tree, member.object, member.token, &content);
        },
        .value => |value| try content_replace(tree, value, content),
    }
}

fn copy_apply(tree: *Tree, transfer: Transfer) Error!void {
    assert(transfer.from.len <= input_bytes_max);
    assert(transfer.path.len <= input_bytes_max);

    const node = try node_resolve(tree, transfer.from);
    const destination = try destination_resolve(tree, transfer.path);
    const orphan = try tree_module.subtree_copy(tree, node);
    errdefer tree_module.subtree_discard(tree, orphan);

    try tree_module.subtree_link(tree, orphan, destination);
}

fn move_apply(tree: *Tree, transfer: Transfer) Error!void {
    assert(transfer.from.len <= input_bytes_max);
    assert(transfer.path.len <= input_bytes_max);

    if (move_into_child(transfer)) return error.PatchMalformed;

    const node = try node_resolve(tree, transfer.from);

    if (std.mem.eql(u8, transfer.from, transfer.path)) return;

    const cut = tree_module.subtree_unlink(tree, node);
    errdefer tree_module.subtree_restore(tree, &cut);

    const destination = try destination_resolve(tree, transfer.path);

    try tree_module.subtree_link(tree, cut.orphan, destination);
}

fn remove_apply(tree: *Tree, path: []const u8) Error!void {
    assert(path.len <= input_bytes_max);
    assert(tree.node_count > 0);

    if (path.len == 0) return error.PatchMalformed;

    const node = try node_resolve(tree, path);

    tree.remove(node);
}

fn replace_apply(tree: *Tree, document: *const Document, change: Change) Error!void {
    assert(@backingInt(change.value) < document.node_count);
    assert(change.path.len <= input_bytes_max);

    const node = try node_resolve(tree, change.path);
    const content: Tree.Content = .{ .copy = .{ .document = document, .node = change.value } };

    try content_replace(tree, node, content);
}

fn test_apply(tree: *const Tree, document: *const Document, change: Change) Error!void {
    assert(@backingInt(change.value) < document.node_count);
    assert(change.path.len <= input_bytes_max);

    const node = try node_resolve(tree, change.path);
    if (!equal(tree, node, document, change.value)) return error.TestFailed;
}

fn move_into_child(transfer: Transfer) bool {
    assert(transfer.from.len <= input_bytes_max);
    assert(transfer.path.len <= input_bytes_max);

    if (transfer.from.len >= transfer.path.len) return false;
    if (!std.mem.startsWith(u8, transfer.path, transfer.from)) return false;
    return transfer.path[transfer.from.len] == '/';
}

fn node_resolve(tree: *const Tree, pointer: []const u8) Tree.ConflictError!Tree.Node {
    assert(tree.node_count > 0);
    assert(pointer.len <= input_bytes_max);

    return switch (pointer_module.parent_resolve(Tree, tree, pointer)) {
        .found => |found| pointer_module.token_step(Tree, tree, found.parent, found.token) orelse
            error.PathMissing,
        .malformed => unreachable,
        .missing => error.PathMissing,
        .root => tree.root(),
    };
}

fn destination_resolve(tree: *const Tree, pointer: []const u8) Tree.ConflictError!Destination {
    assert(tree.node_count > 0);
    assert(pointer.len <= input_bytes_max);

    return switch (pointer_module.parent_resolve(Tree, tree, pointer)) {
        .found => |found| destination_of(tree, found.parent, found.token),
        .malformed => unreachable,
        .missing => error.PathMissing,
        .root => .{ .value = tree.root() },
    };
}

fn destination_of(
    tree: *const Tree,
    parent: Tree.Node,
    token: []const u8,
) Tree.ConflictError!Destination {
    assert(@backingInt(parent) < tree.node_count);
    assert(std.mem.findScalar(u8, token, '/') == null);

    switch (tree.kind_of(parent)) {
        .array => {
            const count = tree.count_of(parent);
            const end = std.mem.eql(u8, token, "-");

            const index = if (end) count else pointer_module.index_of(token) orelse
                return error.PathMissing;

            if (index > count) return error.PathMissing;
            return .{ .item = .{ .array = parent, .index = index } };
        },
        .object => {
            const found = pointer_module.token_step(Tree, tree, parent, token);
            if (found) |value| return .{ .value = value };
            return .{ .member = .{ .object = parent, .token = token } };
        },
        .boolean, .null_value, .number, .string => return error.PathMissing,
    }
}

fn content_replace(tree: *Tree, node: Tree.Node, content: Tree.Content) Tree.CapacityError!void {
    assert(@backingInt(node) < tree.node_count);
    assert(content == .copy or content == .object);

    tree.replace(node, content) catch |err| return tree_module.capacity_error_of(err);
}

fn member_set(
    tree: *Tree,
    object: Tree.Node,
    key: []const u8,
    content: Tree.Content,
) Tree.CapacityError!Tree.Node {
    assert(tree.kind_of(object) == .object);
    assert(key.len <= input_bytes_max);
    assert(content == .copy or content == .object);

    return tree.set(object, key, content) catch |err| return tree_module.capacity_error_of(err);
}

fn members_remove(tree: *Tree, object: Tree.Node, key: []const u8) void {
    assert(tree.kind_of(object) == .object);
    assert(key.len <= input_bytes_max);

    for (0..tree.count_of(object) + 1) |_| {
        const value = tree.member(object, key) orelse return;

        tree.remove(value);
    }

    unreachable;
}

fn object_ensure(tree: *Tree, object: Tree.Node, key: []const u8) Tree.CapacityError!Tree.Node {
    assert(tree.kind_of(object) == .object);
    assert(key.len <= input_bytes_max);

    if (tree.member(object, key)) |existing| {
        if (tree.kind_of(existing) == .object) return existing;
    }

    return member_set(tree, object, key, .object);
}

fn equal(
    tree: *const Tree,
    node: Tree.Node,
    document: *const Document,
    value: DocumentNode,
) bool {
    assert(@backingInt(node) < tree.node_count);
    assert(@backingInt(value) < document.node_count);

    var frames: [depth_max]EqualFrame = undefined;
    var depth: u32 = 0;
    var pair: Pair = .{ .node = node, .value = value };

    for (0..tree.node_count + 1) |_| {
        if (!shallow_equal(tree, document, pair)) return false;

        if (tree.count_of(pair.node) > 0) {
            assert(depth < depth_max);

            frames[depth] = frame_of(tree, document, pair);
            depth += 1;
        }

        switch (step_next(tree, document, &frames, &depth)) {
            .done => return true,
            .mismatch => return false,
            .pair => |next| pair = next,
        }
    }

    unreachable;
}

fn frame_of(tree: *const Tree, document: *const Document, pair: Pair) EqualFrame {
    assert(tree.count_of(pair.node) > 0);
    assert(tree.count_of(pair.node) == document.count_of(pair.value));

    return switch (tree.kind_of(pair.node)) {
        .array => .{
            .array = .{ .left = tree.items(pair.node), .right = document.items(pair.value) },
        },
        .boolean, .null_value, .number, .string => unreachable,
        .object => .{
            .object = .{
                .left = tree.entries(pair.node),
                .left_object = pair.node,
                .lockstep = true,
                .right = document.entries(pair.value),
                .right_object = pair.value,
            },
        },
    };
}

fn step_next(
    tree: *const Tree,
    document: *const Document,
    frames: *[depth_max]EqualFrame,
    depth: *u32,
) EqualStep {
    assert(depth.* <= depth_max);
    assert(tree.node_count > 0);

    for (0..depth_max + 1) |_| {
        if (depth.* == 0) return .done;

        const step = switch (frames[depth.* - 1]) {
            .array => |*cursor| item_next(cursor),
            .object => |*cursor| entry_next(tree, document, cursor),
        };

        switch (step) {
            .done => depth.* -= 1,
            .mismatch, .pair => return step,
        }
    }

    unreachable;
}

fn item_next(cursor: *ArrayCursor) EqualStep {
    assert(cursor.left.remaining == cursor.right.remaining);

    const node = cursor.left.next() orelse return .done;
    const value = cursor.right.next() orelse unreachable;

    assert(cursor.left.remaining == cursor.right.remaining);

    return .{ .pair = .{ .node = node, .value = value } };
}

fn entry_next(tree: *const Tree, document: *const Document, cursor: *ObjectCursor) EqualStep {
    assert(tree.kind_of(cursor.left_object) == .object);
    assert(document.kind_of(cursor.right_object) == .object);

    const entry = cursor.left.next() orelse return .done;
    const key = tree.text_of(entry.key).?;

    if (cursor.lockstep) {
        const right = cursor.right.next() orelse unreachable;

        if (document.text_is(right.key, key)) {
            return .{ .pair = .{ .node = entry.value, .value = right.value } };
        }

        cursor.lockstep = false;
    }

    const occurrence = occurrence_index(tree, cursor.left_object, entry);

    const value = occurrence_find(document, cursor.right_object, key, occurrence) orelse
        return .mismatch;

    return .{ .pair = .{ .node = entry.value, .value = value } };
}

fn occurrence_index(tree: *const Tree, object: Tree.Node, entry: Tree.Entries.Entry) u32 {
    assert(tree.kind_of(object) == .object);
    assert(tree.kind_of(entry.key) == .string);

    const text = tree.text_of(entry.key).?;
    var entries = tree.entries(object);
    var result: u32 = 0;

    for (0..tree.count_of(object)) |_| {
        const found = entries.next() orelse unreachable;
        if (found.key == entry.key) return result;

        if (tree.text_is(found.key, text)) result += 1;
    }

    unreachable;
}

fn occurrence_find(
    document: *const Document,
    object: DocumentNode,
    key: []const u8,
    occurrence: u32,
) ?DocumentNode {
    assert(document.kind_of(object) == .object);
    assert(key.len <= input_bytes_max);
    assert(occurrence < document.count_of(object));

    var entries = document.entries(object);
    var remaining = occurrence;

    for (0..document.count_of(object)) |_| {
        const entry = entries.next() orelse unreachable;

        if (document.text_is(entry.key, key)) {
            if (remaining == 0) return entry.value;

            remaining -= 1;
        }
    }

    return null;
}

fn shallow_equal(tree: *const Tree, document: *const Document, pair: Pair) bool {
    assert(@backingInt(pair.node) < tree.node_count);
    assert(@backingInt(pair.value) < document.node_count);

    const kind = tree.kind_of(pair.node);
    if (kind != document.kind_of(pair.value)) return false;

    return switch (kind) {
        .array, .object => tree.count_of(pair.node) == document.count_of(pair.value),
        .boolean => tree.boolean_of(pair.node) == document.boolean_of(pair.value),
        .null_value => true,
        .number => number_equal(tree, document, pair),
        .string => std.mem.eql(u8, tree.text_of(pair.node).?, document.text_of(pair.value).?),
    };
}

fn number_equal(tree: *const Tree, document: *const Document, pair: Pair) bool {
    assert(tree.kind_of(pair.node) == .number);
    assert(document.kind_of(pair.value) == .number);

    const left = tree_module.number_text(tree, pair.node);
    const right = document.source_of(pair.value);
    if (std.mem.eql(u8, left, right)) return true;

    if (number_module.integer_of_text(left)) |left_integer| {
        if (number_module.integer_of_text(right)) |right_integer| {
            return left_integer == right_integer;
        }
    }

    if (number_module.unsigned_of_text(left)) |left_unsigned| {
        if (number_module.unsigned_of_text(right)) |right_unsigned| {
            return left_unsigned == right_unsigned;
        }
    }

    const left_float = number_module.float_of_text(left) orelse return false;
    const right_float = number_module.float_of_text(right) orelse return false;

    return left_float == right_float;
}

const testing = std.testing;

const TestDocument = document_module.DocumentType(.{
    .node_count_max = 512,
    .text_bytes_max = 2048,
});

const TestTree = tree_module.TreeType(.{ .node_count_max = 512, .text_bytes_max = 4096 });

const TestBench = struct {
    operations: TestDocument,
    source: TestDocument,
    tree: TestTree,
};

const TestMerge = struct {
    changes: []const u8,
    source: []const u8,
    written: []const u8,
};

const TestNesting = struct {
    close: []const u8,
    open: []const u8,
};

const TestVector = struct {
    failure: ?Error = null,
    operations: []const u8,
    source: []const u8,
    written: []const u8,
};

fn test_bench_create() !*TestBench {
    const result = try testing.allocator.create(TestBench);

    result.tree.init();

    assert(result.tree.tree.node_count == 1);
    assert(result.tree.storage.records.len == 512);

    return result;
}

fn test_source_copy(bench: *TestBench, source: []const u8) !void {
    assert(source.len > 0);
    assert(source.len <= 2048);

    try bench.source.parse(source);

    bench.tree.init();

    try bench.tree.replace(bench.tree.root(), .{
        .copy = .{ .document = &bench.source.document, .node = bench.source.root() },
    });
}

fn test_written_expect(tree: *const Tree, expected: []const u8) !void {
    assert(tree.node_count > 0);
    assert(expected.len > 0);

    tree_module.audit(tree);

    var buffer: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    try testing.expectEqualStrings(expected, sink.buffered());
}

fn test_vectors_run(vectors: []const TestVector) !void {
    assert(vectors.len > 0);
    assert(vectors.len < 1024);

    const bench = try test_bench_create();
    defer testing.allocator.destroy(bench);

    for (vectors) |*vector| {
        try test_source_copy(bench, vector.source);
        try bench.operations.parse(vector.operations);

        const operations = &bench.operations.document;
        const result = bench.tree.patch(operations, operations.root(), .{ .diagnostic = null });

        if (vector.failure) |failure| {
            try testing.expectError(failure, result);
        } else {
            try result;
        }

        try test_written_expect(&bench.tree.tree, vector.written);
    }
}

fn test_merges_run(merges: []const TestMerge) !void {
    assert(merges.len > 0);
    assert(merges.len < 1024);

    const bench = try test_bench_create();
    defer testing.allocator.destroy(bench);

    for (merges) |*merge| {
        try test_source_copy(bench, merge.source);
        try bench.operations.parse(merge.changes);

        const changes = &bench.operations.document;
        const root = bench.tree.root();

        try bench.tree.merge_patch(root, changes, changes.root());
        try test_written_expect(&bench.tree.tree, merge.written);

        try bench.tree.merge_patch(root, changes, changes.root());
        try test_written_expect(&bench.tree.tree, merge.written);
    }
}

const test_rfc_6902_vectors = [_]TestVector{
    .{
        .source = "{\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"add\",\"path\":\"/baz\",\"value\":\"qux\"}]",
        .written = "{\"foo\":\"bar\",\"baz\":\"qux\"}",
    },
    .{
        .source = "{\"foo\":[\"bar\",\"baz\"]}",
        .operations = "[{\"op\":\"add\",\"path\":\"/foo/1\",\"value\":\"qux\"}]",
        .written = "{\"foo\":[\"bar\",\"qux\",\"baz\"]}",
    },
    .{
        .source = "{\"baz\":\"qux\",\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"remove\",\"path\":\"/baz\"}]",
        .written = "{\"foo\":\"bar\"}",
    },
    .{
        .source = "{\"foo\":[\"bar\",\"qux\",\"baz\"]}",
        .operations = "[{\"op\":\"remove\",\"path\":\"/foo/1\"}]",
        .written = "{\"foo\":[\"bar\",\"baz\"]}",
    },
    .{
        .source = "{\"baz\":\"qux\",\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"replace\",\"path\":\"/baz\",\"value\":\"boo\"}]",
        .written = "{\"baz\":\"boo\",\"foo\":\"bar\"}",
    },
    .{
        .source = "{\"foo\":{\"bar\":\"baz\",\"waldo\":\"fred\"}," ++
            "\"qux\":{\"corge\":\"grault\"}}",
        .operations = "[{\"op\":\"move\",\"from\":\"/foo/waldo\",\"path\":\"/qux/thud\"}]",
        .written = "{\"foo\":{\"bar\":\"baz\"}," ++
            "\"qux\":{\"corge\":\"grault\",\"thud\":\"fred\"}}",
    },
    .{
        .source = "{\"foo\":[\"all\",\"grass\",\"cows\",\"eat\"]}",
        .operations = "[{\"op\":\"move\",\"from\":\"/foo/1\",\"path\":\"/foo/3\"}]",
        .written = "{\"foo\":[\"all\",\"cows\",\"eat\",\"grass\"]}",
    },
    .{
        .source = "{\"baz\":\"qux\",\"foo\":[\"a\",2,\"c\"]}",
        .operations = "[{\"op\":\"test\",\"path\":\"/baz\",\"value\":\"qux\"}," ++
            "{\"op\":\"test\",\"path\":\"/foo/1\",\"value\":2}]",
        .written = "{\"baz\":\"qux\",\"foo\":[\"a\",2,\"c\"]}",
    },
    .{
        .failure = error.TestFailed,
        .source = "{\"baz\":\"qux\"}",
        .operations = "[{\"op\":\"test\",\"path\":\"/baz\",\"value\":\"bar\"}]",
        .written = "{\"baz\":\"qux\"}",
    },
    .{
        .source = "{\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"add\",\"path\":\"/child\",\"value\":{\"grandchild\":{}}}]",
        .written = "{\"foo\":\"bar\",\"child\":{\"grandchild\":{}}}",
    },
    .{
        .source = "{\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"add\",\"path\":\"/baz\",\"value\":\"qux\",\"xyz\":123}]",
        .written = "{\"foo\":\"bar\",\"baz\":\"qux\"}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"add\",\"path\":\"/baz/bat\",\"value\":\"qux\"}]",
        .written = "{\"foo\":\"bar\"}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"foo\":\"bar\"}",
        .operations = "[{\"op\":\"add\",\"path\":\"/baz\",\"value\":\"qux\"," ++
            "\"op\":\"remove\"}]",
        .written = "{\"foo\":\"bar\"}",
    },
    .{
        .source = "{\"/\":9,\"~1\":10}",
        .operations = "[{\"op\":\"test\",\"path\":\"/~01\",\"value\":10}]",
        .written = "{\"/\":9,\"~1\":10}",
    },
    .{
        .failure = error.TestFailed,
        .source = "{\"/\":9,\"~1\":10}",
        .operations = "[{\"op\":\"test\",\"path\":\"/~01\",\"value\":\"10\"}]",
        .written = "{\"/\":9,\"~1\":10}",
    },
    .{
        .source = "{\"foo\":[\"bar\"]}",
        .operations = "[{\"op\":\"add\",\"path\":\"/foo/-\",\"value\":[\"abc\",\"def\"]}]",
        .written = "{\"foo\":[\"bar\",[\"abc\",\"def\"]]}",
    },
};

test "the RFC 6902 appendix A examples apply as the RFC shows" {
    try test_vectors_run(&test_rfc_6902_vectors);
}

test "the RFC 7396 appendix A examples merge as the RFC shows, and again changes nothing" {
    const merges = [_]TestMerge{
        .{ .source = "{\"a\":\"b\"}", .changes = "{\"a\":\"c\"}", .written = "{\"a\":\"c\"}" },
        .{
            .source = "{\"a\":\"b\"}",
            .changes = "{\"b\":\"c\"}",
            .written = "{\"a\":\"b\",\"b\":\"c\"}",
        },
        .{ .source = "{\"a\":\"b\"}", .changes = "{\"a\":null}", .written = "{}" },
        .{
            .source = "{\"a\":\"b\",\"b\":\"c\"}",
            .changes = "{\"a\":null}",
            .written = "{\"b\":\"c\"}",
        },
        .{ .source = "{\"a\":[\"b\"]}", .changes = "{\"a\":\"c\"}", .written = "{\"a\":\"c\"}" },
        .{
            .source = "{\"a\":\"c\"}",
            .changes = "{\"a\":[\"b\"]}",
            .written = "{\"a\":[\"b\"]}",
        },
        .{
            .source = "{\"a\":{\"b\":\"c\"}}",
            .changes = "{\"a\":{\"b\":\"d\",\"c\":null}}",
            .written = "{\"a\":{\"b\":\"d\"}}",
        },
        .{
            .source = "{\"a\":[{\"b\":\"c\"}]}",
            .changes = "{\"a\":[1]}",
            .written = "{\"a\":[1]}",
        },
        .{ .source = "[\"a\",\"b\"]", .changes = "[\"c\",\"d\"]", .written = "[\"c\",\"d\"]" },
        .{ .source = "{\"a\":\"b\"}", .changes = "[\"c\"]", .written = "[\"c\"]" },
        .{ .source = "{\"a\":\"foo\"}", .changes = "null", .written = "null" },
        .{ .source = "{\"a\":\"foo\"}", .changes = "\"bar\"", .written = "\"bar\"" },
        .{
            .source = "{\"e\":null}",
            .changes = "{\"a\":1}",
            .written = "{\"e\":null,\"a\":1}",
        },
        .{
            .source = "[1,2]",
            .changes = "{\"a\":\"b\",\"c\":null}",
            .written = "{\"a\":\"b\"}",
        },
        .{
            .source = "{}",
            .changes = "{\"a\":{\"bb\":{\"ccc\":null}}}",
            .written = "{\"a\":{\"bb\":{}}}",
        },
    };

    try test_merges_run(&merges);
}

const test_pairs = "[[1,2],[3,4]]";

const test_yyjson_vectors = [_]TestVector{
    .{ .failure = error.PatchMalformed, .source = "[]", .operations = "{}", .written = "[]" },
    .{ .failure = error.PatchMalformed, .source = "[1]", .operations = "[123]", .written = "[1]" },
    .{
        .failure = error.PatchMalformed,
        .source = "[]",
        .operations = "[{\"op\":\"add\",\"path\":\"/-\",\"value\":0}," ++
            "{\"op\":\"err\",\"path\":\"/-\",\"value\":1}]",
        .written = "[0]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[]",
        .operations = "[{\"path\":\"/-\",\"value\":1}]",
        .written = "[]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[]",
        .operations = "[{\"op\":\"add\",\"value\":2}]",
        .written = "[]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[]",
        .operations = "[{\"op\":\"add\",\"path\":null,\"value\":2}]",
        .written = "[]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":0,\"path\":\"/0\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"\",\"path\":\"/0\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"set\",\"path\":\"/0\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"Add\",\"path\":\"/0\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[0]",
        .operations = "[{\"op\":\"add\",\"path\":\"/1\"}]",
        .written = "[0]",
    },
    .{
        .source = "[0]",
        .operations = "[{\"op\":\"add\",\"path\":\"/1\",\"value\":1}]",
        .written = "[0,1]",
    },
    .{
        .failure = error.PathMissing,
        .source = "[0]",
        .operations = "[{\"op\":\"add\",\"path\":\"/2\",\"value\":1}]",
        .written = "[0]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[0]",
        .operations = "[{\"op\":\"add\",\"path\":\"/~2\",\"value\":1}]",
        .written = "[0]",
    },
    .{
        .source = "[0]",
        .operations = "[{\"op\":\"add\",\"path\":\"\",\"value\":1}]",
        .written = "1",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"remove\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"remove\",\"path\":0}]",
        .written = "[1]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"remove\",\"path\":\"\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PathMissing,
        .source = "[1]",
        .operations = "[{\"op\":\"remove\",\"path\":\"/-\"}]",
        .written = "[1]",
    },
    .{
        .source = "[1]",
        .operations = "[{\"op\":\"remove\",\"path\":\"/0\"}]",
        .written = "[]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[0]",
        .operations = "[{\"op\":\"replace\",\"path\":\"/0\"}]",
        .written = "[0]",
    },
    .{
        .source = "[0]",
        .operations = "[{\"op\":\"replace\",\"path\":\"/0\",\"value\":1}]",
        .written = "[1]",
    },
    .{
        .failure = error.PathMissing,
        .source = "[0]",
        .operations = "[{\"op\":\"replace\",\"path\":\"/1\",\"value\":1}]",
        .written = "[0]",
    },
    .{
        .source = "[0]",
        .operations = "[{\"op\":\"replace\",\"path\":\"\",\"value\":1}]",
        .written = "1",
    },
    .{
        .failure = error.PatchMalformed,
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"/0/0\"}]",
        .written = test_pairs,
    },
    .{
        .failure = error.PatchMalformed,
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"path\":\"/1/0\"}]",
        .written = test_pairs,
    },
    .{
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"/0/0\",\"path\":\"/1/0\"}]",
        .written = "[[2],[1,3,4]]",
    },
    .{
        .failure = error.PatchMalformed,
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":0,\"path\":\"/1/0\"}]",
        .written = test_pairs,
    },
    .{
        .failure = error.PathMissing,
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"/0/a\",\"path\":\"/1/0\"}]",
        .written = test_pairs,
    },
    .{
        .failure = error.PathMissing,
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"/0/0\",\"path\":\"/1/a\"}]",
        .written = test_pairs,
    },
    .{
        .failure = error.PatchMalformed,
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"/0/~\",\"path\":\"/1/0\"}]",
        .written = test_pairs,
    },
    .{
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"\",\"path\":\"\"}]",
        .written = test_pairs,
    },
    .{
        .source = test_pairs,
        .operations = "[{\"op\":\"move\",\"from\":\"/0/0\",\"path\":\"\"}]",
        .written = "1",
    },
    .{
        .source = test_pairs,
        .operations = "[{\"op\":\"copy\",\"from\":\"/0/0\",\"path\":\"/1/0\"}]",
        .written = "[[1,2],[1,3,4]]",
    },
    .{
        .failure = error.PathMissing,
        .source = test_pairs,
        .operations = "[{\"op\":\"copy\",\"from\":\"/0/0\",\"path\":\"/1/a\"}]",
        .written = test_pairs,
    },
    .{
        .source = test_pairs,
        .operations = "[{\"op\":\"copy\",\"from\":\"\",\"path\":\"\"}]",
        .written = test_pairs,
    },
    .{
        .source = test_pairs,
        .operations = "[{\"op\":\"copy\",\"from\":\"/0/0\",\"path\":\"\"}]",
        .written = "1",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "[1]",
        .operations = "[{\"op\":\"test\",\"path\":\"/0\"}]",
        .written = "[1]",
    },
    .{
        .failure = error.PathMissing,
        .source = "[1]",
        .operations = "[{\"op\":\"test\",\"path\":\"/1\",\"value\":1}]",
        .written = "[1]",
    },
    .{
        .failure = error.TestFailed,
        .source = "[1]",
        .operations = "[{\"op\":\"test\",\"path\":\"\",\"value\":2}]",
        .written = "[1]",
    },
    .{
        .source = "[1,2,3]",
        .operations = "[{\"op\":\"add\",\"path\":\"/3\",\"value\":4}," ++
            "{\"op\":\"remove\",\"path\":\"/1\"}," ++
            "{\"op\":\"replace\",\"path\":\"/0\",\"value\":{\"a\":0}}," ++
            "{\"op\":\"move\",\"from\":\"/0/a\",\"path\":\"/1\"}," ++
            "{\"op\":\"copy\",\"from\":\"/3\",\"path\":\"/0/b\"}," ++
            "{\"op\":\"test\",\"path\":\"/0\",\"value\":{\"b\":4}}]",
        .written = "[{\"b\":4},0,3,4]",
    },
};

test "the yyjson patch vectors fail or apply as yyjson shows, with each member checked" {
    try test_vectors_run(&test_yyjson_vectors);
}

test "test compares numbers by value, objects as unordered sets, and strings by decoded bytes" {
    const source = "{\"n\":1,\"z\":-0,\"b\":9007199254740993,\"u\":18446744073709551615," ++
        "\"o\":{\"a\":1,\"b\":[1,2]},\"s\":\"a\u{e9}\",\"t\":true,\"x\":null}";

    const passed = [_][]const u8{
        "[{\"op\":\"test\",\"path\":\"/n\",\"value\":1.0}]",
        "[{\"op\":\"test\",\"path\":\"/n\",\"value\":1e0}]",
        "[{\"op\":\"test\",\"path\":\"/n\",\"value\":10E-1}]",
        "[{\"op\":\"test\",\"path\":\"/z\",\"value\":0}]",
        "[{\"op\":\"test\",\"path\":\"/z\",\"value\":-0.0}]",
        "[{\"op\":\"test\",\"path\":\"/b\",\"value\":9007199254740993}]",
        "[{\"op\":\"test\",\"path\":\"/u\",\"value\":18446744073709551615}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"b\":[1,2.0],\"a\":1}}]",
        "[{\"op\":\"test\",\"path\":\"/s\",\"value\":\"a\\u00e9\"}]",
        "[{\"op\":\"test\",\"path\":\"/t\",\"value\":true}]",
        "[{\"op\":\"test\",\"path\":\"/x\",\"value\":null}]",
        "[{\"op\":\"test\",\"path\":\"\",\"value\":{\"x\":null,\"t\":true,\"s\":\"a\u{e9}\"," ++
            "\"o\":{\"b\":[1,2],\"a\":1},\"u\":18446744073709551615,\"b\":9007199254740993," ++
            "\"z\":0,\"n\":1}}]",
    };

    const failed = [_][]const u8{
        "[{\"op\":\"test\",\"path\":\"/n\",\"value\":2}]",
        "[{\"op\":\"test\",\"path\":\"/n\",\"value\":\"1\"}]",
        "[{\"op\":\"test\",\"path\":\"/b\",\"value\":9007199254740992}]",
        "[{\"op\":\"test\",\"path\":\"/u\",\"value\":18446744073709551614}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"b\":[2,1],\"a\":1}}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"a\":1}}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"a\":1,\"c\":[1,2]}}]",
        "[{\"op\":\"test\",\"path\":\"/o/b\",\"value\":[1,2,3]}]",
        "[{\"op\":\"test\",\"path\":\"/s\",\"value\":\"a\"}]",
        "[{\"op\":\"test\",\"path\":\"/t\",\"value\":1}]",
        "[{\"op\":\"test\",\"path\":\"/x\",\"value\":false}]",
        "[{\"op\":\"test\",\"path\":\"/x\",\"value\":{}}]",
    };

    var vectors: [passed.len + failed.len]TestVector = undefined;

    for (passed, 0..) |operations, index| {
        vectors[index] = .{ .operations = operations, .source = source, .written = source };
    }

    for (failed, passed.len..) |operations, index| {
        vectors[index] = .{
            .failure = error.TestFailed,
            .operations = operations,
            .source = source,
            .written = source,
        };
    }

    try test_vectors_run(&vectors);
}

test "move and copy relink a subtree, replace a member in place, and reach the root" {
    const vectors = [_]TestVector{
        .{
            .source = "{\"a\":1,\"b\":2,\"c\":3}",
            .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/c\"}]",
            .written = "{\"b\":2,\"c\":1}",
        },
        .{
            .source = "{\"a\":{\"b\":1}}",
            .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"\"}]",
            .written = "{\"b\":1}",
        },
        .{
            .source = "{\"a\":{\"b\":{\"c\":1}}}",
            .operations = "[{\"op\":\"move\",\"from\":\"/a/b\",\"path\":\"/a\"}]",
            .written = "{\"a\":{\"c\":1}}",
        },
        .{
            .source = "[1,2,3,4]",
            .operations = "[{\"op\":\"move\",\"from\":\"/0\",\"path\":\"/3\"}," ++
                "{\"op\":\"move\",\"from\":\"/3\",\"path\":\"/0\"}," ++
                "{\"op\":\"move\",\"from\":\"/1\",\"path\":\"/-\"}]",
            .written = "[1,3,4,2]",
        },
        .{
            .source = "{\"a\":[1],\"b\":{}}",
            .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b/a\"}," ++
                "{\"op\":\"add\",\"path\":\"/b/a/-\",\"value\":2}]",
            .written = "{\"b\":{\"a\":[1,2]}}",
        },
        .{
            .source = "{\"a\":1}",
            .operations = "[{\"op\":\"copy\",\"from\":\"\",\"path\":\"/b\"}]",
            .written = "{\"a\":1,\"b\":{\"a\":1}}",
        },
        .{
            .source = "{\"a\":1,\"b\":2}",
            .operations = "[{\"op\":\"copy\",\"from\":\"/b\",\"path\":\"/a\"}]",
            .written = "{\"a\":2,\"b\":2}",
        },
        .{
            .source = "{\"a\":{\"b\":[1,{\"c\":\"d\"}]}}",
            .operations = "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/e\"}," ++
                "{\"op\":\"replace\",\"path\":\"/e/b/1/c\",\"value\":\"x\"}," ++
                "{\"op\":\"remove\",\"path\":\"/e/b/0\"}]",
            .written = "{\"a\":{\"b\":[1,{\"c\":\"d\"}]},\"e\":{\"b\":[{\"c\":\"x\"}]}}",
        },
        .{
            .source = "{\"a\":{\"b\":[1,2]}}",
            .operations = "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/a/b/1\"}]",
            .written = "{\"a\":{\"b\":[1,{\"b\":[1,2]},2]}}",
        },
    };

    try test_vectors_run(&vectors);
}

const test_unchanged_vectors = [_]TestVector{
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":{\"b\":1},\"c\":2}",
        .operations = "[{\"op\":\"move\",\"from\":\"/a/b\",\"path\":\"/c/x\"}]",
        .written = "{\"a\":{\"b\":1},\"c\":2}",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "{\"a\":[[1]]}",
        .operations = "[{\"op\":\"move\",\"from\":\"/a/0\",\"path\":\"/a/0/0\"}]",
        .written = "{\"a\":[[1]]}",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "{\"a\":{\"b\":{}}}",
        .operations = "[{\"op\":\"move\",\"from\":\"\",\"path\":\"/a\"}]",
        .written = "{\"a\":{\"b\":{}}}",
    },
    .{
        .failure = error.PatchMalformed,
        .source = "{\"a\":1}",
        .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/~\"}]",
        .written = "{\"a\":1}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":1}",
        .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b/c\"}]",
        .written = "{\"a\":1}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":1,\"b\":2,\"c\":3}",
        .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/x/y\"}]",
        .written = "{\"a\":1,\"b\":2,\"c\":3}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":1,\"b\":2,\"c\":3}",
        .operations = "[{\"op\":\"move\",\"from\":\"/b\",\"path\":\"/x/y\"}]",
        .written = "{\"a\":1,\"b\":2,\"c\":3}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":1,\"b\":2,\"c\":3}",
        .operations = "[{\"op\":\"move\",\"from\":\"/c\",\"path\":\"/x/y\"}]",
        .written = "{\"a\":1,\"b\":2,\"c\":3}",
    },
    .{
        .failure = error.PathMissing,
        .source = "[1,2,3]",
        .operations = "[{\"op\":\"move\",\"from\":\"/1\",\"path\":\"/3\"}]",
        .written = "[1,2,3]",
    },
    .{
        .failure = error.PathMissing,
        .source = "[1,2,3]",
        .operations = "[{\"op\":\"move\",\"from\":\"/0\",\"path\":\"/-/0\"}]",
        .written = "[1,2,3]",
    },
    .{
        .failure = error.PathMissing,
        .source = "[1,2,3]",
        .operations = "[{\"op\":\"move\",\"from\":\"/2\",\"path\":\"/x\"}]",
        .written = "[1,2,3]",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":1}",
        .operations = "[{\"op\":\"move\",\"from\":\"/b\",\"path\":\"/b\"}]",
        .written = "{\"a\":1}",
    },
    .{
        .failure = error.PathMissing,
        .source = "{\"a\":[1]}",
        .operations = "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/a/x\"}]",
        .written = "{\"a\":[1]}",
    },
};

test "a failed move or copy leaves the tree as it was" {
    try test_vectors_run(&test_unchanged_vectors);
}

test "keys reach the tree unescaped, and a repeated key resolves to its last member" {
    const vectors = [_]TestVector{
        .{
            .source = "{\"x\":{}}",
            .operations = "[{\"op\":\"add\",\"path\":\"/x/a~1b~0c\",\"value\":1}," ++
                "{\"op\":\"test\",\"path\":\"/x/a~1b~0c\",\"value\":1}," ++
                "{\"op\":\"move\",\"from\":\"/x/a~1b~0c\",\"path\":\"/x/~0\"}," ++
                "{\"op\":\"copy\",\"from\":\"/x/~0\",\"path\":\"/x/~1\"}," ++
                "{\"op\":\"add\",\"path\":\"/x/q\",\"value\":\"a\\\"b\\n\"}]",
            .written = "{\"x\":{\"~\":1,\"/\":1,\"q\":\"a\\\"b\\n\"}}",
        },
        .{
            .source = "{\"a\":1,\"a\":2}",
            .operations = "[{\"op\":\"replace\",\"path\":\"/a\",\"value\":3}]",
            .written = "{\"a\":1,\"a\":3}",
        },
        .{
            .source = "{\"a\":1,\"a\":2}",
            .operations = "[{\"op\":\"remove\",\"path\":\"/a\"}," ++
                "{\"op\":\"test\",\"path\":\"/a\",\"value\":1}]",
            .written = "{\"a\":1}",
        },
        .{
            .source = "5",
            .operations = "[{\"op\":\"test\",\"path\":\"\",\"value\":5.0}]",
            .written = "5",
        },
    };

    try test_vectors_run(&vectors);
}

test "a failed operation leaves the earlier ones applied and reports where it starts" {
    const bench = try test_bench_create();
    defer testing.allocator.destroy(bench);

    try test_source_copy(bench, "{\"a\":1}");

    try bench.operations.parse(
        \\[
        \\ {"op": "add", "path": "/b", "value": 2},
        \\  {"op": "remove", "path": "/missing"},
        \\ {"op": "add", "path": "/c", "value": 3}
        \\]
    );

    const operations = &bench.operations.document;
    var position: tokenizer_module.Position = .{ .column = 0, .line = 0 };
    const result = bench.tree.patch(operations, operations.root(), .{ .diagnostic = &position });

    try testing.expectError(error.PathMissing, result);
    try testing.expectEqual(@as(u32, 3), position.line);
    try testing.expectEqual(@as(u32, 3), position.column);
    try test_written_expect(&bench.tree.tree, "{\"a\":1,\"b\":2}");

    try bench.operations.parse("\n  {\"op\": \"remove\", \"path\": \"/a\"}");

    const malformed = bench.tree.patch(operations, operations.root(), .{ .diagnostic = &position });

    try testing.expectError(error.PatchMalformed, malformed);
    try testing.expectEqual(@as(u32, 2), position.line);
    try testing.expectEqual(@as(u32, 3), position.column);
}

test "test matches a repeated key by its occurrences in order" {
    const source = "{\"o\":{\"a\":1,\"b\":3,\"a\":2},\"p\":{\"a\":2,\"a\":2}}";

    const passed = [_][]const u8{
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"a\":1,\"b\":3,\"a\":2}}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"b\":3,\"a\":1,\"a\":2}}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"a\":1,\"a\":2,\"b\":3}}]",
        "[{\"op\":\"test\",\"path\":\"/p\",\"value\":{\"a\":2,\"a\":2}}]",
    };

    const failed = [_][]const u8{
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"a\":2,\"b\":3,\"a\":1}}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"a\":1,\"b\":3,\"c\":2}}]",
        "[{\"op\":\"test\",\"path\":\"/o\",\"value\":{\"b\":3,\"a\":2}}]",
        "[{\"op\":\"test\",\"path\":\"/p\",\"value\":{\"a\":2,\"b\":3}}]",
        "[{\"op\":\"test\",\"path\":\"/p\",\"value\":{\"a\":2}}]",
    };

    var vectors: [passed.len + failed.len]TestVector = undefined;

    for (passed, 0..) |operations, index| {
        vectors[index] = .{ .operations = operations, .source = source, .written = source };
    }

    for (failed, passed.len..) |operations, index| {
        vectors[index] = .{
            .failure = error.TestFailed,
            .operations = operations,
            .source = source,
            .written = source,
        };
    }

    try test_vectors_run(&vectors);
}

test "merge patch removes every member a null names and merges below any target" {
    const merges = [_]TestMerge{
        .{
            .source = "{\"a\":1,\"b\":2,\"a\":3}",
            .changes = "{\"a\":null}",
            .written = "{\"b\":2}",
        },
        .{
            .source = "{\"a\":1,\"b\":2,\"a\":3}",
            .changes = "{\"a\":5}",
            .written = "{\"a\":1,\"b\":2,\"a\":5}",
        },
        .{
            .source = "{\"a\":{\"b\":\"c\"}}",
            .changes = "{\"a\":[1]}",
            .written = "{\"a\":[1]}",
        },
        .{
            .source = "{\"a\":[1],\"b\":{\"c\":null}}",
            .changes = "{\"a\":{\"x\":{\"y\":true}},\"b\":{\"c\":{}},\"d\":null}",
            .written = "{\"a\":{\"x\":{\"y\":true}},\"b\":{\"c\":{}}}",
        },
        .{
            .source = "{\"a\":1}",
            .changes = "{\"b\":2,\"b\":null,\"c\":3,\"c\":4}",
            .written = "{\"a\":1,\"c\":4}",
        },
        .{ .source = "[1]", .changes = "{}", .written = "{}" },
        .{ .source = "{\"a\":1}", .changes = "{}", .written = "{\"a\":1}" },
    };

    try test_merges_run(&merges);

    const bench = try test_bench_create();
    defer testing.allocator.destroy(bench);

    try test_source_copy(bench, "{\"x\":[1,{\"y\":2}],\"z\":3}");
    try bench.operations.parse("{\"y\":null,\"w\":{\"v\":[]}}");

    const changes = &bench.operations.document;
    const target = bench.tree.pointer_find(bench.tree.root(), "/x/1") orelse unreachable;

    try bench.tree.merge_patch(target, changes, changes.root());
    try test_written_expect(&bench.tree.tree, "{\"x\":[1,{\"w\":{\"v\":[]}}],\"z\":3}");
}

fn test_repeated(nesting: TestNesting, inner: []const u8, count: u32) []const u8 {
    assert(nesting.open.len > 0);
    assert(inner.len > 0);
    assert(count < 1024);

    var result: []const u8 = inner;

    for (0..count) |_| result = nesting.open ++ result ++ nesting.close;

    return result;
}

test "copy, move, add, test, and merge patch hold 64 levels and refuse a 65th" {
    const braces: TestNesting = .{ .close = "}", .open = "{\"a\":" };
    const brackets: TestNesting = .{ .close = "]", .open = "[" };
    const arrays = comptime test_repeated(brackets, "1", depth_max - 1);
    const arrays_inner = comptime test_repeated(brackets, "1", depth_max - 2);
    const arrays_other = comptime test_repeated(brackets, "2", depth_max - 2);
    const objects = comptime test_repeated(braces, "1", depth_max);
    const source = "{\"a\":" ++ arrays ++ ",\"b\":[]}";

    const vectors = [_]TestVector{
        .{
            .failure = error.DepthExceeded,
            .source = source,
            .operations = "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b/-\"}]",
            .written = source,
        },
        .{
            .failure = error.DepthExceeded,
            .source = source,
            .operations = "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b/0\"}]",
            .written = source,
        },
        .{
            .source = source,
            .operations = "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/c\"}," ++
                "{\"op\":\"move\",\"from\":\"/c\",\"path\":\"/b\"}," ++
                "{\"op\":\"test\",\"path\":\"/b/0\",\"value\":" ++ arrays_inner ++ "}]",
            .written = "{\"a\":" ++ arrays ++ ",\"b\":" ++ arrays ++ "}",
        },
        .{
            .failure = error.TestFailed,
            .source = source,
            .operations = "[{\"op\":\"test\",\"path\":\"/a/0\",\"value\":" ++ arrays_other ++ "}]",
            .written = source,
        },
        .{
            .failure = error.DepthExceeded,
            .source = "{\"a\":{\"b\":{}}}",
            .operations = "[{\"op\":\"add\",\"path\":\"/a/b/c\",\"value\":" ++ arrays_inner ++ "}]",
            .written = "{\"a\":{\"b\":{}}}",
        },
    };

    try test_vectors_run(&vectors);

    try test_merges_run(&.{.{ .source = "{}", .changes = objects, .written = objects }});

    const bench = try test_bench_create();
    defer testing.allocator.destroy(bench);

    try test_source_copy(bench, "{\"x\":{}}");
    try bench.operations.parse(objects);

    const changes = &bench.operations.document;
    const target = bench.tree.member(bench.tree.root(), "x") orelse unreachable;
    const result = bench.tree.merge_patch(target, changes, changes.root());

    try testing.expectError(error.DepthExceeded, result);
}

test "an operation that runs out of records fails whole and keeps the earlier ones" {
    const zeros = comptime test_repeated(.{ .close = "", .open = "0," }, "0", 199);
    const source = "{\"a\":[" ++ zeros ++ "]}";
    const doubled = "{\"a\":[" ++ zeros ++ "],\"b\":[" ++ zeros ++ "]}";

    const vectors = [_]TestVector{
        .{
            .failure = error.NodesExhausted,
            .source = source,
            .operations = "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b\"}," ++
                "{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/c\"}]",
            .written = doubled,
        },
        .{
            .failure = error.NodesExhausted,
            .source = source,
            .operations = "[{\"op\":\"add\",\"path\":\"/b\",\"value\":[" ++ zeros ++ "]}," ++
                "{\"op\":\"add\",\"path\":\"/c\",\"value\":[" ++ zeros ++ "]}]",
            .written = doubled,
        },
        .{
            .failure = error.NodesExhausted,
            .source = source,
            .operations = "[{\"op\":\"add\",\"path\":\"/b\",\"value\":[" ++ zeros ++ "]}," ++
                "{\"op\":\"add\",\"path\":\"/a/0\",\"value\":[" ++ zeros ++ "]}]",
            .written = doubled,
        },
    };

    try test_vectors_run(&vectors);
}

test "an add, copy, or move whose key runs out of text fails whole" {
    const bench = try test_bench_create();
    defer testing.allocator.destroy(bench);

    try test_source_copy(bench, "{\"a\":[1]}");

    const tree = &bench.tree.tree;
    const padding: [4096]u8 = @splat('p');
    const padding_bytes = tree.text.len - tree.text_count - 16;

    _ = try bench.tree.set(bench.tree.root(), "pad", .{ .string = padding[0..padding_bytes] });

    const key = padding[0 .. tree.text.len - tree.text_count];
    const counts = [2]u32{ tree.node_count, tree.text_count };

    assert(key.len > 0);
    assert(key.len < 16);

    var before: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&before);

    try tree.write(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    const formats = .{
        "[{{\"op\":\"add\",\"path\":\"/{s}\",\"value\":0}}]",
        "[{{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/{s}\"}}]",
        "[{{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/{s}\"}}]",
    };

    var buffer: [128]u8 = undefined;

    inline for (formats) |format| {
        try bench.operations.parse(try std.mem.print(&buffer, format, .{key}));

        const operations = &bench.operations.document;
        const result = bench.tree.patch(operations, operations.root(), .{ .diagnostic = null });

        try testing.expectError(error.TextExhausted, result);
        try testing.expectEqual(counts, [2]u32{ tree.node_count, tree.text_count });
        try test_written_expect(tree, sink.buffered());
    }
}
