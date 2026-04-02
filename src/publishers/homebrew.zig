//! Homebrew tap publisher — generates a formula, clones the tap repo,
//! commits the formula file, and pushes via SSH.
//!
//! The tap repo can host multiple formulae — each project writes to
//! Formula/<project_name>.rb inside the shared repo.

const std = @import("std");

const log = std.log.scoped(.homebrew_publish);

/// Error set for Homebrew tap publishing.
pub const HomebrewPublishError = error{
    InvalidConfig,
    ArtifactNotFound,
    ReadError,
    WriteError,
    ProcessError,
    PushFailed,
} || std.mem.Allocator.Error;

/// Options for generating and pushing a Homebrew formula to a tap repo.
pub const HomebrewPublishOptions = struct {
    /// Tap repository — "owner/tap-repo" (e.g. "vmvarela/homebrew-tap").
    tap: []const u8,
    /// Optional SSH private key for pushing.
    /// Falls back to HOMEBREW_TAP_SSH_KEY env var.
    tap_ssh_key: ?[]const u8 = null,
    /// GitHub owner (for building URLs).
    owner: []const u8,
    /// GitHub repo (for building URLs).
    repo: []const u8,
    /// Release tag (e.g. "v0.2.0").
    tag: []const u8,
    /// Project binary name.
    project_name: []const u8,
    /// Package description.
    description: []const u8,
    /// Package homepage URL.
    homepage: []const u8,
    /// SPDX license.
    license: []const u8,
    /// Dist directory containing release artifacts.
    dist_dir: []const u8,
    /// If true, only generate and report — do not push.
    dry_run: bool = false,
};

/// Result of Homebrew publish operation.
pub const HomebrewPublishResult = struct {
    success: bool,
    formula_path: []const u8,
    pushed: bool,
    message: []const u8,

    pub fn deinit(self: *HomebrewPublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.formula_path);
        allocator.free(self.message);
    }
};

/// Generate a Homebrew formula and optionally push it to the tap repo.
pub fn publishHomebrewFormula(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: HomebrewPublishOptions,
) HomebrewPublishError!HomebrewPublishResult {
    if (opts.tap.len == 0) return error.InvalidConfig;
    if (opts.owner.len == 0) return error.InvalidConfig;
    if (opts.repo.len == 0) return error.InvalidConfig;

    const packagers = @import("../packagers/homebrew.zig");

    // Find the tarball artifact
    const artifact = try packagers.findTarball(allocator, io, opts.dist_dir, opts.project_name);
    defer {
        allocator.free(artifact.file_name);
        allocator.free(artifact.full_path);
    }

    // Normalise version (strip 'v' prefix)
    const version = if (std.mem.startsWith(u8, opts.tag, "v")) opts.tag[1..] else opts.tag;

    // Build URLs
    const tarball_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ opts.owner, opts.repo, opts.tag, artifact.file_name },
    );
    defer allocator.free(tarball_url);

    const head_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}.git",
        .{ opts.owner, opts.repo },
    );
    defer allocator.free(head_url);

    const sha256_hex = std.fmt.bytesToHex(artifact.sha256, .lower);

    // Formula class name
    const formula_name = try packagers.capitaliseName(allocator, opts.project_name);
    defer allocator.free(formula_name);

    // Generate formula content
    const formula_content = try renderFormula(allocator, .{
        .formula_name = formula_name,
        .project_name = opts.project_name,
        .version = version,
        .description = opts.description,
        .homepage = opts.homepage,
        .license = opts.license,
        .tarball_url = tarball_url,
        .tarball_sha256 = &sha256_hex,
        .head_url = head_url,
        .binary_path = artifact.full_path,
    });
    defer allocator.free(formula_content);

    // Write formula to dist directory for reference
    const formula_file_name = try std.fmt.allocPrint(allocator, "{s}.rb", .{opts.project_name});
    defer allocator.free(formula_file_name);

    const formula_dir = try std.fs.path.join(allocator, &.{ opts.dist_dir, "homebrew" });
    defer allocator.free(formula_dir);
    std.Io.Dir.cwd().createDirPath(io, formula_dir) catch return error.WriteError;

    const formula_path = try std.fs.path.join(allocator, &.{ formula_dir, formula_file_name });
    errdefer allocator.free(formula_path);

    writeFile(io, formula_path, formula_content) catch return error.WriteError;

    if (opts.dry_run) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "generated formula (dry-run, no push): {s}",
            .{formula_path},
        );
        return .{
            .success = true,
            .formula_path = formula_path,
            .pushed = false,
            .message = msg,
        };
    }

    // Resolve SSH key
    const ssh_key = resolveSshKey(allocator, opts.tap_ssh_key) catch null;
    defer if (ssh_key) |k| allocator.free(k);

    if (ssh_key == null) {
        log.warn("tap push skipped: no SSH key found — set 'tap_ssh_key' in takeoff.jsonc or the HOMEBREW_TAP_SSH_KEY environment variable", .{});
        const msg = try allocator.dupe(
            u8,
            "generated formula; tap push skipped (no tap_ssh_key and no HOMEBREW_TAP_SSH_KEY)",
        );
        return .{
            .success = true,
            .formula_path = formula_path,
            .pushed = false,
            .message = msg,
        };
    }

    // Parse tap repo: "owner/repo" → clone URL
    const clone_url = try buildCloneUrl(allocator, opts.tap, ssh_key.?);
    defer allocator.free(clone_url);

    // Push to tap
    const pushed = try pushToTap(
        allocator,
        io,
        opts.tap,
        clone_url,
        ssh_key.?,
        opts.project_name,
        formula_name,
        formula_content,
        version,
    );

    if (pushed) {
        const msg = try allocator.dupe(
            u8,
            "generated formula and pushed to tap",
        );
        return .{
            .success = true,
            .formula_path = formula_path,
            .pushed = true,
            .message = msg,
        };
    } else {
        const msg = try allocator.dupe(
            u8,
            "generated formula; no tap push needed (no changes)",
        );
        return .{
            .success = true,
            .formula_path = formula_path,
            .pushed = false,
            .message = msg,
        };
    }
}

