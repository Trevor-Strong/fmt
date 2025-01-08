const std = @import("std");

const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters: []const []const u8 = b.option(
        []const []const u8,
        "test-filter",
        "Set unit test filter",
    ) orelse &.{};
    const check_fmt = b.option(
        bool,
        "check_fmt",
        "Check the formatting of files instead of fixing it",
    ) orelse false;

    const module = b.addModule("fmt", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/fmt.zig"),
    });
    module.addImport("fmt", module);

    // Formatting

    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = check_fmt,
    });

    const fmt_step = b.step("fmt", "'zig fmt' the source files");
    fmt_step.dependOn(&fmt.step);

    // Test

    const unit_tests = b.addTest(.{
        .root_module = module,
        .filters = test_filters,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
