const std = @import("std");

const document_module = @import("document.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

pub const link_kind_shift: u5 = 29;
pub const link_target_mask: u32 = (1 << link_kind_shift) - 1;
pub const node_count_limit: u32 = link_target_mask;
pub const text_bytes_limit: u32 = link_target_mask;

comptime {
    assert(@sizeOf(Record) == 16);
    assert(@bitSizeOf(Record.Kind) + @as(u32, link_kind_shift) == 32);
    assert(node_count_limit < tokenizer_module.input_bytes_max);
    assert(text_bytes_limit < tokenizer_module.input_bytes_max);
}

pub const Capacity = struct {
    node_count_max: u32,
    text_bytes_max: u32,
};

pub const Record = struct {
    end: u32,
    link: u32,
    size: u32,
    start: u32,

    pub const Kind = enum(u3) {
        null_value,
        false_value,
        true_value,
        number,
        string,
        string_escaped,
        array,
        object,
    };

    pub fn kind(record: *const Record) Kind {
        assert(record.start < record.end);
        assert(record.end <= tokenizer_module.input_bytes_max);

        const result: Kind = @fromBackingInt(@as(u3, @intCast(record.link >> link_kind_shift)));

        if (result == .string_escaped) assert(record.size > 0);

        return result;
    }

    pub fn target(record: *const Record) u32 {
        assert(record.start < record.end);
        assert(record.end <= tokenizer_module.input_bytes_max);

        const result = record.link & link_target_mask;

        assert(result <= link_target_mask);

        return result;
    }
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

pub fn link_of(kind: Record.Kind, target: u32) u32 {
    assert(target <= link_target_mask);
    assert(@backingInt(kind) <= @backingInt(Record.Kind.object));

    const result = @as(u32, @backingInt(kind)) << link_kind_shift | target;

    assert(result & link_target_mask == target);

    return result;
}

const testing = std.testing;

test "a link packs the kind above the target and unpacks to both" {
    for (std.enums.values(Record.Kind)) |kind| {
        for ([_]u32{ 0, 1, 4096, link_target_mask }) |target| {
            const link = link_of(kind, target);
            const size: u32 = if (kind == .string_escaped) 1 else 0;
            const record: Record = .{ .end = 2, .link = link, .size = size, .start = 0 };

            try testing.expectEqual(kind, record.kind());
            try testing.expectEqual(target, record.target());
        }
    }
}

test Storage {
    var storage: Storage = try .init(testing.allocator, .{
        .node_count_max = 64,
        .text_bytes_max = 256,
    });

    defer storage.deinit(testing.allocator);

    const document = try testing.allocator.create(document_module.Document);
    defer testing.allocator.destroy(document);

    try document.parse(storage, "{\"name\": \"caf\\u00e9\", \"ports\": [80, 443]}");

    const name = document.member(document.root(), "name") orelse return error.NameMissing;

    try testing.expectEqualStrings("caf\u{e9}", document.text_of(name).?);
    try testing.expectEqual(@as(usize, 64), storage.records.len);
}

test StorageType {
    const Fixed = StorageType(.{ .node_count_max = 16, .text_bytes_max = 0 });
    const fixed = try testing.allocator.create(Fixed);
    defer testing.allocator.destroy(fixed);

    const document = try testing.allocator.create(document_module.Document);
    defer testing.allocator.destroy(document);

    try document.parse(fixed.storage(), "[true, null, 1.5]");

    try testing.expectEqual(@as(u32, 3), document.count_of(document.root()));
    try testing.expectError(error.TextExhausted, document.parse(fixed.storage(), "[\"\\n\"]"));
}
