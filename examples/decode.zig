const std = @import("std");

const json = @import("json");

const assert = std.debug.assert;

const Endpoint = union(enum) {
    port: u16,
    socket: []const u8,
};

const Server = struct {
    endpoint: Endpoint,
    host: []const u8,
    tags: []const []const u8 = &.{},

    pub const json = .{ .host = "Host" };
};

const input =
    \\{"Host": "localhost", "endpoint": 8080, "tags": ["edge", "blue"]}
;

const input_relaxed =
    \\// settings.jsonc
    \\{
    \\    "Host": "localhost",
    \\    "endpoint": "/run/server.sock", /* a socket instead of a port */
    \\    "tags": ["edge",],
    \\}
;

pub fn main() !void {
    assert(input.len <= json.limits.input_bytes_max);

    var buffer: [4096]u8 = undefined;
    var region: json.Region = .init(&buffer);
    var server: Server = undefined;
    var diagnostic: json.Diagnostic = undefined;

    json.decode(Server, &region, input, &server, .{ .diagnostic = &diagnostic }) catch |err| {
        const at = diagnostic.position;

        std.debug.print("{s} at {d}:{d}\n", .{ json.message(err), at.line, at.column });

        return err;
    };

    std.debug.print("host: {s}\n", .{server.host});

    switch (server.endpoint) {
        .port => |port| std.debug.print("port: {d}\n", .{port}),
        .socket => |path| std.debug.print("socket: {s}\n", .{path}),
    }

    for (server.tags) |tag| std.debug.print("tag: {s}\n", .{tag});

    try missing_report(&region);
    try mismatch_report(&region);
    try relaxed_report(&region);

    var encoded_buffer: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&encoded_buffer);

    var writer: json.Writer = .init(&sink, .{
        .indent = 2,
        .layout = .compact,
        .non_finite = .refused,
        .notation = .ecmascript,
        .utf8 = .trusted,
    });

    try json.encode(Server, &writer, &server, .{ .null_members = .omitted });

    writer.finish();

    std.debug.print("{s}\n", .{sink.buffered()});

    assert(std.mem.startsWith(u8, sink.buffered(), "{\"endpoint\":8080,\"Host\":\"localhost\""));
}

fn relaxed_report(region: *json.Region) !void {
    assert(region.used <= region.top);
    assert(input_relaxed.len <= json.limits.input_bytes_max);

    var server: Server = undefined;

    const options: json.DecodeOptions = .{ .diagnostic = null, .unknown_members = .ignored };

    try json.decode_relaxed(Server, region, input_relaxed, &server, options);

    assert(server.endpoint == .socket);
    assert(server.tags.len == 1);

    std.debug.print("relaxed socket: {s}\n", .{server.endpoint.socket});

    const strict = json.decode(Server, region, input_relaxed, &server, options);

    assert(strict == error.Malformed);
}

fn missing_report(region: *json.Region) !void {
    assert(region.used <= region.top);

    const used = region.used;
    var server: Server = undefined;
    var diagnostic: json.Diagnostic = undefined;
    const partial = "{\"Host\": \"localhost\"}";

    json.decode(Server, region, partial, &server, .{ .diagnostic = &diagnostic }) catch |err| {
        switch (err) {
            error.MemberMissing => {
                const at = diagnostic.position;

                assert(region.used == used);
                assert(std.mem.eql(u8, diagnostic.member, "endpoint"));

                std.debug.print("{s} {s} at {d}:{d}\n", .{
                    json.message(err),
                    diagnostic.member,
                    at.line,
                    at.column,
                });

                return;
            },
            else => return err,
        }
    };

    return error.MemberAccepted;
}

fn mismatch_report(region: *json.Region) !void {
    assert(region.used <= region.top);

    const Fleet = struct { servers: []const Server };

    const fleet_input =
        \\{"servers": [{"Host": "a", "endpoint": 80},
        \\ {"Host": "b", "endpoint": true}]}
    ;

    var fleet: Fleet = undefined;
    var diagnostic: json.Diagnostic = undefined;

    json.decode(Fleet, region, fleet_input, &fleet, .{ .diagnostic = &diagnostic }) catch |err| {
        switch (err) {
            error.Mismatch => {
                var buffer: [64]u8 = undefined;
                const pointer = json.pointer_at(fleet_input, diagnostic.position, &buffer) orelse {
                    return error.PointerLong;
                };

                assert(std.mem.eql(u8, pointer, "/servers/1/endpoint"));

                std.debug.print("{s} at {s}\n", .{ json.message(err), pointer });

                return;
            },
            else => return err,
        }
    };

    return error.MismatchAccepted;
}
