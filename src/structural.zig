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

pub const avx2_enabled = intrinsics_enabled and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx2);

const ssse3_enabled = intrinsics_enabled and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .ssse3);

const pclmul_enabled = intrinsics_enabled and
    std.Target.x86.featureSetHas(builtin.target.cpu.features, .pclmul);

pub const functions_aligned =
    !builtin.target.cpu.arch.isWasm();

pub const lanes_narrow =
    builtin.target.cpu.arch.isWasm();

pub const document_indexed = std.simd.suggestVectorLength(u8) != null and
    (builtin.target.cpu.arch != .x86_64 or avx2_enabled);

pub const walk_direct = !document_indexed or lanes_narrow;

const pshufb_enabled = avx2_enabled or ssse3_enabled;
pub const chunk_bytes: u32 = if (avx2_enabled) 32 else 16;
const chunk_count: u32 = @divExact(block_bytes, chunk_bytes);
const escape_unicode_bytes: u32 = 6;
const hex_digit_count: u32 = escape_unicode_bytes - 2;
const pair_high_positions: u64 = (1 << (block_bytes - escape_unicode_bytes)) - 1;
const flatten_step: u32 = 4;
const flatten_groups: u32 = 6;
const pending_max: u32 = 64;
pub const scan_bytes_max: u32 = 512 * block_bytes;
const scan_blocks_max: u32 = @divExact(scan_bytes_max, block_bytes);
const scan_unroll: u32 = 2;
const strings_heavy_density: u32 = 1;
const strings_heavy_scale: u32 = 3;

comptime {
    assert(block_bytes == @bitSizeOf(u64));
    assert(block_bytes == chunk_count * chunk_bytes);
    assert(chunk_bytes % 16 == 0);
    assert(even_bits & (even_bits << 1) == 0);
    assert(flatten_step * flatten_groups < block_bytes);
    assert(index_capacity >= 2 * block_bytes);
    assert(index_position_mask >= tokenizer_module.input_bytes_max - 1);
    assert(index_position_mask < entry_sentinel);
    assert(index_escaped & entry_sentinel != 0);
    assert(pending_max > scan_unroll + 1);
    assert(pending_max <= scan_blocks_max);
}

pub const Chunk = @Vector(chunk_bytes, u8);
const ChunkMask = @Int(.unsigned, chunk_bytes);
const Half = @Vector(16, u8);
const Pair = @Vector(2, u64);
const SignedChunk = @Vector(chunk_bytes, i8);
const Wide = @Vector(32, u8);
const sysv: std.lang.CallingConvention = .{ .x86_64_sysv = .{} };

extern fn @"llvm.x86.avx2.pshuf.b"(table: Wide, indices: Wide) callconv(sysv) Wide;
extern fn @"llvm.x86.pclmulqdq"(left: Pair, right: Pair, immediate: u8) callconv(sysv) Pair;
extern fn @"llvm.x86.ssse3.pshuf.b.128"(table: Half, indices: Half) callconv(sysv) Half;

