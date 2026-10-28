const std = @import("std");

const bounded = @import("bounded");
const codec = @import("codec.zig");
const document_fuzz = @import("document_fuzz.zig");
const number_fuzz = @import("number_fuzz.zig");
const number_module = @import("number.zig");
const region_module = @import("region.zig");
const stream_fuzz = @import("stream_fuzz.zig");
const string = @import("string.zig");
const tokenizer_module = @import("tokenizer.zig");
const tree_fuzz = @import("tree_fuzz.zig");
const writer_fuzz = @import("writer_fuzz.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Empty = codec.Empty;
const EntryType = codec.EntryType;
const Prng = std.Random.DefaultPrng;
const Raw = codec.Raw;
const Region = region_module.Region;
const Token = tokenizer_module.Token;
const Tokenizer = tokenizer_module.Tokenizer;
const Writer = writer_module.Writer;

const Fuzzer = enum {
    codec,
    document,
    number,
    region,
    sizing,
    smoke,
    stream,
    string,
    tokenizer,
    tree,
    writer,
};

const Options = struct {
    events_max: u32,
    seed: u64,
};

const JSONFrame = struct {
    first: bool,
    object: bool,
    remaining: u32,
};

const arguments_bytes_max: u32 = 4096;
const decoded_bytes_max: u32 = 64 * 1024;
const events_max_default: u32 = 20_000;
const events_max_smoke: u32 = 512;
const json_depth_generate_max: u32 = 6;
const json_step_max: u32 = 1 << 20;
const json_width_max: u32 = 6;
const mutation_alphabet = "{}[]:,\"\\ -+.eE0123456789tfnaulrsx\x00\x1f\xc3\xed\xa0\xff";
const mutation_count_max: u32 = 4;
const mutation_relaxed_alphabet = mutation_alphabet ++ "//**\n\r,,]}\xef\xbb\xbfINi";
const reference_bytes: u32 = 4 * 1024 * 1024;
const region_bytes: u32 = 4 * 1024 * 1024;
const region_model_count_max: u32 = 64;
const seed_smoke: u64 = 0x5eed;
const sizing_count_max: u32 = 6;
const sizing_witness_period: u32 = 8;
const string_codepoint_count_max: u32 = 12;
const text_bytes_max: u32 = 64 * 1024;

const usage_text = "usage: fuzz " ++
    "<codec|document|number|region|sizing|stream|string|tokenizer|tree|writer|smoke> [seed]\n";

comptime {
    assert(events_max_smoke < events_max_default);
    assert(json_depth_generate_max < tokenizer_module.depth_max);
}

const JSONStack = bounded.ArrayType(JSONFrame, json_depth_generate_max + 1);
const Positions = std.StaticBitSet(text_bytes_max + 1);
const Text = bounded.ArrayType(u8, text_bytes_max);

const Pair = struct {
    blanked: []const u8,
    relaxed: []const u8,
};

const RelaxedCounts = struct {
    accepted_mutated: u32,
    bom: u32,
    comma: u32,
    comment_block: u32,
    comment_line: u32,
    non_finite: u32,
    rejected_mutated: u32,
    rejected_open: u32,
};

const RelaxedLayout = struct {
    closers: Positions,
    inside: Positions,
    numbers: Positions,
};

const State = struct {
    blanked: Text,
    decoded: [decoded_bytes_max]u8,
    decoded_other: [decoded_bytes_max]u8,
    document: document_fuzz.State,
    number: number_fuzz.State,
    prng: Prng,
    reference: [reference_bytes]u8,
    region: Region,
    region_buffer: [region_bytes]u8 align(region_module.alignment_bytes),
    relaxed: Text,
    relaxed_counts: RelaxedCounts,
    relaxed_layout: RelaxedLayout,
    scratch: [region_bytes]u8 align(region_module.alignment_bytes),
    sizing: SizingCounts,
    stream: stream_fuzz.State,
    text: Text,
    text_other: Text,
    tree: tree_fuzz.State,
    writer: writer_fuzz.State,
};

pub fn main(init: std.process.Init) !void {
    assert(init.environ_map.count() < std.math.maxInt(u32));

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2) return usage();
    if (arguments.len > 3) return usage();

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse return usage();
    const seed_text = if (arguments.len == 3) arguments[2] else "";
    const state = try init.gpa.create(State);
    defer init.gpa.destroy(state);

    if (fuzzer == .smoke) {
        if (seed_text.len > 0) return usage();

        for (std.enums.values(Fuzzer)) |each| {
            if (each == .smoke) continue;

            try run(state, each, &.{ .events_max = events_max_smoke, .seed = seed_smoke });
        }

        return;
    }

    const seed = if (seed_text.len == 0) seed_random(init.io) else try seed_parse(seed_text);

    try run(state, fuzzer, &.{ .events_max = events_max_default, .seed = seed });
}

fn usage() error{ArgumentsInvalid} {
    assert(usage_text.len > 0);

    std.debug.print("{s}", .{usage_text});

    return error.ArgumentsInvalid;
}

fn seed_parse(text: []const u8) error{ArgumentsInvalid}!u64 {
    assert(text.len > 0);
    assert(text.len <= arguments_bytes_max);

    const result = std.fmt.parseInt(u64, text, 10) catch return usage();
    return result;
}

fn seed_random(io: std.Io) u64 {
    var result: u64 = 0;

    io.random(std.mem.asBytes(&result));

    return result;
}

fn run(state: *State, fuzzer: Fuzzer, options: *const Options) !void {
    assert(fuzzer != .smoke);
    assert(options.events_max > 0);

    std.debug.print("fuzz {t}: seed={d} events_max={d}\n", .{
        fuzzer,
        options.seed,
        options.events_max,
    });

    state.blanked = .empty;
    state.prng = .init(options.seed);
    state.region = .init(&state.region_buffer);
    state.relaxed = .empty;
    state.relaxed_counts = std.mem.zeroes(RelaxedCounts);
    state.sizing = .{ .events = 0, .tightest = 0, .witnessed = 0 };
    state.text = .empty;
    state.text_other = .empty;

    number_fuzz.counts_reset(&state.number);
    stream_fuzz.counts_reset(&state.stream);
    tree_fuzz.counts_reset(&state.tree);

    for (0..options.events_max) |_| {
        switch (fuzzer) {
            .codec => try codec_event(state),
            .document => try document_fuzz.event(&state.document, &state.prng, &state.reference),
            .number => try number_fuzz.event(&state.number, &state.prng),
            .region => try region_event(state),
            .sizing => try sizing_event(state),
            .smoke => unreachable,
            .stream => try stream_fuzz.event(&state.stream, &state.prng),
            .string => try string_event(state),
            .tokenizer => try tokenizer_event(state),
            .tree => try tree_fuzz.event(&state.tree, &state.prng, &state.reference),
            .writer => try writer_fuzz.event(&state.writer, &state.prng, &state.reference),
        }
    }

    if (fuzzer == .number) try number_fuzz.summary_check(&state.number, options.events_max);
    if (fuzzer == .sizing) try sizing_summary_check(&state.sizing, options.events_max);
    if (fuzzer == .stream) try stream_fuzz.summary_check(&state.stream, options.events_max);
    if (fuzzer == .tokenizer) try relaxed_summary_check(&state.relaxed_counts);
    if (fuzzer == .tree) try tree_fuzz.summary_check(&state.tree, options.events_max);
}