/// Render a Homebrew formula (delegates to packager).
fn renderFormula(
    allocator: std.mem.Allocator,
    cfg: anytype,
) HomebrewPublishError![]const u8 {
    const packagers = @import("../packagers/homebrew.zig");
    const full_cfg = packagers.HomebrewConfig{
        .formula_name = cfg.formula_name,
        .project_name = cfg.project_name,
        .version = cfg.version,
        .description = cfg.description,
        .homepage = cfg.homepage,
        .license = cfg.license,
        .tarball_url = cfg.tarball_url,
        .tarball_sha256 = cfg.tarball_sha256,
        .head_url = cfg.head_url,
        .binary_path = cfg.binary_path,
        .output_path = "", // not writing to disk here
    };
    return packagers.renderFormula(allocator, full_cfg);
}

/// Build the SSH clone URL for the tap repo.
/// Accepts "owner/repo" or "owner/owner/repo" (full path).
fn buildCloneUrl(
    allocator: std.mem.Allocator,
    tap: []const u8,
    ssh_key: []const u8,
) HomebrewPublishError![]const u8 {
    _ = ssh_key; // unused for URL construction, kept for signature clarity
    // Parse "owner/repo"
    const slash = std.mem.indexOfScalar(u8, tap, '/') orelse {
        // Just a repo name — assume GitHub convention
        return try std.fmt.allocPrint(allocator, "git@github.com:{s}/{s}.git", .{ tap, tap });
    };
    const owner = tap[0..slash];
    const repo = tap[slash + 1 ..];
    return try std.fmt.allocPrint(allocator, "git@github.com:{s}/{s}.git", .{ owner, repo });
}

/// Resolve the SSH key from config or environment.
fn resolveSshKey(allocator: std.mem.Allocator, configured_key: ?[]const u8) !?[]const u8 {
    if (configured_key) |k| {
        if (k.len == 0) return null;
        return try allocator.dupe(u8, k);
    }
    const environ = std.Options.debug_threaded_io.?.environ.process_environ;
    return std.process.Environ.getAlloc(environ, allocator, "HOMEBREW_TAP_SSH_KEY") catch null;
}

