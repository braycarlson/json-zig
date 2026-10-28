const std = @import("std");

const lacuna = @import("lacuna");

const assert = std.debug.assert;

const python = [_][]const u8{
    "uv",
    "run",
    "--no-project",
    "--python",
    "/usr/bin/python3",
    "--with",
    "pytest",
    "python",
};

const platforms = platforms: {
    var result: [lacuna.platforms.len]lacuna.Platform = undefined;
    var count: usize = 0;

    for (lacuna.platforms) |platform| {
        switch (platform.query.cpu_arch.?) {
            .aarch64, .x86_64 => {
                result[count] = platform;
                count += 1;
            },
            else => {},
        }
    }

    const selected = result[0..count].*;

    break :platforms selected;
};

const Interpreter = struct {
    command: []const []const u8,
    version: lacuna.Version,
};

const versioned_interpreters = interpreters_of(&lacuna.versioned_all, "+gil");
const free_threaded_interpreters = interpreters_of(&lacuna.free_threaded_default, "t");

comptime {
    assert(platforms.len > 0);
    assert(platforms.len < lacuna.platforms.len);
    assert(versioned_interpreters.len == lacuna.versioned_all.len);
}

pub fn build(builder: *std.Build) void {
    assert(builder.graph.host.result.ptrBitWidth() == 64);
    assert(python.len > 0);

    const json = builder.createModule(.{
        .root_source_file = builder.dependency("json", .{}).path("src/json.zig"),
        .omit_frame_pointer = true,
    });

    const target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} });

    const module = builder.createModule(.{
        .root_source_file = builder.path("src/json_zig.zig"),
        .imports = &.{.{ .name = "json", .module = json }},
        .omit_frame_pointer = true,
    });

    const extension = lacuna.add_extension(builder, .{
        .dispatch = true,
        .free_threaded = &lacuna.free_threaded_default,
        .module = module,
        .name = "json_zig",
        .optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null }),
        .package = .{
            .license = .{
                .expression = "MIT",
                .files = &.{.{ .name = "LICENSE", .path = builder.path("../../LICENSE") }},
            },
            .name = "json-zig",
            .summary = "Parse JSON with json-zig",
            .version = "0.1.0",
        },
        .platforms = &platforms,
        .release_optimize = .fast,
        .strip = false,
        .target = target,
        .versioned = &lacuna.versioned_all,
    });

    const test_step = builder.step("test", "Run the unit tests and every build's pytest suite");

    python_tests_add(builder, &extension, test_step);
    unit_tests_add(builder, .{ .json = json, .step = test_step, .target = target });

    builder.getInstallStep().dependOn(extension.develop);
}

fn python_tests_add(
    builder: *std.Build,
    extension: *const lacuna.Extension,
    test_step: *std.Build.Step,
) void {
    assert(extension.versioned.len == versioned_interpreters.len);
    assert(extension.free_threaded.len == free_threaded_interpreters.len);

    const script = builder.path("tests/test_json_zig.py");
    const stable: lacuna.PythonTestOptions = .{ .python = &python, .script = script };

    test_step.dependOn(&lacuna.add_python_test(builder, extension, stable).step);

    for (versioned_interpreters) |interpreter| {
        const options: lacuna.PythonTestOptions = .{
            .python = interpreter.command,
            .script = script,
            .versioned = interpreter.version,
        };

        test_step.dependOn(&lacuna.add_python_test(builder, extension, options).step);
    }

    for (free_threaded_interpreters) |interpreter| {
        const options: lacuna.PythonTestOptions = .{
            .free_threaded = interpreter.version,
            .python = interpreter.command,
            .script = script,
        };

        test_step.dependOn(&lacuna.add_python_test(builder, extension, options).step);
    }
}

const Unit = struct {
    json: *std.Build.Module,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
};

fn unit_tests_add(builder: *std.Build, unit: Unit) void {
    assert(unit.json.owner.graph == builder.graph);
    assert(unit.step.owner == builder);

    const lacuna_module = builder.dependency("lacuna", .{}).module("lacuna");

    const tests = builder.addTest(.{
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("src/unit_tests.zig"),
            .imports = &.{
                .{ .name = "json", .module = unit.json },
                .{ .name = "lacuna", .module = lacuna_module },
            },
            .target = unit.target,
            .optimize = .debug,
        }),
        .use_llvm = true,
    });

    unit.step.dependOn(&builder.addRunArtifact(tests).step);
}

fn interpreters_of(
    comptime versions: []const lacuna.Version,
    comptime suffix: []const u8,
) [versions.len]Interpreter {
    comptime assert(versions.len > 0);
    comptime assert(suffix.len > 0);

    var result: [versions.len]Interpreter = undefined;

    for (versions, &result) |version, *interpreter| {
        const name = std.fmt.comptimePrint("{d}.{d}{s}", .{ version.major, version.minor, suffix });

        interpreter.* = .{
            .command = &.{
                "uv",
                "run",
                "--no-project",
                "--python",
                name,
                "--with",
                "pytest",
                "python",
            },
            .version = version,
        };
    }

    return result;
}
