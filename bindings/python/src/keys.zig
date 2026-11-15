const std = @import("std");

const lacuna = @import("lacuna");

const objects = @import("objects.zig");
const policy_module = @import("policy.zig");

const assert = std.debug.assert;

const c = lacuna.c;

const Policy = policy_module.Policy;
const PyObject = c.PyObject;

pub const cached_bytes_max: u32 = 64;
pub const shared_enabled = !c.unlocked_possible;

pub const plain_flavor: Flavor = if (shared_enabled) .shared else .plain;

const bypass_hit_ratio: u32 = 4;
const bypass_misses_min: u32 = 32;
const cache_bits: u6 = 10;
const cache_count: u32 = 1 << cache_bits;
const occupied_words: u32 = @divExact(cache_count, 64);
const older_words: u32 = @divExact(cache_count, 2 * 64);
const insert_misses_max: u32 = @divExact(cache_count, 2);
const text_inline_bytes: u32 = 16;

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

fn EntryType(comptime flavor: Flavor) type {
    return struct {
        head: u64,
        length: u32,
        object: *PyObject,
        tail: u64,
        text: if (flavor == .shared) void else []const u8,
    };
}

pub const Flavor = enum {
    held,
    plain,
    renamed,
    shared,
};

fn policy_held(comptime flavor: Flavor) bool {
    comptime assert(@typeInfo(Flavor).@"enum".field_names.len == 4);

    return switch (flavor) {
        .held, .renamed => true,
        .plain, .shared => false,
    };
}

fn bypass_capable(comptime flavor: Flavor) bool {
    comptime assert(@typeInfo(Flavor).@"enum".field_names.len == 4);

    return switch (flavor) {
        .plain, .shared => true,
        .held, .renamed => false,
    };
}

pub const Cache = CacheType(.plain);
pub const SharedCache = CacheType(.shared);
pub const Shared = if (shared_enabled) *SharedCache else void;

