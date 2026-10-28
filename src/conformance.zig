const std = @import("std");

const codec = @import("codec.zig");
const document_module = @import("document.zig");
const number_module = @import("number.zig");
const oracle = @import("number_oracle.zig");
const region_module = @import("region.zig");
const storage_module = @import("storage.zig");
const stream_module = @import("stream.zig");
const tokenizer_module = @import("tokenizer.zig");
const tree_module = @import("tree.zig");
const writer_module = @import("writer.zig");

const assert = std.debug.assert;

const Document = document_module.Document;
const DocumentNode = document_module.Node;
const Position = tokenizer_module.Position;
const Region = region_module.Region;
const Storage = storage_module.Storage;
const Stream = stream_module.Stream;
const Tokenizer = tokenizer_module.Tokenizer;
const TokenizerType = tokenizer_module.TokenizerType;
const Tree = tree_module.Tree;
const Writer = writer_module.Writer;

const checker_directory = "json/test_checker";
const encoding_directory = "json/test_encoding";
const entry_count_max: u32 = 4096;
const exit_failure: u8 = 1;
const exit_success: u8 = 0;
const file_bytes_max: u32 = 4 * 1024 * 1024;
const number_directory = "num";
const number_line_count_max: u32 = 1 << 20;
const parsing_directory = "test_parsing";
const round_trip_directory = "json/test_roundtrip";
const stream_window_bytes: u32 = 64;
const transform_directory = "test_transform";
const yyjson_directory = "json/test_yyjson";
const patch_files = [_][]const u8{ "spec_tests.json", "tests.json" };

const usage_text = "usage: conformance <JSONTestSuite directory> <json-patch-tests directory> " ++
    "<yyjson test/data directory>";

const relaxed_accepted_pinned = [_][]const u8{
    "n_array_extra_comma.json",
    "n_array_number_and_comma.json",
    "n_number_-NaN.json",
    "n_number_Inf.json",
    "n_number_NaN.json",
    "n_number_infinity.json",
    "n_number_minus_infinity.json",
    "n_object_trailing_comma.json",
    "n_object_trailing_comment.json",
    "n_object_trailing_comment_slash_open.json",
    "n_structure_object_with_comment.json",
};

const yyjson_tags_accepted = [_][]const u8{
    "bignum",
    "bom",
    "comma",
    "comment",
    "endcomment",
    "inf",
    "nan",
};

comptime {
    assert(file_bytes_max <= tokenizer_module.input_bytes_max);
    assert(entry_count_max >= 1024);
}

const Expectation = enum {
    accept,
    either,
    reject,
};

const Naming = enum {
    json_checker,
    json_test_suite,
    transform,
};

const NumberClass = enum {
    integer,
    invalid,
    literal,
    real,
};

const Location = struct {
    root_path: []const u8,
    sub_path: []const u8,
};

const NumberFile = struct {
    class: NumberClass,
    content: []const u8,
    name: []const u8,
};

const Verdicts = struct {
    agreed: bool,
    relaxed: bool,
    strict: bool,
};

const ExternalTally = struct {
    encoding_failed: u32,
    encoding_passed: u32,
    number_failed: u32,
    number_passed: u32,
    round_trip_equal: u32,
    round_trip_total: u32,
};

const Tally = struct {
    document_agreed: u32,
    document_total: u32,
    either_accepted: u32,
    either_rejected: u32,
    failed: u32,
    passed: u32,
    patch_disabled: u32,
    patch_failed: u32,
    patch_passed: u32,
    relaxed: RelaxedTally,
    round_trip_equal: u32,
    round_trip_total: u32,
    stream_file_agreed: u32,
    stream_window_agreed: u32,
    stream_window_exhausted: u32,
    stream_window_explained: u32,
    tree_equal: u32,
    tree_total: u32,
};

const RelaxedTally = struct {
    agreed: u32,
    either_accepted: u32,
    either_rejected: u32,
    invalid_rejected: u32,
    pinned_accepted: u32,
    total: u32,
    unpinned_accepted: u32,
    valid_equal: u32,
    valid_total: u32,
    yyjson_matched: u32,
    yyjson_total: u32,
};

const Checker = struct {
    buffer: []u8,
    documents: *[2]Document,
    external: ExternalTally,
    gpa: std.mem.Allocator,
    json_checker: Tally,
    scratch: []DocumentNode,
    stream_buffer: []u8,
    tally: Tally,
    transform: Tally,
};

const StreamOutcome = union(enum) {
    agreed,
    differed,
    exhausted: Exhaustion,

    const Exhaustion = struct {
        explained: bool,
    };
};

const Case = struct {
    accepted: bool,
    expectation: Expectation,
    name: []const u8,
};

const PatchBench = struct {
    storage: Tree.Storage,
    suite: *const Document,
    tree: Tree,
};

const PatchCase = struct {
    doc: DocumentNode,
    expected: ?DocumentNode,
    failure: bool,
    operations: DocumentNode,
};

pub fn main(init: std.process.Init) u8 {
    assert(init.environ_map.count() < std.math.maxInt(u32));

    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        return failed("the arguments could not be read");
    };

    if (arguments.len != 4) return failed(usage_text);

    const buffer = init.gpa.alloc(u8, file_bytes_max) catch {
        return failed("the file buffer is unavailable");
    };

    defer init.gpa.free(buffer);

    const documents = init.gpa.create([2]Document) catch {
        return failed("the documents are unavailable");
    };

    defer init.gpa.destroy(documents);

    const scratch = init.gpa.alloc(DocumentNode, file_bytes_max) catch {
        return failed("the sort scratch is unavailable");
    };

    defer init.gpa.free(scratch);

    const stream_buffer = init.gpa.alloc(u8, file_bytes_max) catch {
        return failed("the stream buffer is unavailable");
    };

    defer init.gpa.free(stream_buffer);

    var checker: Checker = .{
        .buffer = buffer,
        .documents = documents,
        .external = std.mem.zeroes(ExternalTally),
        .gpa = init.gpa,
        .json_checker = std.mem.zeroes(Tally),
        .scratch = scratch,
        .stream_buffer = stream_buffer,
        .tally = std.mem.zeroes(Tally),
        .transform = std.mem.zeroes(Tally),
    };

    return main_run(init.io, arguments, &checker);
}

