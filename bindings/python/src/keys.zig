const std = @import("std");

const lacuna = @import("lacuna");

const objects = @import("objects.zig");
const policy_module = @import("policy.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const Policy = policy_module.Policy;
const PyObject = c.PyObject;

pub const cached_bytes_max: u32 = 64;

const cache_bits: u6 = 10;
const cache_count: u32 = 1 << cache_bits;
const occupied_words: u32 = @divExact(cache_count, 64);

const Touched = @Int(.unsigned, occupied_words);

comptime {
    assert(std.math.isPowerOfTwo(cache_count));
    assert(cached_bytes_max >= 16);
}

pub const Window = struct {
    length: u32,
    reach: []const u8,

    fn text(window: Window) []const u8 {
        assert(window.length <= window.reach.len);
        assert(window.length <= cached_bytes_max);

        return window.reach[0..window.length];
    }
};

const Slot = enum(u32) { _ };

const Key = struct {
    head: u64,
    length: u32,
    tail: u64,
    text: []const u8,
};

const Entry = struct {
    head: u64,
    length: u32,
    object: *PyObject,
    tail: u64,
    text: []const u8,
};

pub const Flavor = enum {
    held,
    plain,
    renamed,
};

pub const Cache = CacheType(.plain);

pub fn CacheType(comptime flavor: Flavor) type {
    return struct {
        entries: [cache_count]Entry,
        occupied: [occupied_words]u64,
        origins: if (flavor == .held) [cache_count]*PyObject else void,
        policy: if (flavor == .plain) void else *const Policy,
        touched: Touched,

        const Origin = if (flavor == .held) *PyObject else void;

        pub fn reset(cache: *@This()) void {
            assert(occupied_words == cache.occupied.len);
            assert(cache_count == cache.entries.len);

            cache.occupied = @splat(0);
            cache.touched = 0;
        }

        pub fn deinit(cache: *@This()) void {
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
                    if (flavor == .held) c.Py_DecRef(cache.origins[slot]);
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

        pub inline fn object_of(cache: *@This(), window: Window, origin: Origin) ?*PyObject {
            assert(window.length <= cached_bytes_max);
            assert(window.reach.len >= window.length);
            if (flavor == .held) assert(@intFromPtr(origin) % @alignOf(*PyObject) == 0);

            const key = key_of(window);
            const first = key_slot(&key);
            const bits = cache.occupied[first >> 6] >> @intCast(first & 63);

            if (bits & 1 != 0) {
                if (key_equal(&cache.entries[first], &key)) return cache.entries[first].object;
            }

            if (bits & 2 != 0) {
                if (key_equal(&cache.entries[first + 1], &key)) {
                    return cache.entries[first + 1].object;
                }
            }

            const slot: Slot = @fromBackingInt(first);

            return cache.object_store(window.reach, window.length, slot, origin);
        }

        noinline fn object_store(
            cache: *@This(),
            reach: []const u8,
            length: u32,
            slot: Slot,
            origin: Origin,
        ) ?*PyObject {
            assert(length <= cached_bytes_max);
            assert(@backingInt(slot) % 2 == 0);
            if (std.debug.runtime_safety) assert(reach.len >= length);
            if (flavor == .held) assert(@intFromPtr(origin) % @alignOf(*PyObject) == 0);

            const first: u32 = @backingInt(slot);
            const window: Window = .{ .length = length, .reach = reach };
            const key = key_of(window);
            const word = &cache.occupied[first >> 6];
            const shift: u6 = @intCast(first & 63);
            const bits = (word.* >> shift) & 3;

            assert(key_slot(&key) == first);

            if (flavor == .held) cache.origins_shift(first, bits);

            if (bits & 2 != 0) c.Py_DecRef(cache.entries[first + 1].object);
            if (bits & 1 != 0) cache.entries[first + 1] = cache.entries[first];

            word.* &= ~(@as(u64, 3) << shift);
            word.* |= (bits & 1) << (shift + 1);

            const text = window.text();

            const created = if (flavor == .plain)
                objects.text_object(text)
            else
                cache.policy.renamed(text);

            const object = created orelse return null;

            cache.entries[first] = .{
                .head = key.head,
                .length = key.length,
                .object = object,
                .tail = key.tail,
                .text = text,
            };

            if (flavor == .held) {
                c.Py_IncRef(origin);
                cache.origins[first] = origin;
            }

            word.* |= @as(u64, 1) << shift;
            cache.touched |= @as(Touched, 1) << @intCast(first >> 6);

            return object;
        }

        fn origins_shift(cache: *@This(), first: u32, bits: u64) void {
            comptime assert(flavor == .held);
            assert(first % 2 == 0);
            assert(bits <= 3);

            if (bits & 2 != 0) c.Py_DecRef(cache.origins[first + 1]);
            if (bits & 1 != 0) cache.origins[first + 1] = cache.origins[first];
        }
    };
}

inline fn key_of(window: Window) Key {
    assert(window.length <= cached_bytes_max);
    assert(window.reach.len >= window.length);

    const length = window.length;
    const text = window.text();

    const result: Key = if (length >= 8) .{
        .head = std.mem.readInt(u64, text[0..8], .little),
        .length = length,
        .tail = std.mem.readInt(u64, text[length - 8 ..][0..8], .little),
        .text = text,
    } else .{
        .head = word_short(window),
        .length = length,
        .tail = 0,
        .text = text,
    };

    assert(result.length == text.len);

    return result;
}

inline fn word_short(window: Window) u64 {
    assert(window.length < 8);
    assert(window.reach.len >= window.length);

    const mask = (@as(u64, 1) << @intCast(window.length * 8)) - 1;
    const reach = window.reach;

    if (reach.len >= 8) return std.mem.readInt(u64, reach[0..8], .little) & mask;

    var result: u64 = 0;

    for (window.text(), 0..) |byte, index| result |= @as(u64, byte) << @intCast(index * 8);

    assert(result & ~mask == 0);

    return result;
}

inline fn key_slot(key: *const Key) u32 {
    assert(key.length <= cached_bytes_max);
    assert(std.math.isPowerOfTwo(cache_count));

    const mixed = (key.head ^ std.math.rotl(u64, key.tail, 29) ^ key.length) *% 0x9e3779b97f4a7c15;
    const set: u32 = @intCast(mixed >> (64 - @as(u7, cache_bits - 1)));
    const result = set * 2;

    assert(result + 1 < cache_count);

    return result;
}

inline fn key_equal(entry: *const Entry, key: *const Key) bool {
    assert(entry.length <= cached_bytes_max);
    assert(key.length <= cached_bytes_max);

    if (entry.length != key.length) return false;
    if (entry.head != key.head) return false;
    if (entry.tail != key.tail) return false;
    if (key.length <= 16) return true;

    const length = key.length;
    var offset: u32 = 8;

    for (0..@divExact(cached_bytes_max, 8)) |_| {
        if (offset + 8 > length - 8) break;
        if (word_of(entry.text, offset) != word_of(key.text, offset)) return false;

        offset += 8;
    }

    return word_of(entry.text, length - 16) == word_of(key.text, length - 16);
}

inline fn word_of(text: []const u8, offset: u32) u64 {
    assert(offset + 8 <= text.len);
    assert(text.len <= cached_bytes_max);

    return std.mem.readInt(u64, text[offset..][0..8], .little);
}

test "keys equal exactly when their text is equal" {
    var prng: std.Random.DefaultPrng = .init(0x6b657973);
    const random = prng.random();

    var left_buffer: [cached_bytes_max + 8]u8 = undefined;
    var right_buffer: [cached_bytes_max + 8]u8 = undefined;

    for (0..20_000) |_| {
        const length = random.uintAtMost(u32, cached_bytes_max);

        random.bytes(&left_buffer);
        random.bytes(&right_buffer);

        for (0..length) |index| {
            left_buffer[index] = random.uintLessThan(u8, 3) + 'a';
            right_buffer[index] = if (random.uintLessThan(u8, 8) == 0)
                random.uintLessThan(u8, 3) + 'a'
            else
                left_buffer[index];
        }

        const left = key_of(.{ .length = length, .reach = &left_buffer });
        const right = key_of(.{ .length = length, .reach = &right_buffer });

        const entry: Entry = .{
            .head = left.head,
            .length = left.length,
            .object = undefined,
            .tail = left.tail,
            .text = left.text,
        };

        const expected = std.mem.eql(u8, left_buffer[0..length], right_buffer[0..length]);

        try std.testing.expectEqual(expected, key_equal(&entry, &right));

        if (expected) try std.testing.expectEqual(key_slot(&left), key_slot(&right));
    }
}