/// Clone the tap repo, write the formula, commit, and push.
fn pushToTap(
    allocator: std.mem.Allocator,
    io: std.Io,
    tap: []const u8,
    clone_url: []const u8,
    ssh_key: []const u8,
    project_name: []const u8,
    formula_name: []const u8,
    formula_content: []const u8,
    version: []const u8,
) HomebrewPublishError!bool {
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/takeoff-homebrew-{s}-{s}", .{ tap, version });
    defer allocator.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch return error.WriteError;

    const ssh_cmd = try std.fmt.allocPrint(
        allocator,
        "ssh -i \"{s}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new",
        .{ssh_key},
    );
    defer allocator.free(ssh_cmd);

    // Clone
    const clone_cmd = try std.fmt.allocPrint(
        allocator,
        "GIT_SSH_COMMAND='{s}' git clone \"{s}\" \"{s}\"",
        .{ ssh_cmd, clone_url, tmp_dir },
    );
    defer allocator.free(clone_cmd);
    try runShell(allocator, io, clone_cmd);

    // Ensure Formula/ directory exists
    const formula_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "Formula" });
    defer allocator.free(formula_dir);
    std.Io.Dir.cwd().createDirPath(io, formula_dir) catch return error.WriteError;

    // Write formula file
    const formula_file = try std.fmt.allocPrint(
        allocator,
        "{s}.rb",
        .{project_name},
    );
    defer allocator.free(formula_file);

    const formula_path = try std.fs.path.join(allocator, &.{ formula_dir, formula_file });
    defer allocator.free(formula_path);

    writeFile(io, formula_path, formula_content) catch return error.WriteError;

    // Git add
    const add_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" add \"Formula/{s}.rb\"",
        .{ tmp_dir, project_name },
    );
    defer allocator.free(add_cmd);
    try runShell(allocator, io, add_cmd);

    // Check if there are changes
    const diff_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" diff --cached --quiet",
        .{tmp_dir},
    );
    defer allocator.free(diff_cmd);
    const changed = try runShellReturnsChanged(allocator, io, diff_cmd);
    if (!changed) return false;

    // Commit
    const commit_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" commit -m \"Update {s} to {s} [skip ci]\"",
        .{ tmp_dir, formula_name, version },
    );
    defer allocator.free(commit_cmd);
    try runShell(allocator, io, commit_cmd);

    // Push
    const push_cmd = try std.fmt.allocPrint(
        allocator,
        "GIT_SSH_COMMAND='{s}' git -C \"{s}\" push",
        .{ ssh_cmd, tmp_dir },
    );
    defer allocator.free(push_cmd);
    try runShell(allocator, io, push_cmd);

    return true;
}

fn runShell(allocator: std.mem.Allocator, io: std.Io, command: []const u8) HomebrewPublishError!void {
    const run = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return error.ProcessError;
    defer {
        allocator.free(run.stdout);
        allocator.free(run.stderr);
    }
    if (run.term != .exited or run.term.exited != 0) {
        if (run.stderr.len > 0) log.err("command failed: {s}\n{s}", .{ command, run.stderr });
        return error.PushFailed;
    }
}

fn runShellReturnsChanged(allocator: std.mem.Allocator, io: std.Io, command: []const u8) HomebrewPublishError!bool {
    const run = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.ProcessError;
    defer {
        allocator.free(run.stdout);
        allocator.free(run.stderr);
    }
    if (run.term == .exited and run.term.exited == 0) return false;
    if (run.term == .exited and run.term.exited == 1) return true;
    return error.ProcessError;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) HomebrewPublishError!void {
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return error.WriteError;
    defer f.close(io);
    f.writeStreamingAll(io, content) catch return error.WriteError;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildCloneUrl parses owner/repo" {
    const allocator = std.testing.allocator;
    const url = try buildCloneUrl(allocator, "vmvarela/homebrew-tap", "key");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("git@github.com:vmvarela/homebrew-tap.git", url);
}

test "buildCloneUrl handles bare repo name" {
    const allocator = std.testing.allocator;
    const url = try buildCloneUrl(allocator, "homebrew-tap", "key");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("git@github.com:homebrew-tap/homebrew-tap.git", url);
}

test "renderFormula produces valid formula" {
    const allocator = std.testing.allocator;

    const content = try renderFormula(allocator, .{
        .formula_name = "Takeoff",
        .project_name = "takeoff",
        .version = "0.2.0",
        .description = "Release automation for Zig projects",
        .homepage = "https://github.com/vmvarela/takeoff",
        .license = "MIT",
        .tarball_url = "https://example.com/takeoff-0.2.0-macos-aarch64.tar.gz",
        .tarball_sha256 = "abc123",
        .head_url = "https://github.com/vmvarela/takeoff.git",
        .binary_path = "/dev/null",
    });
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "class Takeoff < Formula") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "sha256 \"abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "head \"https://github.com/vmvarela/takeoff.git\"") != null);
}