pub fn CacheType(comptime flavor: Flavor) type {
    return struct {
        bypass: bool,
        entries: [cache_count]Entry,
        hits: u32,
        misses: u32,
        occupied: [occupied_words]u64,
        older: [older_words]u64,
        origins: if (flavor == .held) [cache_count]*PyObject else void,
        policy: if (policy_held(flavor)) *const Policy else void,
        texts: if (flavor == .shared) [cache_count][cached_bytes_max]u8 else void,
        touched: Touched,

        const Entry = EntryType(flavor);
        const Origin = if (flavor == .held) *PyObject else void;

        pub const empty: @This() = .{
            .bypass = false,
            .entries = undefined,
            .hits = 0,
            .misses = 0,
            .occupied = @splat(0),
            .older = @splat(0),
            .origins = undefined,
            .policy = undefined,
            .texts = undefined,
            .touched = 0,
        };

        pub fn reset(cache: *@This()) void {
            assert(occupied_words == cache.occupied.len);
            assert(cache_count == cache.entries.len);

            cache.occupied = @splat(0);
            cache.older = @splat(0);
            cache.touched = 0;
            cache.call_begin();
        }

        pub fn call_begin(cache: *@This()) void {
            assert(cache.hits <= std.math.maxInt(u32));
            assert(cache.misses <= std.math.maxInt(u32));

            cache.bypass = false;
            cache.hits = 0;
            cache.misses = 0;
        }

        pub inline fn object_owned(cache: *@This(), window: Window, origin: Origin) ?*PyObject {
            assert(window.length <= cached_bytes_max);
            assert(window.reach.len >= window.length);
            if (flavor == .held) assert(@intFromPtr(origin) % @alignOf(*PyObject) == 0);

            if (comptime bypass_capable(flavor)) {
                if (cache.bypass) {
                    @branchHint(.unlikely);

                    return objects.text_object(window.text());
                }
            }

            if (flavor == .shared) {
                if (cache.misses >= insert_misses_max) return cache.object_unstored(window);
            }

            const object = cache.object_of(window, origin) orelse return null;

            objects.acquire(object);

            return object;
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

            if (cache.hit_of(first, &key)) |object| return object;

            const slot: Slot = @fromBackingInt(first);

            return cache.object_store(window.reach, window.length, slot, origin);
        }

        inline fn hit_of(cache: *@This(), first: u32, key: *const Key) ?*PyObject {
            assert(first % 2 == 0);
            assert(key.length <= cached_bytes_max);

            const bits = cache.occupied[first >> 6] >> @intCast(first & 63);

            if (bits & 1 != 0) {
                if (cache.slot_matches(first, key)) {
                    cache.hits +%= 1;

                    return cache.entries[first].object;
                }
            }

            if (bits & 2 != 0) {
                if (cache.slot_matches(first + 1, key)) {
                    cache.hits +%= 1;

                    return cache.entries[first + 1].object;
                }
            }

            return null;
        }

        noinline fn object_unstored(cache: *@This(), window: Window) ?*PyObject {
            comptime assert(flavor == .shared);
            assert(window.length <= cached_bytes_max);
            assert(cache.misses >= insert_misses_max);

            const key = key_of(window);
            const first = key_slot(&key);

            if (cache.hit_of(first, &key)) |object| {
                objects.acquire(object);

                return object;
            }

            cache.misses +%= 1;

            if (cache.hits *| bypass_hit_ratio < cache.misses) cache.bypass = true;

            return objects.text_object(window.text());
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
            const text = window.text();

            assert(key_slot(&key) == first);

            const object = cache.object_created(first, text) orelse return null;

            const word = &cache.occupied[first >> 6];
            const shift: u6 = @intCast(first & 63);
            const bits = (word.* >> shift) & 3;
            const way = cache.victim_of(first, bits);
            const target = first + way;
            const evicting = (bits >> way) & 1 != 0;

            if (evicting) {
                c.Py_DecRef(cache.entries[target].object);
                if (flavor == .held) c.Py_DecRef(cache.origins[target]);
            }

            const entry = &cache.entries[target];

            entry.head = key.head;
            entry.length = key.length;
            entry.object = object;
            entry.tail = key.tail;

            if (flavor == .shared) {
                const stored: Slot = @fromBackingInt(target);

                if (key.length > text_inline_bytes) cache.text_store(stored, window);
            } else {
                entry.text = text;
            }

            if (flavor == .held) {
                c.Py_IncRef(origin);
                cache.origins[target] = origin;
            }

            word.* |= @as(u64, 1) << (shift + @as(u6, way));
            cache.older_mark(first, way);
            cache.touched |= @as(Touched, 1) << @intCast(first >> 6);

            return object;
        }

        inline fn object_created(cache: *@This(), first: u32, text: []const u8) ?*PyObject {
            assert(first % 2 == 0);
            assert(text.len <= cached_bytes_max);

            const created = if (comptime policy_held(flavor))
                cache.policy.renamed(text)
            else if (flavor == .shared)
                cache.recycled(first, text) orelse objects.text_object(text)
            else
                objects.text_object(text);

            const object = created orelse return null;

            cache.misses +%= 1;

            if (cache.misses >= bypass_misses_min) {
                if (cache.hits *| bypass_hit_ratio < cache.misses) cache.bypass = true;
            }

            assert(@intFromPtr(object) % @alignOf(*PyObject) == 0);

            return object;
        }

        fn recycled(cache: *@This(), first: u32, text: []const u8) ?*PyObject {
            comptime assert(flavor == .shared);
            assert(first % 2 == 0);
            assert(text.len <= cached_bytes_max);

            const word = &cache.occupied[first >> 6];
            const shift: u6 = @intCast(first & 63);

            const bits = (word.* >> shift) & 3;

            if (bits != 3) return null;

            const way = cache.victim_of(first, bits);
            const evicted = cache.entries[first + way].object;

            if (!objects.text_rewrite(evicted, text)) return null;

            word.* &= ~(@as(u64, 1) << (shift + @as(u6, way)));

            return evicted;
        }

        inline fn victim_of(cache: *const @This(), first: u32, bits: u64) u1 {
            assert(first % 2 == 0);
            assert(bits <= 3);

            if (bits & 1 == 0) return 0;
            if (bits & 2 == 0) return 1;

            const set = first >> 1;
            const older: u1 = @intCast((cache.older[set >> 6] >> @intCast(set & 63)) & 1);

            assert((bits >> older) & 1 != 0);

            return older;
        }

        inline fn older_mark(cache: *@This(), first: u32, way: u1) void {
            assert(first % 2 == 0);
            assert(first < cache_count);

            const set = first >> 1;
            const bit = @as(u64, 1) << @intCast(set & 63);

            if (way == 0) {
                cache.older[set >> 6] |= bit;
            } else {
                cache.older[set >> 6] &= ~bit;
            }
        }

        inline fn text_store(cache: *@This(), slot: Slot, window: Window) void {
            comptime assert(flavor == .shared);
            assert(@backingInt(slot) < cache_count);
            assert(window.length > text_inline_bytes);

            const row = &cache.texts[@backingInt(slot)];

            if (window.reach.len < cached_bytes_max) {
                @memcpy(row[0..window.length], window.text());
            } else {
                row.* = window.reach[0..cached_bytes_max].*;
            }
        }

        inline fn slot_matches(cache: *const @This(), slot: u32, key: *const Key) bool {
            assert(slot < cache_count);
            assert(key.length <= cached_bytes_max);

            const entry = &cache.entries[slot];
            const text = if (flavor == .shared)
                cache.texts[slot][0..entry.length]
            else
                entry.text;

            const stored: Key = .{
                .head = entry.head,
                .length = entry.length,
                .tail = entry.tail,
                .text = text,
            };

            return key_equal(.{ .stored = &stored, .wanted = key });
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

const KeyPair = struct {
    stored: *const Key,
    wanted: *const Key,
};

inline fn key_equal(pair: KeyPair) bool {
    const stored = pair.stored;
    const key = pair.wanted;

    assert(stored.length <= cached_bytes_max);
    assert(key.length <= cached_bytes_max);

    if (stored.length != key.length) return false;
    if (stored.head != key.head) return false;
    if (stored.tail != key.tail) return false;
    if (key.length <= 16) return true;

    const length = key.length;
    var offset: u32 = 8;

    for (0..@divExact(cached_bytes_max, 8)) |_| {
        if (offset + 8 > length - 8) break;
        if (word_of(stored.text, offset) != word_of(key.text, offset)) return false;

        offset += 8;
    }

    return word_of(stored.text, length - 16) == word_of(key.text, length - 16);
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
    var copy: [cached_bytes_max]u8 = undefined;

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
        const expected = std.mem.eql(u8, left_buffer[0..length], right_buffer[0..length]);

        @memcpy(copy[0..length], left_buffer[0..length]);
        @memset(left_buffer[0..length], 'z');

        const stored: Key = .{
            .head = left.head,
            .length = left.length,
            .tail = left.tail,
            .text = copy[0..length],
        };

        try std.testing.expectEqual(expected, key_equal(.{ .stored = &stored, .wanted = &right }));

        if (expected) try std.testing.expectEqual(key_slot(&left), key_slot(&right));
    }
}
