const std = @import("std");
const config = @import("config.zig");

const log = std.log.scoped(.build);

/// Error set for build operations.
pub const BuildError = error{
    InvalidTarget,
    BuildFailed,
    ArtifactNotFound,
    ProcessSpawnFailed,
    ProcessWaitFailed,
    OutputParseFailed,
} || std.mem.Allocator.Error;

/// Represents a resolved build target with all necessary information.
pub const BuildTarget = struct {
    /// The CPU architecture (e.g., "x86_64", "aarch64")
    arch: []const u8,
    /// The operating system (e.g., "linux", "macos", "windows")
    os: []const u8,
    /// Optional CPU features/specific model
    cpu: ?[]const u8,
    /// The target triple string for Zig (e.g., "x86_64-linux-gnu")
    target_string: []const u8,
    /// The output path/name for packaging (e.g., "takeoff-x86_64-linux")
    output_path: []const u8,
    /// The project name (used to find the binary zig actually produces)
    project_name: []const u8,
    /// Additional build flags
    flags: []const []const u8,

    /// Initialize a BuildTarget from config Target and project info.
    pub fn fromConfig(
        allocator: std.mem.Allocator,
        target: config.Target,
        project_name: []const u8,
        output_template: ?[]const u8,
        build_flags: []const []const u8,
        git_tag: ?[]const u8,
    ) BuildError!BuildTarget {
        const target_string = try formatTargetString(allocator, target);
        errdefer allocator.free(target_string);

        const output_path = try resolveOutputPath(
            allocator,
            output_template,
            project_name,
            target,
            git_tag,
        );
        errdefer allocator.free(output_path);

        const flags_copy = try allocator.alloc([]const u8, build_flags.len);
        errdefer {
            for (flags_copy) |f| allocator.free(f);
            allocator.free(flags_copy);
        }
        for (build_flags, 0..) |f, i| {
            flags_copy[i] = try allocator.dupe(u8, f);
        }

        return BuildTarget{
            .arch = try allocator.dupe(u8, target.arch),
            .os = try allocator.dupe(u8, target.os),
            .cpu = if (target.cpu) |c| try allocator.dupe(u8, c) else null,
            .target_string = target_string,
            .output_path = output_path,
            .project_name = try allocator.dupe(u8, project_name),
            .flags = flags_copy,
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *const BuildTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.arch);
        allocator.free(self.os);
        if (self.cpu) |c| allocator.free(c);
        allocator.free(self.target_string);
        allocator.free(self.output_path);
        allocator.free(self.project_name);
        for (self.flags) |f| allocator.free(f);
        allocator.free(self.flags);
    }
};

/// Format a target string in the format "cpu-os-abi" for Zig.
fn formatTargetString(allocator: std.mem.Allocator, target: config.Target) BuildError![]const u8 {
    // Use configured ABI if provided, otherwise use default for the OS
    const abi = target.abi orelse getDefaultAbi(target.os);

    if (abi.len == 0) {
        // macOS doesn't use ABI suffix
        return std.fmt.allocPrint(allocator, "{s}-{s}", .{ target.arch, target.os });
    }

    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ target.arch, target.os, abi });
}

/// Get the default ABI string for a given OS.
fn getDefaultAbi(os: []const u8) []const u8 {
    if (std.mem.eql(u8, os, "linux")) return "gnu";
    if (std.mem.eql(u8, os, "windows")) return "gnu";
    if (std.mem.eql(u8, os, "freebsd")) return "gnu";
    if (std.mem.eql(u8, os, "netbsd")) return "gnu";
    if (std.mem.eql(u8, os, "openbsd")) return "gnu";
    // macOS uses no ABI suffix
    return "";
}

