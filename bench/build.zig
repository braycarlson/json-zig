const std = @import("std");

const assert = std.debug.assert;

const driver_linker_script = "drivers/zig/functions.ld";
const driver_name = "json_bench";
const driver_root = "drivers/zig/json_bench.zig";

comptime {
    assert(std.mem.endsWith(u8, driver_linker_script, ".ld"));
    assert(driver_name.len > 0);
    assert(std.mem.endsWith(u8, driver_root, ".zig"));
}

pub fn build(builder: *std.Build) void {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const json = builder.dependency("json", .{}).module("json");
    const target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} });
    const optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null });

    const driver = builder.addExecutable(.{
        .name = driver_name,
        .root_module = builder.createModule(.{
            .root_source_file = builder.path(driver_root),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = true,
            .imports = &.{.{ .name = "json", .module = json }},
        }),
        .use_lld = true,
    });

    driver.link_function_sections = true;
    driver.setLinkerScript(builder.path(driver_linker_script));

    assert(driver.kind == .exe);
    assert(driver.link_function_sections);
    assert(driver.linker_script != null);

    builder.installArtifact(driver);
}