fn tokenizer_event(state: *State) !void {
    assert(state.text.count <= text_bytes_max);
    assert(state.reference.len == reference_bytes);

    state.text.clear();

    json_document_generate(&state.prng, &state.text, json_depth_generate_max) catch |err| {
        switch (err) {
            error.Overflow => return,
        }
    };

    try relaxed_event(state, state.text.slice());

    const mutations = state.prng.random().uintAtMost(u32, mutation_count_max);

    for (0..mutations) |_| text_mutate(&state.prng, &state.text, mutation_alphabet);

    const input = state.text.slice();
    const ours = accepts(input);
    var reference: std.heap.FixedBufferAllocator = .init(&state.reference);
    const theirs = std.json.validate(reference.allocator(), input) catch false;

    if (ours != theirs) {
        std.debug.print("json disagreement on {d} bytes: ours={} std={}\n{s}\n", .{
            input.len,
            ours,
            theirs,
            input,
        });

        return error.ReferenceDisagreement;
    }

    if (mutations == 0) assert(ours);
    if (ours) try tokens_compare(state, input);
}

fn accepts(input: []const u8) bool {
    assert(input.len <= text_bytes_max);

    var tokenizer: Tokenizer = .init(input);
    const input_start = @intFromPtr(input.ptr);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch return false;

        assert(tokenizer.depth <= tokenizer_module.depth_max);
        assert(tokenizer.index <= input.len);

        switch (token) {
            .end => return true,
            .key, .number, .string => |text| {
                assert(@intFromPtr(text.ptr) >= input_start);
                assert(@intFromPtr(text.ptr) + text.len <= input_start + input.len);
            },
            else => {},
        }
    }

    unreachable;
}

fn tokens_compare(state: *State, input: []const u8) !void {
    assert(input.len <= text_bytes_max);
    assert(state.decoded.len == decoded_bytes_max);

    var reference: std.heap.FixedBufferAllocator = .init(&state.reference);
    const allocator = reference.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(allocator, input);
    var tokenizer: Tokenizer = .init(input);

    for (0..input.len + 2) |_| {
        const ours = try tokenizer.next();
        const theirs = try scanner.nextAlloc(allocator, .alloc_always);

        try token_match(state, ours, theirs);

        if (ours == .end) return;
    }

    unreachable;
}

fn token_match(state: *State, ours: tokenizer_module.Token, theirs: std.json.Token) !void {
    assert(state.decoded.len == decoded_bytes_max);
    assert(ours != .end or theirs == .end_of_document);

    const matched = switch (ours) {
        .array_begin => theirs == .array_begin,
        .array_end => theirs == .array_end,
        .boolean => |value| if (value) theirs == .true else theirs == .false,
        .end => theirs == .end_of_document,
        .key, .string => |raw| matched: {
            if (theirs != .allocated_string) break :matched false;

            const text = try string.unescape(raw, &state.decoded);

            break :matched std.mem.eql(u8, text, theirs.allocated_string);
        },
        .null_value => theirs == .null,
        .number => |text| theirs == .allocated_number and
            std.mem.eql(u8, text, theirs.allocated_number),
        .object_begin => theirs == .object_begin,
        .object_end => theirs == .object_end,
    };

    if (!matched) return error.ReferenceDisagreement;
}

fn relaxed_event(state: *State, input: []const u8) !void {
    assert(input.len <= text_bytes_max);
    assert(input.len > 0);

    const random = state.prng.random();
    const non_finite = random.uintLessThan(u32, 4) == 0;

    try relaxed_layout_build(&state.relaxed_layout, input);

    relaxed_build(state, input, non_finite) catch |err| switch (err) {
        error.Overflow => return,
    };

    const relaxed = state.relaxed.slice();
    const blanked = state.blanked.slice();

    try relaxed_tokens_expect(&state.relaxed_counts, .{ .blanked = blanked, .relaxed = relaxed });

    if (non_finite) return;

    state.text_other.clear();

    const terminated = blank_reference(relaxed, &state.text_other);

    assert(terminated);

    if (!std.mem.eql(u8, blanked, state.text_other.slice())) {
        std.debug.print("reference blanker disagrees on\n{any}\n{any}\n", .{ relaxed, blanked });

        return error.ReferenceDisagreement;
    }

    const mutations = random.intRangeAtMost(u32, 1, mutation_count_max);

    for (0..mutations) |_| text_mutate(&state.prng, &state.relaxed, mutation_relaxed_alphabet);

    if (random.uintLessThan(u32, 4) == 0) {
        state.relaxed.truncate(random.uintAtMost(u32, state.relaxed.count));
    }

    try relaxed_mutated_check(state);
}

fn relaxed_mutated_check(state: *State) !void {
    assert(state.relaxed.count <= text_bytes_max);
    assert(state.text_other.count == state.blanked.count);

    const input = state.relaxed.slice();
    if (spelling_present(input)) return;

    state.text_other.clear();

    const terminated = blank_reference(input, &state.text_other);
    const blanked = state.text_other.slice();
    const expected = terminated and accepts(blanked);
    const ours = relaxed_accepts(input);

    if (!terminated) state.relaxed_counts.rejected_open += 1;

    if (ours != expected) {
        std.debug.print("relaxed disagreement on {d} bytes: ours={} reference={}\n{s}\n", .{
            input.len,
            ours,
            expected,
            input,
        });

        return error.ReferenceDisagreement;
    }

    if (ours) {
        state.relaxed_counts.accepted_mutated += 1;

        try relaxed_tokens_expect(&state.relaxed_counts, .{ .blanked = blanked, .relaxed = input });
    } else {
        state.relaxed_counts.rejected_mutated += 1;
    }
}

fn relaxed_layout_build(layout: *RelaxedLayout, input: []const u8) !void {
    assert(input.len <= text_bytes_max);
    assert(input.len > 0);

    layout.closers = .empty;
    layout.inside = .empty;
    layout.numbers = .empty;

    var tokenizer: Tokenizer = .init(input);
    var previous: Token = .end;

    for (0..input.len + 2) |_| {
        const token = try tokenizer.next();
        const end = tokenizer.index;

        const start = switch (token) {
            .array_begin, .object_begin => end - 1,
            .array_end, .object_end => start: {
                const empty = previous == .array_begin or previous == .object_begin;

                if (!empty) layout.closers.set(end - 1);

                break :start end - 1;
            },
            .boolean, .null_value, .string => tokenizer.value_start,
            .end => return,
            .key => tokenizer.key_start - 1,
            .number => start: {
                layout.numbers.set(tokenizer.value_start);

                break :start tokenizer.value_start;
            },
        };

        assert(start < end);

        for (start + 1..end) |position| layout.inside.set(position);

        previous = token;
    }

    unreachable;
}

