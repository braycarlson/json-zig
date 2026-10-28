const std = @import("std");

const json = @import("json");

const assert = std.debug.assert;

const Config = json.TreeType(.{ .node_count_max = 128, .text_bytes_max = 1024 });
const Source = json.DocumentType(.{ .node_count_max = 128, .text_bytes_max = 256 });

const settings =
    \\{"name": "warbler", "ports": [8080, 8443],
    \\ "tls": {"enabled": false, "ciphers": ["TLS_AES_128_GCM_SHA256"]}}
;

const changes =
    \\[{"op": "test", "path": "/tls/enabled", "value": true},
    \\ {"op": "add", "path": "/ports/-", "value": 9443},
    \\ {"op": "remove", "path": "/tls/ciphers/0"}]
;

const options: json.Writer.Options = .{
    .indent = 2,
    .layout = .pretty,
    .non_finite = .null_value,
    .notation = .ecmascript,
    .utf8 = .trusted,
};

pub fn main() !void {
    assert(settings.len <= json.limits.input_bytes_max);
    assert(options.indent >= 1);

    var config: Config = undefined;
    var source: Source = undefined;

    config.init();
    try built_write(&config);

    try source.parse(settings);
    try copied_edit(&config, &source);
    try patched_edit(&config, &source);
}

fn built_write(config: *Config) !void {
    assert(config.tree.node_count == 1);
    assert(config.kind_of(config.root()) == .null_value);

    try config.replace(config.root(), .object);

    const root = config.root();
    const name = try config.set(root, "name", .{ .string = "warbler" });
    const ports = try config.set(root, "ports", .array);
    const first = try config.append(ports, .{ .unsigned = 8443 });
    const front = try config.insert(ports, 0, .{ .unsigned = 8080 });

    _ = try config.set(root, "ratio", .{ .float = 0.75 });

    try lines_print(config);

    assert(config.text_is(name, "warbler"));
    assert(config.unsigned_of(front) == 8080);
    assert(config.item(ports, 1) == first);
}

fn copied_edit(config: *Config, source: *const Source) !void {
    assert(source.document.node_count > 0);
    assert(config.tree.node_count > 0);

    try config.replace(config.root(), .{
        .copy = .{ .document = &source.document, .node = source.root() },
    });

    const root = config.root();
    const segments = [_][]const u8{ "tls", "ciphers" };
    const enabled = config.pointer_find(root, "/tls/enabled") orelse return error.EnabledMissing;
    const ciphers = config.path_find(root, &segments) orelse return error.CiphersMissing;
    const ports = config.member(root, "ports") orelse return error.PortsMissing;
    const legacy = config.item(ports, 0) orelse return error.PortMissing;

    try config.replace(enabled, .{ .boolean = true });

    _ = try config.append(ciphers, .{ .string = "TLS_CHACHA20_POLY1305_SHA256" });

    config.remove(legacy);

    try lines_print(config);

    const added = config.pointer_find(root, "/tls/ciphers/1") orelse return error.CipherMissing;

    assert(config.text_is(added, "TLS_CHACHA20_POLY1305_SHA256"));
    assert(config.count_of(ports) == 1);
}

fn patched_edit(config: *Config, source: *Source) !void {
    assert(config.tree.node_count > 0);
    assert(changes.len <= json.limits.input_bytes_max);

    try source.parse(changes);

    var position: json.Position = .{ .column = 0, .line = 0 };

    config.patch(&source.document, source.root(), .{ .diagnostic = &position }) catch |err| {
        std.debug.print("{t} at {d}:{d}\n", .{ err, position.line, position.column });

        return err;
    };

    try lines_print(config);

    const ports = config.member(config.root(), "ports") orelse return error.PortsMissing;

    assert(config.count_of(ports) == 2);
}

fn lines_print(config: *const Config) !void {
    assert(config.tree.node_count > 0);
    assert(options.layout == .pretty);

    var buffer: [1024]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try config.write(&sink, options);

    std.debug.print("{s}\n", .{sink.buffered()});
}