pub const Entries = [entries_capacity]u32;
pub const Indices = [index_capacity]u32;
pub const entries_capacity: u32 = index_capacity + 1;
pub const entry_sentinel: u32 = std.math.maxInt(u32);

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
    carry_breaks: Chunk,
    carry_escaped: u64,
    carry_in_string: u64,
    escape_validation: bool,
    flag_next: bool,
    strings_heavy: bool,
    surrogate_low: u32,
    utf8_errors: Chunk,
    utf8_next: u32,
    utf8_previous: Chunk,

    pub const empty: Indexer = .{
        .block_next = 0,
        .carry_breaks = @splat(0xff),
        .carry_escaped = 0,
        .carry_in_string = 0,
        .escape_validation = true,
        .flag_next = false,
        .strings_heavy = false,
        .surrogate_low = 0,
        .utf8_errors = @splat(0),
        .utf8_next = 0,
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

        var entries: [pending_max]Pending = undefined;
        var marks: Marks = .{ .count = 0, .entries = &entries, .range_start = kept };
        var state = indexer.*;
        defer indexer.* = state;

        const classifier = classifier_load();
        const full_end: u32 = @intCast(input.len - input.len % block_bytes);
        const scan_end = @min(full_end, state.block_next + scan_bytes_max);

        var count: u32 = kept;
        var errors: u64 = 0;
        var previous: Scan = .{ .attention = 0, .escaped = 0, .structurals = 0, .suspects = 0 };
        var start_previous: u32 = 0;

        scan: while (state.block_next < scan_end) {
            inline for (0..scan_unroll) |unroll_index| {
                if (state.block_next == scan_end) break :scan;

                flatten(indices[count..][0..block_bytes], start_previous, previous.structurals);
                count += @popCount(previous.structurals);
                previous.structurals = 0;

                if (fill_full(unroll_index, count, &marks)) break :scan;
                if (marks_full(unroll_index, &marks)) state.marks_flush(indices, &marks, count);

                const start = state.block_next;
                const block = block_load(input, start);

                previous = state.block_scan(&block, &classifier);
                start_previous = start;

                if (previous.attention != 0) {
                    @branchHint(.unlikely);

                    marks.block_note(&previous, .{ .slot_base = count, .start = start });

                    errors |= state.suspects_check(&block, start, previous.suspects);
                    errors |= state.escapes_check(input, &block, start, previous.escaped);
                }
            }

            if (skip) {
                errors |= state.fill_skip(input, &classifier, &marks, .{
                    .count = count,
                    .end = scan_end,
                    .structurals = previous.structurals,
                });
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
        assert(held.kept <= marks.range_start);
        assert(marks.range_start <= held.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        var flat_count = held.count;

        if (held.structurals_last != 0) {
            assert(held.start_last + block_bytes == state.block_next);

            flatten(indices[flat_count..][0..block_bytes], held.start_last, held.structurals_last);
            flat_count += @popCount(held.structurals_last);
        }

        const tail = state.tail_index(input, indices, marks.entries[marks.count..], flat_count);
        const utf8_failed = @reduce(.Or, state.utf8_errors) != 0;
        const count = tail.count;
        const marked = marks.count + tail.pending;
        const range: Range = .{ .end = count, .start = marks.range_start };

        state.pending_apply(indices, marks.entries[0..marked], range);

        if (held.errors | tail.errors != 0) return .{ .count = 0, .status = .failed };
        if (utf8_failed) return .{ .count = 0, .status = .failed };

        assert(count <= index_capacity);

        if (state.block_next < input.len) return .{ .count = count, .status = .ready };
        if (!state.finish()) return .{ .count = 0, .status = .failed };
        return .{ .count = count, .status = .exhausted };
    }

    inline fn suspects_check(
        indexer: *Indexer,
        block: *const Block,
        start: u32,
        suspects: u64,
    ) u64 {
        assert(start % block_bytes == 0);
        assert(indexer.utf8_next % block_bytes == 0);

        if (suspects == 0) return 0;

        const high = block_high_of(block);

        if (suspects & high != 0) indexer.utf8_block(block, start);

        return suspects & ~high;
    }

    inline fn utf8_block(indexer: *Indexer, block: *const Block, start: u32) void {
        assert(start % block_bytes == 0);
        assert(indexer.utf8_next <= start);

        if (start != indexer.utf8_next) indexer.utf8_errors |= indexer.utf8_settle();

        indexer.utf8_errors |= indexer.utf8_check(block);
        indexer.utf8_next = start + block_bytes;
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
        const marked = marks.count;

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

            errors |= state.suspects_check(&block, start, strings.suspect);
            state.block_next += block_bytes;
            state.carry_escaped = escape.carry;
            state.carry_breaks = @splat(0xff);

            marks.entries[marks.count] = .{
                .escaped = escape.escaped,
                .slot_base = bounds.count,
                .start = start,
                .structurals = 0,
            };
            marks.count += @intFromBool(escape.escaped != 0);
        }

        if (state.escape_validation) {
            for (marks.entries[marked..marks.count]) |*entry| {
                const block = block_load(input, entry.start);

                errors |= state.escapes_check(input, &block, entry.start, entry.escaped);
            }
        }

        marks.count = @min(marks.count, marked + 1);

        return errors;
    }

    inline fn block_scan(
        indexer: *Indexer,
        block: *const Block,
        classifier: *const Classifier,
    ) Scan {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.carry_escaped <= 1);

        const masks = block_classify(block, classifier, &indexer.carry_breaks);
        const escape = block_escape(indexer, block, classifier);
        const quote = masks.quote & ~escape.escaped;
        const in_string = prefix_xor(quote) ^ indexer.carry_in_string;
        const structurals = masks.starts & ~(in_string ^ quote);

        indexer.block_next += block_bytes;
        indexer.carry_escaped = escape.carry;
        indexer.carry_in_string = @bitCast(@as(i64, @bitCast(in_string)) >> 63);

        assert(structurals & (in_string ^ quote) == 0);

        return .{
            .attention = (escape.escaped | masks.suspect) & in_string,
            .escaped = escape.escaped & in_string,
            .structurals = structurals,
            .suspects = masks.suspect & in_string,
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
            .errors = indexer.suspects_check(&block, start, scan.suspects),
            .pending = 0,
        };

        if (scan.escaped != 0) {
            pending[0] = pending_of(&scan, start);
            pending[0].slot_base = count;
            result.pending = 1;
            result.errors |= indexer.escapes_check(input, &block, start, scan.escaped);
        }

        assert(result.count <= index_capacity);

        return result;
    }

    inline fn escapes_check(
        indexer: *Indexer,
        input: []const u8,
        block: *const Block,
        start: u32,
        escaped: u64,
    ) u64 {
        assert(start % block_bytes == 0);
        assert(start < input.len);
        assert(escaped & (escaped << 1) == 0);

        if (!indexer.escape_validation) return 0;
        if (escaped == 0) return 0;

        const kinds = block_escape_kinds(block);
        const invalid = escaped & ~kinds.valid;
        const unicode = escaped & kinds.unicode;
        if (unicode == 0) return invalid;

        const surrogate_low = unicode_check(input, .{
            .start = start,
            .surrogate_low = indexer.surrogate_low,
            .unicode = unicode,
        });

        indexer.surrogate_low = surrogate_low orelse 0;

        return invalid | @intFromBool(surrogate_low == null);
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

    fn marks_flush(indexer: *Indexer, indices: *Indices, marks: *Marks, count: u32) void {
        assert(marks.count <= pending_max);
        assert(marks.range_start <= count);
        assert(count <= index_capacity);

        const range: Range = .{ .end = count, .start = marks.range_start };

        indexer.pending_apply(indices, marks.entries[0..marks.count], range);

        marks.count = 0;
        marks.range_start = count;
    }

    fn flags_mark(indexer: *Indexer, indices: *Indices, entry: *const Pending, count: u32) void {
        assert(entry.escaped != 0);
        assert(entry.escaped & entry.structurals == 0);
        assert(entry.slot_base <= count);

        const sum = @addWithOverflow(~entry.structurals, entry.escaped);
        const slot_end = entry.slot_base + @popCount(entry.structurals);
        const following = sum[1] == 1 and slot_end < count;

        assert(slot_end <= count);

        var flagged = sum[0] & entry.structurals;

        for (0..block_bytes) |_| {
            const lowest = flagged & (~flagged +% 1);
            const slot = entry.slot_base + @popCount(entry.structurals & (lowest -% 1));

            assert(slot <= slot_end);
            if (lowest != 0) assert(slot < count);

            indices[@min(slot, index_capacity - 1)] |= if (lowest == 0) 0 else index_escaped;
            flagged ^= lowest;

            if (flagged == 0) break;
        }

        assert(flagged == 0);

        indices[@min(slot_end, index_capacity - 1)] |= if (following) index_escaped else 0;
        indexer.flag_next = indexer.flag_next or (sum[1] == 1 and !following);
    }

    fn finish(indexer: *Indexer) bool {
        assert(indexer.block_next % block_bytes == 0);
        assert(indexer.carry_in_string == 0 or ~indexer.carry_in_string == 0);
        assert(indexer.surrogate_low == 0);

        if (indexer.carry_escaped != 0) return false;
        if (indexer.carry_in_string != 0) return false;
        return @reduce(.Or, indexer.utf8_settle()) == 0;
    }

    inline fn utf8_settle(indexer: *Indexer) Chunk {
        assert(@sizeOf(Chunk) == chunk_bytes);
        assert(chunk_bytes >= 3);

        const words: [@divExact(chunk_bytes, 4)]u32 = @bitCast(indexer.utf8_previous);

        if (words[words.len - 1] & utf8_tail_high == 0) return @splat(0);

        const window: UTF8.Window = .{ .current = @splat(0), .previous = indexer.utf8_previous };

        indexer.utf8_previous = @splat(0);

        return utf8_lanes(&window);
    }

    inline fn utf8_check(indexer: *Indexer, block: *const Block) Chunk {
        assert(@sizeOf(Block) == block_bytes);
        assert(chunk_count >= 1);

        var errors: Chunk = @splat(0);
        var previous = indexer.utf8_previous;

        inline for (0..chunk_count) |chunk| {
            const window: UTF8.Window = .{ .current = block[chunk], .previous = previous };

            errors |= utf8_lanes(&window);
            previous = block[chunk];
        }

        indexer.utf8_previous = previous;

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

pub const Spot = struct {
    at: u32,
    open: u32,
};

pub const Close = packed struct(u64) {
    position: u32,
    escaped: bool,
    refilled: bool,
    padding: u30 = 0,

    pub const failed: Close = .{ .position = 0, .escaped = false, .refilled = false };
};

pub const Batch = struct {
    cursor: Cursor,
    indices: Entries,

    pub noinline fn refill(batch: *Batch, input: []const u8) bool {
        assert(batch.cursor.position <= batch.cursor.count);
        assert(input.len <= tokenizer_module.input_bytes_max);

        if (batch.cursor.exhausted) return false;

        batch.cursor.position = batch.cursor.count;

        if (!batch.cursor.refill_ahead(input, 1)) return false;

        batch.indices[batch.cursor.count] = entry_sentinel;

        assert(batch.cursor.position == 0);

        return true;
    }

    pub noinline fn close_find(batch: *Batch, input: []const u8, spot: Spot) Close {
        assert(spot.open < input.len);
        assert(spot.at < entries_capacity);

        var at = spot.at;
        var refilled = false;

        if (batch.indices[at] == entry_sentinel) {
            if (!batch.cursor.exhausted) {
                if (!batch.refill(input)) return .failed;

                at = 0;
                refilled = true;
            }
        }

        var entry = batch.indices[at];

        if (entry == entry_sentinel) {
            entry = batch.cursor.entry_exhausted(input);
        } else if (entry >= index_escaped) {
            batch.indices[at] = entry & index_position_mask;
        } else {
            assert(entry < input.len);
        }

        const before = entry & index_position_mask;
        const close = string_close_find(input, before);

        if (close <= spot.open) return .failed;

        return .{
            .position = close,
            .escaped = entry >= index_escaped,
            .refilled = refilled,
        };
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
    attention: u64,
    escaped: u64,
    structurals: u64,
    suspects: u64,
};

const SuspectScan = struct {
    start: u32,
    surrogate_low: u32,
    suspects: u64,
};

const UnicodeScan = struct {
    start: u32,
    surrogate_low: u32,
    unicode: u64,
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
    range_start: u32,

    inline fn block_note(marks: *Marks, scan: *const Scan, note: Note) void {
        assert(note.start % block_bytes == 0);
        assert(note.slot_base <= index_capacity);

        if (scan.escaped == 0) return;

        assert(marks.count < pending_max);

        marks.entries[marks.count] = pending_of(scan, note.start);
        marks.entries[marks.count].slot_base = note.slot_base;
        marks.count += 1;
    }
};

const Note = struct {
    slot_base: u32,
    start: u32,
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
        quote: Mask,
        starts: Mask,
        suspect: Mask,
    };
}

const Classes = ClassesType(ChunkMask);
const Masks = ClassesType(u64);

const Kinds = struct {
    operator: Chunk,
    whitespace: Chunk,
};

const Escape = struct {
    carry: u64,
    escaped: u64,
};

const EscapeKinds = struct {
    unicode: u64,
    valid: u64,
};

fn HexDigitsType(comptime Mask: type) type {
    return struct {
        hex: Mask,
        second_any: Mask,
        second_low: Mask,
        surrogate_first: Mask,
    };
}

const HexDigits = HexDigitsType(u64);
const HexDigitsAfter = HexDigitsType(@Int(.unsigned, hex_digit_count));

const Spill = struct {
    any: u64,
    first: u64,
    low: u64,
};

const Strings = struct {
    backslash: u64,
    quote: u64,
    suspect: u64,
};

inline fn block_strings(block: *const Block, classifier: *const Classifier) Strings {
    assert(@sizeOf(Block) == block_bytes);
    assert(chunk_count >= 1);

    var result: Strings = .{ .backslash = 0, .quote = 0, .suspect = 0 };

    inline for (0..chunk_count) |chunk| {
        const bytes = block[chunk];
        const shift = chunk * chunk_bytes;
        const backslash: ChunkMask = @bitCast(bytes == classifier.backslash);
        const quote: ChunkMask = @bitCast(bytes == classifier.quote);
        const suspect: ChunkMask = @bitCast(@as(SignedChunk, @bitCast(bytes)) < classifier.space);

        result.backslash |= @as(u64, backslash) << shift;
        result.quote |= @as(u64, quote) << shift;
        result.suspect |= @as(u64, suspect) << shift;
    }

    assert(result.quote & result.backslash == 0);

    return result;
}

inline fn block_escape_kinds(block: *const Block) EscapeKinds {
    assert(@sizeOf(Block) == block_bytes);
    assert(chunk_count >= 1);

    var result: EscapeKinds = .{ .unicode = 0, .valid = 0 };

    inline for (0..chunk_count) |chunk| {
        const bytes = block[chunk];
        const shift = chunk * chunk_bytes;
        const unicode: ChunkMask = @bitCast(bytes == @as(Chunk, @splat('u')));

        result.unicode |= @as(u64, unicode) << shift;
        result.valid |= @as(u64, chunk_escape_valid(bytes)) << shift;
    }

    assert(result.unicode & ~result.valid == 0);

    return result;
}

inline fn block_hex_digits(block: *const Block) HexDigits {
    assert(@sizeOf(Block) == block_bytes);
    assert(chunk_count >= 1);

    var result: HexDigits = .{ .hex = 0, .second_any = 0, .second_low = 0, .surrogate_first = 0 };

    inline for (0..chunk_count) |chunk| {
        const digits = hex_digits_of(chunk_bytes, block[chunk]);
        const shift = chunk * chunk_bytes;

        result.hex |= @as(u64, digits.hex) << shift;
        result.second_any |= @as(u64, digits.second_any) << shift;
        result.second_low |= @as(u64, digits.second_low) << shift;
        result.surrogate_first |= @as(u64, digits.surrogate_first) << shift;
    }

    assert(result.surrogate_first & ~result.hex == 0);
    assert(result.second_low & ~result.second_any == 0);

    return result;
}

inline fn hex_digits_after(input: []const u8, after: u32) HexDigitsAfter {
    assert(after % block_bytes == 0);
    assert(after - block_bytes < input.len);

    if (input.len - @min(input.len, after) < chunk_bytes) return hex_digits_end(input, after);

    const digits = hex_digits_of(chunk_bytes, input[after..][0..chunk_bytes].*);
    const result: HexDigitsAfter = .{
        .hex = @truncate(digits.hex),
        .second_any = @truncate(digits.second_any),
        .second_low = @truncate(digits.second_low),
        .surrogate_first = @truncate(digits.surrogate_first),
    };

    assert(result.surrogate_first & ~result.hex == 0);
    assert(result.second_low & ~result.second_any == 0);

    return result;
}

noinline fn hex_digits_end(input: []const u8, after: u32) HexDigitsAfter {
    assert(after % block_bytes == 0);
    assert(input.len - @min(input.len, after) < chunk_bytes);

    var bytes: [hex_digit_count]u8 = @splat(' ');
    const begin = @min(input.len, after);
    const count = @min(input.len - begin, hex_digit_count);

    @memcpy(bytes[0..count], input[begin..][0..count]);

    const result = hex_digits_of(hex_digit_count, bytes);

    assert(result.surrogate_first & ~result.hex == 0);

    return result;
}

inline fn hex_digits_of(
    comptime lanes: u32,
    bytes: @Vector(lanes, u8),
) HexDigitsType(@Int(.unsigned, lanes)) {
    comptime assert(lanes == chunk_bytes or lanes == hex_digit_count);
    assert(@typeInfo(@TypeOf(bytes)).vector.len == lanes);

    const Lanes = @Vector(lanes, u8);
    const Signed = @Vector(lanes, i8);
    const Mask = @Int(.unsigned, lanes);
    const lower = bytes | @as(Lanes, @splat(0x20));
    const decimal_offset = bytes -% @as(Lanes, @splat('0'));
    const letter_offset = lower -% @as(Lanes, @splat('a'));
    const decimal: Mask = @bitCast(decimal_offset < @as(Lanes, @splat(10)));
    const letter: Mask = @bitCast(letter_offset < @as(Lanes, @splat(6)));
    const any: Mask = @bitCast(@as(Signed, @bitCast(bytes)) > @as(Signed, @splat('7')));
    const low: Mask = @bitCast(@as(Signed, @bitCast(lower)) > @as(Signed, @splat('b')));
    const first: Mask = @bitCast(lower == @as(Lanes, @splat('d')));

    return .{
        .hex = decimal | letter,
        .second_any = any,
        .second_low = low,
        .surrogate_first = first,
    };
}

inline fn chunk_escape_valid(bytes: Chunk) ChunkMask {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@typeInfo(@TypeOf(bytes)).vector.len == chunk_bytes);

    if (pshufb_enabled) {
        const listed: ChunkMask = @bitCast(shuffle(&escape_table, bytes) == bytes);
        const quote: ChunkMask = @bitCast(bytes == @as(Chunk, @splat('"')));
        const carriage: ChunkMask = @bitCast(bytes == @as(Chunk, @splat('r')));

        return listed | quote | carriage;
    }

    var result: ChunkMask = 0;

    inline for ("\"\\/bfnrtu") |byte| {
        const lanes: ChunkMask = @bitCast(bytes == @as(Chunk, @splat(byte)));

        result |= lanes;
    }

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

inline fn block_classify(block: *const Block, classifier: *const Classifier, breaks: *Chunk) Masks {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@sizeOf(Block) == block_bytes);

    var result: Masks = .{
        .quote = 0,
        .starts = 0,
        .suspect = 0,
    };

    inline for (0..chunk_count) |chunk| {
        const classes = chunk_classify(block[chunk], classifier, breaks);

        inline for (@typeInfo(Classes).@"struct".field_names) |name| {
            @field(result, name) |= @as(u64, @field(classes, name)) << (chunk * chunk_bytes);
        }
    }

    assert(result.quote & ~result.starts == 0);

    return result;
}

inline fn block_escape(
    indexer: *const Indexer,
    block: *const Block,
    classifier: *const Classifier,
) Escape {
    assert(indexer.carry_escaped <= 1);
    assert(@sizeOf(Block) == block_bytes);

    var any: Chunk = @splat(0);

    inline for (0..chunk_count) |chunk| any |= lanes_of(block[chunk] == classifier.backslash);

    if (lanes_mask(any) != 0) {
        @branchHint(.unlikely);

        var backslash: u64 = 0;

        inline for (0..chunk_count) |chunk| {
            const lanes = lanes_of(block[chunk] == classifier.backslash);

            backslash |= @as(u64, lanes_mask(lanes)) << (chunk * chunk_bytes);
        }

        return escaped_find(indexer, backslash);
    }

    return .{ .carry = 0, .escaped = indexer.carry_escaped };
}

inline fn chunk_classify(bytes: Chunk, classifier: *const Classifier, breaks: *Chunk) Classes {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@typeInfo(@TypeOf(bytes)).vector.len == chunk_bytes);

    const kinds = chunk_kinds(bytes, classifier);
    const breaks_chunk = kinds.whitespace | kinds.operator;
    const breaks_before = @shuffle(u8, breaks.*, breaks_chunk, UTF8.shift_mask_one);
    const starts = kinds.operator | (breaks_before & ~kinds.whitespace);

    breaks.* = breaks_chunk;

    return .{
        .quote = @bitCast(bytes == classifier.quote),
        .starts = lanes_mask(starts),
        .suspect = @bitCast(@as(SignedChunk, @bitCast(bytes)) < classifier.space),
    };
}

inline fn chunk_kinds(bytes: Chunk, classifier: *const Classifier) Kinds {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@typeInfo(@TypeOf(bytes)).vector.len == chunk_bytes);

    const curled = bytes | @as(Chunk, @bitCast(classifier.space));

    if (pshufb_enabled) {
        return .{
            .operator = lanes_of(shuffle(&classifier.operator, bytes) == curled),
            .whitespace = lanes_of(shuffle(&classifier.whitespace, bytes) == bytes),
        };
    }

    const brace_open = lanes_of(curled == @as(Chunk, @splat('{')));
    const brace_close = lanes_of(curled == @as(Chunk, @splat('}')));
    const colon = lanes_of(bytes == @as(Chunk, @splat(':')));
    const comma = lanes_of(bytes == @as(Chunk, @splat(',')));
    const quote = lanes_of(bytes == classifier.quote);
    const space = lanes_of(bytes == @as(Chunk, @splat(' ')));
    const tab = lanes_of(bytes == @as(Chunk, @splat('\t')));
    const line_feed = lanes_of(bytes == @as(Chunk, @splat('\n')));
    const carriage_return = lanes_of(bytes == @as(Chunk, @splat('\r')));

    return .{
        .operator = brace_open | brace_close | colon | comma | quote,
        .whitespace = space | tab | line_feed | carriage_return,
    };
}

