const std = @import("std");

const json = @import("json");

const assert = std.debug.assert;

const Message = json.DocumentType(.{ .node_count_max = 256, .text_bytes_max = 1024 });

const request =
    \\{"jsonrpc": "2.0", "id": 7, "method": "textDocument/hover",
    \\ "params": {"textDocument": {"uri": "file:///home/user/caf\u00e9.zig"},
    \\ "position": {"line": 12, "character": 4}}}
;

const truncated =
    \\{"jsonrpc": "2.0", "id": 8,
    \\ "method": "shutdown"
;

pub fn main() !void {
    assert(request.len <= json.limits.input_bytes_max);
    assert(truncated.len <= json.limits.input_bytes_max);

    var message: Message = undefined;

    try message.parse(request);
    try request_read(&message);

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try message.write(&sink, .{
        .indent = 2,
        .layout = .pretty,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    std.debug.print("{s}\n", .{sink.buffered()});

    assert(std.mem.find(u8, sink.buffered(), "caf\\u00e9.zig") != null);

    message.parse(truncated) catch |err| {
        const diagnostic = message.diagnostic();

        std.debug.print("{t} at {d}:{d}\n", .{ err, diagnostic.line, diagnostic.column });

        return;
    };

    return error.TruncatedAccepted;
}

fn request_read(message: *const Message) !void {
    assert(message.document.node_count > 0);
    assert(message.kind_of(message.root()) == .object);

    const path_line = [_][]const u8{ "params", "position", "line" };
    const path_uri = [_][]const u8{ "params", "textDocument", "uri" };
    const root = message.root();
    const method = message.member(root, "method") orelse return error.MethodMissing;
    const uri = message.path_find(root, &path_uri) orelse return error.UriMissing;
    const line = message.path_find(root, &path_line) orelse return error.LineMissing;

    std.debug.print("method: {s}\n", .{message.text_of(method).?});
    std.debug.print("uri: {s}\n", .{message.text_of(uri).?});
    std.debug.print("line: {d}\n", .{message.integer_of(line) orelse return error.LineInvalid});

    const parameters = message.member(root, "params") orelse return error.ParametersMissing;
    var entries = message.entries(parameters);

    for (0..message.count_of(parameters)) |_| {
        const entry = entries.next() orelse break;
        const kind = message.kind_of(entry.value);

        std.debug.print("param: {s} ({t})\n", .{ message.text_of(entry.key).?, kind });
    }
}
