const std = @import("std");

const document_module = @import("document.zig");
const storage_module = @import("storage.zig");
const structural = @import("structural.zig");
const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const Indexer = structural.Indexer;
const Storage = storage_module.Storage;

const exit_failure: u8 = 1;
const exit_success: u8 = 0;
const file_bytes_max: u32 = 64 * 1024 * 1024;
const run_count: u32 = 400;
const sample_bytes_min: u32 = 256 * 1024;
const usage_text = "usage: zig build bench -Doptimize=fast -- <file.json>...";

comptime {
    assert(run_count >= 3);
    assert(file_bytes_max <= tokenizer_module.input_bytes_max);
}

const Bench = struct {
    documents: *[2]Document,
    repeat_count: u32,
    source: []const u8,
    storages: [2]Storage,
    times: []u64,
};

const Phase = enum {
    document,
    indexer,
    scalar,
    tokenizer,
};

const Sample = struct {
    best: u64,
    median: u64,
};

pub fn main(init: std.process.Init) u8 {
    assert(init.environ_map.count() < std.math.maxInt(u32));

    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        return failed("the arguments could not be read");
    };

    assert(arguments.len < std.math.maxInt(u32));

    if (arguments.len < 2) return failed(usage_text);

    for (arguments[1..]) |path| {
        file_bench(init.io, init.gpa, path) catch |err| {
            std.debug.print("bench: {s}: {t}\n", .{ path, err });

            return exit_failure;
        };
    }

    return exit_success;
}

fn failed(text: []const u8) u8 {
    assert(text.len > 0);

    std.debug.print("bench: {s}\n", .{text});

    return exit_failure;
}

fn file_bench(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    assert(path.len > 0);
    assert(run_count > 0);

    const limit: std.Io.Limit = .limited(file_bytes_max);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
    defer gpa.free(source);

    const capacity: storage_module.Capacity = .{
        .node_count_max = @intCast(@max(source.len, 1)),
        .text_bytes_max = @intCast(source.len),
    };

    var storage_fast = try Storage.init(gpa, capacity);
    defer storage_fast.deinit(gpa);

    var storage_exact = try Storage.init(gpa, capacity);
    defer storage_exact.deinit(gpa);

    const documents = try gpa.create([2]Document);
    defer gpa.destroy(documents);

    const times = try gpa.alloc(u64, run_count);
    defer gpa.free(times);

    const bench: Bench = .{
        .documents = documents,
        .repeat_count = @intCast(@max(1, @divFloor(sample_bytes_min, @max(source.len, 1)))),
        .source = source,
        .storages = .{ storage_fast, storage_exact },
        .times = times,
    };

    try paths_agree(&bench);
    try phases_print(io, &bench, std.Io.Dir.path.basename(path));
}

fn paths_agree(bench: *const Bench) !void {
    assert(bench.storages[0].records.len >= bench.source.len);
    assert(bench.storages[1].records.len == bench.storages[0].records.len);

    const fast = &bench.documents[0];
    const exact = &bench.documents[1];

    try fast.parse(bench.storages[0], bench.source);
    try document_module.parse_exact(exact, bench.storages[1], bench.source);

    const records_fast = std.mem.sliceAsBytes(bench.storages[0].records[0..fast.node_count]);
    const records_exact = std.mem.sliceAsBytes(bench.storages[1].records[0..exact.node_count]);
    const text_fast = bench.storages[0].text[0..fast.text_count];
    const text_exact = bench.storages[1].text[0..exact.text_count];

    if (!std.mem.eql(u8, records_fast, records_exact)) return error.RecordsDisagree;
    if (!std.mem.eql(u8, text_fast, text_exact)) return error.TextDisagrees;

    if (!document_module.parse_attempt(.scalar, fast, bench.storages[0], bench.source)) {
        return error.ScalarRefused;
    }

    const records_scalar = std.mem.sliceAsBytes(bench.storages[0].records[0..fast.node_count]);
    const text_scalar = bench.storages[0].text[0..fast.text_count];

    if (!std.mem.eql(u8, records_scalar, records_exact)) return error.ScalarRecordsDisagree;
    if (!std.mem.eql(u8, text_scalar, text_exact)) return error.ScalarTextDisagrees;
}

fn phases_print(io: std.Io, bench: *const Bench, name: []const u8) !void {
    assert(name.len > 0);
    assert(bench.times.len == run_count);

    const bytes: f64 = @floatFromInt(bench.source.len * bench.repeat_count);

    for (std.enums.values(Phase)) |phase| {
        const sample = try phase_measure(io, bench, phase);
        const best: f64 = bytes / @as(f64, @floatFromInt(sample.best));
        const median: f64 = bytes / @as(f64, @floatFromInt(sample.median));

        std.debug.print("{s:<20} {t:<10} best {d:>6.2} GB/s  median {d:>6.2} GB/s\n", .{
            name,
            phase,
            best,
            median,
        });
    }
}

fn phase_measure(io: std.Io, bench: *const Bench, phase: Phase) !Sample {
    assert(bench.times.len == run_count);
    assert(bench.source.len <= file_bytes_max);

    for (bench.times) |*time| {
        const start = std.Io.Clock.Timestamp.now(io, .awake);

        for (0..bench.repeat_count) |_| try phase_run(bench, phase);

        const elapsed = start.untilNow(io).raw.nanoseconds;

        time.* = @intCast(@max(elapsed, 1));
    }

    std.mem.sortUnstable(u64, bench.times, {}, std.sort.asc(u64));

    const result: Sample = .{
        .best = bench.times[0],
        .median = bench.times[@divFloor(bench.times.len, 2)],
    };

    assert(result.best <= result.median);
    assert(result.best > 0);

    return result;
}

fn phase_run(bench: *const Bench, phase: Phase) !void {
    assert(bench.repeat_count > 0);
    assert(bench.source.len <= file_bytes_max);

    const document = &bench.documents[0];

    switch (phase) {
        .document => {
            try document.parse(bench.storages[0], bench.source);

            std.mem.doNotOptimizeAway(document.node_count);
        },
        .scalar => {
            const storage = bench.storages[0];

            if (!document_module.parse_attempt(.scalar, document, storage, bench.source)) {
                return error.ScalarRefused;
            }

            std.mem.doNotOptimizeAway(document.node_count);
        },
        .indexer => {
            std.mem.doNotOptimizeAway(structurals_count(bench.source, &document.indices));
        },
        .tokenizer => std.mem.doNotOptimizeAway(try events_count(document, bench.source)),
    }
}

fn events_count(document: *Document, source: []const u8) !u32 {
    assert(source.len <= file_bytes_max);
    assert(document.tokenizer.events.len > 0);

    const tokenizer = &document.tokenizer;

    tokenizer_module.tokenizer_reset(.strict, tokenizer, source);

    var count: u32 = 0;

    for (0..source.len + 2) |_| {
        const events = try tokenizer_module.events_take(.strict, tokenizer);

        count += @intCast(events.len);

        if (events[events.len - 1].kind == .end) return count;
    }

    unreachable;
}

fn structurals_count(source: []const u8, indices: *structural.Indices) u32 {
    assert(source.len <= file_bytes_max);
    assert(indices.len == structural.index_capacity);

    var indexer: Indexer = .empty;
    var count: u32 = 0;

    for (0..@divFloor(source.len, structural.block_bytes) + 2) |_| {
        const result = indexer.fill(source, indices, 0);

        count += result.count;

        if (result.status != .ready) return count;
    }

    unreachable;
}