fn relaxed_build(state: *State, input: []const u8, non_finite: bool) error{Overflow}!void {
    assert(input.len <= text_bytes_max);
    assert(input.len > 0);

    const random = state.prng.random();
    const layout = &state.relaxed_layout;

    state.relaxed.clear();
    state.blanked.clear();

    if (random.uintLessThan(u32, 8) == 0) {
        try relaxed_push(state, .{ .blanked = "   ", .relaxed = "\xef\xbb\xbf" });
        state.relaxed_counts.bom += 1;
    }

    var index: u32 = 0;

    for (0..input.len + 1) |_| {
        if (!layout.inside.isSet(index)) {
            if (random.uintLessThan(u32, 6) == 0) try comment_insert(state, index == input.len);

            const comma = layout.closers.isSet(index) and random.boolean();

            if (comma) {
                try relaxed_push(state, .{ .blanked = " ", .relaxed = "," });
                state.relaxed_counts.comma += 1;
            }
        }

        if (index == input.len) return;

        const replaced = non_finite and layout.numbers.isSet(index) and random.boolean();

        if (replaced) {
            index = number_end(input, index);

            try spelling_insert(state);

            continue;
        }

        const byte = input[index..][0..1];

        try relaxed_push(state, .{ .blanked = byte, .relaxed = byte });
        index += 1;
    }

    unreachable;
}

fn relaxed_push(state: *State, pair: Pair) error{Overflow}!void {
    assert(pair.relaxed.len == pair.blanked.len);
    assert(state.relaxed.count == state.blanked.count);

    try state.relaxed.push_slice(pair.relaxed);
    try state.blanked.push_slice(pair.blanked);
}

fn comment_insert(state: *State, last: bool) error{Overflow}!void {
    assert(state.relaxed.count == state.blanked.count);
    assert(state.relaxed.count <= text_bytes_max);

    const random = state.prng.random();
    const alphabet = "ab */\"\\\x00\xc3\xff";
    var buffer: [16]u8 = undefined;
    const length = random.uintAtMost(u32, 8);
    const block = random.boolean();

    buffer[0] = '/';
    buffer[1] = if (block) '*' else '/';

    for (buffer[2..][0..length]) |*byte| byte.* = alphabet[random.uintLessThan(u32, alphabet.len)];

    var end = 2 + length;

    if (block) {
        for (buffer[2..end], 2..) |byte, position| {
            const closes = byte == '*' and position + 1 < end and buffer[position + 1] == '/';

            if (closes) buffer[position] = 'x';
        }

        buffer[end..][0..2].* = "*/".*;
        end += 2;
        state.relaxed_counts.comment_block += 1;
    } else {
        const terminated = !last or random.boolean();

        if (terminated) {
            buffer[end] = if (random.boolean()) '\n' else '\r';
            end += 1;
        }

        state.relaxed_counts.comment_line += 1;
    }

    var blanked: [16]u8 = @splat(' ');

    const terminator = buffer[end - 1] == '\n' or buffer[end - 1] == '\r';

    if (terminator) blanked[end - 1] = buffer[end - 1];

    try relaxed_push(state, .{ .blanked = blanked[0..end], .relaxed = buffer[0..end] });
}

fn spelling_insert(state: *State) error{Overflow}!void {
    assert(state.relaxed.count == state.blanked.count);
    assert(state.relaxed.count <= text_bytes_max);

    const random = state.prng.random();
    const spellings = [_][]const u8{ "nan", "inf", "infinity" };
    const spelling = spellings[random.uintLessThan(u32, spellings.len)];
    const signed = random.boolean();
    var relaxed: [16]u8 = undefined;
    var blanked: [16]u8 = @splat('1');

    relaxed[0] = '-';
    blanked[0] = '-';

    for (spelling, 1..) |byte, position| {
        relaxed[position] = if (random.boolean()) std.ascii.toUpper(byte) else byte;
    }

    const start: u32 = @intFromBool(!signed);
    const end: u32 = @intCast(spelling.len + 1);

    try relaxed_push(state, .{ .blanked = blanked[start..end], .relaxed = relaxed[start..end] });
}

fn number_end(input: []const u8, start: u32) u32 {
    assert(start < input.len);
    assert(input[start] == '-' or std.ascii.isDigit(input[start]));

    var index = start;

    for (input[start..]) |byte| {
        switch (byte) {
            '+', '-', '.', '0'...'9', 'E', 'e' => index += 1,
            else => break,
        }
    }

    assert(index > start);

    return index;
}

fn relaxed_tokens_expect(counts: *RelaxedCounts, pair: Pair) !void {
    assert(pair.relaxed.len == pair.blanked.len);
    assert(pair.relaxed.len <= text_bytes_max);

    var left: tokenizer_module.TokenizerType(.relaxed) = .init(pair.relaxed);
    var right: Tokenizer = .init(pair.blanked);

    for (0..pair.relaxed.len + 2) |_| {
        const expected = try right.next();
        const token = try left.next();

        if (left.index != right.index) return error.ReferenceDisagreement;

        const spelled = token == .number and number_module.non_finite_is(token.number);

        if (spelled) {
            if (expected != .number) return error.ReferenceDisagreement;

            try non_finite_expect(token.number, @intCast(expected.number.len));

            counts.non_finite += 1;
        } else {
            try std.testing.expectEqualDeep(expected, token);
        }

        if (expected == .end) return;
    }

    unreachable;
}

fn non_finite_expect(text: []const u8, blanked_length: u32) !void {
    assert(text.len >= 3);
    assert(number_module.non_finite_is(text));
    assert(blanked_length > 0);

    if (blanked_length != text.len) return error.ReferenceDisagreement;

    const negative = text[0] == '-';
    const value = number_module.float_of_text(text) orelse return error.ReferenceDisagreement;
    const letter = std.ascii.toLower(text[@intFromBool(negative)]);

    if (letter == 'n') {
        if (!std.math.isNan(value)) return error.ReferenceDisagreement;
    } else {
        if (!std.math.isInf(value)) return error.ReferenceDisagreement;
        if (std.math.signbit(value) != negative) return error.ReferenceDisagreement;
    }
}

fn relaxed_accepts(input: []const u8) bool {
    assert(input.len <= text_bytes_max);

    var tokenizer: tokenizer_module.TokenizerType(.relaxed) = .init(input);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch return false;

        assert(tokenizer.index <= input.len);

        if (token == .end) return true;
    }

    unreachable;
}

fn spelling_present(input: []const u8) bool {
    assert(input.len <= text_bytes_max);

    for ([_][]const u8{ "inf", "nan" }) |spelling| {
        for (0..input.len) |index| {
            if (std.ascii.startsWithIgnoreCase(input[index..], spelling)) return true;
        }
    }

    return false;
}

