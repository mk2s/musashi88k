const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build option: whether the engine may reference the classic Musashi-style
    // global memory functions (m88k_read/write_memory_*) as weak externs.
    //
    //  * STATIC library / source inclusion: ON. The final link resolves the
    //    globals the host defines, so the "just define the functions" workflow
    //    works exactly like Musashi.
    //  * SHARED library (.dylib/.dll): OFF. A standalone shared object must not
    //    reference symbols that live in the host executable (macOS and Windows
    //    reject that), so the shared build uses ONLY the registration API
    //    m88k_set_memory_callbacks().
    const global_opts = b.addOptions();
    global_opts.addOption(bool, "enable_global_callbacks", true);
    const shared_only_opts = b.addOptions();
    shared_only_opts.addOption(bool, "enable_global_callbacks", false);

    // Static library: libm88k.a (or m88k.lib on Windows). Globals enabled.
    const engine_mod = b.createModule(.{
        .root_source_file = b.path("src/m88k.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addOptions("build_options", global_opts);
    const static_lib = b.addLibrary(.{
        .name = "m88k",
        .linkage = .static,
        .root_module = engine_mod,
    });
    static_lib.installHeader(b.path("include/m88k.h"), "m88k.h");
    b.installArtifact(static_lib);

    // Shared library: libm88k.so / .dylib / m88k.dll. Globals disabled so it is
    // fully self-contained and links on every target.
    const shared_mod = b.createModule(.{
        .root_source_file = b.path("src/m88k.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    shared_mod.addOptions("build_options", shared_only_opts);
    const shared_lib = b.addLibrary(.{
        .name = "m88k",
        .linkage = .dynamic,
        .root_module = shared_mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    shared_lib.installHeader(b.path("include/m88k.h"), "m88k.h");
    b.installArtifact(shared_lib);

    // --- C smoke test: links the static library and runs a small program ---
    const test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFile(.{
        .file = b.path("tests/smoke.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    test_mod.addIncludePath(b.path("include"));
    test_mod.linkLibrary(static_lib);
    const smoke = b.addExecutable(.{
        .name = "smoke",
        .root_module = test_mod,
    });
    b.installArtifact(smoke);

    const run_smoke = b.addRunArtifact(smoke);
    const test_step = b.step("test", "Build and run the C smoke test");
    test_step.dependOn(&run_smoke.step);

    // --- Zig unit tests for the decoder ---
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    const run_unit = b.addRunArtifact(unit_tests);
    const unit_step = b.step("unit", "Run Zig unit tests for the decoder");
    unit_step.dependOn(&run_unit.step);

    // --- Differential-test runner ---
    // Reads JSON test cases on stdin, single-steps each against the core, and
    // writes JSON results on stdout. tests/difftest.py feeds the same cases to
    // the nono hardware emulator and compares.
    // One shared cpu module, imported (by the name each file uses) into both
    // the decode module and the runner, so there is a single `Cpu` type.
    const cpu_module = b.createModule(.{
        .root_source_file = b.path("src/cpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    const decode_module = b.createModule(.{
        .root_source_file = b.path("src/decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_module.addImport("cpu.zig", cpu_module);
    const diff_mod = b.createModule(.{
        .root_source_file = b.path("tests/difftest_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    diff_mod.addImport("cpu.zig", cpu_module);
    diff_mod.addImport("decode.zig", decode_module);
    const diff_runner = b.addExecutable(.{
        .name = "difftest_runner",
        .root_module = diff_mod,
    });
    const diff_install = b.addInstallArtifact(diff_runner, .{});
    b.getInstallStep().dependOn(&diff_install.step);
    const diff_step = b.step("difftest-runner", "Build the differential-test runner executable");
    diff_step.dependOn(&diff_install.step);

    // `zig build difftest` runs the fixture through our core and compares the
    // output against the hardware-verified oracle (tests/difftest_oracle.json).
    const run_diff = b.addRunArtifact(diff_runner);
    run_diff.addFileArg(b.path("tests/difftest_cases.json"));
    const diff_out = run_diff.addOutputFileArg("difftest_ours.json");
    const compare = b.addSystemCommand(&.{ "python3", "tests/difftest_compare.py" });
    compare.addFileArg(diff_out);
    compare.addFileArg(b.path("tests/difftest_oracle.json"));
    const difftest_step = b.step("difftest", "Run the differential test suite against the MC88100 oracle");
    difftest_step.dependOn(&compare.step);

    // --- Convenience: cross-compile the libraries for every supported target ---
    const all_targets = [_][]const u8{
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-macos",
        "aarch64-macos",
        "x86_64-windows-gnu",
        "aarch64-windows-gnu",
    };
    const cross_step = b.step("cross", "Build static + shared libs for all six supported targets");
    for (all_targets) |triple| {
        const resolved = b.resolveTargetQuery(std.Target.Query.parse(.{
            .arch_os_abi = triple,
        }) catch @panic("bad target triple"));

        inline for (.{ .{ "static", std.builtin.LinkMode.static, true }, .{ "shared", std.builtin.LinkMode.dynamic, false } }) |cfg| {
            const opts = b.addOptions();
            opts.addOption(bool, "enable_global_callbacks", cfg[2]);
            const mod = b.createModule(.{
                .root_source_file = b.path("src/m88k.zig"),
                .target = resolved,
                .optimize = optimize,
                .link_libc = true,
            });
            mod.addOptions("build_options", opts);
            const lib = b.addLibrary(.{
                .name = "m88k",
                .linkage = cfg[1],
                .root_module = mod,
                .version = if (cfg[1] == .dynamic) .{ .major = 0, .minor = 1, .patch = 0 } else null,
            });
            const install = b.addInstallArtifact(lib, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("{s}/{s}", .{ triple, cfg[0] }) } },
            });
            cross_step.dependOn(&install.step);
        }
    }
}