fn main_run(io: std.Io, arguments: []const [:0]const u8, checker: *Checker) u8 {
    assert(arguments.len == 4);

    const parsing: Location = .{ .root_path = arguments[1], .sub_path = parsing_directory };

    suite_run(io, parsing, .json_test_suite, checker, &checker.tally) catch |err| {
        std.debug.print("conformance: the suite could not be read: {t}\n", .{err});

        return exit_failure;
    };

    patch_suite_run(io, arguments[2], checker) catch |err| {
        std.debug.print("conformance: the patch suite could not be read: {t}\n", .{err});

        return exit_failure;
    };

    const strict_status = summary_print(&checker.tally);

    relaxed_suite_run(io, arguments[1], checker) catch |err| {
        std.debug.print("conformance: the suite could not be read again: {t}\n", .{err});

        return exit_failure;
    };

    yyjson_suite_run(io, arguments[3], checker) catch |err| {
        std.debug.print("conformance: the yyjson suite could not be read: {t}\n", .{err});

        return exit_failure;
    };

    const relaxed_status = relaxed_summary_print(&checker.tally.relaxed);
    const external_status = external_run(io, arguments, checker);

    if (strict_status != exit_success) return strict_status;
    if (relaxed_status != exit_success) return relaxed_status;
    return external_status;
}

fn external_run(io: std.Io, arguments: []const [:0]const u8, checker: *Checker) u8 {
    assert(arguments.len == 4);
    assert(checker.external.round_trip_total == 0);

    external_suites_run(io, arguments, checker) catch |err| {
        std.debug.print("conformance: the transform, JSON_checker, encoding, round trip, " ++
            "or number suite could not be read: {t}\n", .{err});

        return exit_failure;
    };

    const transform_status = suite_summary_print("transform", &checker.transform);
    const checker_status = suite_summary_print("JSON_checker", &checker.json_checker);
    const external_status = external_summary_print(&checker.external);

    if (transform_status != exit_success) return transform_status;
    if (checker_status != exit_success) return checker_status;
    return external_status;
}

fn external_suites_run(io: std.Io, arguments: []const [:0]const u8, checker: *Checker) !void {
    assert(arguments.len == 4);
    assert(checker.transform.document_total == 0);

    const transform: Location = .{ .root_path = arguments[1], .sub_path = transform_directory };
    const json_checker: Location = .{ .root_path = arguments[3], .sub_path = checker_directory };
    const yyjson_path = arguments[3];

    try suite_run(io, transform, .transform, checker, &checker.transform);
    try suite_run(io, json_checker, .json_checker, checker, &checker.json_checker);
    try encoding_suite_run(io, yyjson_path, checker);
    try round_trip_suite_run(io, yyjson_path, checker);
    try number_suite_run(io, yyjson_path, checker);
}

fn suite_summary_print(label: []const u8, tally: *const Tally) u8 {
    assert(label.len > 0);
    assert(tally.patch_passed == 0);

    std.debug.print("conformance: {s} {d} passed, {d} failed, implementation-defined " ++
        "{d} accepted and {d} rejected, document agrees on {d} of {d}, round trip equal on " ++
        "{d} of {d}, tree copy equal on {d} of {d}, stream agrees on {d} of {d}\n", .{
        label,
        tally.passed,
        tally.failed,
        tally.either_accepted,
        tally.either_rejected,
        tally.document_agreed,
        tally.document_total,
        tally.round_trip_equal,
        tally.round_trip_total,
        tally.tree_equal,
        tally.tree_total,
        tally.stream_file_agreed,
        tally.document_total,
    });

    if (tally.document_total == 0) return exit_failure;
    if (agreement_failed(tally)) return exit_failure;
    return exit_success;
}

fn external_summary_print(tally: *const ExternalTally) u8 {
    assert(tally.round_trip_equal <= tally.round_trip_total);
    assert(oracle.digit_count_max > 0);

    std.debug.print("conformance: encoding {d} passed, {d} failed\n", .{
        tally.encoding_passed,
        tally.encoding_failed,
    });

    std.debug.print("conformance: nativejson round trip byte-identical on {d} of {d}\n", .{
        tally.round_trip_equal,
        tally.round_trip_total,
    });

    std.debug.print("conformance: yyjson numbers {d} passed, {d} failed\n", .{
        tally.number_passed,
        tally.number_failed,
    });

    if (tally.encoding_failed > 0) return exit_failure;
    if (tally.encoding_passed == 0) return exit_failure;
    if (tally.round_trip_equal < tally.round_trip_total) return exit_failure;
    if (tally.round_trip_total == 0) return exit_failure;
    if (tally.number_failed > 0) return exit_failure;
    if (tally.number_passed == 0) return exit_failure;
    return exit_success;
}

fn summary_print(tally: *const Tally) u8 {
    assert(tally.document_agreed <= tally.document_total);
    assert(tally.round_trip_equal <= tally.round_trip_total);

    std.debug.print("conformance: {d} passed, {d} failed, implementation-defined {d} accepted " ++
        "and {d} rejected\n", .{
        tally.passed,
        tally.failed,
        tally.either_accepted,
        tally.either_rejected,
    });

    std.debug.print("conformance: document agrees on {d} of {d}, " ++
        "round trip equal on {d} of {d}\n", .{
        tally.document_agreed,
        tally.document_total,
        tally.round_trip_equal,
        tally.round_trip_total,
    });

    std.debug.print("conformance: tree copy equal on {d} of {d}\n", .{
        tally.tree_equal,
        tally.tree_total,
    });

    std.debug.print("conformance: patch {d} passed, {d} failed, {d} disabled\n", .{
        tally.patch_passed,
        tally.patch_failed,
        tally.patch_disabled,
    });

    std.debug.print("conformance: stream agrees on {d} of {d} with a file-sized buffer and " ++
        "on {d} with a {d}-byte buffer, where {d} of the other {d} stop with BufferExhausted " ++
        "at a token that needs more than {d} bytes\n", .{
        tally.stream_file_agreed,
        tally.document_total,
        tally.stream_window_agreed,
        stream_window_bytes,
        tally.stream_window_explained,
        tally.stream_window_exhausted,
        stream_window_bytes,
    });

    if (tally.patch_failed > 0) return exit_failure;
    if (tally.patch_passed == 0) return exit_failure;
    if (agreement_failed(tally)) return exit_failure;
    return exit_success;
}

