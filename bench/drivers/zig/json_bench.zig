const std = @import("std");

const harness = @import("harness.zig");
const json = @import("json");
const models = @import("models.zig");

const assert = std.debug.assert;

const Fnv = harness.Fnv;

const decode_options: json.DecodeOptions = .{ .diagnostic = null, .unknown_members = .ignored };
const encode_options: json.EncodeOptions = .{ .null_members = .emitted };
const file_bytes_max: u32 = 1 << 30;
const output_bytes_min: u32 = 16 << 20;
const region_bytes_min: u32 = 1 << 20;

const std_parse_options: std.json.ParseOptions = .{
    .allocate = .alloc_if_needed,
    .duplicate_field_behavior = .@"error",
    .ignore_unknown_fields = true,
    .max_value_len = null,
    .parse_numbers = true,
};

const std_stringify_options: std.json.Stringify.Options = .{
    .emit_nonportable_numbers_as_strings = false,
    .emit_null_optional_fields = true,
    .emit_strings_as_arrays = false,
    .escape_unicode = false,
    .whitespace = .minified,
};

const writer_options: json.Writer.Options = .{
    .indent = 4,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

comptime {
    assert(file_bytes_max <= json.limits.input_bytes_max);
    assert(output_bytes_min >= region_bytes_min);
}

const Mode = enum {
    decode_canada,
    decode_twitter,
    document,
    encode_canada,
    encode_twitter,
    std_decode_canada,
    std_decode_twitter,
    std_document,
    std_encode_canada,
    std_encode_twitter,
    std_tokenize,
    std_write_document,
    tokenize,
    write_document,
};

const Workload = struct {
    arena: std.heap.ArenaAllocator,
    canada: models.Canada,
    document: *json.Document,
    input: []const u8,
    mode: Mode,
    output: []u8,
    output_length: u64,
    region: json.Region,
    state: u64,
    std_value: std.json.Value,
    storage: json.Storage,
    twitter: models.Twitter,

    pub fn prepare(workload: *Workload) void {
        assert(workload.input.len > 0);
        assert(workload.region.used <= workload.region.top);

        switch (workload.mode) {
            .decode_canada, .decode_twitter => workload.region.reset(),
            .std_decode_canada, .std_decode_twitter, .std_document, .std_tokenize => {
                _ = workload.arena.reset(.retain_capacity);
            },
            .document,
            .encode_canada,
            .encode_twitter,
            .std_encode_canada,
            .std_encode_twitter,
            .std_write_document,
            .tokenize,
            .write_document,
            => {},
        }
    }

    pub fn run(workload: *Workload) !u64 {
        assert(workload.input.len > 0);
        assert(workload.output.len >= output_bytes_min);

        workload.state = switch (workload.mode) {
            .decode_canada => try workload.decode_run(models.Canada, &workload.canada),
            .decode_twitter => try workload.decode_run(models.Twitter, &workload.twitter),
            .document => try workload.document_run(),
            .encode_canada => try workload.encode_run(models.Canada, &workload.canada),
            .encode_twitter => try workload.encode_run(models.Twitter, &workload.twitter),
            .std_decode_canada => try workload.std_decode_run(models.Canada, &workload.canada),
            .std_decode_twitter => try workload.std_decode_run(models.Twitter, &workload.twitter),
            .std_document => try workload.std_decode_run(std.json.Value, &workload.std_value),
            .std_encode_canada => try workload.std_encode_run(models.Canada, &workload.canada),
            .std_encode_twitter => try workload.std_encode_run(models.Twitter, &workload.twitter),
            .std_tokenize => try std_tokens_count(workload.arena.allocator(), workload.input),
            .std_write_document => try workload.std_encode_run(std.json.Value, &workload.std_value),
            .tokenize => try tokens_count(workload.input),
            .write_document => try workload.write_run(),
        };

        return workload.state;
    }

    pub fn checksum(workload: *const Workload, gpa: std.mem.Allocator, buffer: []u8) ![]const u8 {
        assert(buffer.len >= 32);
        assert(workload.input.len > 0);

        var fnv: Fnv = .{};

        switch (workload.mode) {
            .decode_canada, .std_decode_canada => models.canada_feed(&fnv, &workload.canada),
            .decode_twitter, .std_decode_twitter => models.twitter_feed(&fnv, &workload.twitter),
            .document, .std_tokenize, .tokenize => {
                return std.mem.print(buffer, "{d}", .{workload.state});
            },
            .encode_canada, .encode_twitter, .std_encode_canada, .std_encode_twitter => {
                return std.mem.print(buffer, "{d}", .{workload.output_length});
            },
            .std_document => {
                const count = try std_value_count(gpa, &workload.std_value, workload.input);

                return std.mem.print(buffer, "{d}", .{count});
            },
            .std_write_document, .write_document => {
                return std.mem.print(buffer, "{d}", .{workload.output_length});
            },
        }

        return std.mem.print(buffer, "{x:0>16}", .{fnv.state});
    }

    fn decode_run(workload: *Workload, comptime T: type, target: *T) !u64 {
        assert(workload.region.used <= workload.region.top);
        assert(workload.input.len <= json.limits.input_bytes_max);

        try json.decode(T, &workload.region, workload.input, target, decode_options);

        return workload.region.used;
    }

    fn document_run(workload: *Workload) !u64 {
        assert(workload.storage.records.len >= workload.input.len);
        assert(workload.storage.text.len >= workload.input.len);

        try workload.document.parse(workload.storage, workload.input);

        return workload.document.node_count;
    }

    fn encode_run(workload: *Workload, comptime T: type, value: *const T) !u64 {
        assert(workload.output.len >= output_bytes_min);
        assert(workload.input.len > 0);

        var sink: std.Io.Writer = .fixed(workload.output);
        var writer: json.Writer = .init(&sink, writer_options);

        try json.encode(T, &writer, value, encode_options);

        workload.output_length = sink.end;

        return sink.end;
    }

    fn std_decode_run(workload: *Workload, comptime T: type, target: *T) !u64 {
        assert(workload.input.len > 0);
        assert(workload.input.len <= file_bytes_max);

        target.* = try std.json.parseFromSliceLeaky(
            T,
            workload.arena.allocator(),
            workload.input,
            std_parse_options,
        );

        return workload.arena.queryCapacity();
    }

    fn std_encode_run(workload: *Workload, comptime T: type, value: *const T) !u64 {
        assert(workload.output.len >= output_bytes_min);
        assert(workload.input.len > 0);

        var sink: std.Io.Writer = .fixed(workload.output);

        try std.json.Stringify.value(value.*, std_stringify_options, &sink);

        workload.output_length = sink.end;

        return sink.end;
    }

    fn write_run(workload: *Workload) !u64 {
        assert(workload.document.node_count > 0);
        assert(workload.output.len >= output_bytes_min);

        var sink: std.Io.Writer = .fixed(workload.output);

        try workload.document.write(&sink, writer_options);

        workload.output_length = sink.end;

        return sink.end;
    }
};

pub fn main(init: std.process.Init) !void {
    assert(init.environ_map.count() < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    assert(arguments.len < std.math.maxInt(u32));

    if (arguments.len < 3) return error.Usage;

    const gpa = std.heap.page_allocator;
    const mode = std.meta.stringToEnum(Mode, arguments[1]) orelse return error.Usage;
    const time_ns_min = try harness.time_ns_min_of(arguments[3..]);
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[2], gpa, limit);

    if (input.len == 0) return error.InputEmpty;

    var workload = try workload_create(gpa, mode, input);
    const bytes = try workload_prepare(&workload);
    const samples = try gpa.alloc(u64, harness.run_count_max);
    const sample = try harness.measure(Workload, init.io, &workload, samples, time_ns_min);

    var checksum_buffer: [128]u8 = undefined;
    const checksum = try workload.checksum(gpa, &checksum_buffer);

    assert(checksum.len > 0);

    try harness.report(init.io, bytes, sample, checksum);
}

fn std_tokens_count(allocator: std.mem.Allocator, input: []const u8) !u64 {
    assert(input.len > 0);
    assert(input.len <= file_bytes_max);

    var scanner: std.json.Scanner = .initCompleteInput(allocator, input);
    defer scanner.deinit();

    var count: u64 = 0;

    for (0..input.len + 2) |_| {
        switch (try scanner.next()) {
            .end_of_document => return count,
            .array_begin, .false, .null, .number, .object_begin, .string, .true => count += 1,
            else => {},
        }
    }

    unreachable;
}

fn std_value_count(gpa: std.mem.Allocator, root: *const std.json.Value, input: []const u8) !u64 {
    assert(input.len > 0);
    assert(input.len <= file_bytes_max);

    var stack: std.ArrayList(*const std.json.Value) = .empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, root);

    var count: u64 = 0;

    for (0..input.len + 1) |_| {
        const value = stack.pop() orelse return count;

        count += 1;

        switch (value.*) {
            .array => |array| for (array.items) |*item| try stack.append(gpa, item),
            .object => |object| {
                count += object.count();

                for (object.values()) |*item| try stack.append(gpa, item);
            },
            .bool, .float, .integer, .null, .number_string, .string => {},
        }
    }

    unreachable;
}