/// Resolve the output path for a binary, applying template substitution.
fn resolveOutputPath(
    allocator: std.mem.Allocator,
    template: ?[]const u8,
    project_name: []const u8,
    target: config.Target,
    git_tag: ?[]const u8,
) BuildError![]const u8 {
    const ext = getBinaryExtension(target.os);

    if (template) |t| {
        // Apply template substitution
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        while (i < t.len) {
            if (i + 1 < t.len and t[i] == '{' and t[i + 1] == '{') {
                const start = i;
                i += 2;

                const expr_start = i;
                while (i < t.len) {
                    if (i + 1 < t.len and t[i] == '}' and t[i + 1] == '}') {
                        break;
                    }
                    i += 1;
                }

                if (i >= t.len or i + 1 >= t.len) {
                    // Unterminated expression, treat as literal
                    try result.appendSlice(allocator, t[start..]);
                    break;
                }

                const expr = std.mem.trim(u8, t[expr_start..i], " \t");

                if (std.mem.eql(u8, expr, "project")) {
                    try result.appendSlice(allocator, project_name);
                } else if (std.mem.eql(u8, expr, "target")) {
                    try result.appendSlice(allocator, target.arch);
                    try result.append(allocator, '-');
                    try result.appendSlice(allocator, target.os);
                } else if (std.mem.eql(u8, expr, "os")) {
                    try result.appendSlice(allocator, target.os);
                } else if (std.mem.eql(u8, expr, "arch")) {
                    try result.appendSlice(allocator, target.arch);
                } else if (std.mem.eql(u8, expr, "git.tag")) {
                    if (git_tag) |tag| {
                        try result.appendSlice(allocator, tag);
                    }
                } else if (std.mem.eql(u8, expr, "ext")) {
                    try result.appendSlice(allocator, ext);
                } else {
                    // Unknown variable, keep original
                    try result.appendSlice(allocator, t[start .. i + 2]);
                }

                i += 2;
            } else {
                try result.append(allocator, t[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(allocator);
    }

    // Default: {project}-{target}{ext}
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}{s}", .{
        project_name,
        target.arch,
        target.os,
        ext,
    });
}

/// Get the binary extension for a given OS.
fn getBinaryExtension(os: []const u8) []const u8 {
    if (std.mem.eql(u8, os, "windows")) return ".exe";
    return "";
}

/// Result of a single build operation.
pub const BuildResult = struct {
    target: BuildTarget,
    success: bool,
    artifact_path: ?[]const u8,
    error_message: ?[]const u8,

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        if (self.artifact_path) |p| allocator.free(p);
        if (self.error_message) |m| allocator.free(m);
    }
};

/// Run zig build for a single target.
pub fn runBuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: BuildTarget,
    optimize: []const u8,
    verbose: bool,
) BuildError!BuildResult {
    // Build the command arguments
    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    try argv.append(allocator, try allocator.dupe(u8, "zig"));
    try argv.append(allocator, try allocator.dupe(u8, "build"));

    // Use a per-target prefix so parallel builds don't overwrite each other:
    // zig-out/{target_string}/bin/{project_name}
    const prefix_path = try std.fmt.allocPrint(allocator, "zig-out/{s}", .{target.target_string});
    try argv.append(allocator, try allocator.dupe(u8, "--prefix"));
    try argv.append(allocator, prefix_path);

    // Add target flag
    const target_flag = try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{target.target_string});
    try argv.append(allocator, target_flag);

    // Add optimize flag
    const optimize_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize});
    try argv.append(allocator, optimize_flag);

    // Add additional flags from config
    for (target.flags) |flag| {
        try argv.append(allocator, try allocator.dupe(u8, flag));
    }

    if (verbose) {
        log.info("Building target: {s}", .{target.target_string});
        var cmd_line: std.ArrayList(u8) = .empty;
        defer cmd_line.deinit(allocator);
        for (argv.items) |arg| {
            try cmd_line.appendSlice(allocator, arg);
            try cmd_line.append(allocator, ' ');
        }
        log.debug("Command: {s}", .{cmd_line.items});
    }

    const run_result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(10 * 1024 * 1024),
        .stderr_limit = .limited(10 * 1024 * 1024),
    }) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to run zig build: {}", .{err});
        return BuildResult{
            .target = target,
            .success = false,
            .artifact_path = null,
            .error_message = msg,
        };
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    // Check if build succeeded
    const success = switch (run_result.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (!success) {
        var error_msg: std.ArrayList(u8) = .empty;
        errdefer error_msg.deinit(allocator);

        try error_msg.appendSlice(allocator, "Build failed:\n");
        if (run_result.stderr.len > 0) {
            try error_msg.appendSlice(allocator, run_result.stderr);
        } else if (run_result.stdout.len > 0) {
            try error_msg.appendSlice(allocator, run_result.stdout);
        }

        return BuildResult{
            .target = target,
            .success = false,
            .artifact_path = null,
            .error_message = try error_msg.toOwnedSlice(allocator),
        };
    }

    // Locate the artifact produced by zig build.
    // With --prefix=zig-out/{target_string}, the binary lands at:
    //   zig-out/{target_string}/bin/{project_name}{ext}
    const ext = getBinaryExtension(target.os);
    const cwd = std.Io.Dir.cwd();

    const artifact_path = try std.fmt.allocPrint(
        allocator,
        "zig-out/{s}/bin/{s}{s}",
        .{ target.target_string, target.project_name, ext },
    );
    errdefer allocator.free(artifact_path);

    cwd.access(io, artifact_path, .{}) catch {
        allocator.free(artifact_path);
        const msg = try std.fmt.allocPrint(
            allocator,
            "Artifact not found: zig-out/{s}/bin/{s}{s}",
            .{ target.target_string, target.project_name, ext },
        );
        return BuildResult{
            .target = target,
            .success = false,
            .artifact_path = null,
            .error_message = msg,
        };
    };

    if (verbose) {
        log.info("✓ Built: {s}", .{artifact_path});
    }

    return BuildResult{
        .target = target,
        .success = true,
        .artifact_path = artifact_path,
        .error_message = null,
    };
}