fn agreement_failed(tally: *const Tally) bool {
    assert(tally.document_agreed <= tally.document_total);
    assert(tally.stream_window_explained <= tally.stream_window_exhausted);

    if (tally.failed > 0) return true;
    if (tally.document_agreed < tally.document_total) return true;
    if (tally.round_trip_equal < tally.round_trip_total) return true;
    if (tally.tree_equal < tally.tree_total) return true;
    if (tally.stream_file_agreed < tally.document_total) return true;
    if (tally.stream_window_explained < tally.stream_window_exhausted) return true;

    const window_total = tally.stream_window_agreed + tally.stream_window_exhausted;
    return window_total < tally.document_total;
}

fn failed(message: []const u8) u8 {
    assert(message.len > 0);
    assert(exit_failure != exit_success);

    std.debug.print("conformance: {s}\n", .{message});

    return exit_failure;
}

fn suite_run(
    io: std.Io,
    location: Location,
    naming: Naming,
    checker: *Checker,
    tally: *Tally,
) !void {
    assert(location.sub_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    var directory = try directory_open(io, location);
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = (try iterator.next(io)) orelse return;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const expectation = expectation_of(naming, entry.name) orelse continue;
        const content = try directory.readFile(io, entry.name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        const case: Case = .{
            .accepted = accepts(content),
            .expectation = expectation,
            .name = entry.name,
        };

        case_record(&case, tally);

        try document_check(checker, tally, &case, content);

        stream_check(checker, tally, &case, content);
    }

    return error.EntriesExhausted;
}

fn relaxed_summary_print(tally: *const RelaxedTally) u8 {
    assert(tally.valid_equal <= tally.valid_total);
    assert(tally.yyjson_matched <= tally.yyjson_total);

    std.debug.print("conformance: relaxed {d} valid with strict tokens of {d}, " ++
        "{d} invalid rejected, {d} invalid accepted as pinned and {d} unpinned, " ++
        "implementation-defined {d} accepted and {d} rejected\n", .{
        tally.valid_equal,
        tally.valid_total,
        tally.invalid_rejected,
        tally.pinned_accepted,
        tally.unpinned_accepted,
        tally.either_accepted,
        tally.either_rejected,
    });

    std.debug.print("conformance: relaxed yyjson {d} of {d} as tagged, " ++
        "document and decode agree on {d} of {d}\n", .{
        tally.yyjson_matched,
        tally.yyjson_total,
        tally.agreed,
        tally.total,
    });

    if (tally.valid_equal < tally.valid_total) return exit_failure;
    if (tally.unpinned_accepted > 0) return exit_failure;
    if (tally.pinned_accepted != relaxed_accepted_pinned.len) return exit_failure;
    if (tally.yyjson_matched < tally.yyjson_total) return exit_failure;
    if (tally.yyjson_total == 0) return exit_failure;
    if (tally.agreed < tally.total) return exit_failure;
    return exit_success;
}

fn relaxed_suite_run(io: std.Io, root_path: []const u8, checker: *Checker) !void {
    assert(root_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    const options: std.Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .follow_symlinks = true,
        .iterate = true,
    };

    var suite = try std.Io.Dir.cwd().openDir(io, root_path, options);
    defer suite.close(io);

    var directory = try suite.openDir(io, parsing_directory, options);
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = (try iterator.next(io)) orelse return;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const expectation = expectation_of(.json_test_suite, entry.name) orelse continue;
        const content = try directory.readFile(io, entry.name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        const case: Case = .{
            .accepted = relaxed_accepts(content),
            .expectation = expectation,
            .name = entry.name,
        };

        relaxed_case_record(&case, content, &checker.tally.relaxed);

        try relaxed_agreement_check(checker, &case, content);
    }

    return error.EntriesExhausted;
}

fn relaxed_case_record(case: *const Case, content: []const u8, tally: *RelaxedTally) void {
    assert(case.name.len > 0);
    assert(content.len < file_bytes_max);

    switch (case.expectation) {
        .accept => {
            tally.valid_total += 1;

            const equal = case.accepted and tokens_equal(content);

            if (equal) {
                tally.valid_equal += 1;
            } else {
                std.debug.print("RELAXED TOKENS {s}\n", .{case.name});
            }
        },
        .either => {
            if (case.accepted) tally.either_accepted += 1 else tally.either_rejected += 1;
        },
        .reject => {
            if (!case.accepted) {
                tally.invalid_rejected += 1;
            } else if (pinned_is(case.name)) {
                tally.pinned_accepted += 1;
            } else {
                tally.unpinned_accepted += 1;

                std.debug.print("RELAXED UNPINNED {s}\n", .{case.name});
            }
        },
    }
}

fn pinned_is(name: []const u8) bool {
    assert(name.len > 0);
    assert(relaxed_accepted_pinned.len > 0);

    for (relaxed_accepted_pinned) |pinned| {
        if (std.mem.eql(u8, pinned, name)) return true;
    }

    return false;
}

fn relaxed_accepts(input: []const u8) bool {
    assert(input.len <= file_bytes_max);
    assert(input.len <= tokenizer_module.input_bytes_max);

    var tokenizer: TokenizerType(.relaxed) = .init(input);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch return false;
        if (token == .end) return true;
    }

    unreachable;
}

fn tokens_equal(input: []const u8) bool {
    assert(input.len <= file_bytes_max);
    assert(input.len <= tokenizer_module.input_bytes_max);

    var relaxed: TokenizerType(.relaxed) = .init(input);
    var strict: Tokenizer = .init(input);

    for (0..input.len + 2) |_| {
        const expected = strict.next() catch return false;
        const token = relaxed.next() catch return false;
        if (!std.meta.eql(expected, token)) return false;
        if (strict.index != relaxed.index) return false;
        if (expected == .end) return true;
    }

    unreachable;
}

fn relaxed_agreement_check(checker: *Checker, case: *const Case, content: []const u8) !void {
    assert(case.name.len > 0);
    assert(content.len < file_bytes_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];
    const parsed = if (document.parse_relaxed(storage, content)) |_| true else |_| false;

    var buffer: [64]u8 = undefined;
    var region: Region = .init(&buffer);
    var raw: codec.Raw = undefined;

    const options: codec.DecodeOptions = .{ .diagnostic = null, .unknown_members = .ignored };

    const decoded = if (codec.decode_relaxed(codec.Raw, &region, content, &raw, options)) |_|
        true
    else |_|
        false;

    checker.tally.relaxed.total += 1;

    const agreed = parsed == case.accepted and decoded == case.accepted;

    if (agreed) {
        checker.tally.relaxed.agreed += 1;
    } else {
        std.debug.print("RELAXED AGREEMENT {s}: {} {} {}\n", .{
            case.name,
            case.accepted,
            parsed,
            decoded,
        });
    }
}

