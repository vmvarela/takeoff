const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_zon = @import("build.zig.zon");
    const version = b.option([]const u8, "version", "override version") orelse build_zon.version;

    // Detect macOS SDK path via SDKROOT env var or xcrun.
    const sdk_path = detectSdkPath(b);

    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const zig_releaser_mod = b.addModule("ZigReleaser", .{
        .root_source_file = b.path("src/ZigReleaser.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_releaser_mod.addOptions("build_options", options);
    zig_releaser_mod.addImport("toml", toml_dep.module("toml"));

    const exe = b.addExecutable(.{
        .name = "zr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZigReleaser", .module = zig_releaser_mod },
            },
        }),
    });
    if (sdk_path) |sdk| {
        exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        exe.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib/system" }) });
    }

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
                .{ .name = "ZigReleaser", .module = zig_releaser_mod },
            },
        }),
    });
    if (sdk_path) |sdk| {
        exe_unit_tests.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
        exe_unit_tests.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib/system" }) });
    }

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

/// Attempt to locate the macOS SDK path.
/// 1. Honour SDKROOT if set.
/// 2. Fall back to `xcrun --show-sdk-path`.
/// 3. Return null on non-Darwin hosts or when xcrun is unavailable.
fn detectSdkPath(b: *std.Build) ?[]const u8 {
    if (b.graph.env_map.get("SDKROOT")) |sdkroot| {
        return sdkroot;
    }

    if (@import("builtin").os.tag != .macos) return null;

    var child = std.process.Child.init(
        &.{ "xcrun", "--show-sdk-path" },
        b.allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const stdout = child.stdout.?.readToEndAlloc(b.allocator, 4096) catch return null;
    _ = child.wait() catch return null;
    const trimmed = std.mem.trimRight(u8, stdout, "\n\r ");
    return if (trimmed.len > 0) trimmed else null;
}