/// Verify that a binary artifact exists and is valid.
pub fn verifyArtifact(path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(std.Options.debug_io, path, .{}) catch return false;

    // Basic checks
    if (stat.size == 0) return false;

    // Check if it's executable (on Unix systems)
    if (@import("builtin").os.tag != .windows) {
        const mode = stat.mode;
        const is_executable = (mode & 0o111) != 0;
        return is_executable;
    }

    return true;
}

test "getDefaultAbi returns correct values" {
    try std.testing.expectEqualStrings("gnu", getDefaultAbi("linux"));
    try std.testing.expectEqualStrings("gnu", getDefaultAbi("windows"));
    try std.testing.expectEqualStrings("", getDefaultAbi("macos"));
    try std.testing.expectEqualStrings("gnu", getDefaultAbi("freebsd"));
}

test "getBinaryExtension returns correct values" {
    try std.testing.expectEqualStrings(".exe", getBinaryExtension("windows"));
    try std.testing.expectEqualStrings("", getBinaryExtension("linux"));
    try std.testing.expectEqualStrings("", getBinaryExtension("macos"));
}

test "formatTargetString formats correctly" {
    const allocator = std.testing.allocator;

    const linux_target = config.Target{
        .os = "linux",
        .arch = "x86_64",
        .cpu = null,
    };
    const linux_str = try formatTargetString(allocator, linux_target);
    defer allocator.free(linux_str);
    try std.testing.expectEqualStrings("x86_64-linux-gnu", linux_str);

    const macos_target = config.Target{
        .os = "macos",
        .arch = "aarch64",
        .cpu = null,
    };
    const macos_str = try formatTargetString(allocator, macos_target);
    defer allocator.free(macos_str);
    try std.testing.expectEqualStrings("aarch64-macos", macos_str);
}

test "resolveOutputPath with default template" {
    const allocator = std.testing.allocator;

    const target = config.Target{
        .os = "linux",
        .arch = "x86_64",
        .cpu = null,
    };

    const path = try resolveOutputPath(allocator, null, "myapp", target, null);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("myapp-x86_64-linux", path);
}

test "resolveOutputPath with custom template" {
    const allocator = std.testing.allocator;

    const target = config.Target{
        .os = "windows",
        .arch = "x86_64",
        .cpu = null,
    };

    const path = try resolveOutputPath(allocator, "{{ project }}-{{ os }}-{{ arch }}{{ ext }}", "myapp", target, null);
    defer allocator.free(path);

    try std.testing.expectEqualStrings("myapp-windows-x86_64.exe", path);
}

test "BuildTarget.fromConfig creates valid target" {
    const allocator = std.testing.allocator;

    const target = config.Target{
        .os = "linux",
        .arch = "aarch64",
        .cpu = "cortex-a72",
    };

    var build_target = try BuildTarget.fromConfig(
        allocator,
        target,
        "myapp",
        "{{ project }}-{{ target }}",
        &.{"-Dstrip=true"},
        "v1.0.0",
    );
    defer build_target.deinit(allocator);

    try std.testing.expectEqualStrings("aarch64", build_target.arch);
    try std.testing.expectEqualStrings("linux", build_target.os);
    try std.testing.expectEqualStrings("cortex-a72", build_target.cpu.?);
    try std.testing.expectEqualStrings("aarch64-linux-gnu", build_target.target_string);
    try std.testing.expectEqualStrings("myapp-aarch64-linux", build_target.output_path);
    try std.testing.expectEqual(1, build_target.flags.len);
    try std.testing.expectEqualStrings("-Dstrip=true", build_target.flags[0]);
}

test "BuildResult stores build status" {
    const allocator = std.testing.allocator;

    const target = config.Target{
        .os = "linux",
        .arch = "x86_64",
        .cpu = null,
    };

    const build_target = try BuildTarget.fromConfig(
        allocator,
        target,
        "test",
        null,
        &.{},
        null,
    );

    var result = BuildResult{
        .target = build_target,
        .success = true,
        .artifact_path = try allocator.dupe(u8, "/path/to/binary"),
        .error_message = null,
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("/path/to/binary", result.artifact_path.?);
}