fn yyjson_suite_run(io: std.Io, root_path: []const u8, checker: *Checker) !void {
    assert(root_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    const options: std.Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .follow_symlinks = true,
        .iterate = true,
    };

    var root = try std.Io.Dir.cwd().openDir(io, root_path, options);
    defer root.close(io);

    var directory = try root.openDir(io, yyjson_directory, options);
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = (try iterator.next(io)) orelse return;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const content = try directory.readFile(io, entry.name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        const case: Case = .{
            .accepted = relaxed_accepts(content),
            .expectation = if (yyjson_accepted_is(entry.name)) .accept else .reject,
            .name = entry.name,
        };

        checker.tally.relaxed.yyjson_total += 1;

        if (case.accepted == (case.expectation == .accept)) {
            checker.tally.relaxed.yyjson_matched += 1;
        } else {
            std.debug.print("YYJSON {s}: accepted={}\n", .{ case.name, case.accepted });
        }

        try relaxed_agreement_check(checker, &case, content);
    }

    return error.EntriesExhausted;
}

fn yyjson_accepted_is(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len < std.math.maxInt(u32));

    var rest = name;

    for (0..name.len) |_| {
        const open = std.mem.findScalar(u8, rest, '(') orelse return true;
        const close = std.mem.findScalarPos(u8, rest, open, ')') orelse return true;
        const tag = rest[open + 1 .. close];
        if (!tag_accepted(tag)) return false;

        rest = rest[close + 1 ..];
    }

    unreachable;
}

fn tag_accepted(tag: []const u8) bool {
    assert(tag.len < std.math.maxInt(u32));
    assert(yyjson_tags_accepted.len > 0);

    for (yyjson_tags_accepted) |accepted| {
        if (std.mem.eql(u8, accepted, tag)) return true;
    }

    return false;
}

fn directory_open(io: std.Io, location: Location) !std.Io.Dir {
    assert(location.root_path.len > 0);
    assert(location.sub_path.len > 0);

    const options: std.Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .follow_symlinks = true,
        .iterate = true,
    };

    var root = try std.Io.Dir.cwd().openDir(io, location.root_path, options);
    defer root.close(io);

    return root.openDir(io, location.sub_path, options);
}