inline fn lanes_of(predicate: @Vector(chunk_bytes, bool)) Chunk {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@typeInfo(@TypeOf(predicate)).vector.len == chunk_bytes);

    const set: Chunk = @splat(0xff);
    const clear: Chunk = @splat(0);

    return @select(u8, predicate, set, clear);
}

inline fn lanes_mask(lanes: Chunk) ChunkMask {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@typeInfo(@TypeOf(lanes)).vector.len == chunk_bytes);

    const zero: SignedChunk = @splat(0);

    return @bitCast(@as(SignedChunk, @bitCast(lanes)) < zero);
}

inline fn fill_full(comptime unroll_index: u8, count: u32, marks: *const Marks) bool {
    assert(count <= index_capacity);
    assert(marks.count <= pending_max);

    if (unroll_index != 0) return false;
    return count > index_capacity - scan_unroll * block_bytes;
}

inline fn marks_full(comptime unroll_index: u8, marks: *const Marks) bool {
    assert(marks.count <= pending_max);
    assert(marks.range_start <= index_capacity);

    if (unroll_index != 0) return false;
    return marks.count > pending_max - scan_unroll - 1;
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
    operator: Chunk,
    quote: Chunk,
    space: SignedChunk,
    whitespace: Chunk,
};

const classifier_constant: Classifier = .{
    .backslash = @splat('\\'),
    .operator = operator_table,
    .quote = @splat('"'),
    .space = @splat(0x20),
    .whitespace = whitespace_table,
};

