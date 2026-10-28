const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("bench.zig");
    _ = @import("codec.zig");
    _ = @import("conformance.zig");
    _ = @import("document.zig");
    _ = @import("index_tokenizer.zig");
    _ = @import("document_fuzz.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("json.zig");
    _ = @import("number.zig");
    _ = @import("number_fuzz.zig");
    _ = @import("number_oracle.zig");
    _ = @import("patch.zig");
    _ = @import("pointer.zig");
    _ = @import("region.zig");
    _ = @import("rename.zig");
    _ = @import("scalar.zig");
    _ = @import("storage.zig");
    _ = @import("stream.zig");
    _ = @import("string.zig");
    _ = @import("tokenizer.zig");
    _ = @import("tree.zig");
    _ = @import("tree_fuzz.zig");
    _ = @import("writer.zig");
    _ = @import("writer_fuzz.zig");
}

test "every public declaration compiles" {
    const json = @import("json.zig");

    comptime assert(@hasDecl(json, "decode"));
    comptime assert(@hasDecl(json, "Tokenizer"));

    std.testing.refAllDecls(json);
    std.testing.refAllDecls(json.Document);
    std.testing.refAllDecls(json.DocumentType(.{ .node_count_max = 8, .text_bytes_max = 8 }));
    std.testing.refAllDecls(json.Entries);
    std.testing.refAllDecls(json.Items);
    std.testing.refAllDecls(json.Region);
    std.testing.refAllDecls(json.Storage);
    std.testing.refAllDecls(json.StorageType(.{ .node_count_max = 8, .text_bytes_max = 8 }));
    std.testing.refAllDecls(json.Stream);
    std.testing.refAllDecls(json.StreamType(.relaxed));
    std.testing.refAllDecls(json.Tokenizer);
    std.testing.refAllDecls(json.TokenizerType(.relaxed));
    std.testing.refAllDecls(json.Tree);
    std.testing.refAllDecls(json.Tree.Entries);
    std.testing.refAllDecls(json.Tree.Items);
    std.testing.refAllDecls(json.Tree.Storage);
    std.testing.refAllDecls(json.Tree.StorageType(.{ .node_count_max = 8, .text_bytes_max = 8 }));
    std.testing.refAllDecls(json.TreeType(.{ .node_count_max = 8, .text_bytes_max = 8 }));
    std.testing.refAllDecls(json.Writer);
    std.testing.refAllDecls(json.limits);
}
