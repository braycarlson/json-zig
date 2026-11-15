const std = @import("std");

const assert = std.debug.assert;

pub const checksum_bytes_max: u32 = 64;
pub const run_count_max: u32 = 1_000_000;
pub const run_count_min: u32 = 20;
pub const time_ms_min_default: u64 = 1_000;
pub const time_ms_min_max: u64 = 60_000;
pub const warmup_count: u32 = 3;

comptime {
    assert(run_count_min > 1);
    assert(run_count_min < run_count_max);
    assert(time_ms_min_default > 0);
    assert(time_ms_min_default <= time_ms_min_max);
    assert(warmup_count > 0);
}

pub const Fnv = struct {
    state: u64 = 0xcbf29ce484222325,

    pub fn boolean(fnv: *Fnv, value: bool) void {
        fnv.byte(@intFromBool(value));
    }

    pub fn byte(fnv: *Fnv, value: u8) void {
        fnv.state ^= value;
        fnv.state *%= 0x100000001b3;
    }

    pub fn integer(fnv: *Fnv, value: u64) void {
        assert(@clz(value | 1) < 64);

        var bytes: [8]u8 = undefined;

        std.mem.writeInt(u64, &bytes, value, .little);

        for (bytes) |item| fnv.byte(item);
    }

    pub fn text(fnv: *Fnv, value: []const u8) void {
        assert(value.len < std.math.maxInt(u32));

        fnv.integer(value.len);

        for (value) |item| fnv.byte(item);
    }
};

pub const Sample = struct {
    best_ns: u64,
    median_ns: u64,
    run_count: u32,
};

pub fn measure(
    comptime Workload: type,
    io: std.Io,
    workload: *Workload,
    samples: []u64,
    time_ns_min: u64,
) !Sample {
    assert(samples.len == run_count_max);
    assert(time_ns_min > 0);
    assert(time_ns_min <= time_ms_min_max * std.time.ns_per_ms);
    assert(@hasDecl(Workload, "prepare"));
    assert(@hasDecl(Workload, "run"));

    for (0..warmup_count) |_| {
        workload.prepare();
        std.mem.doNotOptimizeAway(try workload.run());
    }

    var count: u32 = 0;
    var time_ns_total: u64 = 0;

    while (count < run_count_max) : (count += 1) {
        if (count >= run_count_min) {
            if (time_ns_total >= time_ns_min) break;
        }

        workload.prepare();

        const start = std.Io.Timestamp.now(io, .awake);
        const live = try workload.run();
        const end = std.Io.Timestamp.now(io, .awake);

        std.mem.doNotOptimizeAway(live);

        const elapsed_ns: u64 = @intCast(start.durationTo(end).nanoseconds);

        samples[count] = elapsed_ns;
        time_ns_total += elapsed_ns;
    }

    assert(count >= run_count_min);
    if (count < run_count_max) assert(time_ns_total >= time_ns_min);

    const taken = samples[0..count];

    std.mem.sortUnstable(u64, taken, {}, std.sort.asc(u64));
    assert(taken[0] <= taken[count - 1]);

    return .{ .best_ns = taken[0], .median_ns = taken[@divFloor(count, 2)], .run_count = count };
}

pub fn time_ns_min_of(arguments: []const [:0]const u8) error{Usage}!u64 {
    assert(arguments.len < std.math.maxInt(u32));

    if (arguments.len > 1) return error.Usage;

    const time_ms_min = if (arguments.len == 0)
        time_ms_min_default
    else
        std.fmt.parseUnsigned(u64, arguments[0], 10) catch return error.Usage;

    if (time_ms_min == 0) return error.Usage;
    if (time_ms_min > time_ms_min_max) return error.Usage;

    const result = time_ms_min * std.time.ns_per_ms;

    assert(result >= std.time.ns_per_ms);

    return result;
}

pub fn report(io: std.Io, bytes: u64, sample: Sample, checksum: []const u8) !void {
    assert(bytes > 0);
    assert(sample.best_ns <= sample.median_ns);
    assert(checksum.len > 0);
    assert(checksum.len <= checksum_bytes_max);

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    try stdout.interface.print("bytes={d} runs={d} best_ns={d} median_ns={d} checksum={s}\n", .{
        bytes,
        sample.run_count,
        sample.best_ns,
        sample.median_ns,
        checksum,
    });

    try stdout.interface.flush();
}
