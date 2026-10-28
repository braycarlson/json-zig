const std = @import("std");
const builtin = @import("builtin");

const tokenizer_module = @import("tokenizer.zig");

const assert = std.debug.assert;

pub const block_bytes: u32 = 64;
const even_bits: u64 = 0x5555_5555_5555_5555;
pub const index_capacity: u32 = 4096;
pub const index_escaped: u32 = 1 << 31;
pub const index_position_mask: u32 = index_escaped - 1;

const intrinsics_enabled = builtin.zig_backend == .stage2_llvm and
    builtin.target.cpu.arch == .x86_64;

const avx2_enabled = intrinsics_enabled and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx2);

const ssse3_enabled = intrinsics_enabled and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .ssse3);

const pclmul_enabled = intrinsics_enabled and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .pclmul);

pub const functions_aligned =
    !builtin.target.cpu.arch.isWasm();

pub const lanes_narrow =
    builtin.target.cpu.arch.isWasm();

const pshufb_enabled = avx2_enabled or ssse3_enabled;
pub const chunk_bytes: u32 = if (avx2_enabled) 32 else 16;
const chunk_count: u32 = @divExact(block_bytes, chunk_bytes);
const flatten_step: u32 = 4;
const flatten_groups: u32 = 6;
const pending_max: u32 = 64;
const scan_bytes_max: u32 = 512 * block_bytes;
const scan_unroll: u32 = 2;
const strings_heavy_density: u32 = 1;
const strings_heavy_scale: u32 = 3;
const utf8_span_bytes: u32 = 256 * block_bytes;

comptime {
    assert(block_bytes == @bitSizeOf(u64));
    assert(block_bytes == chunk_count * chunk_bytes);
    assert(chunk_bytes % 16 == 0);
    assert(even_bits & (even_bits << 1) == 0);
    assert(flatten_step * flatten_groups < block_bytes);
    assert(index_capacity >= 2 * block_bytes);
    assert(index_position_mask >= tokenizer_module.input_bytes_max - 1);
}

pub const Chunk = @Vector(chunk_bytes, u8);
const ChunkMask = @Int(.unsigned, chunk_bytes);
const Half = @Vector(16, u8);
const Lanes = @Vector(chunk_bytes, u1);
const Pair = @Vector(2, u64);
const Wide = @Vector(32, u8);
const sysv: std.lang.CallingConvention = .{ .x86_64_sysv = .{} };

extern fn @"llvm.x86.avx2.pshuf.b"(table: Wide, indices: Wide) callconv(sysv) Wide;
extern fn @"llvm.x86.pclmulqdq"(left: Pair, right: Pair, immediate: u8) callconv(sysv) Pair;
extern fn @"llvm.x86.ssse3.pshuf.b.128"(table: Half, indices: Half) callconv(sysv) Half;

pub const Indices = [index_capacity]u32;

pub const Status = enum {
    exhausted,
    failed,
    ready,
};

pub const Fill = struct {
    count: u32,
    status: Status,
};

const UTF8 = UTF8Type(chunk_bytes);

