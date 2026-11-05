const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Read once: b.option panics if the same name is declared twice.
    const font_opt = b.option([]const u8, "font", "path to a TTF/OTF for the bench and fuzz runs");
    const pairs_opt = b.option([]const u8, "pairs", "fontpath|pairsfile[;...] manifest for the GPOS differential");

    // The library: pure Zig, no libc, no C, no allocator.
    const inkwell_mod = b.addModule("inkwell", .{
        .root_source_file = b.path("src/inkwell.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The UAX #14 conformance corpus is 2.9 MB of generated Zig and is not
    // part of the published package, so a test module is compiled only when it
    // is present. It lives outside `src/` deliberately: `@import` across a
    // module boundary needs a named import, and naming it inside the library
    // module would put the corpus in every consumer's build.
    const corpus_present = if (b.build_root.handle.access(
        b.graph.io,
        "test/linebreak/linebreak_cases.zig",
        .{},
    )) |_| true else |_| false;
    const test_mod = if (corpus_present) blk: {
        const cases_mod = b.createModule(.{
            .root_source_file = b.path("test/linebreak/linebreak_cases.zig"),
            .target = target,
            .optimize = optimize,
        });
        break :blk b.createModule(.{
            .root_source_file = b.path("test/linebreak/linebreak_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "inkwell", .module = inkwell_mod },
                .{ .name = "linebreak_cases", .module = cases_mod },
            },
        });
    } else null;

    const unit_tests = b.addTest(.{ .root_module = inkwell_mod });
    const test_step = b.step("test", "run the unit tests (no font file needed)");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    if (test_mod) |tm| {
        const conf_tests = b.addTest(.{ .root_module = tm });
        test_step.dependOn(&b.addRunArtifact(conf_tests).step);
    }

    // Malformed input: truncate and flip bits, on a real face. Separate test
    // binary so the ordinary suite stays fast, and skipped when no font is
    // configured rather than silently passing.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "inkwell", .module = inkwell_mod }},
        .link_libc = true,
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    run_fuzz.has_side_effects = true;
    if (font_opt) |f| {
        run_fuzz.setEnvironmentVariable("INKWELL_TEST_FONT", f);
    }

    // Timing harness. Pure Zig, like the library itself.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "inkwell", .module = inkwell_mod }},
        .link_libc = true,
    });
    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.has_side_effects = true;
    if (font_opt) |f| {
        run_bench.setEnvironmentVariable("INKWELL_BENCH_FONT", f);
    }
    const bench_step = b.step("bench", "time glyph rasterisation and cache hits (-Dfont=path)");
    bench_step.dependOn(&run_bench.step);

    // GPOS pair adjustment, differentially against fontTools' decode. Same
    // shape as fuzz: skipped rather than silently passing without inputs.
    const gpos_mod = b.createModule(.{
        .root_source_file = b.path("test/gpos_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "inkwell", .module = inkwell_mod }},
        .link_libc = true,
    });
    const gpos_tests = b.addTest(.{ .root_module = gpos_mod });
    const run_gpos = b.addRunArtifact(gpos_tests);
    run_gpos.has_side_effects = true;
    if (pairs_opt) |p| {
        run_gpos.setEnvironmentVariable("INKWELL_GPOS", p);
    }
    const gpos_step = b.step("gpos", "compare GPOS pair adjustments against fontTools (-Dpairs=manifest)");
    gpos_step.dependOn(&run_gpos.step);

    const fuzz_step = b.step("fuzz", "mangle the face under -Dfont (or INKWELL_TEST_FONT): truncations and bit flips");
    fuzz_step.dependOn(&run_fuzz.step);
}