inline fn classifier_load() Classifier {
    var storage: Classifier = undefined;
    const opaque_storage: *volatile Classifier = &storage;

    opaque_storage.* = classifier_constant;

    const result = opaque_storage.*;

    assert(result.space[0] == 0x20);
    assert(result.quote[chunk_bytes - 1] == '"');

    return result;
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

const escape_table = table_repeat(.{
    0xff,
    0xff,
    'b',
    0xff,
    't',
    'u',
    'f',
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    '\\',
    0xff,
    'n',
    '/',
});

const operator_table = table_repeat(.{
    0,
    0,
    '"',
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

inline fn block_high_of(block: *const Block) u64 {
    assert(@sizeOf(Block) == block_bytes);
    assert(chunk_count >= 1);

    var result: u64 = 0;

    inline for (0..chunk_count) |chunk| {
        const high: ChunkMask = @bitCast(block[chunk] >= @as(Chunk, @splat(0x80)));

        result |= @as(u64, high) << (chunk * chunk_bytes);
    }

    return result;
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

noinline fn unicode_check(input: []const u8, scan: UnicodeScan) ?u32 {
    assert(scan.start % block_bytes == 0);
    assert(scan.start < input.len);
    assert(scan.unicode != 0);

    const whole = input.len - scan.start >= block_bytes;
    const block = if (whole) block_load(input, scan.start) else block_load_tail(input, scan.start);
    const suspects = unicode_suspects(input, &block, scan.start, scan.unicode) orelse return null;
    if (suspects == 0) return scan.surrogate_low;

    return unicode_resolve(input, .{
        .start = scan.start,
        .surrogate_low = scan.surrogate_low,
        .suspects = suspects,
    });
}

inline fn unicode_resolve(input: []const u8, scan: SuspectScan) ?u32 {
    assert(scan.start % block_bytes == 0);
    assert(scan.start < input.len);
    assert(scan.suspects != 0);

    var rest = scan.suspects;
    var surrogate_low = scan.surrogate_low;

    for (0..block_bytes) |_| {
        if (rest == 0) return surrogate_low;

        const position = scan.start + @ctz(rest);

        rest &= rest - 1;

        if (position == surrogate_low) {
            surrogate_low = 0;

            continue;
        }

        assert(input[position - 1] == '\\');

        const escape = input[position - 1 ..];
        const length = tokenizer_module.escape_length(escape) catch return null;
        if (length == escape_unicode_bytes) continue;

        assert(length == 2 * escape_unicode_bytes);

        surrogate_low = position + escape_unicode_bytes;
    }

    assert(rest == 0);

    return surrogate_low;
}

inline fn unicode_suspects(input: []const u8, block: *const Block, start: u32, unicode: u64) ?u64 {
    assert(start % block_bytes == 0);
    assert(start < input.len);
    assert(unicode != 0);

    const inside = block_hex_digits(block);

    var needed: u64 = 0;

    inline for (1..hex_digit_count + 1) |offset| {
        needed |= unicode << offset;
    }

    if (needed & ~inside.hex != 0) return null;

    var spill: Spill = .{ .any = 0, .first = 0, .low = 0 };

    if (unicode >> (block_bytes - hex_digit_count) != 0) {
        spill = unicode_spill(input, start, unicode) orelse return null;
    }

    const first = unicode & ((inside.surrogate_first >> 1) | spill.first);
    if (first == 0) return 0;

    const surrogate = first & ((inside.second_any >> 2) | spill.any);
    if (surrogate == 0) return 0;

    const low = surrogate & ((inside.second_low >> 2) | spill.low);
    const high = surrogate & ~low;
    const paired = high & pair_high_positions;
    if ((paired << escape_unicode_bytes) & ~low != 0) return null;

    const resolved = paired | (paired << escape_unicode_bytes);
    const result = surrogate & ~resolved;

    assert(result & ~unicode == 0);
    assert(resolved & ~surrogate == 0);

    return result;
}

inline fn unicode_spill(input: []const u8, start: u32, unicode: u64) ?Spill {
    assert(start % block_bytes == 0);
    assert(start < input.len);
    assert(unicode >> (block_bytes - hex_digit_count) != 0);

    const after = hex_digits_after(input, start + block_bytes);

    var needed: u64 = 0;

    inline for (1..hex_digit_count + 1) |offset| {
        needed |= unicode >> (block_bytes - offset);
    }

    assert(needed != 0);
    assert(needed >> hex_digit_count == 0);

    if (needed & ~@as(u64, after.hex) != 0) return null;

    const result: Spill = .{
        .any = @as(u64, after.second_any) << (block_bytes - 2),
        .first = @as(u64, after.surrogate_first) << (block_bytes - 1),
        .low = @as(u64, after.second_low) << (block_bytes - 2),
    };

    assert(result.low & ~result.any == 0);

    return result;
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

    const result: ChunkMask = @bitCast(utf8_lanes_lookup(window) != @as(Chunk, @splat(0)));

    if (@reduce(.Or, window.current | window.previous) < 0x80) assert(result == 0);

    return result;
}

inline fn utf8_lanes(window: *const UTF8.Window) Chunk {
    assert(chunk_bytes == @typeInfo(Chunk).vector.len);
    assert(@sizeOf(UTF8.Window) == 2 * chunk_bytes);

    if (comptime pshufb_enabled) return utf8_lanes_lookup(window);

    const errors: @Vector(chunk_bytes, bool) = @bitCast(UTF8.errors_compare(window));

    return @select(u8, errors, @as(Chunk, @splat(0xff)), @as(Chunk, @splat(0)));
}

inline fn utf8_lanes_lookup(window: *const UTF8.Window) Chunk {
    comptime assert(pshufb_enabled);
    assert(@sizeOf(UTF8.Window) == 2 * chunk_bytes);

    const nibble: Chunk = @splat(0x0f);
    const bytes = window.current;
    const prior_one = @shuffle(u8, window.previous, bytes, UTF8.shift_mask_one);
    const prior_two = @shuffle(u8, window.previous, bytes, UTF8.shift_mask_two);
    const prior_three = @shuffle(u8, window.previous, bytes, UTF8.shift_mask_three);
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

    return errors;
}

const utf8_tail_high: u32 = 0x8080_8000;
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
        const shift_mask_one = shift_mask(1);
        const shift_mask_two = shift_mask(2);
        const shift_mask_three = shift_mask(3);

        pub fn errors_compare(window: *const Window) Mask {
            assert(@sizeOf(Window) == 2 * lanes);
            assert(lanes >= 4);

            const bytes = window.current;
            const prior_one = @shuffle(u8, window.previous, bytes, shift_mask_one);
            const prior_two = @shuffle(u8, window.previous, bytes, shift_mask_two);
            const prior_three = @shuffle(u8, window.previous, bytes, shift_mask_three);
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

        fn shift_mask(comptime count: u32) @Vector(lanes, i32) {
            @setEvalBranchQuota(lanes * 16);
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

fn test_fill_failed(input: []const u8) bool {
    assert(input.len <= 2 * scan_bytes_max);
    assert(input.len > 0);

    var indexer: Indexer = .empty;
    var indices: Indices = undefined;

    for (0..input.len + 2) |_| {
        switch (indexer.fill(input, &indices, 0).status) {
            .exhausted => return false,
            .failed => return true,
            .ready => {},
        }
    }

    unreachable;
}

fn test_pieces_write(random: std.Random, content: []u8) []const u8 {
    assert(content.len >= 8);
    assert(content.len <= 1024);

    const pieces = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
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
        "\xe0\x80\x80",
        "\xf5\x80\x80\x80",
        "\x80",
        "\xc2",
        "\xe0\xa0",
        "\xf0\x90\x80",
        "\xff",
    };

    var length: u32 = 0;
    const count = random.uintLessThan(u32, 16);

    for (0..count) |_| {
        const weight = random.uintLessThan(u32, 8);
        const piece_count: u32 = if (weight < 5) 2 else pieces.len;
        const piece = pieces[random.uintLessThan(u32, piece_count)];
        if (length + piece.len > content.len) break;

        @memcpy(content[length..][0..piece.len], piece);
        length += @intCast(piece.len);
    }

    return content[0..length];
}

test "the indexer fails a document exactly when one of its strings is invalid UTF-8" {
    var prng: std.Random.DefaultPrng = .init(0x75746639);
    const random = prng.random();

    for (0..30_000) |_| {
        var content_first: [512]u8 = undefined;
        var buffer: [2048]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&buffer);

        try sink.writeAll("[");
        try sink.splatByteAll(' ', random.uintLessThan(u32, 2 * block_bytes));
        try sink.writeAll("\"");

        const first = test_pieces_write(random, &content_first);

        try sink.writeAll(first);
        try sink.writeAll("\",");
        try sink.splatByteAll(' ', random.uintLessThan(u32, 4 * block_bytes));
        try sink.writeAll("\"");

        var content_second: [512]u8 = undefined;
        const second = test_pieces_write(random, &content_second);

        try sink.writeAll(second);
        try sink.writeAll("\"");
        try sink.splatByteAll(' ', random.uintLessThan(u32, 2 * block_bytes));
        try sink.writeAll("]");

        const valid = std.unicode.utf8ValidateSlice(first) and
            std.unicode.utf8ValidateSlice(second);

        try testing.expectEqual(!valid, test_fill_failed(sink.buffered()));
    }
}

fn test_escapes_write(random: std.Random, content: []u8) []const u8 {
    assert(content.len >= 16);
    assert(content.len <= 1024);

    const pieces = [_][]const u8{
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "a",
        "u",
        "\\\\",
        "\\\"",
        "\\/",
        "\\n",
        "\\u0041",
        "\\uD83D\\uDE00",
        "\\b",
        "\\f",
        "\\r",
        "\\t",
        "\\u00e9",
        "\\udbff\\udfff",
        "\\uD83D",
        "\\uDE00",
        "\\uD83Da",
        "\\uD83D\\u0041",
        "\\\\uDE00",
        "\\\\\\uDE00",
        "\\u12",
        "\\uZZZZ",
        "\\U0041",
        "\\a",
        "\\x",
        "\\'",
        "\\ ",
    };

    var length: u32 = 0;
    const count = random.uintLessThan(u32, 12);

    for (0..count) |_| {
        const weight = random.uintLessThan(u32, 8);
        const piece_count: u32 = if (weight < 6) 15 else pieces.len;
        const piece = pieces[random.uintLessThan(u32, piece_count)];
        if (length + piece.len > content.len) break;

        @memcpy(content[length..][0..piece.len], piece);
        length += @intCast(piece.len);
    }

    return content[0..length];
}

test "the indexer fails a document exactly when one of its escapes is invalid" {
    var prng: std.Random.DefaultPrng = .init(0x65736370);
    const random = prng.random();

    var outcomes: [2]u32 = @splat(0);

    for (0..30_000) |_| {
        var content_first: [256]u8 = undefined;
        var buffer: [1024]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&buffer);

        try sink.writeAll("[");
        try sink.splatByteAll(' ', random.uintLessThan(u32, 2 * block_bytes));
        try sink.writeAll("\"");
        try sink.writeAll(test_escapes_write(random, &content_first));
        try sink.writeAll("\",");

        var content_second: [256]u8 = undefined;

        try sink.splatByteAll(' ', random.uintLessThan(u32, 2 * block_bytes));
        try sink.writeAll("\"");
        try sink.writeAll(test_escapes_write(random, &content_second));
        try sink.writeAll("\"");
        try sink.splatByteAll(' ', random.uintLessThan(u32, 2 * block_bytes));
        try sink.writeAll("]");

        const document = sink.buffered();
        const valid = try std.json.validate(testing.allocator, document);

        outcomes[@intFromBool(valid)] += 1;

        try testing.expectEqual(!valid, test_fill_failed(document));
    }

    try testing.expect(outcomes[0] > 1_000);
    try testing.expect(outcomes[1] > 1_000);
}

test "the indexer fails a long string exactly when one of its skipped escapes is invalid" {
    var prng: std.Random.DefaultPrng = .init(0x736b6970);
    const random = prng.random();

    var outcomes: [2]u32 = @splat(0);
    var buffer: [2 * scan_bytes_max]u8 = undefined;

    for (0..2_000) |_| {
        var content: [256]u8 = undefined;
        var sink: std.Io.Writer = .fixed(&buffer);

        try sink.writeAll("[\"");
        try sink.splatByteAll('a', scan_bytes_max + random.uintLessThan(u32, 8 * block_bytes));
        try sink.writeAll(test_escapes_write(random, &content));
        try sink.splatByteAll('a', random.uintLessThan(u32, 4 * block_bytes));
        try sink.writeAll("\"]");

        const document = sink.buffered();
        const valid = try std.json.validate(testing.allocator, document);

        outcomes[@intFromBool(valid)] += 1;

        try testing.expectEqual(!valid, test_fill_failed(document));
    }

    try testing.expect(outcomes[0] > 200);
    try testing.expect(outcomes[1] > 200);
}

test "the indexer pairs surrogate escapes across a block and a fill boundary" {
    const texts = [_][]const u8{ "\\uD83D\\uDE00", "\\uD83D\\u0041", "\\u0041\\uDE00", "\\uDE00" };
    const expected_valid = [_]bool{ true, false, false, false };
    const boundaries = [_]u32{ scan_bytes_max, scan_bytes_max + 4 * block_bytes };

    var buffer: [scan_bytes_max + 8 * block_bytes]u8 = undefined;
    var small: [32]u8 = undefined;

    for (texts, expected_valid) |text, valid| {
        const document = try std.mem.print(&small, "[\"{s}\"]", .{text});

        try testing.expectEqual(valid, try std.json.validate(testing.allocator, document));
        try testing.expectEqual(!valid, test_fill_failed(document));

        for (boundaries) |boundary| {
            for (boundary - 16..boundary + 4) |offset| {
                @memset(&buffer, 'a');
                @memcpy(buffer[offset..][0..text.len], text);

                buffer[0] = '[';
                buffer[1] = '"';
                buffer[buffer.len - 2] = '"';
                buffer[buffer.len - 1] = ']';

                try testing.expectEqual(!valid, test_fill_failed(&buffer));
            }
        }
    }
}

test "the indexer judges each unicode escape at every block offset as the standard library does" {
    const texts = [_][]const u8{
        "\\u0041",
        "\\uG234",
        "\\u1G34",
        "\\u12G4",
        "\\u123G",
        "\\u12 4",
        "\\uabcd\\uABCD",
        "\\ud7ff\\uD7A3",
        "\\ud800\\udc00",
        "\\uDBFF\\uDFFF",
        "\\ud800",
        "\\udc00",
        "\\ud800\\ud800",
        "\\ud800\\u0041",
        "\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9\\u00e9",
        "\\u3042\\u3044\\uD83D\\uDE00\\u3046\\u304G",
    };

    var buffer: [4 * block_bytes + 128]u8 = undefined;
    var outcomes: [2]u32 = @splat(0);

    for (texts) |text| {
        for (0..2 * block_bytes) |offset| {
            var sink: std.Io.Writer = .fixed(&buffer);

            try sink.writeAll("[\"");
            try sink.splatByteAll('a', offset);
            try sink.writeAll(text);
            try sink.writeAll("\"]");

            const document = sink.buffered();
            const valid = try std.json.validate(testing.allocator, document);

            outcomes[@intFromBool(valid)] += 1;

            try testing.expectEqual(!valid, test_fill_failed(document));
        }
    }

    try testing.expect(outcomes[0] > 0);
    try testing.expect(outcomes[1] > 0);
}

test "the indexer pairs surrogate escapes at every block offset as the standard library does" {
    const texts = [_][]const u8{
        "\\uD83D\\uDE00\\uDBFF\\uDFFF",
        "\\ud83d\\uDe00",
        "\\uD800\\uD800\\uDC00",
        "\\uD800\\uDC00\\uDC00",
        "\\uDC00\\uD800",
        "\\uD83Dx\\uDE00",
        "\\uD83D\\\\uDE00",
        "\\uD83D\\n\\uDE00",
        "\\u3042\\uD83D\\uDE00\\u3042",
        "\\uDBFF\\uE000",
        "\\uD7FF\\uDC00",
    };

    var buffer: [4 * block_bytes + 128]u8 = undefined;
    var outcomes: [2]u32 = @splat(0);

    for (texts) |text| {
        for (0..2 * block_bytes) |offset| {
            var sink: std.Io.Writer = .fixed(&buffer);

            try sink.writeAll("[\"");
            try sink.splatByteAll('a', offset);
            try sink.writeAll(text);
            try sink.writeAll("\"]");

            const document = sink.buffered();
            const valid = try std.json.validate(testing.allocator, document);

            outcomes[@intFromBool(valid)] += 1;

            try testing.expectEqual(!valid, test_fill_failed(document));
        }
    }

    try testing.expect(outcomes[0] > 1_000);
    try testing.expect(outcomes[1] > 300);
}

test "the indexer judges every pair of surrogate boundary escapes at every block offset" {
    const units = [_][]const u8{
        "0041",
        "d7ff",
        "D800",
        "d83d",
        "DAFF",
        "db00",
        "dB7F",
        "DBFF",
        "dc00",
        "DE00",
        "dfff",
        "E000",
        "ffff",
    };

    var buffer: [4 * block_bytes + 128]u8 = undefined;
    var outcomes: [2]u32 = @splat(0);

    for (units) |first| {
        for (units) |second| {
            for (0..2 * block_bytes) |offset| {
                var sink: std.Io.Writer = .fixed(&buffer);

                try sink.writeAll("[\"");
                try sink.splatByteAll('a', offset);
                try sink.writeAll("\\u");
                try sink.writeAll(first);
                try sink.writeAll("\\u");
                try sink.writeAll(second);
                try sink.writeAll("\"]");

                const document = sink.buffered();
                const valid = try std.json.validate(testing.allocator, document);

                outcomes[@intFromBool(valid)] += 1;

                try testing.expectEqual(!valid, test_fill_failed(document));
            }
        }
    }

    try testing.expect(outcomes[0] > 10_000);
    try testing.expect(outcomes[1] > 4_000);
}

test "the indexer fails a control byte inside a string and allows one outside it" {
    var buffer: [256]u8 = undefined;

    for ([_]u8{ 0x00, 0x01, 0x08, 0x09, 0x0a, 0x0d, 0x1f, 0x20, 0x7f }) |byte| {
        for (0..2 * block_bytes) |offset| {
            @memset(buffer[0 .. offset + 1], 'a');
            buffer[0] = '"';
            buffer[offset + 1] = byte;
            buffer[offset + 2] = '"';
            @memset(buffer[offset + 3 ..], ' ');

            try testing.expectEqual(byte < 0x20, test_fill_failed(&buffer));

            buffer[offset + 2] = ' ';
            buffer[offset + 1] = '"';
            buffer[offset + 3] = byte;

            try testing.expect(!test_fill_failed(&buffer));
        }
    }
}

fn test_starts_expected(input: []const u8, starts: *std.ArrayList(u32)) void {
    assert(input.len <= tokenizer_module.input_bytes_max);
    assert(starts.items.len == 0);

    var in_string = false;
    var escaped = false;
    var after_break = true;
    var flag: u32 = 0;

    for (input, 0..) |byte, position| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                flag = index_escaped;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
                after_break = true;
            } else {
                assert(byte >= 0x20);
            }

            continue;
        }

        const start = @as(u32, @intCast(position)) | flag;
        const count = starts.items.len;

        switch (byte) {
            '"' => {
                starts.appendAssumeCapacity(start);
                in_string = true;
            },
            '{', '}', '[', ']', ':', ',' => {
                starts.appendAssumeCapacity(start);
                after_break = true;
            },
            ' ', '\n', '\r', '\t' => after_break = true,
            else => {
                if (after_break) starts.appendAssumeCapacity(start);

                after_break = false;
            },
        }

        if (starts.items.len > count) flag = 0;
    }
}

