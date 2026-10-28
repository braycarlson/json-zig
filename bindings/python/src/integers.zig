const std = @import("std");

const lacuna = @import("lacuna");

const assert = std.debug.assert;

const c = lacuna.c;

const PyObject = c.PyObject;

const cache_bits: u6 = 10;
const cache_count: u32 = 1 << cache_bits;
const occupied_words: u32 = @divExact(cache_count, 64);
const small_max: i64 = 256;
const small_min: i64 = -5;

const Touched = @Int(.unsigned, occupied_words);

comptime {
    assert(std.math.isPowerOfTwo(cache_count));
    assert(occupied_words * 64 == cache_count);
}

const Entry = struct {
    object: *PyObject,
    value: i64,
};

pub const Cache = struct {
    entries: [cache_count]Entry,
    occupied: [occupied_words]u64,
    touched: Touched,

    pub fn reset(cache: *Cache) void {
        assert(occupied_words == cache.occupied.len);
        assert(cache_count == cache.entries.len);

        cache.occupied = @splat(0);
        cache.touched = 0;
    }

    pub fn deinit(cache: *Cache) void {
        assert(occupied_words == cache.occupied.len);
        assert(cache_count == cache.entries.len);

        var words = cache.touched;

        for (0..occupied_words) |_| {
            if (words == 0) break;

            const word_index = @ctz(words);
            var bits = cache.occupied[word_index];

            for (0..64) |_| {
                if (bits == 0) break;

                const slot = @as(u32, word_index) * 64 + @ctz(bits);

                c.Py_DecRef(cache.entries[slot].object);
                bits &= bits - 1;
            }

            cache.occupied[word_index] = 0;
            words &= words - 1;
        }

        cache.touched = 0;

        if (std.debug.runtime_safety) {
            for (cache.occupied) |word| assert(word == 0);
        }
    }

    pub inline fn object_of(cache: *Cache, value: i64) ?*PyObject {
        if (std.debug.runtime_safety) assert(value != std.math.minInt(i64));
        assert(occupied_words == cache.occupied.len);

        const slot = slot_of(value);
        const bit = @as(u64, 1) << @intCast(slot & 63);
        const entry = &cache.entries[slot];
        if (std.debug.runtime_safety) assert(!cache.held(slot) or slot_of(entry.value) == slot);

        if (cache.occupied[slot >> 6] & bit != 0) {
            if (entry.value == value) return entry.object;
        }

        return cache.object_store(value);
    }

    fn held(cache: *const Cache, slot: u32) bool {
        assert(slot < cache_count);
        assert(occupied_words == cache.occupied.len);

        return cache.occupied[slot >> 6] & (@as(u64, 1) << @intCast(slot & 63)) != 0;
    }

    noinline fn object_store(cache: *Cache, value: i64) ?*PyObject {
        if (std.debug.runtime_safety) assert(value != std.math.minInt(i64));
        assert(occupied_words == cache.occupied.len);

        const slot = slot_of(value);
        const word = &cache.occupied[slot >> 6];
        const bit = @as(u64, 1) << @intCast(slot & 63);
        const entry = &cache.entries[slot];

        if (word.* & bit != 0) {
            assert(entry.value != value);

            c.Py_DecRef(entry.object);
            word.* &= ~bit;
        }

        const object = c.PyLong_FromLongLong(value) orelse return null;

        entry.* = .{ .object = object, .value = value };
        word.* |= bit;
        cache.touched |= @as(Touched, 1) << @intCast(slot >> 6);

        return object;
    }
};

pub fn small_is(value: i64) bool {
    assert(small_min < 0);
    assert(small_max > 0);

    return value >= small_min and value <= small_max;
}

fn slot_of(value: i64) u32 {
    if (std.debug.runtime_safety) assert(value != std.math.minInt(i64));
    assert(std.math.isPowerOfTwo(cache_count));
    assert(cache_bits < 32);

    const mixed = @as(u64, @bitCast(value)) *% 0x9e37_79b9_7f4a_7c15;
    const result: u32 = @intCast(mixed >> (64 - @as(u7, cache_bits)));

    assert(result < cache_count);

    return result;
}
