# json-zig

A JSON decoder and writer for Zig. The library decodes JSON straight into Zig types, and a read-only document carries explicit limits on depth, input size, and node count. A separate editable tree covers the cases that need mutation, alongside JSON Pointer, JSON Patch, Merge Patch, a streaming reader for JSON Lines, and an opt-in relaxed syntax. The library is tested against JSONTestSuite, json-patch-tests, and the yyjson suite.