fn test_starts_actual(input: []const u8, starts: *std.ArrayList(u32)) !void {
    assert(input.len <= tokenizer_module.input_bytes_max);
    assert(starts.items.len == 0);

    var indexer: Indexer = .empty;
    var indices: Indices = undefined;

    for (0..input.len + 2) |_| {
        const result = indexer.fill(input, &indices, 0);

        try testing.expect(result.status != .failed);

        starts.appendSliceAssumeCapacity(indices[0..result.count]);

        if (result.status == .exhausted) return;
    }

    return error.TestUnexpectedResult;
}

test "the indexer flags an escaped string it skips over as a walk over the bytes does" {
    const escapes = [_][]const u8{
        "\\n",
        "\\\\",
        "\\\"",
        "\\u00e9",
        "\\ud83d\\ude00",
    };

    var prng: std.Random.DefaultPrng = .init(0x666c6167);
    const random = prng.random();

    var buffer: [2 * scan_bytes_max]u8 = undefined;
    var expected_storage: [256]u32 = undefined;
    var actual_storage: [256]u32 = undefined;
    var flagged: u32 = 0;

    for (0..200) |_| {
        var sink: std.Io.Writer = .fixed(&buffer);

        try sink.writeAll("[\"");
        try sink.splatByteAll('a', scan_bytes_max);
        try sink.writeAll("\"");

        for (0..random.uintLessThan(u32, 36)) |_| {
            const escape = escapes[random.uintLessThan(u32, escapes.len)];

            try sink.writeAll(",\"");
            try sink.splatByteAll('a', random.uintLessThan(u32, 6 * block_bytes));

            if (random.boolean()) try sink.writeAll(escape);

            try sink.splatByteAll('a', random.uintLessThan(u32, 6 * block_bytes));
            try sink.writeAll("\"");
        }

        try sink.writeAll("]");

        const input = sink.buffered();
        var expected: std.ArrayList(u32) = .initBuffer(&expected_storage);
        var actual: std.ArrayList(u32) = .initBuffer(&actual_storage);

        test_starts_expected(input, &expected);
        try test_starts_actual(input, &actual);

        try testing.expectEqualSlices(u32, expected.items, actual.items);

        for (expected.items) |start| flagged += @intFromBool(start & index_escaped != 0);
    }

    try testing.expect(flagged > 1_000);
}