fn blank_reference(input: []const u8, output: *Text) bool {
    assert(input.len <= text_bytes_max);
    assert(output.count == 0);

    output.push_slice_assume_capacity(input);

    const bytes = output.slice_mutable();
    var index: u32 = 0;
    var last: u8 = 0;

    if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) {
        @memset(bytes[0..3], ' ');
        index = 3;
    }

    for (0..input.len + 1) |_| {
        if (index >= input.len) return true;

        const byte = input[index];

        switch (byte) {
            '"' => {
                last = '"';
                index = string_end_reference(input, index);
            },
            '/' => {
                const end = comment_end_reference(input, index) orelse return false;

                if (end == index) {
                    last = '/';
                    index += 1;
                } else {
                    @memset(bytes[index..end], ' ');
                    index = end;
                }
            },
            ',' => {
                const after = significant_next_reference(input, index + 1);
                const closing = after == ']' or after == '}';
                const valued = std.mem.findScalar(u8, "[{,:", last) == null and last != 0;
                const trailing = closing and valued;

                if (trailing) bytes[index] = ' ' else last = ',';

                index += 1;
            },
            ' ', '\t', '\n', '\r' => index += 1,
            else => {
                last = byte;
                index += 1;
            },
        }
    }

    unreachable;
}

fn string_end_reference(input: []const u8, start: u32) u32 {
    assert(start < input.len);
    assert(input[start] == '"');

    var index = start + 1;

    for (0..input.len) |_| {
        if (index >= input.len) break;

        switch (input[index]) {
            '"' => {
                index += 1;

                break;
            },
            '\\' => index += 2,
            else => index += 1,
        }
    }

    const result: u32 = @intCast(@min(index, input.len));

    assert(result > start);

    return result;
}

fn comment_end_reference(input: []const u8, start: u32) ?u32 {
    assert(start < input.len);
    assert(input[start] == '/');

    const marker: u8 = if (start + 1 == input.len) 0 else input[start + 1];

    const found: ?usize = switch (marker) {
        '*' => if (std.mem.findPos(u8, input, start + 2, "*/")) |close| close + 2 else null,
        '/' => std.mem.findAnyPos(u8, input, start + 2, "\n\r") orelse input.len,
        else => start,
    };

    const end = found orelse return null;
    const result: u32 = @intCast(end);

    assert(result >= start);
    assert(result <= input.len);

    return result;
}

fn significant_next_reference(input: []const u8, start: u32) u8 {
    assert(start <= input.len);
    assert(input.len <= text_bytes_max);

    var index = start;

    for (0..input.len + 1) |_| {
        if (index >= input.len) return 0;

        switch (input[index]) {
            ' ', '\t', '\n', '\r' => index += 1,
            '/' => {
                const end = comment_end_reference(input, index) orelse return 0;
                if (end == index) return '/';

                index = end;
            },
            else => return input[index],
        }
    }

    unreachable;
}

fn relaxed_summary_check(counts: *const RelaxedCounts) !void {
    assert(counts.comma <= std.math.maxInt(u32));
    assert(counts.bom <= std.math.maxInt(u32));

    std.debug.print("fuzz tokenizer relaxed: bom={d} comma={d} block={d} line={d} " ++
        "non_finite={d} mutated accepted={d} rejected={d} open={d}\n", .{
        counts.bom,
        counts.comma,
        counts.comment_block,
        counts.comment_line,
        counts.non_finite,
        counts.accepted_mutated,
        counts.rejected_mutated,
        counts.rejected_open,
    });

    const witnesses = [_]u32{
        counts.accepted_mutated,
        counts.bom,
        counts.comma,
        counts.comment_block,
        counts.comment_line,
        counts.non_finite,
        counts.rejected_mutated,
        counts.rejected_open,
    };

    for (witnesses) |witness| {
        if (witness == 0) return error.RelaxationUnwitnessed;
    }
}

fn json_document_generate(prng: *Prng, text: *Text, depth_max: u32) error{Overflow}!void {
    assert(depth_max <= json_depth_generate_max);
    assert(text.count == 0);

    var stack: JSONStack = .empty;

    try json_value_begin(prng, text, &stack, depth_max);

    for (0..json_step_max) |_| {
        if (stack.count == 0) return;

        const top = stack.get_mutable(stack.count - 1);

        if (top.remaining == 0) {
            try text.push_slice(if (top.object) "}" else "]");
            stack.truncate(stack.count - 1);

            continue;
        }

        if (!top.first) try text.push_slice(", ");

        if (top.object) {
            try json_string_generate(prng, text);
            try text.push_slice(" : ");
        }

        top.first = false;
        top.remaining -= 1;

        try json_value_begin(prng, text, &stack, depth_max);
    }

    return error.Overflow;
}

fn json_value_begin(
    prng: *Prng,
    text: *Text,
    stack: *JSONStack,
    depth_max: u32,
) error{Overflow}!void {
    assert(stack.count <= depth_max);
    assert(depth_max <= json_depth_generate_max);

    const random = prng.random();
    const choice_count: u32 = if (stack.count == depth_max) 5 else 7;

    switch (random.uintLessThan(u32, choice_count)) {
        0 => try text.push_slice(if (random.boolean()) "true" else "false"),
        1 => try text.push_slice("null"),
        2 => try json_number_generate(prng, text),
        3, 4 => try json_string_generate(prng, text),
        5, 6 => |choice| {
            const object = choice == 6;
            const frame = try stack.push_slot();

            frame.* = .{
                .first = true,
                .object = object,
                .remaining = random.uintAtMost(u32, json_width_max),
            };

            try text.push_slice(if (object) "{" else "[");
        },
        else => unreachable,
    }
}

fn json_number_generate(prng: *Prng, text: *Text) error{Overflow}!void {
    assert(text.count <= text_bytes_max);

    const random = prng.random();
    const count = text.count;

    switch (random.uintLessThan(u32, 4)) {
        0 => try text_print(text, "{d}", .{random.int(i64)}),
        1 => try text_print(text, "{d}", .{random.int(u64)}),
        2 => try text_print(text, "-{d}.{d}e{d}", .{
            random.uintAtMost(u32, 9),
            random.int(u16),
            random.intRangeAtMost(i32, -300, 300),
        }),
        3 => try text_print(text, "{d}.5E+{d}", .{ random.int(u8), random.uintAtMost(u8, 30) }),
        else => unreachable,
    }

    assert(text.count > count);
}

fn text_print(text: *Text, comptime format: []const u8, arguments: anytype) error{Overflow}!void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(text.count <= text_bytes_max);

    const written = std.mem.print(text.slice_unused(), format, arguments) catch {
        return error.Overflow;
    };

    text.resize_assume_capacity(text.count + @as(u32, @intCast(written.len)));

    assert(text.count <= text_bytes_max);
}

