const std = @import("std");

const assert = std.debug.assert;

pub const Rename = enum {
    camel,
    kebab,
    lower,
    pascal,
    snake,
    upper,
};

const Case = enum {
    lower,
    upper,
};

const Leading = enum {
    kept,
    titled,
};

const Output = struct {
    target: []u8,
    used: u32,

    fn emit(output: *Output, byte: u8) bool {
        assert(output.used <= output.target.len);
        assert(output.target.len <= std.math.maxInt(u32));

        if (output.used == output.target.len) return false;

        output.target[output.used] = byte;
        output.used += 1;

        return true;
    }

    fn emit_all(output: *Output, bytes: []const u8) bool {
        assert(output.used <= output.target.len);
        assert(bytes.len <= std.math.maxInt(u32));

        if (output.target.len - output.used < bytes.len) return false;

        @memcpy(output.target[output.used..][0..bytes.len], bytes);
        output.used += @intCast(bytes.len);

        return true;
    }
};

pub fn rename(style: Rename, name: []const u8, target: []u8) ?[]const u8 {
    assert(name.len <= std.math.maxInt(u32));
    assert(target.len <= std.math.maxInt(u32));

    if (style != .kebab) {
        if (!ascii_is(name)) return null;
    }

    var output: Output = .{ .target = target, .used = 0 };

    const written = switch (style) {
        .camel => words_put(&output, name, .kept),
        .kebab => kebab_put(&output, name),
        .lower => cased_put(&output, name, .lower),
        .pascal => words_put(&output, name, .titled),
        .snake => snake_put(&output, name),
        .upper => cased_put(&output, name, .upper),
    };

    if (!written) return null;

    const result = target[0..output.used];

    assert(result.len <= 2 * name.len + 1);

    return result;
}

fn ascii_is(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    for (name) |byte| {
        if (!std.ascii.isAscii(byte)) return false;
    }

    return true;
}

fn cased_put(output: *Output, name: []const u8, case: Case) bool {
    assert(output.used == 0);
    assert(ascii_is(name));

    for (name) |byte| {
        const mapped = switch (case) {
            .lower => std.ascii.toLower(byte),
            .upper => std.ascii.toUpper(byte),
        };

        if (!output.emit(mapped)) return false;
    }

    assert(output.used == name.len);

    return true;
}