pub const Indexer = struct {
    block_next: u32,
    carry_escaped: u64,
    carry_in_string: u64,
    carry_scalar: u64,
    flag_next: bool,
    strings_heavy: bool,
    utf8_bytes: Chunk,
    utf8_next: u32,
    utf8_pending: bool,
    utf8_previous: Chunk,

    pub const empty: Indexer = .{
        .block_next = 0,
        .carry_escaped = 0,
        .carry_in_string = 0,
        .carry_scalar = 0,
        .flag_next = false,
        .strings_heavy = false,
        .utf8_bytes = @splat(0),
        .utf8_next = 0,
        .utf8_pending = false,
        .utf8_previous = @splat(0),
    };

    const fill_variant = if (functions_aligned)
        fill_variant_aligned
    else
        fill_variant_unaligned;

    pub fn fill(indexer: *Indexer, input: []const u8, indices: *Indices, kept: u32) Fill {
        assert(indexer.block_next <= input.len);
        assert(kept < block_bytes);

        const start = indexer.block_next;

        const result = if (indexer.strings_heavy)
            indexer.fill_variant(true, input, indices, kept)
        else
            indexer.fill_variant(false, input, indices, kept);

        const scanned = @divFloor(indexer.block_next - start, block_bytes);
        const produced = result.count -| kept;

        indexer.strings_heavy = produced * strings_heavy_density < scanned * strings_heavy_scale;

        return result;
    }

    noinline fn fill_variant_aligned(
        indexer: *Indexer,
        comptime skip: bool,
        input: []const u8,
        indices: *Indices,
        kept: u32,
    ) align(4096) Fill {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.block_next <= input.len);
        assert(kept < block_bytes);

        return fill_variant_body(indexer, skip, input, indices, kept);
    }

    noinline fn fill_variant_unaligned(
        indexer: *Indexer,
        comptime skip: bool,
        input: []const u8,
        indices: *Indices,
        kept: u32,
    ) Fill {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.block_next <= input.len);
        assert(kept < block_bytes);

        return fill_variant_body(indexer, skip, input, indices, kept);
    }

    inline fn fill_variant_body(
        indexer: *Indexer,
        comptime skip: bool,
        input: []const u8,
        indices: *Indices,
        kept: u32,
    ) Fill {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.block_next <= input.len);
        assert(kept < block_bytes);

        var state = indexer.*;
        defer indexer.* = state;

        const classifier = classifier_load();
        const full_end: u32 = @intCast(input.len - input.len % block_bytes);
        const scan_end = @min(full_end, state.block_next + scan_bytes_max);

        var count: u32 = kept;
        var errors: u64 = 0;
        var entries: [pending_max]Pending = undefined;
        var marks: Marks = .{ .count = 0, .entries = &entries };
        var previous: Scan = .{ .errors = 0, .escaped = 0, .structurals = 0 };
        var start_previous: u32 = 0;

        scan: while (state.block_next < scan_end) {
            inline for (0..scan_unroll) |unroll_index| {
                if (state.block_next == scan_end) break :scan;

                flatten(indices[count..][0..block_bytes], start_previous, previous.structurals);
                count += @popCount(previous.structurals);
                previous.structurals = 0;

                if (unroll_index == 0) {
                    if (fill_full(count, &marks)) break :scan;
                }

                const start = state.block_next;
                const block = block_load(input, start);

                previous = state.block_scan(&block, &classifier);
                start_previous = start;
                errors |= previous.errors;

                if (previous.escaped != 0) {
                    marks.entries[marks.count] = pending_of(&previous, start);
                    marks.entries[marks.count].slot_base = count;
                    marks.count += 1;
                }
            }

            if (skip) {
                const bounds: Skip = .{
                    .count = count,
                    .end = scan_end,
                    .structurals = previous.structurals,
                };

                errors |= state.fill_skip(input, &classifier, &marks, bounds);
            }
        }

        return state.fill_finish(input, indices, &marks, &.{
            .count = count,
            .errors = errors,
            .kept = kept,
            .start_last = start_previous,
            .structurals_last = previous.structurals,
        });
    }

    inline fn fill_finish(
        state: *Indexer,
        input: []const u8,
        indices: *Indices,
        marks: *Marks,
        held: *const Held,
    ) Fill {
        assert(marks.count <= pending_max);
        assert(held.count <= index_capacity);
        assert(held.kept <= held.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        var flat_count = held.count;

        if (held.structurals_last != 0) {
            assert(held.start_last + block_bytes == state.block_next);

            flatten(indices[flat_count..][0..block_bytes], held.start_last, held.structurals_last);
            flat_count += @popCount(held.structurals_last);
        }

        const errors = held.errors | state.fill_utf8(input);
        const tail = state.tail_index(input, indices, marks.entries[marks.count..], flat_count);
        const count = tail.count;
        const marked = marks.count + tail.pending;
        const range: Range = .{ .end = count, .start = held.kept };

        state.pending_apply(indices, marks.entries[0..marked], range);

        if (errors | tail.errors != 0) return .{ .count = 0, .status = .failed };

        assert(count <= index_capacity);

        if (state.block_next < input.len) return .{ .count = count, .status = .ready };
        if (!state.finish()) return .{ .count = 0, .status = .failed };
        return .{ .count = count, .status = .exhausted };
    }

    inline fn fill_utf8(state: *Indexer, input: []const u8) u64 {
        assert(state.utf8_next <= state.block_next);
        assert(state.block_next <= input.len);

        const due = state.block_next - state.utf8_next >= utf8_span_bytes;

        if (!due) {
            const full_end: u32 = @intCast(input.len - input.len % block_bytes);
            if (state.block_next != full_end) return 0;
        }

        const high: ChunkMask = @bitCast(state.utf8_bytes >= @as(Chunk, @splat(0x80)));
        const range: Range = .{ .end = state.block_next, .start = state.utf8_next };
        const checked = high != 0 or state.utf8_pending;

        state.utf8_bytes = @splat(0);
        state.utf8_next = state.block_next;

        if (!checked) return 0;
        return state.utf8_range(input, range);
    }

    inline fn fill_skip(
        state: *Indexer,
        input: []const u8,
        classifier: *const Classifier,
        marks: *Marks,
        bounds: Skip,
    ) u64 {
        assert(bounds.end <= input.len);
        assert(bounds.count <= index_capacity);

        if (bounds.structurals | ~state.carry_in_string != 0) return 0;

        var errors: u64 = 0;

        for (0..@divFloor(scan_bytes_max, block_bytes)) |_| {
            if (state.block_next == bounds.end) break;
            if (marks.count == pending_max) break;

            const start = state.block_next;
            const block = block_load(input, start);
            const strings = block_strings(&block, classifier);
            const carry = state.carry_escaped;
            const escaping: Escaping = .{ .backslash = strings.backslash, .carry = carry };
            const escape = escaped_branchless(escaping);
            if (strings.quote & ~escape.escaped != 0) break;

            inline for (0..chunk_count) |chunk| state.utf8_bytes |= block[chunk];

            errors |= strings.control;
            state.block_next += block_bytes;
            state.carry_escaped = escape.carry;
            state.carry_scalar = 0;

            marks.entries[marks.count] = .{
                .escaped = escape.escaped,
                .slot_base = bounds.count,
                .start = start,
                .structurals = 0,
            };
            marks.count += @intFromBool(escape.escaped != 0);
        }

        return errors;
    }

    inline fn block_scan(
        indexer: *Indexer,
        block: *const Block,
        classifier: *const Classifier,
    ) Scan {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.carry_escaped <= 1);

        inline for (0..chunk_count) |chunk| indexer.utf8_bytes |= block[chunk];

        const masks = block_classify(block, classifier);
        const escape = escaped_find(indexer, masks.backslash);
        const quote = masks.quote & ~escape.escaped;
        const in_string = prefix_xor(quote) ^ indexer.carry_in_string;
        const scalar = ~(masks.operator | masks.whitespace);
        const scalar_nonquote = scalar & ~quote;
        const scalar_follows = scalar_nonquote << 1 | indexer.carry_scalar;
        const scalar_start = scalar & ~scalar_follows;

        indexer.block_next += block_bytes;
        indexer.carry_escaped = escape.carry;
        indexer.carry_in_string = @bitCast(@as(i64, @bitCast(in_string)) >> 63);
        indexer.carry_scalar = scalar_nonquote >> 63;

        const structurals = (masks.operator | scalar_start) & ~(in_string ^ quote);

        assert(structurals & masks.whitespace == 0);
        assert(structurals & (in_string ^ quote) == 0);

        return .{
            .errors = masks.control & in_string,
            .escaped = escape.escaped & in_string,
            .structurals = structurals,
        };
    }

    inline fn tail_index(
        indexer: *Indexer,
        input: []const u8,
        indices: *Indices,
        pending: []Pending,
        count: u32,
    ) Tail {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.block_next <= input.len);
        assert(pending.len <= pending_max);
        assert(count <= index_capacity);

        const full_end: u32 = @intCast(input.len - input.len % block_bytes);
        const skipped: Tail = .{ .count = count, .errors = 0, .pending = 0 };
        if (indexer.block_next < full_end) return skipped;
        if (indexer.block_next == input.len) return skipped;
        if (count > index_capacity - block_bytes) return skipped;
        if (pending.len == 0) return skipped;

        const classifier = classifier_load();
        const start = indexer.block_next;
        const block = block_load_tail(input, start);
        const scan = indexer.block_scan(&block, &classifier);

        flatten(indices[count..][0..block_bytes], start, scan.structurals);

        var result: Tail = .{
            .count = count + @popCount(scan.structurals),
            .errors = scan.errors | indexer.utf8_step(&block),
            .pending = 0,
        };

        if (scan.escaped != 0) {
            pending[0] = pending_of(&scan, start);
            pending[0].slot_base = count;
            result.pending = 1;
        }

        assert(result.count <= index_capacity);

        return result;
    }

    fn pending_apply(
        indexer: *Indexer,
        indices: *Indices,
        pending: []const Pending,
        range: Range,
    ) void {
        assert(range.start <= range.end);
        assert(range.end <= index_capacity);
        assert(pending.len <= pending_max);

        if (indexer.flag_next) {
            if (range.end > range.start) {
                indices[range.start] |= index_escaped;
                indexer.flag_next = false;
            }
        }

        for (pending) |*entry| indexer.flags_mark(indices, entry, range.end);
    }

    fn flags_mark(indexer: *Indexer, indices: *Indices, entry: *const Pending, count: u32) void {
        assert(entry.escaped != 0);
        assert(entry.escaped & entry.structurals == 0);
        assert(entry.slot_base <= count);

        const sum = @addWithOverflow(~entry.structurals, entry.escaped);
        const slot_end = entry.slot_base + @popCount(entry.structurals);

        var flagged = sum[0] & entry.structurals;

        for (0..block_bytes) |_| {
            if (flagged == 0) break;

            const below = (flagged & (~flagged +% 1)) - 1;
            const slot = entry.slot_base + @popCount(entry.structurals & below);

            assert(slot < slot_end);
            assert(slot < count);

            indices[slot] |= index_escaped;
            flagged &= flagged - 1;
        }

        assert(flagged == 0);

        if (sum[1] == 0) return;

        if (slot_end < count) {
            indices[slot_end] |= index_escaped;
        } else {
            assert(slot_end == count);

            indexer.flag_next = true;
        }
    }

    fn finish(indexer: *Indexer) bool {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.carry_in_string == 0 or ~indexer.carry_in_string == 0);

        if (indexer.carry_escaped != 0) return false;
        if (!indexer.utf8_pending) return true;

        const window: UTF8.Window = .{ .current = @splat(0), .previous = indexer.utf8_previous };

        indexer.utf8_pending = false;

        return utf8_errors(&window) == 0;
    }

    inline fn utf8_range(indexer: *Indexer, input: []const u8, range: Range) u64 {
        assert(range.start % block_bytes == 0);
        assert(range.start <= range.end);
        assert(range.end <= input.len);
        assert(range.end - range.start < utf8_span_bytes + scan_bytes_max);

        const start = range.start;
        const end = range.end;

        const pair_bytes = 2 * block_bytes;
        const pair_end = end - (end - start) % pair_bytes;

        var errors: u64 = 0;

        for (0..@divExact(pair_end - start, pair_bytes)) |pair_index| {
            const first = start + @as(u32, @intCast(pair_index)) * pair_bytes;
            const blocks = block_pair_load(input, first);

            var merged: Chunk = blocks[0][0];

            inline for (0..2) |block| {
                inline for (0..chunk_count) |chunk| merged |= blocks[block][chunk];
            }

            const high: ChunkMask = @bitCast(merged >= @as(Chunk, @splat(0x80)));

            const checked = high != 0 or indexer.utf8_pending;

            if (checked) {
                errors |= indexer.utf8_step(&blocks[0]);
                errors |= indexer.utf8_step(&blocks[1]);
            }
        }

        if (pair_end < end) {
            const block = block_load(input, pair_end);

            errors |= indexer.utf8_step(&block);
        }

        return errors;
    }

    inline fn utf8_step(indexer: *Indexer, block: *const Block) u64 {
        assert(@sizeOf(Block) == block_bytes);
        if (!indexer.utf8_pending) assert(utf8_tail_ascii(indexer.utf8_previous));

        var merged: Chunk = block[0];

        inline for (1..chunk_count) |chunk| merged |= block[chunk];

        const high: ChunkMask = @bitCast(merged >= @as(Chunk, @splat(0x80)));

        if (high == 0) {
            if (!indexer.utf8_pending) return 0;
        }

        return indexer.utf8_check(block);
    }

    fn utf8_check(indexer: *Indexer, block: *const Block) u64 {
        assert(@sizeOf(Block) == block_bytes);
        if (!indexer.utf8_pending) assert(block_has_high(block));

        const chunk_last = block[chunk_count - 1];
        const high_last: ChunkMask = @bitCast(chunk_last >= @as(Chunk, @splat(0x80)));

        var errors: u64 = 0;
        var previous = indexer.utf8_previous;

        inline for (0..chunk_count) |chunk| {
            const window: UTF8.Window = .{ .current = block[chunk], .previous = previous };

            errors |= @as(u64, utf8_errors(&window)) << (chunk * chunk_bytes);
            previous = block[chunk];
        }

        indexer.utf8_previous = chunk_last;
        indexer.utf8_pending = high_last >> (chunk_bytes - 3) != 0;

        return errors;
    }
};