fn json_string_generate(prng: *Prng, text: *Text) error{Overflow}!void {
    assert(text.count <= text_bytes_max);

    const random = prng.random();
    var buffer: [string_codepoint_count_max * 12 + 128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var decoded: [string_codepoint_count_max * 4]u8 = undefined;
    var decoded_length: u32 = 0;
    const codepoint_count = random.uintAtMost(u32, string_codepoint_count_max);

    for (0..codepoint_count) |_| {
        const codepoint = codepoint_random(prng);

        decoded_length += std.unicode.utf8Encode(codepoint, decoded[decoded_length..]) catch {
            return error.Overflow;
        };
    }

    writer.writeByte('"') catch return error.Overflow;
    string.escape_write(&writer, decoded[0..decoded_length], .trusted) catch return error.Overflow;
    writer.writeByte('"') catch return error.Overflow;

    if (random.uintLessThan(u32, 8) == 0) {
        writer.end -= 1;

        writer.writeAll("\\u00e9\\ud83d\\ude00\\/\\b\\f\"") catch return error.Overflow;
    }

    if (random.uintLessThan(u32, 16) == 0) {
        writer.end -= 1;

        writer.splatByteAll('w', 40) catch return error.Overflow;
        writer.writeByte('"') catch return error.Overflow;
    }

    try text.push_slice(writer.buffered());
}

fn codepoint_random(prng: *Prng) u21 {
    assert(std.unicode.utf8ValidCodepoint(0x10ffff));
    assert(!std.unicode.utf8ValidCodepoint(0xd800));

    const random = prng.random();

    const result: u21 = switch (random.uintLessThan(u32, 5)) {
        0 => random.uintLessThan(u21, 0x80),
        1 => random.intRangeAtMost(u21, 0x80, 0x7ff),
        2 => random.intRangeAtMost(u21, 0xe000, 0xffff),
        3 => random.intRangeAtMost(u21, 0x10000, 0x10ffff),
        4 => random.uintLessThan(u21, 0x20),
        else => unreachable,
    };

    assert(std.unicode.utf8ValidCodepoint(result));

    return result;
}

fn text_mutate(prng: *Prng, text: *Text, alphabet: []const u8) void {
    assert(text.count <= text_bytes_max);
    assert(alphabet.len > 0);

    const random = prng.random();
    const position = random.uintAtMost(u32, text.count);
    const replacement = alphabet[random.uintLessThan(u32, @intCast(alphabet.len))];
    const bytes = text.slice_mutable();

    switch (random.uintLessThan(u32, 3)) {
        0 => {
            if (text.full()) return;

            text.resize_assume_capacity(text.count + 1);

            const grown = text.slice_mutable();

            std.mem.copyBackwards(u8, grown[position + 1 ..], grown[position .. grown.len - 1]);
            grown[position] = replacement;
        },
        1 => {
            if (position == bytes.len) return;

            std.mem.copyForwards(u8, bytes[position .. bytes.len - 1], bytes[position + 1 ..]);
            text.truncate(text.count - 1);
        },
        2 => {
            if (position == bytes.len) return;

            bytes[position] = replacement;
        },
        else => unreachable,
    }
}

const CodecChoice = union(enum) {
    count: i64,
    flag: bool,
    label: []const u8,
    leaf: CodecLeaf,
    list: []const u32,
    none,
};

const CodecKind = enum {
    alpha,
    beta,
    empty,
    unrecognized,

    pub const json = .{ .alpha = "alpha", .beta = "beta-value", .empty = "" };
};

const CodecLeaf = struct {
    flag: ?bool = null,
    kind: ?CodecKind = null,
    number: ?i64 = null,
    ratio: ?f64 = null,
    single: ?f32 = null,
    text: ?[]const u8 = null,
    unsigned: ?u64 = null,

    pub const json = .{
        .flag = "Flag",
        .kind = "kind",
        .number = "Number",
        .ratio = "ratio",
        .text = "Text",
        .unsigned = "Unsigned",
    };
};

const CodecRecord = struct {
    detail: ?Raw = null,
    labels: ?[]const EntryType([]const u8) = null,
    leaf: ?CodecLeaf = null,
    leaves: ?[]const CodecLeaf = null,
    matrix: ?[]const []const []const u8 = null,
    nullable: ?[]const EntryType(?u64) = null,
    sets: ?[]const EntryType(Empty) = null,
    tickets: ?[]const CodecTicket = null,

    pub const json = .{
        .detail = "Detail",
        .labels = "Labels",
        .leaf = "Leaf",
        .leaves = "Leaves",
        .matrix = "Matrix",
        .nullable = "Nullable",
        .sets = "Sets",
    };
};

const CodecTicket = struct {
    choice: CodecChoice,
    id: u64,
    note: []const u8 = "",
    owner: ?[]const u8,

    pub const json = .{ .owner = "Owner" };
};

const ticket_names = [_][]const u8{ "choice", "id", "note", "Owner" };
const ticket_required = [_]u32{ 0, 1, 3 };

fn codec_event(state: *State) !void {
    assert(state.region_buffer.len == region_bytes);
    assert(state.scratch.len == region_bytes);

    var storage: Region = .init(&state.scratch);
    var record: CodecRecord = .{};

    try record_generate(state, &storage, &record);

    const random = state.prng.random();
    const writer_options = writer_options_random(&state.prng);

    const encode_options: codec.EncodeOptions = .{
        .null_members = if (random.boolean()) .emitted else .omitted,
    };

    const first = try record_encode(&record, &state.text, &writer_options, &encode_options);
    var reference: std.heap.FixedBufferAllocator = .init(&state.reference);
    if (!try std.json.validate(reference.allocator(), first)) return error.EncodingInvalid;

    var decoded: CodecRecord = undefined;

    state.region.reset();

    try codec.decode(CodecRecord, &state.region, first, &decoded, .{ .diagnostic = null });
    try std.testing.expectEqualDeep(record, decoded);
    try std.testing.expectEqual(region_bytes, @backingInt(state.region.mark()));

    const second = try record_encode(&decoded, &state.text_other, &writer_options, &encode_options);

    try std.testing.expectEqualStrings(first, second);

    if (record.labels) |labels| try duplicates_check(state, &storage, labels, &writer_options);

    const tickets = record.tickets orelse return;

    if (tickets.len > 0) try ticket_missing_check(state, &tickets[0], &writer_options);
}

fn duplicates_check(
    state: *State,
    storage: *Region,
    labels: []const EntryType([]const u8),
    writer_options: *const Writer.Options,
) !void {
    assert(labels.len <= 4);
    assert(writer_options.indent >= 1);

    const Labels = []const EntryType([]const u8);
    const doubled = try storage.reserve(EntryType([]const u8), @intCast(2 * labels.len));

    for (labels, 0..) |label, index| {
        doubled[index] = label;

        doubled[doubled.len - 1 - index] = .{
            .key = label.key,
            .value = try string_generate(&state.prng, storage),
        };
    }

    var sink: std.Io.Writer = .fixed(&state.text_other.buffer);
    var writer: Writer = .init(&sink, writer_options.*);

    try codec.encode(Labels, &writer, &@as(Labels, doubled), .{ .null_members = .omitted });

    writer.finish();

    var decoded: Labels = undefined;

    state.region.reset();

    try codec.decode(Labels, &state.region, sink.buffered(), &decoded, .{ .diagnostic = null });
    try std.testing.expectEqual(labels.len, decoded.len);

    for (labels, decoded, 0..) |label, entry, index| {
        try std.testing.expectEqualStrings(label.key, entry.key);
        try std.testing.expectEqualStrings(doubled[doubled.len - 1 - index].value, entry.value);
    }
}

fn writer_options_random(prng: *Prng) Writer.Options {
    const random = prng.random();

    const result: Writer.Options = .{
        .indent = random.intRangeAtMost(u8, 1, 16),
        .layout = if (random.boolean()) .compact else .pretty,
        .non_finite = .refused,
        .notation = if (random.boolean()) .decimal else .ecmascript,
        .utf8 = random.enumValue(Writer.UTF8),
    };

    assert(result.indent >= 1);
    assert(result.indent <= 16);

    return result;
}

fn record_encode(
    record: *const CodecRecord,
    text: *Text,
    writer_options: *const Writer.Options,
    encode_options: *const codec.EncodeOptions,
) ![]const u8 {
    assert(text.buffer.len == text_bytes_max);
    assert(writer_options.indent >= 1);

    var sink: std.Io.Writer = .fixed(&text.buffer);
    var writer: Writer = .init(&sink, writer_options.*);

    try codec.encode(CodecRecord, &writer, record, encode_options.*);

    writer.finish();

    return sink.buffered();
}

fn ticket_missing_check(
    state: *State,
    ticket: *const CodecTicket,
    writer_options: *const Writer.Options,
) !void {
    assert(ticket_names.len == @typeInfo(CodecTicket).@"struct".field_names.len);
    assert(writer_options.indent >= 1);

    const skipped = ticket_required[state.prng.random().uintLessThan(u32, ticket_required.len)];
    const encode_options: codec.EncodeOptions = .{ .null_members = .emitted };
    var sink: std.Io.Writer = .fixed(&state.text_other.buffer);
    var writer: Writer = .init(&sink, writer_options.*);

    try writer.object_begin();

    inline for (@typeInfo(CodecTicket).@"struct".field_names, 0..) |name, index| {
        if (index != skipped) {
            const Field = @FieldType(CodecTicket, name);

            try writer.key(ticket_names[index]);
            try codec.encode(Field, &writer, &@field(ticket, name), encode_options);
        }
    }

    try writer.object_end();

    writer.finish();

    var decoded: CodecTicket = undefined;

    state.region.reset();

    const result = codec.decode(CodecTicket, &state.region, sink.buffered(), &decoded, .{
        .diagnostic = null,
    });

    try std.testing.expectError(error.MemberMissing, result);
    try std.testing.expectEqual(@as(u32, 0), state.region.used);
}

fn record_generate(state: *State, storage: *Region, record: *CodecRecord) !void {
    assert(storage.used == 0);
    assert(record.leaf == null);

    const prng = &state.prng;
    const random = prng.random();

    if (random.boolean()) record.leaf = try leaf_generate(prng, storage);
    if (random.boolean()) record.labels = try labels_generate(prng, storage);
    if (random.boolean()) record.matrix = try matrix_generate(prng, storage);
    if (random.boolean()) record.nullable = try nullable_generate(prng, storage);
    if (random.boolean()) record.tickets = try tickets_generate(prng, storage);

    if (random.boolean()) {
        const leaves = try storage.reserve(CodecLeaf, random.uintAtMost(u32, 4));

        for (leaves) |*leaf| leaf.* = try leaf_generate(prng, storage);

        record.leaves = leaves;
    }

    if (random.boolean()) {
        const sets = try storage.reserve(EntryType(Empty), random.uintAtMost(u32, 3));

        for (sets, 0..) |*entry, index| {
            entry.* = .{ .key = try key_generate(prng, storage, @intCast(index)), .value = .{} };
        }

        record.sets = sets;
    }

    if (random.boolean()) try detail_generate(state, storage, record);
}

fn detail_generate(state: *State, storage: *Region, record: *CodecRecord) !void {
    assert(storage.used <= storage.top);
    assert(record.detail == null);

    state.text_other.clear();

    json_document_generate(&state.prng, &state.text_other, 3) catch |err| switch (err) {
        error.Overflow => return,
    };

    const bytes = try storage.reserve(u8, state.text_other.count);

    @memcpy(bytes, state.text_other.slice());

    if (std.mem.eql(u8, bytes, "null")) return;

    record.detail = .{ .text = bytes };
}

fn leaf_generate(prng: *Prng, storage: *Region) !CodecLeaf {
    assert(storage.used <= storage.top);

    const random = prng.random();
    const kinds = [_]CodecKind{ .alpha, .beta, .empty };
    var leaf: CodecLeaf = .{};

    if (random.boolean()) leaf.flag = random.boolean();
    if (random.boolean()) leaf.kind = kinds[random.uintLessThan(u32, kinds.len)];
    if (random.boolean()) leaf.number = random.int(i64);
    if (random.boolean()) leaf.text = try string_generate(prng, storage);
    if (random.boolean()) leaf.unsigned = random.int(u64);

    if (random.boolean()) {
        const ratio: f64 = @bitCast(random.int(u64));

        if (std.math.isFinite(ratio)) leaf.ratio = ratio;
    }

    if (random.boolean()) {
        const single: f32 = @bitCast(random.int(u32));

        if (std.math.isFinite(single)) leaf.single = single;
    }

    if (leaf.ratio) |ratio| assert(std.math.isFinite(ratio));
    if (leaf.single) |single| assert(std.math.isFinite(single));

    return leaf;
}

fn labels_generate(prng: *Prng, storage: *Region) ![]const EntryType([]const u8) {
    assert(storage.used <= storage.top);

    const count = prng.random().uintAtMost(u32, 4);
    const labels = try storage.reserve(EntryType([]const u8), count);

    for (labels, 0..) |*label, index| {
        label.* = .{
            .key = try key_generate(prng, storage, @intCast(index)),
            .value = try string_generate(prng, storage),
        };
    }

    assert(labels.len == count);

    return labels;
}

fn matrix_generate(prng: *Prng, storage: *Region) ![]const []const []const u8 {
    assert(storage.used <= storage.top);

    const random = prng.random();
    const rows = try storage.reserve([]const []const u8, random.uintAtMost(u32, 3));

    for (rows) |*row| {
        const cells = try storage.reserve([]const u8, random.uintAtMost(u32, 3));

        for (cells) |*cell| cell.* = try string_generate(prng, storage);

        row.* = cells;
    }

    assert(rows.len <= 3);

    return rows;
}

fn nullable_generate(prng: *Prng, storage: *Region) ![]const EntryType(?u64) {
    assert(storage.used <= storage.top);

    const random = prng.random();
    const entries = try storage.reserve(EntryType(?u64), random.uintAtMost(u32, 4));

    for (entries, 0..) |*entry, index| {
        entry.* = .{
            .key = try key_generate(prng, storage, @intCast(index)),
            .value = if (random.boolean()) random.int(u64) else null,
        };
    }

    assert(entries.len <= 4);

    return entries;
}

fn tickets_generate(prng: *Prng, storage: *Region) ![]const CodecTicket {
    assert(storage.used <= storage.top);

    const tickets = try storage.reserve(CodecTicket, prng.random().uintAtMost(u32, 4));

    for (tickets) |*ticket| ticket.* = try ticket_generate(prng, storage);

    assert(tickets.len <= 4);

    return tickets;
}

fn ticket_generate(prng: *Prng, storage: *Region) !CodecTicket {
    assert(storage.used <= storage.top);

    const random = prng.random();

    const result: CodecTicket = .{
        .choice = try choice_generate(prng, storage),
        .id = random.int(u64),
        .note = if (random.boolean()) try string_generate(prng, storage) else "",
        .owner = if (random.boolean()) try string_generate(prng, storage) else null,
    };

    assert(result.note.len <= string_codepoint_count_max * 4);

    return result;
}

fn choice_generate(prng: *Prng, storage: *Region) !CodecChoice {
    assert(storage.used <= storage.top);

    const random = prng.random();

    const result: CodecChoice = switch (random.uintLessThan(u32, 6)) {
        0 => .{ .count = random.int(i64) },
        1 => .{ .flag = random.boolean() },
        2 => .{ .label = try string_generate(prng, storage) },
        3 => .{ .leaf = try leaf_generate(prng, storage) },
        4 => .{ .list = try list_generate(prng, storage) },
        5 => .none,
        else => unreachable,
    };

    if (result == .label) assert(result.label.len <= string_codepoint_count_max * 4);

    return result;
}

fn list_generate(prng: *Prng, storage: *Region) ![]const u32 {
    assert(storage.used <= storage.top);

    const random = prng.random();
    const items = try storage.reserve(u32, random.uintAtMost(u32, 4));

    for (items) |*item| item.* = random.int(u32);

    assert(items.len <= 4);

    return items;
}

fn key_generate(prng: *Prng, storage: *Region, index: u32) ![]const u8 {
    assert(index < 10);
    assert(storage.used <= storage.top);

    const text = try string_generate(prng, storage);
    const key = try storage.reserve(u8, @intCast(text.len + 1));

    @memcpy(key[0..text.len], text);
    key[text.len] = '0' + @as(u8, @intCast(index));

    return key;
}

fn string_generate(prng: *Prng, storage: *Region) ![]const u8 {
    assert(storage.used <= storage.top);

    const bytes = try storage.reserve(u8, string_codepoint_count_max * 4);
    var length: u32 = 0;

    for (0..prng.random().uintAtMost(u32, string_codepoint_count_max)) |_| {
        length += try std.unicode.utf8Encode(codepoint_random(prng), bytes[length..]);
    }

    assert(std.unicode.utf8ValidateSlice(bytes[0..length]));

    return bytes[0..length];
}

fn string_event(state: *State) !void {
    assert(state.decoded.len == decoded_bytes_max);
    assert(state.decoded_other.len == decoded_bytes_max);

    var storage: Region = .init(&state.scratch);
    const random = state.prng.random();
    const utf8 = random.enumValue(string.UTF8);
    const original = try string_generate(&state.prng, &storage);
    var input = original;

    if (utf8 != .trusted) input = try text_corrupt(&state.prng, &storage, original);

    var direct: std.Io.Writer = .fixed(&state.text.buffer);

    try direct.writeByte('"');
    try string.escape_write(&direct, input, utf8);
    try direct.writeByte('"');

    const quoted = direct.buffered();
    const escaped = quoted[1 .. quoted.len - 1];
    const slack = random.uintAtMost(u32, 40);
    var streamed: std.Io.Writer = .fixed(state.text_other.buffer[0 .. escaped.len + slack]);

    try string.escape_write(&streamed, input, utf8);
    try std.testing.expectEqualStrings(escaped, streamed.buffered());

    if (escaped.len > 0) {
        var short: std.Io.Writer = .fixed(state.text_other.buffer[0 .. escaped.len - 1]);

        try std.testing.expectError(error.WriteFailed, string.escape_write(&short, input, utf8));
    }

    try policy_check(escaped, utf8);

    var tokenizer: Tokenizer = .init(quoted);
    const raw = (try tokenizer.next()).string;
    const valid = std.unicode.utf8ValidateSlice(input);
    const expected = if (valid) input else string.checked_transform(input, &state.decoded_other);

    try std.testing.expectEqualStrings(expected, try string.unescape(raw, &state.decoded));

    if (valid) try std.testing.expectEqualStrings(escaped, try rewritten_of(state, input, utf8));
}

fn rewritten_of(state: *State, input: []const u8, utf8: string.UTF8) ![]const u8 {
    assert(std.unicode.utf8ValidateSlice(input));
    assert(@backingInt(utf8) < std.enums.values(string.UTF8).len);

    var trusted: std.Io.Writer = .fixed(&state.decoded);

    try string.escape_write(&trusted, input, .trusted);

    var rewritten: std.Io.Writer = .fixed(&state.text_other.buffer);

    try string.escaped_write(&rewritten, trusted.buffered(), utf8);

    return rewritten.buffered();
}

fn policy_check(escaped: []const u8, utf8: string.UTF8) !void {
    assert(escaped.len <= text_bytes_max);
    assert(@backingInt(utf8) < std.enums.values(string.UTF8).len);

    switch (utf8) {
        .ascii => {
            for (escaped) |byte| if (byte >= 0x80) return error.PolicyBroken;
        },
        .bmp => {
            if (!std.unicode.utf8ValidateSlice(escaped)) return error.PolicyBroken;

            for (escaped) |byte| if (byte >= 0xf0) return error.PolicyBroken;
        },
        .checked => {
            if (!std.unicode.utf8ValidateSlice(escaped)) return error.PolicyBroken;
        },
        .trusted => {},
    }
}

fn text_corrupt(prng: *Prng, storage: *Region, original: []const u8) ![]const u8 {
    assert(original.len <= string_codepoint_count_max * 4);
    assert(storage.used <= storage.top);

    const random = prng.random();
    const bytes = try storage.reserve(u8, @intCast(original.len + mutation_count_max));
    var length: u32 = @intCast(original.len);

    @memcpy(bytes[0..length], original);

    for (0..random.uintAtMost(u32, mutation_count_max)) |_| {
        const position = random.uintAtMost(u32, length);

        if (random.boolean()) {
            std.mem.copyBackwards(u8, bytes[position + 1 .. length + 1], bytes[position..length]);
            bytes[position] = random.int(u8) | 0x80;
            length += 1;

            continue;
        }

        if (position == length) continue;

        bytes[position] = random.int(u8);
    }

    assert(length <= bytes.len);

    return bytes[0..length];
}

const RegionModel = struct {
    count: u32,
    values: [region_model_count_max]u64,
};

fn region_event(state: *State) !void {
    assert(state.scratch.len == region_bytes);
    assert(region_model_count_max <= 64);

    var buffer: [4096]u8 align(region_module.alignment_bytes) = undefined;
    var region: Region = .init(&buffer);
    const random = state.prng.random();
    var model: RegionModel = .{ .count = 0, .values = undefined };
    const stack_mark = region.mark();

    for (0..random.uintAtMost(u32, region_model_count_max)) |_| {
        if (random.boolean()) _ = try region.reserve(u8, random.uintAtMost(u32, 9));

        const slot = try region.push(u64);

        slot.* = random.int(u64);
        model.values[model.count] = slot.*;
        model.count += 1;
    }

    const items = try region.take(u64, stack_mark, model.count);

    try std.testing.expectEqualSlices(u64, model.values[0..model.count], items);
    try std.testing.expectEqual(stack_mark, region.mark());
    if (items.len > 0) try std.testing.expect(@intFromPtr(items.ptr) % @alignOf(u64) == 0);
}

const SizingCounts = struct {
    events: u32,
    tightest: u64,
    witnessed: u32,
};

const SizingPair = struct {
    left: []const u8,
    right: []const i16,
};

const SizingRecord = struct {
    flags: []const bool,
    name: []const u8,
    pairs: ?[]const SizingPair = null,
    ratio: f64,
    tags: []const EntryType(?u8),
};

const sizing_types = [_]type{
    []const u8,
    []const []const u8,
    []const u64,
    []const bool,
    []const ?u8,
    []const []const u16,
    []const EntryType([]const i32),
    []const EntryType(bool),
    []const SizingPair,
    SizingRecord,
    []const SizingRecord,
    CodecRecord,
};

fn sizing_event(state: *State) !void {
    assert(state.scratch.len == region_bytes);
    assert(state.sizing.events < std.math.maxInt(u32));

    const choice = state.prng.random().uintLessThan(u32, sizing_types.len);

    inline for (sizing_types, 0..) |T, index| {
        if (index == choice) try sizing_check(T, state);
    }

    state.sizing.events += 1;
}

fn sizing_check(comptime T: type, state: *State) !void {
    assert(state.scratch.len == region_bytes);
    assert(state.region_buffer.len == region_bytes);

    var storage: Region = .init(&state.scratch);
    var value: T = undefined;

    if (T == CodecRecord) {
        value = .{};

        try record_generate(state, &storage, &value);
    } else {
        value = try sizing_value(T, &state.prng, &storage);
    }

    const writer_options = writer_options_random(&state.prng);
    var sink: std.Io.Writer = .fixed(&state.text.buffer);
    var writer: Writer = .init(&sink, writer_options);

    try codec.encode(T, &writer, &value, .{ .null_members = .emitted });

    writer.finish();

    const input = sink.buffered();
    const bound = codec.region_bytes_max(T, @intCast(input.len));
    const offset = state.prng.random().uintLessThan(u32, region_module.alignment_bytes);
    if (offset + bound > state.region_buffer.len) return error.SizingInputLarge;

    var decoded: T = undefined;

    try sizing_decode(T, state.region_buffer[offset..][0..@intCast(bound)], input, &decoded);
    try std.testing.expectEqualDeep(value, decoded);

    if (state.sizing.events % sizing_witness_period == 0) {
        try sizing_witness(T, state, offset, bound, input);
    }
}

fn sizing_decode(comptime T: type, buffer: []u8, input: []const u8, target: *T) !void {
    assert(buffer.len >= region_module.alignment_bytes);
    assert(input.len > 0);

    var region: Region = .init(buffer);

    try codec.decode(T, &region, input, target, .{
        .diagnostic = null,
        .unknown_members = .refused,
    });
}

fn sizing_witness(
    comptime T: type,
    state: *State,
    offset: u32,
    bound: u64,
    input: []const u8,
) !void {
    assert(bound >= region_module.alignment_bytes);
    assert(offset + bound <= state.region_buffer.len);
    assert(input.len > 0);

    var decoded: T = undefined;
    var fails: u64 = region_module.alignment_bytes - 1;
    var fits: u64 = bound;

    for (0..64) |_| {
        if (fits - fails <= 1) break;

        const middle = fails + @divFloor(fits - fails, 2);
        const buffer = state.region_buffer[offset..][0..@intCast(middle)];

        if (sizing_decode(T, buffer, input, &decoded)) {
            fits = middle;
        } else |err| {
            if (err != error.RegionFull) return err;

            fails = middle;
        }
    }

    assert(fits - fails == 1);

    if (fails >= region_module.alignment_bytes) {
        const buffer = state.region_buffer[offset..][0..@intCast(fails)];

        try std.testing.expectError(error.RegionFull, sizing_decode(T, buffer, input, &decoded));
    }

    state.sizing.tightest = @max(state.sizing.tightest, @divFloor(fits * 1000, bound));
    state.sizing.witnessed += 1;
}

fn sizing_summary_check(counts: *const SizingCounts, events_max: u32) !void {
    assert(counts.events == events_max);
    assert(counts.tightest <= 1000);

    std.debug.print("fuzz sizing: witnessed={d} tightest_permille={d}\n", .{
        counts.witnessed,
        counts.tightest,
    });

    if (counts.witnessed == 0) return error.SizingUnwitnessed;
}

fn sizing_value(comptime T: type, prng: *Prng, storage: *Region) !T {
    const random = prng.random();

    switch (comptime codec.shape_of(T)) {
        .boolean => return random.boolean(),
        .float => {
            const value: T = @bitCast(random.int(@Int(.unsigned, @bitSizeOf(T))));
            return if (std.math.isFinite(value)) value else 0.5;
        },
        .integer => return random.int(T),
        .map => {
            const Entry = @typeInfo(T).pointer.child;
            const entries = try storage.reserve(Entry, random.uintAtMost(u32, sizing_count_max));

            for (entries, 0..) |*entry, index| {
                entry.* = .{
                    .key = try key_generate(prng, storage, @intCast(index)),
                    .value = try sizing_value(@FieldType(Entry, "value"), prng, storage),
                };
            }

            return entries;
        },
        .object => {
            var result: T = undefined;

            inline for (@typeInfo(T).@"struct".field_names) |name| {
                const Field = @FieldType(T, name);

                @field(result, name) = try sizing_value(Field, prng, storage);
            }

            return result;
        },
        .optional => {
            if (random.boolean()) return null;
            return try sizing_value(@typeInfo(T).optional.child, prng, storage);
        },
        .sequence => {
            const Element = @typeInfo(T).pointer.child;
            const items = try storage.reserve(Element, random.uintAtMost(u32, sizing_count_max));

            for (items) |*item| item.* = try sizing_value(Element, prng, storage);

            return items;
        },
        .string => return string_generate(prng, storage),
        .adapted, .choice, .entry, .enumeration, .raw => {
            @compileError("no sizing value for this shape");
        },
    }
}