fn kebab_put(output: *Output, name: []const u8) bool {
    assert(output.used == 0);
    assert(name.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trim(u8, name, "_");

    for (trimmed) |byte| {
        if (!output.emit(if (byte == '_') '-' else byte)) return false;
    }

    assert(output.used == trimmed.len);

    return true;
}

fn words_put(output: *Output, name: []const u8, leading: Leading) bool {
    assert(output.used == 0);
    assert(ascii_is(name));

    if (name.len == 0) return true;

    if (leading == .kept) {
        if (std.mem.findScalar(u8, name, '_') == null) return output.emit_all(name);
    }

    var parts = std.mem.splitScalar(u8, name, '_');
    var first = true;

    for (0..name.len + 1) |_| {
        const part = parts.next() orelse break;

        if (first) {
            if (part.len == 0) {
                if (!output.emit('_')) return false;

                continue;
            }

            first = false;

            if (leading == .kept) {
                if (!output.emit_all(part)) return false;

                continue;
            }
        }

        if (!title_put(output, part)) return false;
    }

    assert(output.used <= name.len + 1);

    return true;
}

fn title_put(output: *Output, part: []const u8) bool {
    assert(output.used <= output.target.len);
    assert(ascii_is(part));

    var cased = false;

    for (part) |byte| {
        const mapped = if (cased) std.ascii.toLower(byte) else std.ascii.toUpper(byte);

        if (!output.emit(mapped)) return false;

        cased = std.ascii.isAlphabetic(byte);
    }

    return true;
}

fn snake_put(output: *Output, name: []const u8) bool {
    assert(output.used == 0);
    assert(ascii_is(name));

    for (name, 0..) |byte, index| {
        if (snake_break(name, @intCast(index))) {
            if (!output.emit('_')) return false;
        }

        if (!output.emit(if (byte == '-') '_' else std.ascii.toLower(byte))) return false;
    }

    assert(output.used >= name.len);

    return true;
}

fn snake_break(name: []const u8, index: u32) bool {
    assert(index < name.len);
    assert(ascii_is(name));

    if (index == 0) return false;
    if (!std.ascii.isUpper(name[index])) return false;

    const previous = name[index - 1];
    if (std.ascii.isLower(previous)) return true;
    if (std.ascii.isDigit(previous)) return true;
    if (!std.ascii.isUpper(previous)) return false;
    if (index + 1 == name.len) return false;
    return std.ascii.isLower(name[index + 1]);
}

const testing = std.testing;

const TestVector = struct {
    camel: ?[]const u8,
    input: []const u8,
    kebab: []const u8,
    lower: ?[]const u8,
    pascal: ?[]const u8,
    snake: ?[]const u8,
    upper: ?[]const u8,
};

fn test_expected(vector: *const TestVector, style: Rename) ?[]const u8 {
    assert(vector.input.len <= 64);
    assert(vector.kebab.len <= vector.input.len);

    return switch (style) {
        .camel => vector.camel,
        .kebab => vector.kebab,
        .lower => vector.lower,
        .pascal => vector.pascal,
        .snake => vector.snake,
        .upper => vector.upper,
    };
}

fn test_renamed(style: Rename, name: []const u8, buffer: *[256]u8) []const u8 {
    assert(name.len <= 64);
    assert(style != .kebab or name.len <= buffer.len);

    const result = rename(style, name, buffer).?;

    assert(result.len <= 2 * name.len + 1);

    return result;
}

test rename {
    var buffer: [64]u8 = undefined;

    try testing.expectEqualStrings("userId", rename(.camel, "user_id", &buffer).?);
    try testing.expectEqualStrings("http_server", rename(.snake, "HTTPServer", &buffer).?);
    try testing.expectEqualStrings("straße-name", rename(.kebab, "straße_name", &buffer).?);
    try testing.expectEqual(@as(?[]const u8, null), rename(.camel, "straße_name", &buffer));
    try testing.expectEqual(@as(?[]const u8, null), rename(.snake, "HTTPServer", buffer[0..4]));
}

test "every style reproduces msgspec 0.22 and inflection 0.5.1 on the oracle vectors" {
    var buffer: [256]u8 = undefined;

    for (&test_vectors) |*vector| {
        for (std.enums.values(Rename)) |style| {
            const expected = test_expected(vector, style);
            const found = rename(style, vector.input, &buffer);

            if (expected) |text| {
                try testing.expectEqualStrings(text, found.?);
            } else {
                try testing.expectEqual(@as(?[]const u8, null), found);
            }
        }
    }
}

test "a target one byte short of the result is refused and an exact target is filled" {
    var buffer: [256]u8 = undefined;

    for (&test_vectors) |*vector| {
        for (std.enums.values(Rename)) |style| {
            const expected = test_expected(vector, style) orelse continue;
            const exact = rename(style, vector.input, buffer[0..expected.len]).?;

            try testing.expectEqualStrings(expected, exact);

            if (expected.len > 0) {
                const short = rename(style, vector.input, buffer[0 .. expected.len - 1]);

                try testing.expectEqual(@as(?[]const u8, null), short);
            }
        }
    }
}

test "lower, upper, kebab, snake, and camel are idempotent, and pascal ignores the input case" {
    var prng: std.Random.DefaultPrng = .init(0x72656e61);
    const random = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. ";

    var name_buffer: [16]u8 = undefined;
    var once_buffer: [256]u8 = undefined;
    var twice_buffer: [256]u8 = undefined;
    var lower_buffer: [256]u8 = undefined;

    for (0..20_000) |_| {
        const length = random.uintAtMost(u32, name_buffer.len);
        const name = name_buffer[0..length];

        for (name) |*byte| byte.* = alphabet[random.uintLessThan(u32, alphabet.len)];

        const underscores_only = std.mem.trim(u8, name, "_").len == 0;

        for ([_]Rename{ .lower, .upper, .kebab, .snake, .camel }) |style| {
            if (style == .camel) {
                if (underscores_only) continue;
            }

            const once = test_renamed(style, name, &once_buffer);
            const twice = test_renamed(style, once, &twice_buffer);

            try testing.expectEqualStrings(once, twice);
        }

        const lowered = test_renamed(.lower, name, &lower_buffer);
        const pascal = test_renamed(.pascal, name, &once_buffer);
        const pascal_lowered = test_renamed(.pascal, lowered, &twice_buffer);

        try testing.expectEqualStrings(pascal, pascal_lowered);
    }

    var buffer: [16]u8 = undefined;

    try testing.expectEqualStrings("Userid", rename(.pascal, "UserId", &buffer).?);
    try testing.expectEqualStrings("___", rename(.camel, "__", &buffer).?);
}

test "snake undoes camel, pascal, and kebab exactly when no one-letter word precedes a short one" {
    var prng: std.Random.DefaultPrng = .init(0x74726970);
    const random = prng.random();

    const digit_counts = [_]u32{ 0, 0, 1, 2 };

    var name_buffer: [64]u8 = undefined;
    var styled_buffer: [256]u8 = undefined;
    var back_buffer: [256]u8 = undefined;
    var held_count: u32 = 0;
    var refused_count: u32 = 0;

    for (0..20_000) |_| {
        var length: u32 = 0;
        var condition = true;
        var letters_previous: u32 = 0;

        const word_count = random.intRangeAtMost(u32, 1, 5);

        for (0..word_count) |word_index| {
            if (word_index > 0) {
                name_buffer[length] = '_';
                length += 1;
            }

            const letters = random.intRangeAtMost(u32, 1, 4);
            const digits = digit_counts[random.uintLessThan(u32, digit_counts.len)];

            if (letters_previous == 1) {
                if (letters == 1) condition = false;
            }

            letters_previous = if (digits == 0) letters else 0;

            for (0..letters) |_| {
                name_buffer[length] = 'a' + random.uintLessThan(u8, 26);
                length += 1;
            }

            for (0..digits) |_| {
                name_buffer[length] = '0' + random.uintLessThan(u8, 10);
                length += 1;
            }
        }

        const name = name_buffer[0..length];
        var held = true;

        for ([_]Rename{ .camel, .pascal, .kebab }) |style| {
            const styled = test_renamed(style, name, &styled_buffer);
            const back = test_renamed(.snake, styled, &back_buffer);

            if (!std.mem.eql(u8, back, name)) held = false;
        }

        try testing.expectEqual(condition, held);

        if (held) held_count += 1 else refused_count += 1;
    }

    try testing.expect(held_count > 0);
    try testing.expect(refused_count > 0);
}

const test_vectors = [_]TestVector{
    .{
        .camel = "userId",
        .input = "user_id",
        .kebab = "user-id",
        .lower = "user_id",
        .pascal = "UserId",
        .snake = "user_id",
        .upper = "USER_ID",
    },
    .{
        .camel = "userId",
        .input = "userId",
        .kebab = "userId",
        .lower = "userid",
        .pascal = "Userid",
        .snake = "user_id",
        .upper = "USERID",
    },
    .{
        .camel = "UserId",
        .input = "UserId",
        .kebab = "UserId",
        .lower = "userid",
        .pascal = "Userid",
        .snake = "user_id",
        .upper = "USERID",
    },
    .{
        .camel = "UserID",
        .input = "UserID",
        .kebab = "UserID",
        .lower = "userid",
        .pascal = "Userid",
        .snake = "user_id",
        .upper = "USERID",
    },
    .{
        .camel = "userIDs",
        .input = "userIDs",
        .kebab = "userIDs",
        .lower = "userids",
        .pascal = "Userids",
        .snake = "user_i_ds",
        .upper = "USERIDS",
    },
    .{
        .camel = "userId",
        .input = "user_ID",
        .kebab = "user-ID",
        .lower = "user_id",
        .pascal = "UserId",
        .snake = "user_id",
        .upper = "USER_ID",
    },
    .{
        .camel = "HTTPServer",
        .input = "HTTPServer",
        .kebab = "HTTPServer",
        .lower = "httpserver",
        .pascal = "Httpserver",
        .snake = "http_server",
        .upper = "HTTPSERVER",
    },
    .{
        .camel = "httpServer",
        .input = "http_server",
        .kebab = "http-server",
        .lower = "http_server",
        .pascal = "HttpServer",
        .snake = "http_server",
        .upper = "HTTP_SERVER",
    },
    .{
        .camel = "XMLHttpRequest",
        .input = "XMLHttpRequest",
        .kebab = "XMLHttpRequest",
        .lower = "xmlhttprequest",
        .pascal = "Xmlhttprequest",
        .snake = "xml_http_request",
        .upper = "XMLHTTPREQUEST",
    },
    .{
        .camel = "v2Field",
        .input = "v2_field",
        .kebab = "v2-field",
        .lower = "v2_field",
        .pascal = "V2Field",
        .snake = "v2_field",
        .upper = "V2_FIELD",
    },
    .{
        .camel = "v2Field",
        .input = "v2Field",
        .kebab = "v2Field",
        .lower = "v2field",
        .pascal = "V2Field",
        .snake = "v2_field",
        .upper = "V2FIELD",
    },
    .{
        .camel = "field2",
        .input = "field2",
        .kebab = "field2",
        .lower = "field2",
        .pascal = "Field2",
        .snake = "field2",
        .upper = "FIELD2",
    },
    .{
        .camel = "field2",
        .input = "field_2",
        .kebab = "field-2",
        .lower = "field_2",
        .pascal = "Field2",
        .snake = "field_2",
        .upper = "FIELD_2",
    },
    .{
        .camel = "field2Nd",
        .input = "field_2nd",
        .kebab = "field-2nd",
        .lower = "field_2nd",
        .pascal = "Field2Nd",
        .snake = "field_2nd",
        .upper = "FIELD_2ND",
    },
    .{
        .camel = "HTTP2Server",
        .input = "HTTP2Server",
        .kebab = "HTTP2Server",
        .lower = "http2server",
        .pascal = "Http2Server",
        .snake = "http2_server",
        .upper = "HTTP2SERVER",
    },
    .{
        .camel = "ipv4Address",
        .input = "ipv4_address",
        .kebab = "ipv4-address",
        .lower = "ipv4_address",
        .pascal = "Ipv4Address",
        .snake = "ipv4_address",
        .upper = "IPV4_ADDRESS",
    },
    .{
        .camel = "apiV2Beta",
        .input = "api_v2beta",
        .kebab = "api-v2beta",
        .lower = "api_v2beta",
        .pascal = "ApiV2Beta",
        .snake = "api_v2beta",
        .upper = "API_V2BETA",
    },
    .{
        .camel = "a1B",
        .input = "a_1b",
        .kebab = "a-1b",
        .lower = "a_1b",
        .pascal = "A1B",
        .snake = "a_1b",
        .upper = "A_1B",
    },
    .{
        .camel = "a1B2C3",
        .input = "a1_b2_c3",
        .kebab = "a1-b2-c3",
        .lower = "a1_b2_c3",
        .pascal = "A1B2C3",
        .snake = "a1_b2_c3",
        .upper = "A1_B2_C3",
    },
    .{
        .camel = "_private",
        .input = "_private",
        .kebab = "private",
        .lower = "_private",
        .pascal = "_Private",
        .snake = "_private",
        .upper = "_PRIVATE",
    },
    .{
        .camel = "__dunder",
        .input = "__dunder__",
        .kebab = "dunder",
        .lower = "__dunder__",
        .pascal = "__Dunder",
        .snake = "__dunder__",
        .upper = "__DUNDER__",
    },
    .{
        .camel = "__Dunder",
        .input = "__Dunder",
        .kebab = "Dunder",
        .lower = "__dunder",
        .pascal = "__Dunder",
        .snake = "__dunder",
        .upper = "__DUNDER",
    },
    .{
        .camel = "trailing",
        .input = "trailing_",
        .kebab = "trailing",
        .lower = "trailing_",
        .pascal = "Trailing",
        .snake = "trailing_",
        .upper = "TRAILING_",
    },
    .{
        .camel = "aB",
        .input = "a__b",
        .kebab = "a--b",
        .lower = "a__b",
        .pascal = "AB",
        .snake = "a__b",
        .upper = "A__B",
    },
    .{
        .camel = "a",
        .input = "a",
        .kebab = "a",
        .lower = "a",
        .pascal = "A",
        .snake = "a",
        .upper = "A",
    },
    .{
        .camel = "A",
        .input = "A",
        .kebab = "A",
        .lower = "a",
        .pascal = "A",
        .snake = "a",
        .upper = "A",
    },
    .{
        .camel = "ID",
        .input = "ID",
        .kebab = "ID",
        .lower = "id",
        .pascal = "Id",
        .snake = "id",
        .upper = "ID",
    },
    .{
        .camel = "xYZ",
        .input = "x_y_z",
        .kebab = "x-y-z",
        .lower = "x_y_z",
        .pascal = "XYZ",
        .snake = "x_y_z",
        .upper = "X_Y_Z",
    },
    .{
        .camel = "__",
        .input = "_",
        .kebab = "",
        .lower = "_",
        .pascal = "__",
        .snake = "_",
        .upper = "_",
    },
    .{
        .camel = "___",
        .input = "__",
        .kebab = "",
        .lower = "__",
        .pascal = "___",
        .snake = "__",
        .upper = "__",
    },
    .{ .camel = "", .input = "", .kebab = "", .lower = "", .pascal = "", .snake = "", .upper = "" },
    .{
        .camel = "already-kebab",
        .input = "already-kebab",
        .kebab = "already-kebab",
        .lower = "already-kebab",
        .pascal = "Already-Kebab",
        .snake = "already_kebab",
        .upper = "ALREADY-KEBAB",
    },
    .{
        .camel = "Content-Type",
        .input = "Content-Type",
        .kebab = "Content-Type",
        .lower = "content-type",
        .pascal = "Content-Type",
        .snake = "content_type",
        .upper = "CONTENT-TYPE",
    },
    .{
        .camel = "mixedCaseWord",
        .input = "mixed_Case_Word",
        .kebab = "mixed-Case-Word",
        .lower = "mixed_case_word",
        .pascal = "MixedCaseWord",
        .snake = "mixed_case_word",
        .upper = "MIXED_CASE_WORD",
    },
    .{
        .camel = "ALLCaps",
        .input = "ALL_CAPS",
        .kebab = "ALL-CAPS",
        .lower = "all_caps",
        .pascal = "AllCaps",
        .snake = "all_caps",
        .upper = "ALL_CAPS",
    },
    .{
        .camel = "ABCDef",
        .input = "ABCDef",
        .kebab = "ABCDef",
        .lower = "abcdef",
        .pascal = "Abcdef",
        .snake = "abc_def",
        .upper = "ABCDEF",
    },
    .{
        .camel = "aBC",
        .input = "aBC",
        .kebab = "aBC",
        .lower = "abc",
        .pascal = "Abc",
        .snake = "a_bc",
        .upper = "ABC",
    },
    .{
        .camel = "snake2Digits",
        .input = "snake_2_digits",
        .kebab = "snake-2-digits",
        .lower = "snake_2_digits",
        .pascal = "Snake2Digits",
        .snake = "snake_2_digits",
        .upper = "SNAKE_2_DIGITS",
    },
    .{
        .camel = "first name",
        .input = "first name",
        .kebab = "first name",
        .lower = "first name",
        .pascal = "First Name",
        .snake = "first name",
        .upper = "FIRST NAME",
    },
    .{
        .camel = "dot.caseX",
        .input = "dot.case_x",
        .kebab = "dot.case-x",
        .lower = "dot.case_x",
        .pascal = "Dot.CaseX",
        .snake = "dot.case_x",
        .upper = "DOT.CASE_X",
    },
    .{
        .camel = null,
        .input = "stra\xc3\x9fe_name",
        .kebab = "stra\xc3\x9fe-name",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xc3\xa9clair_type",
        .kebab = "\xc3\xa9clair-type",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xc3\xa9clairType",
        .kebab = "\xc3\xa9clairType",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xc7\x86ungla_x",
        .kebab = "\xc7\x86ungla-x",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xef\xac\x81le_name",
        .kebab = "\xef\xac\x81le-name",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "user_\xef\xac\x81le",
        .kebab = "user-\xef\xac\x81le",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xcf\x83_word",
        .kebab = "\xcf\x83-word",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xc4\xb0stanbul_x",
        .kebab = "\xc4\xb0stanbul-x",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xce\xa3Word",
        .kebab = "\xce\xa3Word",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "na\xc3\xafve_Value",
        .kebab = "na\xc3\xafve-Value",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "x\xd9\xa3Abc",
        .kebab = "x\xd9\xa3Abc",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "_\xc3\xbc_",
        .kebab = "\xc3\xbc",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
    .{
        .camel = null,
        .input = "\xc3\xbc-\xc3\x84",
        .kebab = "\xc3\xbc-\xc3\x84",
        .lower = null,
        .pascal = null,
        .snake = null,
        .upper = null,
    },
};
