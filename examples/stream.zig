const std = @import("std");

const json = @import("json");

const assert = std.debug.assert;

const Event = struct {
    bytes: u32,
    path: []const u8,
    status: u16,
};

const log =
    \\{"path": "/index.html", "status": 200, "bytes": 5120}
    \\{"path": "/missing", "status": 404, "bytes": 0}
    \\{"path": "/api/users", "status": 200, "bytes": 812}
    \\{"path": "/api/orders", "status": 500, "bytes": 64}
    \\
;

pub fn main() !void {
    assert(log.len > 0);

    var source: std.Io.Reader = .fixed(log);
    var window: [64]u8 = undefined;
    var limited = source.limited(.unlimited, &window);
    var stream: json.Stream = undefined;

    stream.init(&limited.interface, .{ .values = .sequence });

    var region_buffer: [256]u8 = undefined;
    var region: json.Region = .init(&region_buffer);
    var bytes_total: u32 = 0;
    var failure_count: u32 = 0;

    for (0..log.len) |_| {
        const text = try stream.value_next();
        if (text.len == 0) break;

        var event: Event = undefined;

        region.reset();

        try json.decode(Event, &region, text, &event, .{
            .diagnostic = null,
            .unknown_members = .refused,
        });

        bytes_total += event.bytes;

        if (event.status >= 500) failure_count += 1;

        std.debug.print("{d} {s}\n", .{ event.status, event.path });
    }

    std.debug.print("{d} bytes, {d} server failures\n", .{ bytes_total, failure_count });

    assert(bytes_total == 5996);
    assert(failure_count == 1);
}
