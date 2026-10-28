const std = @import("std");

const assert = std.debug.assert;

const Artifact = struct {
    name: []const u8,
    root: []const u8,
};

const Context = struct {
    bounded: *std.Build.Module,
    builder: *std.Build,
    filters: []const []const u8,
    module: *std.Build.Module,
    optimize: std.lang.Optimize,
    steps: Steps,
    target: std.Build.ResolvedTarget,
};

const Steps = struct {
    bench: *std.Build.Step,
    check: *std.Build.Step,
    conformance: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    example: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    test_all: *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
    test_wasm: *std.Build.Step,
};

const artifact_bench: Artifact = .{ .name = "bench", .root = "src/bench.zig" };
const artifact_conformance: Artifact = .{ .name = "conformance", .root = "src/conformance.zig" };
const artifact_fuzz: Artifact = .{ .name = "fuzz", .root = "src/fuzz_tests.zig" };

const artifact_examples = [_]Artifact{
    .{ .name = "decode", .root = "examples/decode.zig" },
    .{ .name = "document", .root = "examples/document.zig" },
    .{ .name = "stream", .root = "examples/stream.zig" },
    .{ .name = "tree", .root = "examples/tree.zig" },
    .{ .name = "writer", .root = "examples/writer.zig" },
};

const format_paths = [_][]const u8{ "build.zig", "examples", "src" };
const library_tests_root = "src/library_tests.zig";
const module_root = "src/json.zig";
const unit_tests_root = "src/unit_tests.zig";
const wasm_runner = "tools/wasi_run.mjs";

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .riscv64, .os_tag = .linux },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

const wasm_targets = [_]std.Target.Query{
    .{
        .cpu_arch = .wasm32,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.lime1 },
        .os_tag = .wasi,
    },
    .{
        .cpu_arch = .wasm32,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.lime1 },
        .os_tag = .wasi,
    },
};

comptime {
    assert(artifact_examples.len > 0);
    assert(format_paths.len == 3);
    assert(supported_targets.len == 5);
    assert(wasm_targets.len == 2);
}

pub fn build(builder: *std.Build) void {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const context = Context{
        .bounded = builder.dependency("bounded", .{}).module("bounded"),
        .builder = builder,
        .filters = filters,
        .module = builder.addModule("json", .{ .root_source_file = builder.path(module_root) }),
        .optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null }),
        .steps = steps_declare(builder),
        .target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} }),
    };

    add_bench(&context);
    add_check(&context);
    add_conformance(&context);
    add_example(&context);
    add_format(&context);
    add_fuzz(&context);
    add_unit_tests(&context);
    add_wasm_tests(&context);

    context.steps.continuous_integration.dependOn(context.steps.check);
    context.steps.continuous_integration.dependOn(context.steps.example);
    context.steps.continuous_integration.dependOn(context.steps.fuzz_smoke);
    context.steps.continuous_integration.dependOn(context.steps.test_all);
    context.steps.continuous_integration.dependOn(context.steps.test_wasm);
}

fn steps_declare(builder: *std.Build) Steps {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const result = Steps{
        .bench = builder.step("bench", "Measure parse throughput: zig build bench -- <file>..."),
        .check = builder.step("check", "Compile every artifact for every supported target"),
        .conformance = builder.step(
            "conformance",
            "Run JSONTestSuite, json-patch-tests, and yyjson test/data",
        ),
        .continuous_integration = builder.step("ci", "Run every check, test, and fuzz smoke"),
        .example = builder.step("example", "Build and run every example against the module"),
        .fuzz = builder.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed]"),
        .fuzz_build = builder.step("fuzz:build", "Compile the fuzzers without running them"),
        .fuzz_smoke = builder.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .test_all = builder.step("test", "Run every test suite and the format check"),
        .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
        .test_wasm = builder.step("test:wasm", "Run the unit tests on wasm32 under Node"),
    };

    assert(result.check != result.test_all);
    assert(result.fuzz != result.fuzz_smoke);

    return result;
}

fn executable(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    artifact: Artifact,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() >= 32);
    assert(artifact.name.len > 0);
    assert(std.mem.endsWith(u8, artifact.root, ".zig"));

    return context.builder.addExecutable(.{
        .name = artifact.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact.root),
            .target = target,
            .optimize = context.optimize,
            .omit_frame_pointer = false,
            .imports = &.{.{ .name = "bounded", .module = context.bounded }},
        }),
    });
}

fn example(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    artifact: Artifact,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() >= 32);
    assert(std.mem.startsWith(u8, artifact.root, "examples/"));

    return context.builder.addExecutable(.{
        .name = artifact.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact.root),
            .target = target,
            .optimize = context.optimize,
            .imports = &.{.{ .name = "json", .module = context.module }},
        }),
    });
}