pub const Cursor = struct {
    count: usize,
    exhausted: bool,
    failed: bool,
    indexer: *Indexer,
    indices: *Indices,
    position: usize,

    pub inline fn next(cursor: *Cursor, input: []const u8) ?u32 {
        assert(cursor.position <= cursor.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        if (cursor.position == cursor.count) {
            @branchHint(.unlikely);

            if (!cursor.refill(input)) return null;
        }

        const result = cursor.indices[cursor.position];

        cursor.position += 1;

        return result;
    }

    pub inline fn peek_or_end(cursor: *Cursor, input: []const u8) u32 {
        assert(cursor.position <= cursor.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        if (cursor.position == cursor.count) {
            @branchHint(.unlikely);

            if (!cursor.refill(input)) return cursor.end_entry(input);
        }

        return cursor.indices[cursor.position];
    }

    pub inline fn ahead(cursor: *const Cursor) u64 {
        assert(cursor.position <= cursor.count);
        assert(cursor.count <= index_capacity);

        return cursor.count - cursor.position;
    }

    pub fn refill_ahead(cursor: *Cursor, input: []const u8, comptime ahead_min: comptime_int) bool {
        assert(cursor.position <= cursor.count);
        assert(input.len <= tokenizer_module.input_bytes_max);
        comptime assert(ahead_min < block_bytes);

        if (cursor.failed) return false;
        if (cursor.exhausted) return true;
        if (cursor.count - cursor.position >= ahead_min) return true;

        const kept: u32 = @intCast(cursor.count - cursor.position);

        for (0..kept) |slot| cursor.indices[slot] = cursor.indices[cursor.position + slot];

        const result = fill_ahead(cursor.indexer, input, cursor.indices, kept, ahead_min);

        cursor.count = result.count;
        cursor.exhausted = result.status == .exhausted;
        cursor.failed = result.status == .failed;
        cursor.position = 0;

        assert(cursor.count >= kept or cursor.failed);

        return !cursor.failed;
    }

    pub inline fn flag_clear(cursor: *Cursor) void {
        assert(cursor.position <= cursor.count);
        if (cursor.position == cursor.count) return;

        assert(cursor.indices[cursor.position] & index_escaped != 0);

        cursor.indices[cursor.position] &= index_position_mask;
    }

    inline fn end_entry(cursor: *const Cursor, input: []const u8) u32 {
        assert(cursor.position == cursor.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        if (cursor.failed) return 0;
        return cursor.entry_exhausted(input);
    }

    pub inline fn entry_exhausted(cursor: *const Cursor, input: []const u8) u32 {
        assert(cursor.exhausted);
        assert(cursor.indexer.block_next >= input.len);

        const length: u32 = @intCast(input.len);
        const result = if (cursor.indexer.flag_next) length | index_escaped else length;

        assert(result & index_position_mask == length);

        return result;
    }

    inline fn refill(cursor: *Cursor, input: []const u8) bool {
        assert(cursor.position == cursor.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        if (cursor.exhausted) return false;
        if (cursor.failed) return false;

        const result = fill_ahead(cursor.indexer, input, cursor.indices, 0, 1);

        cursor.count = result.count;
        cursor.exhausted = result.status == .exhausted;
        cursor.failed = result.status == .failed;
        cursor.position = 0;

        return result.count > 0;
    }
};

pub inline fn string_close_find(input: []const u8, before: u32) u32 {
    assert(before <= input.len);
    assert(input.len <= tokenizer_module.input_bytes_max);

    if (before == 0) return 0;

    const last = before - 1;
    const result = if (input[last] == '"') last else string_close_skip(input, last);

    assert(result <= last);

    return result;
}

inline fn string_close_skip(input: []const u8, last: u32) u32 {
    assert(last < input.len);
    assert(input[last] != '"');

    var index = last;

    for (0..last) |_| {
        switch (input[index]) {
            ' ', '\t', '\n', '\r' => index -= 1,
            else => return 0,
        }

        if (input[index] == '"') return index;
    }

    return 0;
}

noinline fn fill_ahead(
    indexer: *Indexer,
    input: []const u8,
    indices: *Indices,
    kept: u32,
    comptime ahead_min: comptime_int,
) Fill {
    assert(indexer.block_next <= input.len);
    assert(input.len <= tokenizer_module.input_bytes_max);
    assert(kept < ahead_min);
    comptime assert(ahead_min < block_bytes);

    var count = kept;

    for (0..@divFloor(input.len, block_bytes) + ahead_min + 2) |_| {
        const result = indexer.fill(input, indices, count);
        if (result.status != .ready) return result;

        count = result.count;
        if (count >= ahead_min) return result;
    }

    return .{ .count = 0, .status = .failed };
}

const Block = [chunk_count]Chunk;

const Pending = struct {
    escaped: u64,
    slot_base: u32,
    start: u32,
    structurals: u64,
};

const Scan = struct {
    errors: u64,
    escaped: u64,
    structurals: u64,
};

const Escaping = struct {
    backslash: u64,
    carry: u64,
};

const Held = struct {
    count: u32,
    errors: u64,
    kept: u32,
    start_last: u32,
    structurals_last: u64,
};

const Marks = struct {
    count: u32,
    entries: *[pending_max]Pending,
};

const Range = struct {
    end: u32,
    start: u32,
};

const Skip = struct {
    count: u32,
    end: u32,
    structurals: u64,
};

const Tail = struct {
    count: u32,
    errors: u64,
    pending: u32,
};

fn ClassesType(comptime Mask: type) type {
    return struct {
        backslash: Mask,
        control: Mask,
        operator: Mask,
        quote: Mask,
        whitespace: Mask,
    };
}

const Classes = ClassesType(ChunkMask);
const Masks = ClassesType(u64);

const Escape = struct {
    carry: u64,
    escaped: u64,
};

const Strings = struct {
    backslash: u64,
    control: u64,
    quote: u64,
};

inline fn block_strings(block: *const Block, classifier: *const Classifier) Strings {
    assert(@sizeOf(Block) == block_bytes);
    assert(chunk_count >= 1);

    var result: Strings = .{ .backslash = 0, .control = 0, .quote = 0 };

    inline for (0..chunk_count) |chunk| {
        const bytes = block[chunk];
        const shift = chunk * chunk_bytes;
        const backslash: ChunkMask = @bitCast(bytes == classifier.backslash);
        const control: ChunkMask = @bitCast(@min(bytes, classifier.control) == bytes);
        const quote: ChunkMask = @bitCast(bytes == classifier.quote);

        result.backslash |= @as(u64, backslash) << shift;
        result.control |= @as(u64, control) << shift;
        result.quote |= @as(u64, quote) << shift;
    }

    assert(result.quote & result.backslash == 0);

    return result;
}

inline fn escaped_branchless(escaping: Escaping) Escape {
    assert(escaping.carry <= 1);
    assert(@popCount(escaping.backslash) <= block_bytes);

    const backslash = escaping.backslash;
    const carry = escaping.carry;

    const odd_bits: u64 = ~even_bits;
    const potential = backslash & ~carry;
    const terminal = ((potential << 1 | odd_bits) -% potential) ^ odd_bits;
    const result: Escape = .{
        .carry = (terminal & backslash) >> 63,
        .escaped = terminal ^ (backslash | carry),
    };

    assert(result.carry <= 1);

    return result;
}

inline fn block_classify(block: *const Block, classifier: *const Classifier) Masks {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@sizeOf(Block) == block_bytes);

    var result: Masks = .{
        .backslash = 0,
        .control = 0,
        .operator = 0,
        .quote = 0,
        .whitespace = 0,
    };

    inline for (0..chunk_count) |chunk| {
        const classes = chunk_classify(block[chunk], classifier);

        inline for (@typeInfo(Classes).@"struct".field_names) |name| {
            @field(result, name) |= @as(u64, @field(classes, name)) << (chunk * chunk_bytes);
        }
    }

    assert(result.quote & result.backslash == 0);
    assert(result.operator & result.whitespace == 0);

    return result;
}

inline fn chunk_classify(bytes: Chunk, classifier: *const Classifier) Classes {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@typeInfo(@TypeOf(bytes)).vector.len == chunk_bytes);

    const curled = bytes | classifier.curl;

    var result: Classes = .{
        .backslash = @bitCast(bytes == classifier.backslash),
        .control = @bitCast(@min(bytes, classifier.control) == bytes),
        .operator = 0,
        .quote = @bitCast(bytes == classifier.quote),
        .whitespace = 0,
    };

    if (pshufb_enabled) {
        const whitespace = shuffle(&classifier.whitespace, bytes) == bytes;
        const operator = shuffle(&classifier.operator, bytes) == curled;

        result.whitespace = @bitCast(whitespace);
        result.operator = @bitCast(operator);
    } else {
        const brace_open: Lanes = @intFromBool(curled == @as(Chunk, @splat('{')));
        const brace_close: Lanes = @intFromBool(curled == @as(Chunk, @splat('}')));
        const colon: Lanes = @intFromBool(bytes == @as(Chunk, @splat(':')));
        const comma: Lanes = @intFromBool(bytes == @as(Chunk, @splat(',')));
        const space: Lanes = @intFromBool(bytes == @as(Chunk, @splat(' ')));
        const tab: Lanes = @intFromBool(bytes == @as(Chunk, @splat('\t')));
        const line_feed: Lanes = @intFromBool(bytes == @as(Chunk, @splat('\n')));
        const carriage_return: Lanes = @intFromBool(bytes == @as(Chunk, @splat('\r')));

        result.whitespace = @bitCast(space | tab | line_feed | carriage_return);
        result.operator = @bitCast(brace_open | brace_close | colon | comma);
    }

    return result;
}

inline fn fill_full(count: u32, marks: *const Marks) bool {
    assert(count <= index_capacity);
    assert(marks.count <= pending_max);

    if (count > index_capacity - scan_unroll * block_bytes) return true;
    return marks.count > pending_max - scan_unroll;
}

inline fn shuffle(table: *const Chunk, indices: Chunk) Chunk {
    comptime assert(pshufb_enabled);
    assert(@reduce(.Or, table.*) != 0);
    assert(@typeInfo(@TypeOf(indices)).vector.len == chunk_bytes);

    if (chunk_bytes == 32) return @"llvm.x86.avx2.pshuf.b"(table.*, indices);
    return @"llvm.x86.ssse3.pshuf.b.128"(table.*, indices);
}

const Classifier = struct {
    backslash: Chunk,
    control: Chunk,
    curl: Chunk,
    operator: Chunk,
    quote: Chunk,
    whitespace: Chunk,
};

const classifier_constant: Classifier = .{
    .backslash = @splat('\\'),
    .control = @splat(0x1f),
    .curl = @splat(0x20),
    .operator = operator_table,
    .quote = @splat('"'),
    .whitespace = whitespace_table,
};

inline fn classifier_load() Classifier {
    var storage: Classifier = undefined;
    const opaque_storage: *volatile Classifier = &storage;

    opaque_storage.* = classifier_constant;

    const result = opaque_storage.*;

    assert(result.control[0] == 0x1f);
    assert(result.quote[chunk_bytes - 1] == '"');

    return result;
}

fn utf8_tail_ascii(previous: Chunk) bool {
    assert(chunk_bytes >= 3);
    assert(@typeInfo(@TypeOf(previous)).vector.len == chunk_bytes);

    const high = @max(previous[chunk_bytes - 1], previous[chunk_bytes - 2]);

    return @max(high, previous[chunk_bytes - 3]) < 0x80;
}

const whitespace_table = table_repeat(.{
    ' ',
    100,
    100,
    100,
    17,
    100,
    113,
    2,
    100,
    '\t',
    '\n',
    112,
    100,
    '\r',
    100,
    100,
});

const operator_table = table_repeat(.{
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ':',
    '{',
    ',',
    '}',
    0,
    0,
});

fn table_repeat(comptime entries: [16]u8) Chunk {
    comptime assert(chunk_bytes % entries.len == 0);
    comptime assert(entries.len == 16);

    var result: [chunk_bytes]u8 = undefined;

    for (&result, 0..) |*lane, position| lane.* = entries[position % entries.len];

    return result;
}

inline fn block_load(input: []const u8, start: u32) Block {
    assert(start % block_bytes == 0);
    assert(start + block_bytes <= input.len);

    const bytes = input[start .. start + block_bytes][0..block_bytes];

    var result: Block = undefined;

    inline for (0..chunk_count) |chunk| {
        result[chunk] = bytes[chunk * chunk_bytes ..][0..chunk_bytes].*;
    }

    return result;
}

inline fn block_pair_load(input: []const u8, start: u32) [2]Block {
    assert(start % block_bytes == 0);
    assert(start + 2 * block_bytes <= input.len);

    const bytes = input[start .. start + 2 * block_bytes][0 .. 2 * block_bytes];

    var result: [2]Block = undefined;

    inline for (0..2) |block| {
        inline for (0..chunk_count) |chunk| {
            const offset = block * block_bytes + chunk * chunk_bytes;

            result[block][chunk] = bytes[offset..][0..chunk_bytes].*;
        }
    }

    return result;
}

noinline fn block_load_tail(input: []const u8, start: u32) Block {
    assert(start < input.len);
    assert(input.len - start < block_bytes);

    var bytes: [block_bytes]u8 = @splat(' ');

    @memcpy(bytes[0 .. input.len - start], input[start..]);

    var result: Block = undefined;

    inline for (0..chunk_count) |chunk| {
        result[chunk] = bytes[chunk * chunk_bytes ..][0..chunk_bytes].*;
    }

    return result;
}

fn block_has_high(block: *const Block) bool {
    assert(@sizeOf(Block) == block_bytes);
    assert(chunk_count >= 1);

    var merged: Chunk = block[0];

    inline for (1..chunk_count) |chunk| merged |= block[chunk];

    return @reduce(.Or, merged) >= 0x80;
}

inline fn flatten(slots: *volatile [block_bytes]u32, start: u32, structurals: u64) void {
    assert(start % block_bytes == 0);
    assert(@popCount(structurals) <= block_bytes);

    if (structurals == 0) return;

    const total = @popCount(structurals);

    var bits = structurals;

    inline for (0..flatten_groups) |group| {
        inline for (0..flatten_step) |offset| {
            slots[group * flatten_step + offset] = start + @ctz(bits);
            bits &= bits -% 1;
        }

        if (total <= (group + 1) * flatten_step) return;
    }

    for (flatten_groups * flatten_step..block_bytes) |slot| {
        if (bits == 0) return;

        slots[slot] = start + @ctz(bits);
        bits &= bits - 1;
    }
}

fn pending_of(scan: *const Scan, start: u32) Pending {
    assert(scan.escaped != 0);
    assert(start % block_bytes == 0);

    return .{
        .escaped = scan.escaped,
        .slot_base = 0,
        .start = start,
        .structurals = scan.structurals,
    };
}

fn escaped_find(indexer: *const Indexer, backslash_all: u64) Escape {
    assert(indexer.carry_escaped <= 1);
    assert(@popCount(backslash_all) <= block_bytes);

    const carry = indexer.carry_escaped;
    if (backslash_all == 0) return .{ .carry = 0, .escaped = carry };

    const backslash = backslash_all & ~carry;
    const follows = backslash << 1 | carry;
    const odd_starts = backslash & ~even_bits & ~follows;
    const sum = @addWithOverflow(odd_starts, backslash);
    const invert = sum[0] << 1;
    const result: Escape = .{ .carry = sum[1], .escaped = (even_bits ^ invert) & follows };

    assert(result.escaped & backslash & ~follows == 0);

    return result;
}

fn prefix_xor(quote: u64) u64 {
    assert(@popCount(quote) <= block_bytes);

    const result = if (pclmul_enabled) prefix_xor_multiply(quote) else prefix_xor_shift(quote);

    assert(result & 1 == quote & 1);
    assert(@popCount(result >> 63) == @popCount(quote) % 2);

    return result;
}

inline fn prefix_xor_multiply(quote: u64) u64 {
    comptime assert(pclmul_enabled);
    assert(@popCount(quote) <= block_bytes);

    const left: Pair = .{ quote, 0 };
    const right: Pair = .{ std.math.maxInt(u64), 0 };
    const result = @"llvm.x86.pclmulqdq"(left, right, 0)[0];

    assert(result & 1 == quote & 1);

    return result;
}

fn prefix_xor_shift(quote: u64) u64 {
    assert(@popCount(quote) <= block_bytes);

    var result = quote;

    result ^= result << 1;
    result ^= result << 2;
    result ^= result << 4;
    result ^= result << 8;
    result ^= result << 16;
    result ^= result << 32;

    assert(result & 1 == quote & 1);

    return result;
}

fn utf8_errors(window: *const UTF8.Window) ChunkMask {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@sizeOf(UTF8.Window) == 2 * chunk_bytes);

    const result = if (pshufb_enabled) utf8_errors_lookup(window) else UTF8.errors_compare(window);

    if (@reduce(.Or, window.current | window.previous) < 0x80) assert(result == 0);

    return result;
}

fn utf8_errors_lookup(window: *const UTF8.Window) ChunkMask {
    comptime assert(pshufb_enabled);
    assert(@sizeOf(UTF8.Window) == 2 * chunk_bytes);

    const nibble: Chunk = @splat(0x0f);
    const bytes = window.current;
    const prior_one = @shuffle(u8, window.previous, bytes, UTF8.shift_mask(1));
    const prior_two = @shuffle(u8, window.previous, bytes, UTF8.shift_mask(2));
    const prior_three = @shuffle(u8, window.previous, bytes, UTF8.shift_mask(3));
    const nibble_prior_high = prior_one >> @splat(4);
    const nibble_prior_low = prior_one & nibble;
    const nibble_current_high = bytes >> @splat(4);
    const class_prior_high = shuffle(&utf8_prior_high, nibble_prior_high);
    const class_prior_low = shuffle(&utf8_prior_low, nibble_prior_low);
    const class_current_high = shuffle(&utf8_current_high, nibble_current_high);
    const special = class_prior_high & class_prior_low & class_current_high;
    const third = prior_two -| @as(Chunk, @splat(0xe0 - 0x80));
    const fourth = prior_three -| @as(Chunk, @splat(0xf0 - 0x80));
    const required = (third | fourth) & @as(Chunk, @splat(0x80));
    const errors = special ^ required;
    const result: ChunkMask = @bitCast(errors != @as(Chunk, @splat(0)));

    if (@reduce(.Or, window.current | window.previous) < 0x80) assert(result == 0);

    return result;
}

const utf8_short_too: u8 = 1 << 0;
const utf8_long_too: u8 = 1 << 1;
const utf8_overlong_3: u8 = 1 << 2;
const utf8_large_too: u8 = 1 << 3;
const utf8_surrogate: u8 = 1 << 4;
const utf8_overlong_2: u8 = 1 << 5;
const utf8_large_too_1000: u8 = 1 << 6;
const utf8_overlong_4: u8 = 1 << 6;
const utf8_continuation_two: u8 = 1 << 7;
const utf8_carry: u8 = utf8_short_too | utf8_long_too | utf8_continuation_two;
const utf8_large: u8 = utf8_carry | utf8_large_too | utf8_large_too_1000;
const utf8_continuation: u8 = utf8_long_too | utf8_overlong_2 | utf8_continuation_two;
const utf8_lead_four: u8 = utf8_short_too | utf8_large_too | utf8_large_too_1000 | utf8_overlong_4;
const utf8_continuation_1000: u8 = utf8_overlong_3 | utf8_large_too_1000 | utf8_overlong_4;

const utf8_prior_high = table_repeat(.{
    utf8_long_too,
    utf8_long_too,
    utf8_long_too,
    utf8_long_too,
    utf8_long_too,
    utf8_long_too,
    utf8_long_too,
    utf8_long_too,
    utf8_continuation_two,
    utf8_continuation_two,
    utf8_continuation_two,
    utf8_continuation_two,
    utf8_short_too | utf8_overlong_2,
    utf8_short_too,
    utf8_short_too | utf8_overlong_3 | utf8_surrogate,
    utf8_lead_four,
});

const utf8_prior_low = table_repeat(.{
    utf8_carry | utf8_overlong_3 | utf8_overlong_2 | utf8_overlong_4,
    utf8_carry | utf8_overlong_2,
    utf8_carry,
    utf8_carry,
    utf8_carry | utf8_large_too,
    utf8_large,
    utf8_large,
    utf8_large,
    utf8_large,
    utf8_large,
    utf8_large,
    utf8_large,
    utf8_large,
    utf8_large | utf8_surrogate,
    utf8_large,
    utf8_large,
});

const utf8_current_high = table_repeat(.{
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_continuation | utf8_continuation_1000,
    utf8_continuation | utf8_overlong_3 | utf8_large_too,
    utf8_continuation | utf8_surrogate | utf8_large_too,
    utf8_continuation | utf8_surrogate | utf8_large_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
    utf8_short_too,
});

pub fn utf8_valid(bytes: []const u8) bool {
    assert(bytes.len <= tokenizer_module.input_bytes_max);
    assert(@sizeOf(UTF8.Window) == 2 * chunk_bytes);

    const length: u32 = @intCast(bytes.len);
    const full_end = length - length % chunk_bytes;

    var errors: ChunkMask = 0;
    var previous: Chunk = @splat(0);
    var start: u32 = 0;

    while (start < full_end) : (start += chunk_bytes) {
        const current: Chunk = bytes[start..][0..chunk_bytes].*;
        const window: UTF8.Window = .{ .current = current, .previous = previous };

        errors |= utf8_errors(&window);
        previous = window.current;
    }

    var tail: [chunk_bytes]u8 = @splat(' ');

    @memcpy(tail[0 .. length - full_end], bytes[full_end..]);

    const last: UTF8.Window = .{ .current = tail, .previous = previous };
    const terminal: UTF8.Window = .{ .current = @splat(' '), .previous = tail };

    errors |= utf8_errors(&last);
    errors |= utf8_errors(&terminal);

    return errors == 0;
}

pub fn UTF8Type(comptime lanes: u32) type {
    comptime assert(lanes % 16 == 0);
    comptime assert(lanes <= 64);

    return struct {
        pub const Window = struct {
            current: Vector,
            previous: Vector,
        };

        const Bits = @Vector(lanes, u1);
        const Mask = @Int(.unsigned, lanes);
        const Vector = @Vector(lanes, u8);

        pub fn errors_compare(window: *const Window) Mask {
            assert(@sizeOf(Window) == 2 * lanes);
            assert(lanes >= 4);

            const bytes = window.current;
            const prior_one = @shuffle(u8, window.previous, bytes, shift_mask(1));
            const prior_two = @shuffle(u8, window.previous, bytes, shift_mask(2));
            const prior_three = @shuffle(u8, window.previous, bytes, shift_mask(3));
            const tail_bits = bytes & @as(Vector, @splat(0xc0));
            const continuation: Bits = @intFromBool(tail_bits == @as(Vector, @splat(0x80)));
            const after_lead: Bits = @intFromBool(prior_one >= @as(Vector, @splat(0xc0)));
            const after_three: Bits = @intFromBool(prior_two >= @as(Vector, @splat(0xe0)));
            const after_four: Bits = @intFromBool(prior_three >= @as(Vector, @splat(0xf0)));
            const mismatch = (after_lead | after_three | after_four) ^ continuation;
            const lead_offset = bytes -% @as(Vector, @splat(0xc0));
            const lead_overlong: Bits = @intFromBool(lead_offset < @as(Vector, @splat(2)));
            const lead_beyond: Bits = @intFromBool(bytes >= @as(Vector, @splat(0xf5)));
            const after_e0: Bits = @intFromBool(prior_one == @as(Vector, @splat(0xe0)));
            const after_ed: Bits = @intFromBool(prior_one == @as(Vector, @splat(0xed)));
            const after_f0: Bits = @intFromBool(prior_one == @as(Vector, @splat(0xf0)));
            const after_f4: Bits = @intFromBool(prior_one == @as(Vector, @splat(0xf4)));
            const below_a0: Bits = @intFromBool(bytes < @as(Vector, @splat(0xa0)));
            const below_90: Bits = @intFromBool(bytes < @as(Vector, @splat(0x90)));
            const second_overlong = (after_e0 & below_a0) | (after_f0 & below_90);
            const second_beyond = (after_ed & ~below_a0) | (after_f4 & ~below_90);
            const leads = lead_overlong | lead_beyond;
            const errors = mismatch | leads | second_overlong | second_beyond;
            const result: Mask = @bitCast(errors);

            comptime assert(@bitSizeOf(@TypeOf(result)) == lanes);

            return result;
        }

        pub fn shift_mask(comptime count: u32) @Vector(lanes, i32) {
            comptime assert(count >= 1);
            comptime assert(count <= 3);

            var result: [lanes]i32 = undefined;

            for (&result, 0..) |*lane, position| {
                if (position < count) {
                    lane.* = @intCast(lanes - count + position);
                } else {
                    lane.* = ~@as(i32, @intCast(position - count));
                }
            }

            return result;
        }
    };
}

const testing = std.testing;

fn test_utf8_valid(input: []const u8, comptime lookup: bool) bool {
    assert(input.len <= 4096);
    assert(chunk_bytes >= 16);

    var previous: Chunk = @splat(0);
    var errors: ChunkMask = 0;
    var start: u32 = 0;

    while (start < input.len) : (start += chunk_bytes) {
        var bytes: [chunk_bytes]u8 = @splat(' ');
        const length = @min(chunk_bytes, input.len - start);

        @memcpy(bytes[0..length], input[start..][0..length]);

        const window: UTF8.Window = .{ .current = bytes, .previous = previous };

        errors |= if (lookup) utf8_errors_lookup(&window) else UTF8.errors_compare(&window);
        previous = window.current;
    }

    const terminal: UTF8.Window = .{ .current = @splat(0), .previous = previous };

    errors |= if (lookup) utf8_errors_lookup(&terminal) else UTF8.errors_compare(&terminal);

    return errors == 0;
}

test "both UTF-8 validators agree with the standard library on random sequences" {
    var prng: std.Random.DefaultPrng = .init(0x75746638);
    const random = prng.random();

    const pieces = [_][]const u8{
        "a",
        "\x7f",
        "\xc2\x80",
        "\xdf\xbf",
        "\xe0\xa0\x80",
        "\xed\x9f\xbf",
        "\xed\xa0\x80",
        "\xef\xbf\xbf",
        "\xf0\x90\x80\x80",
        "\xf4\x8f\xbf\xbf",
        "\xf4\x90\x80\x80",
        "\xc0\x80",
        "\xc1\xbf",
        "\xe0\x80\x80",
        "\xf0\x80\x80\x80",
        "\xf5\x80\x80\x80",
        "\x80",
        "\xbf",
        "\xc2",
        "\xe0\xa0",
        "\xf0\x90\x80",
        "\xff",
        "\xfe",
        " ",
        "\xe1\x80\x80",
    };

    var buffer: [256]u8 = undefined;

    for (0..20_000) |_| {
        var length: u32 = 0;
        const count = random.uintLessThan(u32, 24);

        for (0..count) |_| {
            const piece = pieces[random.uintLessThan(u32, pieces.len)];
            if (length + piece.len > buffer.len) break;

            @memcpy(buffer[length..][0..piece.len], piece);
            length += @intCast(piece.len);
        }

        const input = buffer[0..length];
        const expected = std.unicode.utf8ValidateSlice(input);

        try testing.expectEqual(expected, test_utf8_valid(input, false));
        try testing.expectEqual(expected, utf8_valid(input));

        if (pshufb_enabled) try testing.expectEqual(expected, test_utf8_valid(input, true));
    }
}

test "both UTF-8 validators agree with the standard library on every two-byte pair" {
    var buffer: [chunk_bytes + 2]u8 = @splat('a');

    for (0..256) |first| {
        for (0..256) |second| {
            for ([_]u32{ 0, chunk_bytes - 1 }) |offset| {
                buffer = @splat('a');
                buffer[offset] = @intCast(first);
                buffer[offset + 1] = @intCast(second);

                const expected = std.unicode.utf8ValidateSlice(&buffer);

                try testing.expectEqual(expected, test_utf8_valid(&buffer, false));
                try testing.expectEqual(expected, utf8_valid(&buffer));

                if (pshufb_enabled) {
                    try testing.expectEqual(expected, test_utf8_valid(&buffer, true));
                }
            }
        }
    }
}

test "prefix_xor matches a running parity" {
    var prng: std.Random.DefaultPrng = .init(0x70786f72);
    const random = prng.random();

    for (0..2_000) |_| {
        const bits = random.int(u64);

        var expected: u64 = 0;
        var parity: u64 = 0;

        for (0..64) |bit| {
            parity ^= (bits >> @intCast(bit)) & 1;
            expected |= parity << @intCast(bit);
        }

        try testing.expectEqual(expected, prefix_xor(bits));
        try testing.expectEqual(expected, prefix_xor_shift(bits));
    }
}

test "escaped_find marks the byte after each odd backslash run across blocks" {
    var prng: std.Random.DefaultPrng = .init(0x65736361);
    const random = prng.random();

    for (0..2_000) |_| {
        const words = [2]u64{
            random.int(u64) & random.int(u64),
            random.int(u64) & random.int(u64),
        };

        var expected = [2]u64{ 0, 0 };
        var pending = false;

        for (0..128) |position| {
            const word = @divFloor(position, 64);
            const bit: u6 = @intCast(position % 64);

            if (pending) {
                expected[word] |= @as(u64, 1) << bit;
                pending = false;
            } else {
                pending = (words[word] >> bit) & 1 == 1;
            }
        }

        var indexer: Indexer = .empty;
        const first = escaped_find(&indexer, words[0]);

        indexer.carry_escaped = first.carry;

        const second = escaped_find(&indexer, words[1]);

        try testing.expectEqual(expected[0], first.escaped);
        try testing.expectEqual(expected[1], second.escaped);
        try testing.expectEqual(@intFromBool(pending), second.carry);
    }
}

test "escaped_branchless agrees with escaped_find across carries" {
    var prng: std.Random.DefaultPrng = .init(0x62726e63);
    const random = prng.random();

    for (0..20_000) |_| {
        const backslash = random.int(u64) & random.int(u64);
        const carry: u64 = random.uintLessThan(u64, 2);

        var indexer: Indexer = .empty;

        indexer.carry_escaped = carry;

        const expected = escaped_find(&indexer, backslash);
        const actual = escaped_branchless(.{ .backslash = backslash, .carry = carry });

        try testing.expectEqual(expected.escaped, actual.escaped);
        try testing.expectEqual(expected.carry, actual.carry);
    }
}