test "the indexer flags escaped strings past a full scratch as a walk over the bytes does" {
    const escapes = [_][]const u8{
        "\\n",
        "\\\\",
        "\\\"",
        "\\u00e9",
        "\\ud83d\\ude00",
    };

    const reaches = [_]u32{
        16,
        block_bytes,
        6 * block_bytes,
    };

    var prng: std.Random.DefaultPrng = .init(0x666c7573);
    const random = prng.random();

    var buffer: [2 * scan_bytes_max]u8 = undefined;
    var expected_storage: [8192]u32 = undefined;
    var actual_storage: [8192]u32 = undefined;
    var flagged: u32 = 0;

    for (0..60) |_| {
        var sink: std.Io.Writer = .fixed(&buffer);
        const reach_max = reaches[random.uintLessThan(u32, reaches.len)];

        try sink.writeAll("[0");

        for (0..4000) |_| {
            if (buffer.len - sink.buffered().len < 2 * reach_max + 16) break;

            const escape = escapes[random.uintLessThan(u32, escapes.len)];
            const reach = random.intRangeAtMost(u32, 1, reach_max);

            try sink.writeAll(",\"");
            try sink.splatByteAll('a', random.uintLessThan(u32, reach));
            try sink.writeAll(escape);
            try sink.splatByteAll('a', random.uintLessThan(u32, reach));
            try sink.writeAll("\"");
        }

        try sink.writeAll("]");

        const input = sink.buffered();
        var expected: std.ArrayList(u32) = .initBuffer(&expected_storage);
        var actual: std.ArrayList(u32) = .initBuffer(&actual_storage);

        test_starts_expected(input, &expected);
        try test_starts_actual(input, &actual);

        try testing.expectEqualSlices(u32, expected.items, actual.items);

        for (expected.items) |start| flagged += @intFromBool(start & index_escaped != 0);
    }

    try testing.expect(flagged > 10_000);
}

