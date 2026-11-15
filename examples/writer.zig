const std = @import("std");

const json = @import("json");

const assert = std.debug.assert;

const Reading = struct {
    name: []const u8,
    value: f64,
};

const readings = [_]Reading{
    .{ .name = "cpu", .value = 0.375 },
    .{ .name = "disk", .value = std.math.nan(f64) },
    .{ .name = "memory", .value = 1.5e9 },
};

pub fn main() !void {
    assert(readings.len > 0);

    var buffer: [2048]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&buffer);

    try report_write(&sink);
    try lines_write(&sink);

    std.debug.print("{s}", .{sink.buffered()});

    assert(std.mem.endsWith(u8, sink.buffered(), "{\"name\":\"memory\",\"value\":1500000000}\n"));
}

fn report_write(sink: *std.Io.Writer) !void {
    assert(sink.end == 0);

    var writer: json.Writer = .init(sink, .{
        .indent = 2,
        .layout = .pretty,
        .non_finite = .null_value,
        .notation = .ecmascript,
        .utf8 = .checked,
    });

    try writer.object_begin();
    try writer.key("title");
    try writer.string_begin();
    try writer.string_part("nightly ");
    try writer.string_part("report");
    try writer.string_end();
    try writer.key("readings");
    try writer.array_begin();

    for (readings) |reading| {
        try writer.object_begin();
        try writer.key("name");
        try writer.string(reading.name);
        try writer.key("value");
        try writer.float(reading.value);
        try writer.object_end();
    }

    try writer.array_end();
    try writer.object_end();

    writer.finish();

    try sink.writeByte('\n');

    assert(std.mem.endsWith(u8, sink.buffered(), "\n}\n"));
}

fn lines_write(sink: *std.Io.Writer) !void {
    assert(sink.end > 0);

    for (readings) |reading| {
        var writer: json.Writer = .init(sink, .{
            .indent = 2,
            .layout = .compact,
            .non_finite = .null_value,
            .notation = .ecmascript,
            .utf8 = .trusted,
        });

        try json.encode(Reading, &writer, &reading, .{ .null_members = .omitted });

        writer.finish();

        try sink.writeByte('\n');

        assert(std.mem.endsWith(u8, sink.buffered(), "}\n"));
    }
}