fn add_bench(context: *const Context) void {
    assert(context.steps.bench != context.steps.test_all);
    assert(artifact_bench.root.len > 0);

    const bench = executable(context, context.target, artifact_bench);
    const run = context.builder.addRunArtifact(bench);

    run.addPassthruArgs();
    run.has_side_effects = true;

    context.steps.bench.dependOn(&run.step);
}

fn add_check(context: *const Context) void {
    assert(supported_targets.len > 0);
    assert(context.steps.check != context.steps.test_all);

    const artifacts = [_]Artifact{ artifact_bench, artifact_conformance, artifact_fuzz };

    for (supported_targets) |query| {
        const resolved = context.builder.resolveTargetQuery(query);

        for (artifacts) |artifact| {
            const compiled = executable(context, resolved, artifact);

            context.steps.check.dependOn(&compiled.step);
        }

        for (artifact_examples) |artifact| {
            context.steps.check.dependOn(&example(context, resolved, artifact).step);
        }

        context.steps.check.dependOn(&unit_tests(context, resolved, unit_tests_root).step);
    }
}

fn add_example(context: *const Context) void {
    assert(context.steps.example != context.steps.check);
    assert(artifact_examples.len > 0);

    for (artifact_examples) |artifact| {
        const run = context.builder.addRunArtifact(example(context, context.target, artifact));

        context.steps.example.dependOn(&run.step);
    }
}

fn add_conformance(context: *const Context) void {
    assert(context.steps.conformance != context.steps.test_all);
    assert(artifact_conformance.root.len > 0);

    const conformance = executable(context, context.target, artifact_conformance);
    const run = context.builder.addRunArtifact(conformance);

    run.addPassthruArgs();
    run.has_side_effects = true;

    context.steps.conformance.dependOn(&run.step);
}

fn add_format(context: *const Context) void {
    assert(format_paths.len > 0);
    assert(context.steps.test_format != context.steps.test_all);

    const format = context.builder.addFmt(.{
        .paths = context.builder.pathList(&format_paths),
        .check = true,
    });

    context.steps.test_format.dependOn(&format.step);
    context.steps.test_all.dependOn(&format.step);
}

fn add_fuzz(context: *const Context) void {
    assert(context.steps.fuzz != context.steps.fuzz_smoke);
    assert(artifact_fuzz.root.len > 0);

    const fuzz = executable(context, context.target, artifact_fuzz);
    const fuzz_run = context.builder.addRunArtifact(fuzz);
    const fuzz_smoke = context.builder.addRunArtifact(fuzz);

    const fuzz_install = context.builder.addInstallArtifact(fuzz, .{
        .dest_dir = .default,
        .pdb_dir = .default,
        .compiler_rt_dyn_lib_dir = .default,
        .h_dir = .default,
        .implib_dir = .default,
        .dylib_symlinks = null,
        .dest_sub_path = null,
    });

    fuzz_run.addPassthruArgs();
    fuzz_smoke.addArg("smoke");

    context.steps.fuzz.dependOn(&fuzz_run.step);
    context.steps.fuzz_build.dependOn(&fuzz_install.step);
    context.steps.fuzz_smoke.dependOn(&fuzz_smoke.step);
}

fn unit_tests(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    root: []const u8,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() >= 32);
    assert(context.filters.len < 64);
    assert(std.mem.eql(u8, root, unit_tests_root) or std.mem.eql(u8, root, library_tests_root));

    return context.builder.addTest(.{
        .name = "unit_tests",
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(root),
            .target = target,
            .optimize = context.optimize,
            .imports = &.{.{ .name = "bounded", .module = context.bounded }},
        }),
        .filters = context.filters,
    });
}

fn add_unit_tests(context: *const Context) void {
    assert(context.steps.test_unit != context.steps.test_all);
    assert(unit_tests_root.len > 0);

    const suite = unit_tests(context, context.target, unit_tests_root);
    const run = context.builder.addRunArtifact(suite);

    run.setCwd(context.builder.path("."));
    run.has_side_effects = true;

    context.steps.test_unit.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
}

fn add_wasm_tests(context: *const Context) void {
    assert(context.steps.test_wasm != context.steps.test_all);
    assert(wasm_targets.len > 0);
    assert(library_tests_root.len > 0);

    for (wasm_targets) |query| {
        const target = context.builder.resolveTargetQuery(query);
        const suite = unit_tests(context, target, library_tests_root);
        const run = context.builder.addSystemCommand(&.{ "node", "--no-warnings" });

        run.addFileArg(context.builder.path(wasm_runner));
        run.addArtifactArg(suite);
        run.setCwd(context.builder.path("."));
        run.has_side_effects = true;

        context.steps.test_wasm.dependOn(&run.step);
    }
}