test "the indexer marks the same positions and escape flags as a walk over the bytes" {
    const pieces = [_][]const u8{
        "{",
        "}",
        "[",
        "]",
        ":",
        ",",
        " ",
        "  ",
        "\n",
        "\t",
        "\r\n",
        "true",
        "null",
        "-12.5e3",
        "7",
        "\"\"",
        "\"text\"",
        "\"a\\\"b\"",
        "\"\\\\\"",
        "\"\\u00e9 \\n\"",
        "\"\xc3\xa9\"",
        "\"\xe6\x97\xa5\xe6\x9c\xac\"",
        "\"a long string that runs past the end of the scanned block on its own, twice over\"",
    };

    var prng: std.Random.DefaultPrng = .init(0x73746172);
    const random = prng.random();

    var buffer: [1024]u8 = undefined;
    var expected_storage: [1024]u32 = undefined;
    var actual_storage: [8192]u32 = undefined;

    for (0..30_000) |_| {
        var expected: std.ArrayList(u32) = .initBuffer(&expected_storage);
        var actual: std.ArrayList(u32) = .initBuffer(&actual_storage);
        var sink: std.Io.Writer = .fixed(&buffer);

        for (0..random.uintLessThan(u32, 60)) |_| {
            sink.writeAll(pieces[random.uintLessThan(u32, pieces.len)]) catch break;
        }

        const input = sink.buffered();

        test_starts_expected(input, &expected);
        try test_starts_actual(input, &actual);

        try testing.expectEqualSlices(u32, expected.items, actual.items);
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