fn encoding_suite_run(io: std.Io, root_path: []const u8, checker: *Checker) !void {
    assert(root_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    const location: Location = .{ .root_path = root_path, .sub_path = encoding_directory };
    var directory = try directory_open(io, location);
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = (try iterator.next(io)) orelse return;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const content = try directory.readFile(io, entry.name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        const expected = encoding_verdicts_of(entry.name);
        const actual = try verdicts_of(checker, content);

        if (std.meta.eql(expected, actual)) {
            checker.external.encoding_passed += 1;
        } else {
            checker.external.encoding_failed += 1;

            std.debug.print("ENCODING {s}: {}\n", .{ entry.name, actual });
        }
    }

    return error.EntriesExhausted;
}

fn encoding_verdicts_of(name: []const u8) Verdicts {
    assert(name.len > 0);
    assert(std.mem.endsWith(u8, name, ".json"));

    const utf8 = std.mem.eql(u8, name, "utf8.json");
    const bom = std.mem.eql(u8, name, "utf8bom.json");

    return .{ .agreed = true, .relaxed = utf8 or bom, .strict = utf8 };
}

fn verdicts_of(checker: *Checker, content: []const u8) !Verdicts {
    assert(content.len > 0);
    assert(content.len < file_bytes_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];
    const strict = accepts(content);
    const relaxed = relaxed_accepts(content);
    const parsed = if (document.parse(storage, content)) |_| true else |_| false;
    const parsed_relaxed = if (document.parse_relaxed(storage, content)) |_| true else |_| false;

    const raw = raw_accepts(content);
    const agreed = parsed == strict and raw == strict and parsed_relaxed == relaxed;

    return .{ .agreed = agreed, .relaxed = relaxed, .strict = strict };
}

fn round_trip_suite_run(io: std.Io, root_path: []const u8, checker: *Checker) !void {
    assert(root_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    const location: Location = .{ .root_path = root_path, .sub_path = round_trip_directory };
    var directory = try directory_open(io, location);
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = (try iterator.next(io)) orelse return;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const content = try directory.readFile(io, entry.name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        checker.external.round_trip_total += 1;

        if (try round_trip_identical(checker, content)) {
            checker.external.round_trip_equal += 1;
        } else {
            std.debug.print("NATIVEJSON ROUND TRIP {s}\n", .{entry.name});
        }
    }

    return error.EntriesExhausted;
}

fn round_trip_identical(checker: *Checker, content: []const u8) !bool {
    assert(content.len > 0);
    assert(content.len < file_bytes_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];

    document.parse(storage, content) catch return false;

    var written: std.Io.Writer.Allocating = .init(checker.gpa);
    defer written.deinit();

    try document.write(&written.writer, layout_options(.compact));

    if (!std.mem.eql(u8, content, written.written())) return false;

    var tree_storage: Tree.Storage = try .init(checker.gpa, capacity_of(content));
    defer tree_storage.deinit(checker.gpa);

    var tree: Tree = undefined;

    tree.init(tree_storage);

    try tree.replace(tree.root(), .{ .copy = .{ .document = document, .node = document.root() } });

    var copied: std.Io.Writer.Allocating = .init(checker.gpa);
    defer copied.deinit();

    try tree.write(&copied.writer, layout_options(.compact));

    return std.mem.eql(u8, content, copied.written());
}

fn number_suite_run(io: std.Io, root_path: []const u8, checker: *Checker) !void {
    assert(root_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    const location: Location = .{ .root_path = root_path, .sub_path = number_directory };
    var directory = try directory_open(io, location);
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..entry_count_max) |_| {
        const entry = (try iterator.next(io)) orelse return;
        if (entry.kind != .file) continue;

        const class = number_class_of(entry.name) orelse continue;
        const content = try directory.readFile(io, entry.name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        const file: NumberFile = .{ .class = class, .content = content, .name = entry.name };

        try number_file_check(checker, &file);
    }

    return error.EntriesExhausted;
}

fn number_class_of(name: []const u8) ?NumberClass {
    assert(name.len > 0);
    assert(name.len < std.math.maxInt(u32));

    if (!std.mem.endsWith(u8, name, ".txt")) return null;
    if (std.mem.find(u8, name, "(fail)") != null) return .invalid;
    if (std.mem.find(u8, name, "(ext)") != null) return .invalid;
    if (std.mem.startsWith(u8, name, "literal")) return .literal;
    if (std.mem.startsWith(u8, name, "int")) return .integer;
    if (std.mem.startsWith(u8, name, "real")) return .real;
    return null;
}

fn number_file_check(checker: *Checker, file: *const NumberFile) !void {
    assert(file.name.len > 0);
    assert(file.content.len < file_bytes_max);

    var lines = std.mem.splitScalar(u8, file.content, '\n');

    for (0..number_line_count_max) |_| {
        const line = std.mem.trimEnd(u8, lines.next() orelse return, "\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (try number_line_passes(checker, file.class, line)) {
            checker.external.number_passed += 1;
        } else {
            checker.external.number_failed += 1;

            std.debug.print("NUMBER {s}: {s}\n", .{ file.name, line[0..@min(line.len, 80)] });
        }
    }

    return error.LinesExhausted;
}

fn number_line_passes(checker: *Checker, class: NumberClass, line: []const u8) !bool {
    assert(line.len > 0);
    assert(line.len < oracle.digit_count_max);

    const verdicts = try verdicts_of(checker, line);
    if (!verdicts.agreed) return false;

    switch (class) {
        .integer, .real => {
            if (!verdicts.strict) return false;
            if (!verdicts.relaxed) return false;
            if (!try number_floats_check(checker, line)) return false;
            if (class == .integer) return number_integers_check(checker, line);
            if (number_module.integer_of_text(line) != null) return false;
            return number_module.unsigned_of_text(line) == null;
        },
        .invalid => return !verdicts.strict and !verdicts.relaxed,
        .literal => return !verdicts.strict and verdicts.relaxed,
    }
}

fn number_floats_check(checker: *Checker, line: []const u8) !bool {
    assert(line.len > 0);
    assert(line.len < oracle.digit_count_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(line));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];

    try document.parse(storage, line);

    const infinity = infinity_of(f64, line);

    const wide = [_]f64{
        number_module.float_of_text(line) orelse infinity,
        document.float_of(document.root()) orelse infinity,
        decoded_float_of(f64, line),
    };

    for (wide) |value| {
        if (!try oracle.float_check(f64, checker.gpa, line, value)) return false;
    }

    return oracle.float_check(f32, checker.gpa, line, decoded_float_of(f32, line));
}

fn number_integers_check(checker: *Checker, line: []const u8) !bool {
    assert(line.len > 0);
    assert(line.len < oracle.digit_count_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(line));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];

    try document.parse(storage, line);

    const root = document.root();

    const signed = [_]?i64{
        number_module.integer_of_text(line),
        document.integer_of(root),
        decoded_integer_of(i64, line),
    };

    const unsigned = [_]?u64{
        number_module.unsigned_of_text(line),
        document.unsigned_of(root),
        decoded_integer_of(u64, line),
    };

    for (signed) |value| {
        if (!try oracle.integer_check(i64, checker.gpa, line, value)) return false;
    }

    for (unsigned) |value| {
        if (!try oracle.integer_check(u64, checker.gpa, line, value)) return false;
    }

    return true;
}

fn infinity_of(comptime T: type, line: []const u8) T {
    comptime assert(@typeInfo(T) == .float);
    assert(line.len > 0);

    const sign: T = if (line[0] == '-') -1 else 1;

    return std.math.copysign(std.math.inf(T), sign);
}

fn decoded_float_of(comptime T: type, line: []const u8) T {
    comptime assert(@typeInfo(T) == .float);
    assert(line.len > 0);

    var buffer: [64]u8 = undefined;
    var region: Region = .init(&buffer);
    var result: T = undefined;

    codec.decode(T, &region, line, &result, .{ .diagnostic = null }) catch {
        return infinity_of(T, line);
    };

    return result;
}

fn decoded_integer_of(comptime T: type, line: []const u8) ?T {
    comptime assert(@typeInfo(T) == .int);
    assert(line.len > 0);

    var buffer: [64]u8 = undefined;
    var region: Region = .init(&buffer);
    var result: T = undefined;

    codec.decode(T, &region, line, &result, .{ .diagnostic = null }) catch return null;

    return result;
}

fn expectation_of(naming: Naming, name: []const u8) ?Expectation {
    assert(name.len > 0);
    assert(name.len < std.math.maxInt(u32));

    switch (naming) {
        .json_checker => {
            if (std.mem.startsWith(u8, name, "pass")) return .accept;
            if (std.mem.endsWith(u8, name, "_EXCLUDE.json")) return .accept;
            if (std.mem.startsWith(u8, name, "fail")) return .reject;
            return null;
        },
        .json_test_suite => {
            if (std.mem.startsWith(u8, name, "y_")) return .accept;
            if (std.mem.startsWith(u8, name, "n_")) return .reject;
            if (std.mem.startsWith(u8, name, "i_")) return .either;
            return null;
        },
        .transform => return .either,
    }
}

fn accepts(input: []const u8) bool {
    assert(input.len <= file_bytes_max);
    assert(input.len <= tokenizer_module.input_bytes_max);

    var tokenizer: Tokenizer = .init(input);

    for (0..input.len + 2) |_| {
        const token = tokenizer.next() catch return false;
        if (token == .end) return true;
    }

    unreachable;
}

fn document_check(checker: *Checker, tally: *Tally, case: *const Case, content: []const u8) !void {
    assert(case.name.len > 0);
    assert(content.len < file_bytes_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];
    const parsed = if (document.parse(storage, content)) |_| true else |_| false;
    const raw = raw_accepts(content);
    const scalar = try backend_agrees(.scalar, checker, content, parsed);
    const simd = try backend_agrees(.simd, checker, content, parsed);

    tally.document_total += 1;

    if (parsed == case.accepted) {
        if (raw == case.accepted) {
            if (scalar) {
                if (simd) tally.document_agreed += 1;
            }
        }
    }

    if (parsed != case.accepted) std.debug.print("DOCUMENT {s}: {}\n", .{ case.name, parsed });
    if (raw != case.accepted) std.debug.print("RAW {s}: {}\n", .{ case.name, raw });
    if (!scalar) std.debug.print("SCALAR {s}\n", .{case.name});
    if (!simd) std.debug.print("SIMD {s}\n", .{case.name});

    if (!case.accepted) return;

    tally.round_trip_total += 1;

    if (!parsed) return;

    if (try round_trip_equal(checker)) {
        tally.round_trip_equal += 1;
    } else {
        std.debug.print("ROUND TRIP {s}\n", .{case.name});
    }

    tally.tree_total += 1;

    if (try tree_equal(checker, content)) {
        tally.tree_equal += 1;
    } else {
        std.debug.print("TREE {s}\n", .{case.name});
    }
}

fn backend_agrees(
    comptime backend: document_module.Backend,
    checker: *Checker,
    content: []const u8,
    parsed: bool,
) !bool {
    comptime assert(@backingInt(backend) < std.enums.values(document_module.Backend).len);
    assert(content.len < file_bytes_max);
    if (parsed) assert(checker.documents[0].node_count > 0);

    var storage: Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    const document = &checker.documents[0];
    const other = &checker.documents[1];
    if (!document_module.parse_attempt(backend, other, storage, content)) return !parsed;
    if (!parsed) return false;
    if (other.node_count != document.node_count) return false;
    if (other.text_count != document.text_count) return false;

    const records = std.mem.sliceAsBytes(document.storage.records[0..document.node_count]);
    const other_records = std.mem.sliceAsBytes(storage.records[0..other.node_count]);
    if (!std.mem.eql(u8, records, other_records)) return false;

    const text = document.storage.text[0..document.text_count];
    return std.mem.eql(u8, text, storage.text[0..other.text_count]);
}

fn capacity_of(content: []const u8) storage_module.Capacity {
    assert(content.len <= storage_module.node_count_limit);
    assert(content.len <= storage_module.text_bytes_limit);

    const length: u32 = @intCast(content.len);
    return .{ .node_count_max = @max(length, 1), .text_bytes_max = length };
}

fn raw_accepts(content: []const u8) bool {
    assert(content.len < file_bytes_max);
    assert(region_module.alignment_bytes <= 64);

    var buffer: [64]u8 = undefined;
    var region: Region = .init(&buffer);
    var raw: codec.Raw = undefined;

    codec.decode(codec.Raw, &region, content, &raw, .{ .diagnostic = null }) catch return false;

    assert(raw.text.len > 0);

    return true;
}

fn round_trip_equal(checker: *Checker) !bool {
    assert(checker.documents[0].node_count > 0);
    assert(checker.documents[0].source.len < file_bytes_max);

    const document = &checker.documents[0];

    var compact: std.Io.Writer.Allocating = .init(checker.gpa);
    defer compact.deinit();

    try document.write(&compact.writer, layout_options(.compact));

    var compact_storage: Storage = try .init(checker.gpa, capacity_of(compact.written()));
    defer compact_storage.deinit(checker.gpa);

    if (!reparsed_equal(checker, compact_storage, compact.written())) return false;

    var rewrite: std.Io.Writer.Allocating = .init(checker.gpa);
    defer rewrite.deinit();

    try checker.documents[1].write(&rewrite.writer, layout_options(.compact));

    if (!std.mem.eql(u8, compact.written(), rewrite.written())) return false;

    var pretty: std.Io.Writer.Allocating = .init(checker.gpa);
    defer pretty.deinit();

    try document.write(&pretty.writer, layout_options(.pretty));

    var pretty_storage: Storage = try .init(checker.gpa, capacity_of(pretty.written()));
    defer pretty_storage.deinit(checker.gpa);

    return reparsed_equal(checker, pretty_storage, pretty.written());
}

fn reparsed_equal(checker: *Checker, storage: Storage, output: []const u8) bool {
    assert(output.len > 0);
    assert(storage.records.len >= output.len);

    checker.documents[1].parse(storage, output) catch return false;

    const comparison: document_module.Comparison = .{
        .left = &checker.documents[0],
        .right = &checker.documents[1],
    };

    return document_module.structure_equal(comparison);
}

fn tree_equal(checker: *Checker, content: []const u8) !bool {
    assert(checker.documents[0].node_count > 0);
    assert(content.len < file_bytes_max);

    const document = &checker.documents[0];

    var storage: Tree.Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    var tree: Tree = undefined;

    tree.init(storage);

    try tree.replace(tree.root(), .{ .copy = .{ .document = document, .node = document.root() } });

    tree_module.audit(&tree);

    for ([_]Writer.Layout{ .compact, .pretty }) |layout| {
        if (!try tree_written_equal(checker, &tree, layout)) return false;
    }

    return true;
}

fn tree_written_equal(checker: *Checker, tree: *const Tree, layout: Writer.Layout) !bool {
    assert(tree.node_count > 0);
    assert(layout == .compact or layout == .pretty);

    const options = layout_options(layout);

    var output: std.Io.Writer.Allocating = .init(checker.gpa);
    defer output.deinit();

    try tree.write(&output.writer, options);

    var direct: std.Io.Writer.Allocating = .init(checker.gpa);
    defer direct.deinit();

    try checker.documents[0].write(&direct.writer, options);

    if (checker.documents[0].text_count == 0) {
        if (!std.mem.eql(u8, output.written(), direct.written())) return false;
    }

    var storage: Storage = try .init(checker.gpa, capacity_of(output.written()));
    defer storage.deinit(checker.gpa);

    if (!reparsed_equal(checker, storage, output.written())) return false;

    var rewrite: std.Io.Writer.Allocating = .init(checker.gpa);
    defer rewrite.deinit();

    try checker.documents[1].write(&rewrite.writer, options);

    return std.mem.eql(u8, output.written(), rewrite.written());
}

fn patch_suite_run(io: std.Io, root_path: []const u8, checker: *Checker) !void {
    assert(root_path.len > 0);
    assert(checker.buffer.len == file_bytes_max);

    const options: std.Io.Dir.OpenOptions = .{
        .access_sub_paths = true,
        .follow_symlinks = true,
        .iterate = false,
    };

    var directory = try std.Io.Dir.cwd().openDir(io, root_path, options);
    defer directory.close(io);

    for (patch_files) |name| {
        const content = try directory.readFile(io, name, checker.buffer);
        if (content.len == checker.buffer.len) return error.FileTooLarge;

        try patch_file_check(checker, content);
    }
}

fn patch_file_check(checker: *Checker, content: []const u8) !void {
    assert(content.len < file_bytes_max);
    assert(checker.tally.patch_failed <= entry_count_max);

    var storage: Storage = try .init(checker.gpa, capacity_of(content));
    defer storage.deinit(checker.gpa);

    const suite = &checker.documents[0];

    try suite.parse(storage, content);

    if (suite.kind_of(suite.root()) != .array) return error.SuiteMalformed;

    var bench: PatchBench = .{
        .storage = try .init(checker.gpa, capacity_of(content)),
        .suite = suite,
        .tree = undefined,
    };

    defer bench.storage.deinit(checker.gpa);

    var records = suite.items(suite.root());

    for (0..suite.count_of(suite.root())) |_| {
        const record = records.next() orelse unreachable;

        try patch_record_check(checker, &bench, record);
    }
}

fn patch_record_check(checker: *Checker, bench: *PatchBench, record: DocumentNode) !void {
    assert(bench.storage.records.len > 0);
    assert(@backingInt(record) < bench.suite.node_count);

    const suite = bench.suite;
    if (suite.kind_of(record) != .object) return error.SuiteMalformed;

    if (suite.member(record, "disabled")) |disabled| {
        if (suite.boolean_of(disabled) orelse false) {
            checker.tally.patch_disabled += 1;

            return;
        }
    }

    const case: PatchCase = .{
        .doc = suite.member(record, "doc") orelse return,
        .expected = suite.member(record, "expected"),
        .failure = suite.member(record, "error") != null,
        .operations = suite.member(record, "patch") orelse return,
    };

    if (try patch_case_passes(checker, bench, &case)) {
        checker.tally.patch_passed += 1;
    } else {
        checker.tally.patch_failed += 1;

        std.debug.print("PATCH {s}\n", .{patch_comment_of(suite, record)});
    }
}

fn patch_case_passes(checker: *Checker, bench: *PatchBench, case: *const PatchCase) !bool {
    assert(@backingInt(case.doc) < bench.suite.node_count);
    assert(@backingInt(case.operations) < bench.suite.node_count);

    const suite = bench.suite;
    const tree = &bench.tree;

    tree.init(bench.storage);

    try tree.replace(tree.root(), .{ .copy = .{ .document = suite, .node = case.doc } });

    var position: Position = .{ .column = 0, .line = 0 };
    const result = tree.patch(suite, case.operations, .{ .diagnostic = &position });

    tree_module.audit(tree);

    result catch |err| {
        const conflict = switch (err) {
            error.DepthExceeded, error.NodesExhausted, error.TextExhausted => false,
            error.PatchMalformed, error.PathMissing, error.TestFailed => true,
        };

        return case.failure and conflict and position.line >= 1;
    };

    if (case.failure) return false;

    const expected = case.expected orelse return true;
    return patch_result_equal(checker, bench, expected);
}

fn patch_result_equal(checker: *Checker, bench: *const PatchBench, expected: DocumentNode) !bool {
    assert(bench.tree.node_count > 0);
    assert(@backingInt(expected) < bench.suite.node_count);

    var output: std.Io.Writer.Allocating = .init(checker.gpa);
    defer output.deinit();

    try bench.tree.write(&output.writer, layout_options(.compact));

    var storage: Storage = try .init(checker.gpa, capacity_of(output.written()));
    defer storage.deinit(checker.gpa);

    const result = &checker.documents[1];

    result.parse(storage, output.written()) catch return false;

    assert(checker.scratch.len >= result.node_count);
    assert(checker.scratch.len >= bench.suite.node_count);

    var left: std.Io.Writer.Allocating = .init(checker.gpa);
    defer left.deinit();

    var right: std.Io.Writer.Allocating = .init(checker.gpa);
    defer right.deinit();

    try sorted_write(result, checker.scratch, &left.writer, result.root());
    try sorted_write(bench.suite, checker.scratch, &right.writer, expected);

    return std.mem.eql(u8, left.written(), right.written());
}

fn sorted_write(
    document: *const Document,
    scratch: []DocumentNode,
    sink: *std.Io.Writer,
    node: DocumentNode,
) !void {
    assert(scratch.len >= document.node_count);
    assert(@backingInt(node) < document.node_count);

    var writer: Writer = .init(sink, layout_options(.compact));

    try document.node_write_sorted(scratch, &writer, node);

    writer.finish();
}

fn patch_comment_of(suite: *const Document, record: DocumentNode) []const u8 {
    assert(suite.kind_of(record) == .object);
    assert(suite.node_count > 0);

    const comment = suite.member(record, "comment") orelse return "(no comment)";
    return suite.text_of(comment) orelse "(no comment)";
}

fn layout_options(layout: Writer.Layout) Writer.Options {
    assert(layout == .compact or layout == .pretty);
    assert(@typeInfo(Writer.Layout).@"enum".field_names.len == 2);

    return .{ .indent = 2, .layout = layout, .non_finite = .refused, .utf8 = .trusted };
}

fn stream_check(checker: *Checker, tally: *Tally, case: *const Case, content: []const u8) void {
    assert(case.name.len > 0);
    assert(content.len < checker.stream_buffer.len);

    const file_buffer = checker.stream_buffer[0 .. content.len + 1];
    const window_buffer = checker.stream_buffer[0..stream_window_bytes];

    switch (stream_outcome(content, file_buffer)) {
        .agreed => tally.stream_file_agreed += 1,
        .differed, .exhausted => std.debug.print("STREAM {s}\n", .{case.name}),
    }

    switch (stream_outcome(content, window_buffer)) {
        .agreed => tally.stream_window_agreed += 1,
        .differed => std.debug.print("STREAM WINDOW {s}\n", .{case.name}),
        .exhausted => |exhaustion| {
            tally.stream_window_exhausted += 1;

            if (exhaustion.explained) {
                tally.stream_window_explained += 1;
            } else {
                std.debug.print("STREAM EXHAUSTED {s}\n", .{case.name});
            }
        },
    }
}

fn stream_outcome(content: []const u8, buffer: []u8) StreamOutcome {
    assert(content.len < file_bytes_max);
    assert(buffer.len > 0);
    assert(buffer.len <= tokenizer_module.input_bytes_max);

    var source: std.Io.Reader = .fixed(content);
    var limited = source.limited(.unlimited, buffer);
    var stream: Stream = undefined;
    var tokenizer: Tokenizer = .init(content);

    stream.init(&limited.interface, .{ .values = .single });

    for (0..content.len + 2) |_| {
        const start = token_start(content, tokenizer.index);
        const expected = tokenizer.next();

        const actual = stream.next() catch |err| {
            const diagnostic = stream.diagnostic();

            if (err == error.BufferExhausted) {
                const token: ?tokenizer_module.Token = expected catch null;
                const explained = stream_exhaustion_explained(content, start, token, &tokenizer);
                const placed = position_is(content, start, diagnostic);

                return .{ .exhausted = .{ .explained = explained and placed } };
            }

            const reference_err = if (expected) |_| {
                return .differed;
            } else |reference_err| reference_err;

            if (reference_err != err) return .differed;

            const placed = position_is(content, tokenizer.failure_index, diagnostic);
            return if (placed) .agreed else .differed;
        };

        const token = expected catch return .differed;

        std.testing.expectEqualDeep(token, actual) catch return .differed;

        if (token == .end) return .agreed;
    }

    unreachable;
}

fn stream_exhaustion_explained(
    content: []const u8,
    start: u32,
    expected: ?tokenizer_module.Token,
    tokenizer: *const Tokenizer,
) bool {
    assert(start <= content.len);
    assert(tokenizer.index <= content.len);
    if (expected) |token| assert(token != .end);

    const token = expected orelse return tokenizer.failure_index - start + 1 > stream_window_bytes;

    const needed: u32 = switch (token) {
        .number => tokenizer.index - start + 1,
        else => tokenizer.index - start,
    };

    return needed > stream_window_bytes;
}

fn position_is(content: []const u8, index: u32, position: Position) bool {
    assert(index <= content.len);
    assert(position.line >= 1);

    const expected = tokenizer_module.position_of(content, index);
    return expected.line == position.line and expected.column == position.column;
}

fn token_start(content: []const u8, index: u32) u32 {
    assert(index <= content.len);
    assert(content.len <= file_bytes_max);

    const blank = " \t\n\r";
    const first = std.mem.findNonePos(u8, content, index, blank) orelse content.len;
    const separator = first < content.len and (content[first] == ',' or content[first] == ':');

    const result = if (separator)
        std.mem.findNonePos(u8, content, first + 1, blank) orelse content.len
    else
        first;

    assert(result >= index);
    assert(result <= content.len);

    return @intCast(result);
}

fn case_record(case: *const Case, tally: *Tally) void {
    assert(case.name.len > 0);
    assert(tally.failed <= entry_count_max);

    switch (case.expectation) {
        .accept, .reject => {
            if (case.accepted == (case.expectation == .accept)) {
                tally.passed += 1;
            } else {
                tally.failed += 1;

                std.debug.print("FAIL {s}: accepted={}\n", .{ case.name, case.accepted });
            }
        },
        .either => {
            if (case.accepted) tally.either_accepted += 1 else tally.either_rejected += 1;

            std.debug.print("implementation-defined {s}: accepted={}\n", .{
                case.name,
                case.accepted,
            });
        },
    }
}

const testing = std.testing;

test "a yyjson case is expected to pass exactly when every tag is a relaxation json-zig covers" {
    try testing.expect(yyjson_accepted_is("blns.json"));
    try testing.expect(yyjson_accepted_is("trailing_comma_1(comma).min.json"));
    try testing.expect(yyjson_accepted_is("literal_inf(inf).json"));
    try testing.expect(!yyjson_accepted_is("literal_inf(inf)(ext_num).json"));
    try testing.expect(!yyjson_accepted_is("comment_multiline_empty(fail).json"));
    try testing.expect(!yyjson_accepted_is("str_single_quote_1(str_sq).json"));
    try testing.expect(!yyjson_accepted_is("content_after_doc_1(garbage).min.json"));
}

test "a case name prefix names what the parser must do with it" {
    const suite: Naming = .json_test_suite;

    try testing.expectEqual(Expectation.accept, expectation_of(suite, "y_object.json").?);
    try testing.expectEqual(Expectation.reject, expectation_of(suite, "n_array_comma.json").?);
    try testing.expectEqual(Expectation.either, expectation_of(suite, "i_number_huge_exp.json").?);
    try testing.expectEqual(@as(?Expectation, null), expectation_of(suite, "README.md"));
}

test "a JSON_checker name passes, fails, or is excluded because RFC 8259 allows it" {
    const json_checker: Naming = .json_checker;

    try testing.expectEqual(Expectation.accept, expectation_of(json_checker, "pass01.json").?);
    try testing.expectEqual(Expectation.reject, expectation_of(json_checker, "fail02.json").?);
    const excluded = expectation_of(json_checker, "fail18_EXCLUDE.json").?;

    try testing.expectEqual(Expectation.accept, excluded);
    try testing.expectEqual(Expectation.either, expectation_of(.transform, "number_1e6.json").?);
}

test "a yyjson number file name gives the class every line in it belongs to" {
    try testing.expectEqual(NumberClass.integer, number_class_of("int.txt").?);
    try testing.expectEqual(NumberClass.integer, number_class_of("int(big).txt").?);
    try testing.expectEqual(NumberClass.real, number_class_of("real(inf).txt").?);
    try testing.expectEqual(NumberClass.real, number_class_of("real_7.txt").?);
    try testing.expectEqual(NumberClass.invalid, number_class_of("real(inf)(ext).txt").?);
    try testing.expectEqual(NumberClass.invalid, number_class_of("hex(fail).txt").?);
    try testing.expectEqual(NumberClass.invalid, number_class_of("literal(ext).txt").?);
    try testing.expectEqual(NumberClass.literal, number_class_of("literal.txt").?);
    try testing.expectEqual(@as(?NumberClass, null), number_class_of("README.md"));
    try testing.expectEqual(@as(?NumberClass, null), number_class_of("hex(ext)(big).txt.bak"));
}
