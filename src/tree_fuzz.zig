const std = @import("std");

const document_fuzz = @import("document_fuzz.zig");
const document_module = @import("document.zig");
const number_module = @import("number.zig");
const region_module = @import("region.zig");
const storage_module = @import("storage.zig");
const tokenizer_module = @import("tokenizer.zig");
const tree_module = @import("tree.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const DocumentNode = document_module.Node;
const DocumentRecord = storage_module.Record;
const Position = tokenizer_module.Position;
const Prng = std.Random.DefaultPrng;
const Region = region_module.Region;
const Tree = tree_module.Tree;
const Writer = writer_module.Writer;

const campaign_events_min: u32 = 20_000;
const check_interval: u32 = 32;
const depth_max = tokenizer_module.depth_max;
const input_bytes_max: u32 = 16 * 1024;
const members_capacity_min: u32 = 4;
const operation_count_max: u32 = 48;
const operation_position: Position = .{ .column = 2, .line = 1 };
const operations_bytes_max: u32 = 512 * 1024;
const operations_records_max: u32 = 8 * 1024;
const output_bytes_max: u32 = 4 * 1024 * 1024;
const patch_pointer_bytes_max: u32 = 2048;
const records_max: u32 = 16 * 1024;
const reference_bytes_min: u32 = 1024 * 1024;
const tree_large_node_count: u32 = 512;
const tree_records_max: u32 = 2048;
const tree_text_bytes_max: u32 = 32 * 1024;
const walk_depth_max: u32 = 12;

comptime {
    assert(records_max >= tree_records_max);
    assert(records_max >= input_bytes_max);
    assert(output_bytes_max > tree_text_bytes_max);
    assert(operations_records_max > 2 * tree_records_max);
    assert(operations_bytes_max > 8 * tree_text_bytes_max);
}

const TreeStorage = Tree.StorageType(.{
    .node_count_max = tree_records_max,
    .text_bytes_max = tree_text_bytes_max,
});

const keys = [_][]const u8{ "a", "b", "", "a/b", "m~n", "~1", "caf\u{e9}", "k\"q\\" };
const keys_fresh = [_][]const u8{ "fresh", "fr/e~sh", "", "\u{2603}" };

const numbers_invalid = [_][]const u8{
    "",
    "-",
    "01",
    "+1",
    "1.",
    ".5",
    "1e",
    "0x1",
    "nan1",
    "1 ",
};

const numbers_valid = [_][]const u8{
    "0",
    "-0",
    "1.50",
    "2.5E-3",
    "1e400",
    "-9223372036854775808",
    "18446744073709551616",
    "NaN",
    "-inf",
    "Infinity",
};

const operations_options: Writer.Options = .{
    .indent = 1,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

const strings = [_][]const u8{
    "",
    "plain",
    "q\"b\\",
    "tab\there\n",
    "\u{1f600}\u{e9}",
    "\x01\x1f",
};

const strings_invalid = [_][]const u8{
    "\xff",
    "\xc3",
    "\xed\xa0\x80",
    "a\x80",
    "\xf4\x90\x80\x80",
};

const Counts = std.EnumArray(Outcome, u32);
const PatchError = Tree.CapacityError || Tree.ConflictError || Tree.PatchError;

const Exceeded = struct {
    depth: bool,
    nodes: bool,
    text: bool,
};

const Failure = struct {
    err: Tree.EditError,
    refusal: *const Refusal,
};

const Generated = struct {
    content: Tree.Content,
    model: *Model,
    need: Need,
    refusal: ?Tree.ValueError,
};

const Member = struct {
    key: []const u8,
    value: *Model,
};

const Model = struct {
    count: u32,
    float: ?f64,
    kind: ModelKind,
    members: []Member,
    text: []const u8,
};

const ModelKind = enum {
    array,
    false_value,
    null_value,
    number,
    object,
    string,
    true_value,
};

const Need = struct {
    height: u32,
    node_count: u32,
    text_bytes: u64,
};

const Operation = enum {
    append,
    insert,
    remove,
    replace,
    set,
};

const Outcome = enum {
    append,
    copy,
    depth_exceeded,
    insert,
    merge_idempotent,
    merge_refused,
    merge_settled,
    nodes_exhausted,
    number_invalid,
    patch_added,
    patch_copied,
    patch_malformed,
    patch_moved,
    patch_refused,
    patch_test_failed,
    patch_test_passed,
    remove_item,
    remove_member,
    replace,
    replace_root,
    set_member,
    set_replaced,
    text_exhausted,
    tree_large,
    utf8_invalid,
};

const Pair = struct {
    model: *Model,
    node: DocumentNode,
};

const PatchStep = struct {
    from: ?[]const u8,
    path: []const u8,
    value: PatchValue,
    verb: []const u8,
};

const PatchTarget = struct {
    node: Tree.Node,
    pointer: []const u8,
};

const PatchValue = union(enum) {
    absent,
    node: Tree.Node,
    unequal: Tree.Node,
};

const Push = struct {
    key: []const u8,
    node: DocumentNode,
    owner: *Model,
};

const Refusal = struct {
    before: []const u8,
    exceeded: Exceeded,
    generated: *const Generated,
};

pub const State = struct {
    counts: Counts,
    documents: [2]Document,
    input: [input_bytes_max]u8,
    levels: [records_max]u32,
    merged: [output_bytes_max]u8,
    models: [records_max]*Model,
    operations: Document,
    operations_records: [operations_records_max]DocumentRecord,
    operations_source: [operations_bytes_max]u8,
    operations_text: [operations_bytes_max]u8,
    output: [output_bytes_max]u8,
    pairs: [records_max]Pair,
    patch_pointers: [3][patch_pointer_bytes_max]u8,
    pointers: document_fuzz.PointerScratch,
    records: [2][records_max]DocumentRecord,
    reparse_text: [output_bytes_max]u8,
    rewrite: [output_bytes_max]u8,
    source_text: [input_bytes_max]u8,
    storages: [2]TreeStorage,
    trees: [2]Tree,
};

const Target = struct {
    level: u32,
    model: *Model,
    node: Tree.Node,
    parent: ?*Model,
    position: u32,
};

pub fn event(state: *State, prng: *Prng, reference: []u8) !void {
    assert(reference.len >= reference_bytes_min);
    assert(state.output.len == output_bytes_max);

    var region: Region = .init(reference);
    const root = try model_create(&region, .null_value);
    const operation_count = prng.random().uintAtMost(u32, operation_count_max);

    tree_prepare(state, prng);

    for (0..operation_count) |count| {
        operation_apply(state, prng, &region, root) catch |err| switch (err) {
            error.RegionFull => break,
            else => return err,
        };

        tree_module.audit(&state.trees[0]);

        if (count % check_interval == check_interval - 1) try check(state, prng, root);
    }

    try check(state, prng, root);
}

pub fn counts_reset(state: *State) void {
    assert(state.output.len == output_bytes_max);
    assert(@typeInfo(Outcome).@"enum".field_names.len > 0);

    state.counts = .initFill(0);
}

pub fn summary_check(state: *const State, events_max: u32) !void {
    assert(events_max > 0);
    assert(campaign_events_min > 0);

    for (std.enums.values(Outcome)) |outcome| {
        std.debug.print("fuzz tree: {t}={d}\n", .{ outcome, state.counts.get(outcome) });
    }

    if (events_max < campaign_events_min) return;

    for (std.enums.values(Outcome)) |outcome| {
        if (state.counts.get(outcome) == 0) return error.OutcomeUnreached;
    }
}

fn tree_prepare(state: *State, prng: *Prng) void {
    assert(state.storages[0].records.len == tree_records_max);
    assert(state.storages[0].text.len == tree_text_bytes_max);

    const random = prng.random();
    const generous = random.boolean();
    const node_count_max = if (generous) tree_records_max else random.intRangeAtMost(u32, 1, 64);
    const text_bytes_max = if (generous) tree_text_bytes_max else random.uintAtMost(u32, 256);
    const full = state.storages[0].storage();

    state.trees[0].init(.{
        .records = full.records[0..node_count_max],
        .text = full.text[0..text_bytes_max],
    });
}

fn operation_apply(state: *State, prng: *Prng, region: *Region, root: *Model) !void {
    assert(root.kind != .number or root.count == 0);
    assert(state.trees[0].node_count > 0);

    const target = try target_find(state, prng, root);
    const random = prng.random();

    const preferred: Operation = switch (target.model.kind) {
        .array => if (random.boolean()) .append else .insert,
        .object => .set,
        .false_value, .null_value, .number, .string, .true_value => .replace,
    };

    const removable: Operation = if (target.parent == null) preferred else .remove;

    const operation: Operation = switch (random.uintLessThan(u32, 8)) {
        0 => removable,
        1 => .replace,
        else => preferred,
    };

    switch (operation) {
        .append => try append_apply(state, prng, region, &target),
        .insert => try insert_apply(state, prng, region, &target),
        .remove => try remove_apply(state, &target),
        .replace => try replace_apply(state, prng, region, &target),
        .set => try set_apply(state, prng, region, &target),
    }
}

fn target_find(state: *State, prng: *Prng, root: *Model) !Target {
    assert(root.kind != .number or root.count == 0);
    assert(state.trees[0].node_count > 0);

    const tree = &state.trees[0];
    const random = prng.random();

    var target: Target = .{
        .level = 0,
        .model = root,
        .node = tree.root(),
        .parent = null,
        .position = 0,
    };

    for (0..walk_depth_max) |_| {
        if (target.model.count == 0) break;
        if (random.uintLessThan(u32, 3) == 0) break;

        const position = random.uintLessThan(u32, target.model.count);
        const child = try child_find(tree, target.node, position);
        const parent = target.model;
        const level = target.level + 1;

        target = .{
            .level = level,
            .model = parent.members[position].value,
            .node = child,
            .parent = parent,
            .position = position,
        };
    }

    assert(target.level <= depth_max);

    return target;
}

fn child_find(tree: *const Tree, container: Tree.Node, position: u32) !Tree.Node {
    assert(position < tree.count_of(container));
    assert(tree.kind_of(container) != .string);

    if (tree.kind_of(container) == .array) {
        return tree.item(container, position) orelse error.ItemMissing;
    }

    var entries = tree.entries(container);

    for (0..position) |_| {
        _ = entries.next() orelse return error.EntryMissing;
    }

    const entry = entries.next() orelse return error.EntryMissing;
    return entry.value;
}

fn set_apply(state: *State, prng: *Prng, region: *Region, target: *const Target) !void {
    assert(target.model.kind == .object);
    assert(target.level < depth_max);

    const random = prng.random();
    const invalid = random.uintLessThan(u32, 16) == 0;
    const key_invalid = strings_invalid[random.uintLessThan(u32, strings_invalid.len)];
    const key = if (invalid) key_invalid else keys[random.uintLessThan(u32, keys.len)];
    const generated = try content_generate(state, prng, region);

    try members_room(region, target.model);

    if (invalid) return key_refusal_check(state, target, key, &generated);

    const existing = member_last(target.model, key);
    const need = need_set(&generated.need, existing != null, key);
    const tree = &state.trees[0];

    const refusal: Refusal = .{
        .before = try written_compact(state, &state.rewrite),
        .exceeded = exceeded_of(tree, need, target.level + 1),
        .generated = &generated,
    };

    const value = tree.set(target.node, key, generated.content) catch |err| {
        return failure_check(state, &.{ .err = err, .refusal = &refusal });
    };

    try acceptance_check(&refusal);

    if (existing) |index| {
        target.model.members[index].value = generated.model;

        counted(state, .set_replaced);
    } else {
        member_add(target.model, .{ .key = key, .value = generated.model });
        counted(state, .set_member);
    }

    if (tree.member(target.node, key) != value) return error.MemberDisagreement;
}

fn need_set(value: *const Need, replaced: bool, key: []const u8) Need {
    assert(value.node_count > 0);
    assert(key.len <= input_bytes_max);

    if (replaced) {
        return .{
            .height = value.height,
            .node_count = value.node_count - 1,
            .text_bytes = value.text_bytes,
        };
    }

    return .{
        .height = value.height,
        .node_count = value.node_count + 1,
        .text_bytes = value.text_bytes + key.len + 2,
    };
}

fn key_refusal_check(
    state: *State,
    target: *const Target,
    key: []const u8,
    generated: *const Generated,
) !void {
    assert(!std.unicode.utf8ValidateSlice(key));
    assert(target.model.kind == .object);

    const before = try written_compact(state, &state.rewrite);
    const result = state.trees[0].set(target.node, key, generated.content);

    _ = result catch |err| switch (err) {
        error.Utf8Invalid => {
            const after = try written_compact(state, &state.output);
            if (!std.mem.eql(u8, before, after)) return error.RefusalChanged;

            counted(state, .utf8_invalid);

            return;
        },
        error.DepthExceeded, error.NodesExhausted, error.NumberInvalid, error.TextExhausted => {
            return error.RefusalDisagreement;
        },
    };

    return error.KeyAccepted;
}

fn append_apply(state: *State, prng: *Prng, region: *Region, target: *const Target) !void {
    assert(target.model.kind == .array);
    assert(target.level < depth_max);

    const generated = try content_generate(state, prng, region);
    const count = target.model.count;

    try members_room(region, target.model);

    const tree = &state.trees[0];

    const refusal: Refusal = .{
        .before = try written_compact(state, &state.rewrite),
        .exceeded = exceeded_of(tree, generated.need, target.level + 1),
        .generated = &generated,
    };

    const value = tree.append(target.node, generated.content) catch |err| switch (err) {
        error.DepthExceeded,
        error.NodesExhausted,
        error.NumberInvalid,
        error.TextExhausted,
        error.Utf8Invalid,
        => |refused| return failure_check(state, &.{ .err = refused, .refusal = &refusal }),
    };

    try acceptance_check(&refusal);

    member_add(target.model, .{ .key = "", .value = generated.model });
    counted(state, .append);

    if (tree.item(target.node, count) != value) return error.ItemDisagreement;
}

fn insert_apply(state: *State, prng: *Prng, region: *Region, target: *const Target) !void {
    assert(target.model.kind == .array);
    assert(target.level < depth_max);

    const index = prng.random().uintAtMost(u32, target.model.count);
    const generated = try content_generate(state, prng, region);

    try members_room(region, target.model);

    const tree = &state.trees[0];

    const refusal: Refusal = .{
        .before = try written_compact(state, &state.rewrite),
        .exceeded = exceeded_of(tree, generated.need, target.level + 1),
        .generated = &generated,
    };

    const value = tree.insert(target.node, index, generated.content) catch |err| switch (err) {
        error.DepthExceeded,
        error.NodesExhausted,
        error.NumberInvalid,
        error.TextExhausted,
        error.Utf8Invalid,
        => |refused| return failure_check(state, &.{ .err = refused, .refusal = &refusal }),
    };

    try acceptance_check(&refusal);

    member_insert(target.model, index, .{ .key = "", .value = generated.model });
    counted(state, .insert);

    if (tree.item(target.node, index) != value) return error.ItemDisagreement;
}

fn replace_apply(state: *State, prng: *Prng, region: *Region, target: *const Target) !void {
    assert(target.level <= depth_max);
    assert(target.model.count < tree_records_max);

    const generated = try content_generate(state, prng, region);
    const tree = &state.trees[0];

    const need: Need = .{
        .height = generated.need.height,
        .node_count = generated.need.node_count - 1,
        .text_bytes = generated.need.text_bytes,
    };

    const refusal: Refusal = .{
        .before = try written_compact(state, &state.rewrite),
        .exceeded = exceeded_of(tree, need, target.level),
        .generated = &generated,
    };

    tree.replace(target.node, generated.content) catch |err| {
        return failure_check(state, &.{ .err = err, .refusal = &refusal });
    };

    try acceptance_check(&refusal);

    if (target.parent) |parent| {
        parent.members[target.position].value = generated.model;
    } else {
        target.model.* = generated.model.*;

        counted(state, .replace_root);
    }

    counted(state, .replace);

    if (tree.kind_of(target.node) != kind_of_model(generated.model)) return error.KindDisagreement;
}

fn remove_apply(state: *State, target: *const Target) !void {
    assert(target.parent != null);
    assert(target.level > 0);

    const parent = target.parent orelse return error.ParentMissing;
    const tree = &state.trees[0];
    const node_count = tree.node_count;
    const outcome: Outcome = if (parent.kind == .object) .remove_member else .remove_item;

    tree.remove(target.node);

    const removed = member_delete(parent, target.position);
    if (removed.value != target.model) return error.ModelDisagreement;
    if (tree.node_count != node_count) return error.NodeCountChanged;

    counted(state, outcome);
}

fn written_compact(state: *const State, buffer: []u8) ![]const u8 {
    assert(state.trees[0].node_count > 0);
    assert(buffer.len == output_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try state.trees[0].write(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    return sink.buffered();
}

fn acceptance_check(refusal: *const Refusal) !void {
    assert(refusal.before.len > 0);
    assert(refusal.generated.need.node_count > 0);

    if (refusal.generated.refusal != null) return error.ValueAccepted;
    if (refusal.exceeded.depth) return error.CapacityAccepted;
    if (refusal.exceeded.nodes) return error.CapacityAccepted;
    if (refusal.exceeded.text) return error.CapacityAccepted;
}

fn failure_check(state: *State, failure: *const Failure) !void {
    assert(failure.refusal.before.len > 0);
    assert(state.trees[0].node_count > 0);

    counted(state, try outcome_of(failure));

    const after = try written_compact(state, &state.output);
    if (!std.mem.eql(u8, failure.refusal.before, after)) return error.RefusalChanged;
}

fn outcome_of(failure: *const Failure) !Outcome {
    assert(failure.refusal.generated.need.height <= depth_max);
    assert(failure.refusal.before.len > 0);

    const exceeded = failure.refusal.exceeded;

    if (failure.refusal.generated.refusal) |expected| {
        if (failure.err != expected) return error.RefusalDisagreement;

        return switch (expected) {
            error.NumberInvalid => .number_invalid,
            error.Utf8Invalid => .utf8_invalid,
        };
    }

    return switch (failure.err) {
        error.DepthExceeded => if (exceeded.depth) .depth_exceeded else error.DepthRefused,
        error.NodesExhausted => if (exceeded.nodes) .nodes_exhausted else error.NodesRefused,
        error.NumberInvalid, error.Utf8Invalid => error.ValueRefused,
        error.TextExhausted => if (exceeded.text) .text_exhausted else error.TextRefused,
    };
}

fn exceeded_of(tree: *const Tree, need: Need, level: u32) Exceeded {
    assert(level <= depth_max);
    assert(need.height <= depth_max);

    return .{
        .depth = level + need.height > depth_max,
        .nodes = need.node_count > tree.records.len - tree.node_count,
        .text = need.text_bytes > tree.text.len - tree.text_count,
    };
}

fn counted(state: *State, outcome: Outcome) void {
    assert(state.counts.get(outcome) < std.math.maxInt(u32));
    assert(@backingInt(outcome) < @typeInfo(Outcome).@"enum".field_names.len);

    state.counts.getPtr(outcome).* += 1;
}

fn member_last(object: *const Model, key: []const u8) ?u32 {
    assert(object.kind == .object);
    assert(key.len <= input_bytes_max);

    var result: ?u32 = null;

    for (object.members[0..object.count], 0..) |member, index| {
        if (std.mem.eql(u8, member.key, key)) result = @intCast(index);
    }

    return result;
}

fn members_room(region: *Region, model: *Model) !void {
    assert(model.count <= model.members.len);
    assert(model.kind == .array or model.kind == .object);

    if (model.count < model.members.len) return;

    const capacity: u32 = @max(members_capacity_min, 2 * model.count);
    const members = try region.reserve(Member, capacity);

    @memcpy(members[0..model.count], model.members[0..model.count]);
    model.members = members;

    assert(model.count < model.members.len);
}

fn member_add(model: *Model, member: Member) void {
    assert(model.count < model.members.len);
    assert(member.value.count <= member.value.members.len);

    model.members[model.count] = member;
    model.count += 1;
}

fn member_insert(model: *Model, index: u32, member: Member) void {
    assert(model.count < model.members.len);
    assert(index <= model.count);
    assert(member.value.count <= member.value.members.len);

    std.mem.copyBackwards(
        Member,
        model.members[index + 1 .. model.count + 1],
        model.members[index..model.count],
    );

    model.members[index] = member;
    model.count += 1;
}

fn member_delete(model: *Model, index: u32) Member {
    assert(index < model.count);
    assert(model.count <= model.members.len);

    const result = model.members[index];

    std.mem.copyForwards(
        Member,
        model.members[index .. model.count - 1],
        model.members[index + 1 .. model.count],
    );

    model.count -= 1;

    return result;
}

fn kind_of_model(model: *const Model) Tree.Kind {
    assert(@typeInfo(ModelKind).@"enum".field_names.len == 7);
    assert(model.kind != .object or model.text.len == 0);

    return switch (model.kind) {
        .array => .array,
        .false_value, .true_value => .boolean,
        .null_value => .null_value,
        .number => .number,
        .object => .object,
        .string => .string,
    };
}

fn model_create(region: *Region, kind: ModelKind) !*Model {
    assert(@sizeOf(Model) > 0);
    assert(region.used <= region.top);

    const slots = try region.reserve(Model, 1);

    slots[0] = .{ .count = 0, .float = null, .kind = kind, .members = &.{}, .text = "" };

    return &slots[0];
}

fn text_keep(region: *Region, text: []const u8) ![]const u8 {
    assert(text.len <= input_bytes_max);
    assert(region.used <= region.top);

    const bytes = try region.reserve(u8, @intCast(text.len));

    @memcpy(bytes, text);

    return bytes;
}

fn content_generate(state: *State, prng: *Prng, region: *Region) !Generated {
    assert(state.input.len == input_bytes_max);
    assert(numbers_valid.len > 0);

    return switch (prng.random().uintLessThan(u32, 16)) {
        0 => scalar_generated(region, .null_value, .null_value),
        1 => scalar_generated(region, .{ .boolean = true }, .true_value),
        2 => scalar_generated(region, .{ .boolean = false }, .false_value),
        3, 4 => integer_generated(region, prng),
        5 => text_generated(region, prng, .number),
        6, 7 => text_generated(region, prng, .string),
        8 => scalar_generated(region, .array, .array),
        9 => scalar_generated(region, .object, .object),
        10 => float_generated(region, prng),
        else => copy_generated(state, prng, region),
    };
}

fn scalar_generated(region: *Region, content: Tree.Content, kind: ModelKind) !Generated {
    assert(content != .copy);
    assert(kind != .number);

    const model = try model_create(region, kind);

    const height: u32 = switch (kind) {
        .array, .object => 1,
        .false_value, .null_value, .number, .string, .true_value => 0,
    };

    return .{
        .content = content,
        .model = model,
        .need = .{ .height = height, .node_count = 1, .text_bytes = 0 },
        .refusal = null,
    };
}

fn integer_generated(region: *Region, prng: *Prng) !Generated {
    assert(region.used <= region.top);
    assert(numbers_valid.len > 0);

    const random = prng.random();
    const model = try model_create(region, .number);
    const signed = random.boolean();
    const value = random.int(u64);
    const integer: i64 = @bitCast(value);
    var buffer: [24]u8 = undefined;

    const text = if (signed)
        try std.mem.print(&buffer, "{d}", .{integer})
    else
        try std.mem.print(&buffer, "{d}", .{value});

    model.text = try text_keep(region, text);

    return .{
        .content = if (signed) .{ .integer = integer } else .{ .unsigned = value },
        .model = model,
        .need = .{ .height = 0, .node_count = 1, .text_bytes = text.len },
        .refusal = null,
    };
}

fn float_generated(region: *Region, prng: *Prng) !Generated {
    assert(region.used <= region.top);
    assert(number_module.float_bytes_max >= 24);

    const random = prng.random();
    const specials = [_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), -0.0 };
    const special = specials[random.uintLessThan(u32, specials.len)];
    const value: f64 = if (random.uintLessThan(u32, 4) == 0) special else @bitCast(random.int(u64));
    const model = try model_create(region, .number);
    var buffer: [number_module.float_bytes_max]u8 = undefined;

    const text = if (std.math.isFinite(value))
        number_module.float_format(f64, value, &buffer)
    else
        number_module.spelling_of(value);

    model.float = value;

    return .{
        .content = .{ .float = value },
        .model = model,
        .need = .{ .height = 0, .node_count = 1, .text_bytes = text.len },
        .refusal = null,
    };
}

fn text_generated(region: *Region, prng: *Prng, kind: ModelKind) !Generated {
    assert(kind == .number or kind == .string);
    assert(strings.len > 0);

    const random = prng.random();
    const invalid = random.uintLessThan(u32, 6) == 0;
    const number = kind == .number;
    const valid_list: []const []const u8 = if (number) &numbers_valid else &strings;
    const invalid_list: []const []const u8 = if (number) &numbers_invalid else &strings_invalid;
    const list = if (invalid) invalid_list else valid_list;
    const text = list[random.uintLessThan(u32, @intCast(list.len))];
    const model = try model_create(region, kind);
    const refusal: Tree.ValueError = if (number) error.NumberInvalid else error.Utf8Invalid;
    const quote_bytes: u32 = if (number) 0 else 2;

    model.text = text;

    return .{
        .content = if (number) .{ .number = text } else .{ .string = text },
        .model = model,
        .need = .{ .height = 0, .node_count = 1, .text_bytes = text.len + quote_bytes },
        .refusal = if (invalid) refusal else null,
    };
}

fn copy_generated(state: *State, prng: *Prng, region: *Region) !Generated {
    assert(state.input.len == input_bytes_max);
    assert(state.records[0].len == records_max);

    const random = prng.random();
    var sink: std.Io.Writer = .fixed(&state.input);

    if (random.uintLessThan(u32, 4) == 0) {
        const shallowest: u32 = if (random.boolean()) 1 else depth_max - 8;
        const depth = random.intRangeAtMost(u32, shallowest, depth_max);

        try sink.splatByteAll('[', depth);
        try sink.writeAll("7");
        try sink.splatByteAll(']', depth);
    } else {
        document_fuzz.document_generate(prng, &sink) catch |err| switch (err) {
            error.WriteFailed => return scalar_generated(region, .null_value, .null_value),
            else => return err,
        };
    }

    const document = &state.documents[0];

    const storage: storage_module.Storage = .{
        .records = state.records[0][0..@max(sink.end, 1)],
        .text = state.source_text[0..sink.end],
    };

    try document.parse(storage, sink.buffered());

    const index = random.uintLessThan(u32, document.node_count);
    const source: DocumentNode = if (random.boolean()) document.root() else @fromBackingInt(index);
    const model = try model_from(state, region, document, source);

    counted(state, .copy);

    return .{
        .content = .{ .copy = .{ .document = document, .node = source } },
        .model = model,
        .need = need_of(state, model),
        .refusal = null,
    };
}

fn model_from(
    state: *State,
    region: *Region,
    document: *const Document,
    source: DocumentNode,
) !*Model {
    assert(@backingInt(source) < document.node_count);
    assert(document.node_count <= state.pairs.len);

    const root = try model_create(region, model_kind_of(document, source));

    state.pairs[0] = .{ .model = root, .node = source };

    var count: u32 = 1;

    for (0..document.node_count + 1) |_| {
        if (count == 0) return root;

        count -= 1;

        const pair = state.pairs[count];

        try model_fill(state, region, document, pair, &count);
    }

    return error.WalkUnbounded;
}

fn model_fill(
    state: *State,
    region: *Region,
    document: *const Document,
    pair: Pair,
    count: *u32,
) !void {
    assert(@backingInt(pair.node) < document.node_count);
    assert(count.* < state.pairs.len);

    const model = pair.model;
    const member_count = document.count_of(pair.node);

    switch (model.kind) {
        .array, .object => model.members = try region.reserve(Member, member_count),
        .false_value, .null_value, .true_value => {},
        .number => model.text = try text_keep(region, document.source_of(pair.node)),
        .string => model.text = try text_keep(region, document.text_of(pair.node).?),
    }

    var entries = document.entries(pair.node);
    var items = document.items(pair.node);

    for (0..member_count) |_| {
        const push: Push = if (model.kind == .object) push: {
            const entry = entries.next() orelse return error.EntryMissing;
            const key = try text_keep(region, document.text_of(entry.key).?);

            break :push .{ .key = key, .node = entry.value, .owner = model };
        } else .{ .key = "", .node = items.next() orelse return error.ItemMissing, .owner = model };

        try member_push(state, region, document, &push, count);
    }
}

fn member_push(
    state: *State,
    region: *Region,
    document: *const Document,
    push: *const Push,
    count: *u32,
) !void {
    assert(@backingInt(push.node) < document.node_count);
    assert(count.* < state.pairs.len);

    const child = try model_create(region, model_kind_of(document, push.node));

    member_add(push.owner, .{ .key = push.key, .value = child });

    state.pairs[count.*] = .{ .model = child, .node = push.node };
    count.* += 1;
}

fn model_kind_of(document: *const Document, node: DocumentNode) ModelKind {
    assert(@backingInt(node) < document.node_count);
    assert(document.node_count > 0);

    return switch (document.kind_of(node)) {
        .array => .array,
        .boolean => if (document.boolean_of(node) == true) .true_value else .false_value,
        .null_value => .null_value,
        .number => .number,
        .object => .object,
        .string => .string,
    };
}

fn need_of(state: *State, root: *Model) Need {
    assert(root.kind != .number or root.count == 0);
    assert(state.models.len == records_max);

    var need: Need = .{ .height = 0, .node_count = 0, .text_bytes = 0 };
    var count: u32 = 1;

    state.models[0] = root;
    state.levels[0] = 1;

    for (0..records_max) |_| {
        if (count == 0) break;

        count -= 1;

        const model = state.models[count];
        const level = state.levels[count];

        need_add(&need, model, level);

        for (model.members[0..model.count]) |member| {
            state.models[count] = member.value;
            state.levels[count] = level + 1;
            count += 1;
        }
    }

    assert(count == 0);
    assert(need.node_count > 0);

    return need;
}

fn need_add(need: *Need, model: *const Model, level: u32) void {
    assert(level >= 1);
    assert(level <= depth_max + 1);

    need.node_count += 1;

    switch (model.kind) {
        .array => need.height = @max(need.height, level),
        .false_value, .null_value, .true_value => {},
        .number => need.text_bytes += model.text.len,
        .object => {
            need.height = @max(need.height, level);

            for (model.members[0..model.count]) |member| {
                need.node_count += 1;
                need.text_bytes += member.key.len + 2;
            }
        },
        .string => need.text_bytes += model.text.len + 2,
    }
}

fn check(state: *State, prng: *Prng, root: *Model) !void {
    assert(root.kind != .number or root.count == 0);
    assert(state.trees[0].node_count > 0);

    const random = prng.random();

    const options: Writer.Options = .{
        .indent = random.intRangeAtMost(u8, 1, 16),
        .layout = if (random.boolean()) .compact else .pretty,
        .non_finite = if (random.boolean()) .null_value else .refused,
        .notation = if (random.boolean()) .decimal else .ecmascript,
        .utf8 = random.enumValue(Writer.UTF8),
    };

    var sink: std.Io.Writer = .fixed(&state.output);

    try state.trees[0].write(&sink, options);

    if (state.trees[0].node_count >= tree_large_node_count) counted(state, .tree_large);

    const output = sink.buffered();
    const reparsed = &state.documents[1];

    const storage: storage_module.Storage = .{
        .records = state.records[1][0..@min(output.len, records_max)],
        .text = state.reparse_text[0..output.len],
    };

    try reparsed.parse(storage, output);

    try model_compare(state, reparsed, root);
    try fixpoint_check(state, output, &options);
    try copy_check(state, output, &options);
    try patch_check(state, prng, output, &options);
    try document_fuzz.pointers_check(Tree, &state.trees[0], prng, &state.pointers);
}

fn fixpoint_check(state: *State, output: []const u8, options: *const Writer.Options) !void {
    assert(output.len > 0);
    assert(state.documents[1].node_count > 0);

    var sink: std.Io.Writer = .fixed(&state.rewrite);

    try state.documents[1].write(&sink, options.*);

    if (!std.mem.eql(u8, output, sink.buffered())) return error.FixpointDisagreement;
}

fn copy_check(state: *State, output: []const u8, options: *const Writer.Options) !void {
    assert(output.len > 0);
    assert(state.documents[1].node_count > 0);

    const copy = &state.trees[1];
    const document = &state.documents[1];

    copy.init(state.storages[1].storage());

    try copy.replace(copy.root(), .{ .copy = .{ .document = document, .node = document.root() } });

    tree_module.audit(copy);

    var sink: std.Io.Writer = .fixed(&state.rewrite);

    try copy.write(&sink, options.*);

    if (!std.mem.eql(u8, output, sink.buffered())) return error.CopyDisagreement;
}

fn patch_check(
    state: *State,
    prng: *Prng,
    output: []const u8,
    options: *const Writer.Options,
) !void {
    assert(output.len > 0);
    assert(state.trees[1].node_count > 0);

    try patch_test_check(state, prng);
    try unchanged_check(state, output, options);

    try patch_added_check(state, prng, "add");
    try unchanged_check(state, output, options);

    try patch_added_check(state, prng, "copy");
    try unchanged_check(state, output, options);

    try patch_move_check(state, prng);
    try unchanged_check(state, output, options);

    try merge_check(state, prng);
}

fn unchanged_check(state: *State, output: []const u8, options: *const Writer.Options) !void {
    assert(output.len > 0);
    assert(state.trees[1].node_count > 0);

    tree_module.audit(&state.trees[1]);

    var sink: std.Io.Writer = .fixed(&state.rewrite);

    try state.trees[1].write(&sink, options.*);

    if (!std.mem.eql(u8, output, sink.buffered())) return error.PatchChanged;
}

fn patch_test_check(state: *State, prng: *Prng) !void {
    assert(state.trees[1].node_count > 0);
    assert(state.patch_pointers[0].len == patch_pointer_bytes_max);

    const tree = &state.trees[1];
    const target = patch_target_find(tree, prng, &state.patch_pointers[0], false) orelse return;
    const equal = prng.random().boolean();
    const value: PatchValue = if (equal) .{ .node = target.node } else .{ .unequal = target.node };

    const step: PatchStep = .{
        .from = null,
        .path = target.pointer,
        .value = value,
        .verb = "test",
    };

    if (!try operations_parse(state, &.{step})) return;

    var position: Position = .{ .column = 0, .line = 0 };
    const result = operations_apply(state, &position);

    if (equal) {
        try result;

        return counted(state, .patch_test_passed);
    }

    result catch |err| switch (err) {
        error.TestFailed => {
            if (!std.meta.eql(position, operation_position)) return error.DiagnosticPosition;
            return counted(state, .patch_test_failed);
        },
        else => return err,
    };

    return error.TestAccepted;
}

fn patch_added_check(state: *State, prng: *Prng, verb: []const u8) !void {
    assert(std.mem.eql(u8, verb, "add") or std.mem.eql(u8, verb, "copy"));
    assert(state.trees[1].node_count > 0);

    const tree = &state.trees[1];
    const pointers = &state.patch_pointers;
    const container = patch_target_find(tree, prng, &pointers[0], true) orelse return;
    const source = patch_target_find(tree, prng, &pointers[1], false) orelse unreachable;
    const fresh = fresh_paths(tree, prng, container, pointers) orelse return;
    const copy = std.mem.eql(u8, verb, "copy");

    const steps = [_]PatchStep{
        .{
            .from = if (copy) source.pointer else null,
            .path = fresh[0],
            .value = if (copy) .absent else .{ .node = source.node },
            .verb = verb,
        },
        .{ .from = null, .path = fresh[1], .value = .absent, .verb = "remove" },
    };

    if (!try operations_parse(state, &steps)) return;

    var position: Position = .{ .column = 0, .line = 0 };

    operations_apply(state, &position) catch |err| switch (err) {
        error.DepthExceeded, error.NodesExhausted, error.TextExhausted => {
            if (!std.meta.eql(position, operation_position)) return error.DiagnosticPosition;
            return counted(state, .patch_refused);
        },
        else => return err,
    };

    counted(state, if (copy) .patch_copied else .patch_added);
}

fn fresh_paths(
    tree: *const Tree,
    prng: *Prng,
    container: PatchTarget,
    pointers: *[3][patch_pointer_bytes_max]u8,
) ?[2][]const u8 {
    assert(container.pointer.len <= patch_pointer_bytes_max);
    assert(container.pointer.ptr == &pointers[0]);

    const random = prng.random();
    const length = container.pointer.len;

    @memcpy(pointers[2][0..length], container.pointer);

    if (tree.kind_of(container.node) == .array) {
        const count = tree.count_of(container.node);
        const index = random.uintAtMost(u32, count);
        const end = index == count and random.boolean();
        var digits: [16]u8 = undefined;
        const token = index_token(&digits, index);
        const added_token = if (end) "-" else token;
        const added = pointer_extend(&pointers[0], length, added_token) orelse return null;
        const removed = pointer_extend(&pointers[2], length, token) orelse return null;

        return .{ added, removed };
    }

    assert(tree.kind_of(container.node) == .object);

    const key = keys_fresh[random.uintLessThan(u32, keys_fresh.len)];
    if (tree.member(container.node, key) != null) return null;

    const added = pointer_extend(&pointers[0], length, key) orelse return null;
    const removed = pointer_extend(&pointers[2], length, key) orelse return null;

    return .{ added, removed };
}

fn patch_move_check(state: *State, prng: *Prng) !void {
    assert(state.trees[1].node_count > 0);
    assert(state.patch_pointers.len == 3);

    const tree = &state.trees[1];
    const pointers = &state.patch_pointers;
    const container = patch_target_find(tree, prng, &pointers[0], true) orelse return;
    const count = tree.count_of(container.node);
    const random = prng.random();

    if (count == 0) return;
    if (random.uintLessThan(u32, 4) == 0) return patch_malformed_check(state, container);
    if (tree.kind_of(container.node) != .array) return;
    if (count < 2) return;

    const first = random.uintLessThan(u32, count);
    const second = (first + 1 + random.uintLessThan(u32, count - 1)) % count;
    const length = container.pointer.len;

    @memcpy(pointers[2][0..length], container.pointer);

    var digits: [2][16]u8 = undefined;
    const tokens = [2][]const u8{ index_token(&digits[0], first), index_token(&digits[1], second) };
    const from = pointer_extend(&pointers[0], length, tokens[0]) orelse return;
    const path = pointer_extend(&pointers[2], length, tokens[1]) orelse return;

    const steps = [_]PatchStep{
        .{ .from = from, .path = path, .value = .absent, .verb = "move" },
        .{ .from = path, .path = from, .value = .absent, .verb = "move" },
    };

    if (!try operations_parse(state, &steps)) return;

    var position: Position = .{ .column = 0, .line = 0 };

    try operations_apply(state, &position);

    counted(state, .patch_moved);
}

fn patch_malformed_check(state: *State, container: PatchTarget) !void {
    assert(state.trees[1].count_of(container.node) > 0);
    assert(container.pointer.ptr == &state.patch_pointers[0]);

    const length = container.pointer.len;

    @memcpy(state.patch_pointers[2][0..length], container.pointer);

    const path = pointer_extend(&state.patch_pointers[2], length, "0") orelse return;

    const step: PatchStep = .{
        .from = container.pointer,
        .path = path,
        .value = .absent,
        .verb = "move",
    };

    if (!try operations_parse(state, &.{step})) return;

    var position: Position = .{ .column = 0, .line = 0 };

    operations_apply(state, &position) catch |err| switch (err) {
        error.PatchMalformed => {
            if (!std.meta.eql(position, operation_position)) return error.DiagnosticPosition;
            return counted(state, .patch_malformed);
        },
        else => return err,
    };

    return error.MoveAccepted;
}

fn merge_check(state: *State, prng: *Prng) !void {
    assert(state.trees[1].node_count > 0);
    assert(state.documents[1].node_count > 0);

    const tree = &state.trees[1];
    const document = &state.documents[1];
    const pointer = &state.patch_pointers[0];
    const target = patch_target_find(tree, prng, pointer, false) orelse unreachable;
    const changes = changes_find(document, prng);

    tree.merge_patch(target.node, document, changes) catch return merge_refusal(state);
    tree_module.audit(tree);

    try merged_check(tree, target.node, document, changes);

    const repeated = keys_repeated(document);

    if (repeated) {
        tree.merge_patch(target.node, document, changes) catch return merge_refusal(state);
        tree_module.audit(tree);
    }

    const before = try written_tree(tree, &state.rewrite);

    tree.merge_patch(target.node, document, changes) catch return merge_refusal(state);
    tree_module.audit(tree);

    const after = try written_tree(tree, &state.merged);
    if (!std.mem.eql(u8, before, after)) return error.MergeUnstable;

    counted(state, if (repeated) .merge_settled else .merge_idempotent);
}

fn merge_refusal(state: *State) void {
    assert(state.trees[1].node_count > 0);
    assert(state.trees[1].node_count <= state.trees[1].records.len);

    tree_module.audit(&state.trees[1]);
    counted(state, .merge_refused);
}

fn keys_repeated(document: *const Document) bool {
    assert(document.node_count > 0);
    assert(document.node_count <= records_max);

    for (0..document.node_count) |index| {
        const object: DocumentNode = @fromBackingInt(@as(u32, @intCast(index)));
        if (document.kind_of(object) != .object) continue;

        var entries = document.entries(object);

        for (0..document.count_of(object)) |_| {
            const entry = entries.next() orelse unreachable;
            const last = document.member(object, document.text_of(entry.key).?) orelse unreachable;
            if (last != entry.value) return true;
        }
    }

    return false;
}

fn merged_check(
    tree: *const Tree,
    target: Tree.Node,
    document: *const Document,
    changes: DocumentNode,
) !void {
    assert(@backingInt(target) < tree.node_count);
    assert(@backingInt(changes) < document.node_count);

    if (document.kind_of(changes) != .object) {
        return merged_value_check(tree, target, document, changes);
    }

    if (tree.kind_of(target) != .object) return error.MergeKind;

    var entries = document.entries(changes);

    for (0..document.count_of(changes)) |_| {
        const entry = entries.next() orelse return error.EntryMissing;
        const key = document.text_of(entry.key).?;
        const value = document.member(changes, key) orelse return error.MemberMissing;
        const member = tree.member(target, key);

        if (document.kind_of(value) == .null_value) {
            if (member != null) return error.MergeKept;
        } else {
            const node = member orelse return error.MergeDropped;

            if (document.kind_of(value) == .object) {
                if (tree.kind_of(node) != .object) return error.MergeKind;
            } else {
                try merged_value_check(tree, node, document, value);
            }
        }
    }
}

fn merged_value_check(
    tree: *const Tree,
    node: Tree.Node,
    document: *const Document,
    value: DocumentNode,
) !void {
    assert(@backingInt(node) < tree.node_count);
    assert(document.kind_of(value) != .object);

    const kind = document.kind_of(value);
    if (tree.kind_of(node) != kind) return error.MergeKind;

    const equal = switch (kind) {
        .array => tree.count_of(node) == document.count_of(value),
        .boolean => tree.boolean_of(node) == document.boolean_of(value),
        .null_value => true,
        .number => std.mem.eql(u8, tree_module.number_text(tree, node), document.source_of(value)),
        .object => unreachable,
        .string => std.mem.eql(u8, tree.text_of(node).?, document.text_of(value).?),
    };

    if (!equal) return error.MergeValue;
}

fn changes_find(document: *const Document, prng: *Prng) DocumentNode {
    assert(document.node_count > 0);
    assert(document.node_count <= records_max);

    const random = prng.random();
    const start = random.uintLessThan(u32, document.node_count);
    if (random.uintLessThan(u32, 4) == 0) return @fromBackingInt(start);

    for (0..document.node_count) |offset| {
        const index: u32 = @intCast((start + offset) % document.node_count);
        if (document.kind_of(@fromBackingInt(index)) == .object) return @fromBackingInt(index);
    }

    return @fromBackingInt(start);
}

fn written_tree(tree: *const Tree, buffer: []u8) ![]const u8 {
    assert(tree.node_count > 0);
    assert(buffer.len == output_bytes_max);

    var sink: std.Io.Writer = .fixed(buffer);

    try tree.write(&sink, operations_options);

    return sink.buffered();
}

fn patch_target_find(
    tree: *const Tree,
    prng: *Prng,
    buffer: *[patch_pointer_bytes_max]u8,
    containers: bool,
) ?PatchTarget {
    assert(tree.node_count > 0);
    assert(buffer.len == patch_pointer_bytes_max);

    const random = prng.random();
    var parent: ?PatchTarget = null;
    var target: PatchTarget = .{ .node = tree.root(), .pointer = buffer[0..0] };

    for (0..walk_depth_max) |_| {
        const count = tree.count_of(target.node);
        if (count == 0) break;
        if (random.uintLessThan(u32, 3) == 0) break;

        const position = random.uintLessThan(u32, count);
        const step = patch_step(tree, target, buffer, position) orelse break;

        parent = target;
        target = step;
    }

    if (!containers) return target;

    return switch (tree.kind_of(target.node)) {
        .array, .object => target,
        .boolean, .null_value, .number, .string => parent,
    };
}

fn patch_step(
    tree: *const Tree,
    target: PatchTarget,
    buffer: *[patch_pointer_bytes_max]u8,
    position: u32,
) ?PatchTarget {
    assert(position < tree.count_of(target.node));
    assert(target.pointer.len <= buffer.len);

    const length = target.pointer.len;

    if (tree.kind_of(target.node) == .array) {
        var digits: [16]u8 = undefined;
        const token = index_token(&digits, position);
        const pointer = pointer_extend(buffer, length, token) orelse return null;

        return .{ .node = tree.item(target.node, position) orelse unreachable, .pointer = pointer };
    }

    var entries = tree.entries(target.node);
    var key: []const u8 = "";

    for (0..position + 1) |_| {
        const entry = entries.next() orelse unreachable;

        key = tree.text_of(entry.key).?;
    }

    const pointer = pointer_extend(buffer, length, key) orelse return null;
    return .{ .node = tree.member(target.node, key) orelse unreachable, .pointer = pointer };
}

fn pointer_extend(
    buffer: *[patch_pointer_bytes_max]u8,
    length: usize,
    token: []const u8,
) ?[]const u8 {
    assert(length <= buffer.len);
    assert(token.len <= input_bytes_max);

    if (length + 1 + 2 * token.len > buffer.len) return null;

    var cursor = length + 1;

    buffer[length] = '/';

    for (token) |byte| {
        const escaped: []const u8 = switch (byte) {
            '/' => "~1",
            '~' => "~0",
            else => &.{byte},
        };

        @memcpy(buffer[cursor..][0..escaped.len], escaped);
        cursor += escaped.len;
    }

    assert(cursor <= buffer.len);

    return buffer[0..cursor];
}

fn index_token(digits: *[16]u8, index: u32) []const u8 {
    assert(digits.len > 10);
    assert(index < std.math.maxInt(u32));

    const length = std.fmt.printInt(digits, index, 10, .lower, .{
        .alignment = .right,
        .fill = ' ',
        .precision = null,
        .width = null,
    });

    assert(length > 0);

    return digits[0..length];
}

fn operations_parse(state: *State, steps: []const PatchStep) !bool {
    assert(steps.len > 0);
    assert(steps.len <= 2);

    var sink: std.Io.Writer = .fixed(&state.operations_source);
    var writer: Writer = .init(&sink, operations_options);

    operations_write(&state.trees[1], &writer, steps) catch |err| switch (err) {
        error.DepthExceeded, error.WriteFailed => return false,
    };

    writer.finish();

    const storage: storage_module.Storage = .{
        .records = &state.operations_records,
        .text = &state.operations_text,
    };

    state.operations.parse(storage, sink.buffered()) catch |err| switch (err) {
        error.DepthExceeded, error.NodesExhausted, error.TextExhausted => return false,
        error.Malformed => return error.OperationsMalformed,
    };

    return true;
}

fn operations_write(
    tree: *const Tree,
    writer: *Writer,
    steps: []const PatchStep,
) (Writer.CapacityError || std.Io.Writer.Error)!void {
    assert(steps.len > 0);
    assert(tree.node_count > 0);

    try writer.array_begin();

    for (steps) |*step| {
        try writer.object_begin();
        try writer.key("op");
        try writer.string(step.verb);

        if (step.from) |from| {
            try writer.key("from");
            try writer.string(from);
        }

        try writer.key("path");
        try writer.string(step.path);

        switch (step.value) {
            .absent => {},
            .node => |node| {
                try writer.key("value");
                try tree.node_write(writer, node);
            },
            .unequal => |node| {
                try writer.key("value");

                if (tree.kind_of(node) == .null_value) {
                    try writer.boolean(false);
                } else {
                    try writer.null_value();
                }
            },
        }

        try writer.object_end();
    }

    try writer.array_end();
}

fn operations_apply(state: *State, position: *Position) PatchError!void {
    assert(state.operations.node_count > 0);
    assert(state.trees[1].node_count > 0);

    const operations = &state.operations;
    const result = state.trees[1].patch(operations, operations.root(), .{ .diagnostic = position });

    tree_module.audit(&state.trees[1]);

    return result;
}

fn model_compare(state: *State, document: *const Document, root: *Model) !void {
    assert(document.node_count > 0);
    assert(document.node_count <= state.pairs.len);

    state.pairs[0] = .{ .model = root, .node = document.root() };

    var count: u32 = 1;

    for (0..document.node_count + 1) |_| {
        if (count == 0) return;

        count -= 1;

        const pair = state.pairs[count];

        try pair_compare(state, document, pair, &count);
    }

    return error.WalkUnbounded;
}

fn pair_compare(state: *State, document: *const Document, pair: Pair, count: *u32) !void {
    assert(@backingInt(pair.node) < document.node_count);
    assert(count.* < state.pairs.len);

    const model = pair.model;
    const kind = document.kind_of(pair.node);

    switch (model.kind) {
        .array, .object => try container_compare(state, document, pair, count),
        .false_value => if (document.boolean_of(pair.node) != false) return error.ModelDisagreement,
        .null_value => if (kind != .null_value) return error.ModelDisagreement,
        .number => try number_compare(document, pair.node, model),
        .string => {
            if (kind != .string) return error.ModelDisagreement;

            if (!std.mem.eql(u8, model.text, document.text_of(pair.node).?)) {
                return error.StringDisagreement;
            }
        },
        .true_value => if (document.boolean_of(pair.node) != true) return error.ModelDisagreement,
    }
}

fn container_compare(state: *State, document: *const Document, pair: Pair, count: *u32) !void {
    assert(pair.model.kind == .array or pair.model.kind == .object);
    assert(count.* < state.pairs.len);

    const model = pair.model;
    const expected: Document.Kind = if (model.kind == .array) .array else .object;
    if (document.kind_of(pair.node) != expected) return error.ModelDisagreement;
    if (document.count_of(pair.node) != model.count) return error.CountDisagreement;

    var entries = document.entries(pair.node);
    var items = document.items(pair.node);

    for (model.members[0..model.count]) |member| {
        const child = if (expected == .object) entry: {
            const entry = entries.next() orelse return error.EntryMissing;

            if (!std.mem.eql(u8, member.key, document.text_of(entry.key).?)) {
                return error.KeyDisagreement;
            }

            break :entry entry.value;
        } else items.next() orelse return error.ItemMissing;

        state.pairs[count.*] = .{ .model = member.value, .node = child };
        count.* += 1;
    }
}

fn number_compare(document: *const Document, node: DocumentNode, model: *const Model) !void {
    assert(model.kind == .number);
    assert(@backingInt(node) < document.node_count);

    const kind = document.kind_of(node);

    if (model.float) |value| {
        if (!std.math.isFinite(value)) {
            if (kind != .null_value) return error.NonFiniteWritten;
            return;
        }

        const parsed = try std.fmt.parseFloat(f64, document.source_of(node));
        if (@as(u64, @bitCast(parsed)) != @as(u64, @bitCast(value))) return error.FloatDisagreement;
        return;
    }

    if (number_module.non_finite_is(model.text)) {
        if (kind != .null_value) return error.NonFiniteWritten;
        return;
    }

    if (kind != .number) return error.ModelDisagreement;
    if (!std.mem.eql(u8, model.text, document.source_of(node))) return error.NumberDisagreement;
}