fn tokens_count(input: []const u8) !u64 {
    assert(input.len > 0);
    assert(input.len <= json.limits.input_bytes_max);

    var tokenizer: json.Tokenizer = .init(input);
    var count: u64 = 0;

    for (0..input.len + 2) |_| {
        switch (try tokenizer.next()) {
            .end => return count,
            .array_end, .object_end => {},
            else => count += 1,
        }
    }

    unreachable;
}

fn workload_create(gpa: std.mem.Allocator, mode: Mode, input: []const u8) !Workload {
    assert(input.len > 0);
    assert(input.len <= file_bytes_max);

    const input_length: u32 = @intCast(input.len);
    const region_buffer = try gpa.alloc(u8, @max(4 * input.len, region_bytes_min));
    const output = try gpa.alloc(u8, @max(8 * input.len, output_bytes_min));

    const storage: json.Storage = try .init(gpa, .{
        .node_count_max = input_length,
        .text_bytes_max = input_length,
    });

    return .{
        .arena = .init(gpa),
        .canada = .{},
        .document = try gpa.create(json.Document),
        .input = input,
        .mode = mode,
        .output = output,
        .output_length = 0,
        .region = .init(region_buffer),
        .state = 0,
        .std_value = .null,
        .storage = storage,
        .twitter = .{},
    };
}

fn workload_prepare(workload: *Workload) !u64 {
    assert(workload.input.len > 0);
    assert(workload.output_length == 0);

    switch (workload.mode) {
        .encode_canada, .std_encode_canada => {
            _ = try workload.decode_run(models.Canada, &workload.canada);

            return workload.run();
        },
        .encode_twitter, .std_encode_twitter => {
            _ = try workload.decode_run(models.Twitter, &workload.twitter);

            return workload.run();
        },
        .std_write_document => {
            _ = try workload.std_decode_run(std.json.Value, &workload.std_value);

            return workload.run();
        },
        .write_document => {
            _ = try workload.document_run();

            return workload.run();
        },
        else => return workload.input.len,
    }
}
