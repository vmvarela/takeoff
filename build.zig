const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_zon = @import("build.zig.zon");
    const version = b.option([]const u8, "version", "override version") orelse build_zon.version;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const takeoff_mod = b.addModule("TakeOff", .{
        .root_source_file = b.path("src/TakeOff.zig"),
        .target = target,
        .optimize = optimize,
    });
    takeoff_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "takeoff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "TakeOff", .module = takeoff_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "TakeOff", .module = takeoff_mod },
            },
        }),
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = takeoff_mod,
    });

    // Per-module test binaries for modules with their own tests
    const module_test_files = [_][]const u8{
        "src/config.zig",
        "src/build.zig",
        "src/parallel_build.zig",
        "src/packager.zig",
        "src/archive.zig",
        "src/checksum.zig",
        "src/verify.zig",
        "src/changelog.zig",
        "src/progress.zig",
        "src/version.zig",
    };

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_lib_unit_tests.step);

    for (module_test_files) |src_file| {
        const mod_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "TakeOff", .module = takeoff_mod },
                },
            }),
        });
        mod_test.root_module.addOptions("build_options", options);
        test_step.dependOn(&b.addRunArtifact(mod_test).step);
    }
}
