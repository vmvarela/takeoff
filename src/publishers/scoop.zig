//! Scoop bucket publisher — generates a manifest JSON, clones the bucket repo,
//! commits the manifest file, and pushes via SSH.
//!
//! The bucket repo can host multiple manifests — each project writes to
//! bucket/<project_name>.json inside the shared repo.

const std = @import("std");

const log = std.log.scoped(.scoop_publish);

const ReleaseContext = @import("../release/context.zig").ReleaseContext;

/// Error set for Scoop bucket publishing.
pub const ScoopPublishError = error{
    InvalidConfig,
    ArtifactNotFound,
    AssetNotFound,
    InvalidManifest,
    ReadError,
    WriteError,
    ProcessError,
    PushFailed,
} || std.mem.Allocator.Error;

/// Options for generating and pushing a Scoop manifest to a bucket repo.
pub const ScoopPublishOptions = struct {
    /// Bucket repository — "owner/bucket-repo" (e.g. "vmvarela/scoop-bucket").
    bucket: []const u8,
    /// Optional SSH private key for pushing.
    /// Falls back to SCOOP_BUCKET_SSH_KEY env var, then TAKEOFF_SSH_KEY.
    bucket_ssh_key: ?[]const u8 = null,
    /// Release context — source of asset download URLs and tag.
    ctx: *const ReleaseContext,
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

/// Result of Scoop publish operation.
pub const ScoopPublishResult = struct {
    success: bool,
    manifest_path: []const u8,
    pushed: bool,
    message: []const u8,

    pub fn deinit(self: *ScoopPublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_path);
        allocator.free(self.message);
    }
};

/// Generate a Scoop manifest and optionally push it to the bucket repo.
pub fn publishScoopManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ScoopPublishOptions,
) ScoopPublishError!ScoopPublishResult {
    if (opts.bucket.len == 0) return error.InvalidConfig;

    const packagers = @import("../packagers/scoop.zig");

    // Normalise version (strip 'v' prefix)
    const version = if (opts.ctx.tag.len > 0 and opts.ctx.tag[0] == 'v')
        opts.ctx.tag[1..]
    else
        opts.ctx.tag;

    // Find the x86_64 Windows zip (required)
    const x64_artifact = try findWindowsZipByArch(allocator, opts.dist_dir, opts.project_name, "x86_64");
    defer {
        allocator.free(x64_artifact.file_name);
        allocator.free(x64_artifact.full_path);
    }

    const sha256_x64 = try computeSha256(allocator, x64_artifact.full_path);
    defer allocator.free(sha256_x64);

    const url_x64 = try opts.ctx.assetUrl(allocator, x64_artifact.file_name);
    defer allocator.free(url_x64);

    // Find the arm64 Windows zip (optional)
    var url_arm64: ?[]const u8 = null;
    var sha256_arm64: ?[]const u8 = null;
    if (findWindowsZipByArch(allocator, opts.dist_dir, opts.project_name, "aarch64")) |arm_artifact| {
        const sha = computeSha256(allocator, arm_artifact.full_path) catch null;
        const url = opts.ctx.assetUrl(allocator, arm_artifact.file_name) catch null;
        allocator.free(arm_artifact.file_name);
        allocator.free(arm_artifact.full_path);
        url_arm64 = url;
        sha256_arm64 = sha;
    } else |_| {
        // arm64 is optional — no artifact is fine
    }
    defer if (url_arm64) |u| allocator.free(u);
    defer if (sha256_arm64) |h| allocator.free(h);

    const manifest_name = try std.fmt.allocPrint(allocator, "{s}.json", .{opts.project_name});
    defer allocator.free(manifest_name);

    const manifest_path = try std.fs.path.join(allocator, &.{ opts.dist_dir, "scoop", manifest_name });
    defer allocator.free(manifest_path);

    const binary_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{opts.project_name});
    defer allocator.free(binary_name);

    const cfg = packagers.ScoopConfig{
        .project_name = opts.project_name,
        .version = version,
        .description = opts.description,
        .homepage = opts.homepage,
        .license = opts.license,
        .url_64bit = url_x64,
        .sha256_64bit = sha256_x64,
        .url_arm64 = url_arm64,
        .sha256_arm64 = sha256_arm64,
        .binary_name = binary_name,
        .output_path = manifest_path,
    };

    const manifest_content = try packagers.renderManifest(allocator, cfg);
    defer allocator.free(manifest_content);

    // Write the manifest to disk (even in dry-run, for reference)
    const scoop_dir = std.fs.path.dirname(manifest_path) orelse opts.dist_dir;
    std.Io.Dir.cwd().createDirPath(io, scoop_dir) catch return error.WriteError;

    {
        const f = std.Io.Dir.cwd().createFile(io, manifest_path, .{ .truncate = true }) catch return error.WriteError;
        defer f.close(io);
        f.writeStreamingAll(io, manifest_content) catch return error.WriteError;
    }

    // Dry run — just report
    if (opts.dry_run) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "generated manifest (dry-run, no push): {s}",
            .{manifest_path},
        );
        return .{
            .success = true,
            .manifest_path = try allocator.dupe(u8, manifest_path),
            .pushed = false,
            .message = msg,
        };
    }

    // Resolve SSH key — if null, SSH will use ~/.ssh/config defaults
    const ssh_key = resolveSshKey(allocator, opts.bucket_ssh_key) catch null;
    defer if (ssh_key) |k| allocator.free(k);

    // Parse bucket repo: "owner/repo" → clone URL
    const clone_url = try buildCloneUrl(allocator, opts.bucket);
    defer allocator.free(clone_url);

    // Push to bucket
    const pushed = try pushToBucket(
        allocator,
        io,
        opts.bucket,
        clone_url,
        ssh_key,
        opts.project_name,
        manifest_name,
        manifest_content,
        version,
    );

    if (pushed) {
        const msg = try allocator.dupe(u8, "generated manifest and pushed to bucket");
        return .{
            .success = true,
            .manifest_path = try allocator.dupe(u8, manifest_path),
            .pushed = true,
            .message = msg,
        };
    } else {
        const msg = try allocator.dupe(
            u8,
            "generated manifest; no bucket push needed (no changes)",
        );
        return .{
            .success = true,
            .manifest_path = try allocator.dupe(u8, manifest_path),
            .pushed = false,
            .message = msg,
        };
    }
}

/// Find a Windows zip artifact for a specific architecture in the dist directory.
///
/// `arch` must be an architecture keyword present in the filename
/// (e.g. "x86_64", "aarch64").  Returns `error.ArtifactNotFound` when no
/// matching file exists.
pub fn findWindowsZipByArch(
    allocator: std.mem.Allocator,
    dist_dir: []const u8,
    project_name: []const u8,
    arch: []const u8,
) ScoopPublishError!struct {
    file_name: []const u8,
    full_path: []const u8,
} {
    const dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dist_dir, .{ .iterate = true }) catch |err| {
        log.err("cannot open dist directory {s}: {}", .{ dist_dir, err });
        return error.ArtifactNotFound;
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();
    while (iter.next(std.Options.debug_io) catch null) |entry| {
        const name = entry.name;
        if (std.mem.startsWith(u8, name, project_name) and
            std.mem.endsWith(u8, name, ".zip") and
            std.mem.indexOf(u8, name, "windows") != null and
            std.mem.indexOf(u8, name, arch) != null)
        {
            const file_name = try allocator.dupe(u8, name);
            errdefer allocator.free(file_name);
            const full_path = try std.fs.path.join(allocator, &.{ dist_dir, name });
            errdefer allocator.free(full_path);
            return .{ .file_name = file_name, .full_path = full_path };
        }
    }

    log.warn("no Windows-{s} zip found in {s} for {s}", .{ arch, dist_dir, project_name });
    return error.ArtifactNotFound;
}

/// Compute SHA-256 hex digest of a file.
fn computeSha256(allocator: std.mem.Allocator, path: []const u8) ScoopPublishError![]const u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(512 * 1024 * 1024),
    ) catch |err| {
        log.err("failed to read {s}: {}", .{ path, err });
        return error.ReadError;
    };
    defer allocator.free(content);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);

    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash);

    return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&hash, .lower)});
}

/// Build the SSH clone URL for the bucket repo.
fn buildCloneUrl(
    allocator: std.mem.Allocator,
    bucket: []const u8,
) ScoopPublishError![]const u8 {
    const slash = std.mem.indexOfScalar(u8, bucket, '/') orelse {
        return try std.fmt.allocPrint(allocator, "git@github.com:{s}/{s}.git", .{ bucket, bucket });
    };
    const owner = bucket[0..slash];
    const repo = bucket[slash + 1 ..];
    return try std.fmt.allocPrint(allocator, "git@github.com:{s}/{s}.git", .{ owner, repo });
}

/// Resolve the SSH key from config or environment.
fn resolveSshKey(allocator: std.mem.Allocator, configured_key: ?[]const u8) !?[]const u8 {
    if (configured_key) |k| {
        if (k.len == 0) return null;
        return try allocator.dupe(u8, k);
    }
    const environ = std.Options.debug_threaded_io.?.environ.process_environ;
    // Publisher-specific env var
    if (std.process.Environ.getAlloc(environ, allocator, "SCOOP_BUCKET_SSH_KEY") catch null) |key| {
        return key;
    }
    // Common fallback for all publishers
    return std.process.Environ.getAlloc(environ, allocator, "TAKEOFF_SSH_KEY") catch null;
}

/// Clone the bucket repo, write the manifest, commit, and push.
fn pushToBucket(
    allocator: std.mem.Allocator,
    io: std.Io,
    bucket: []const u8,
    clone_url: []const u8,
    ssh_key: ?[]const u8,
    project_name: []const u8,
    manifest_name: []const u8,
    manifest_content: []const u8,
    version: []const u8,
) ScoopPublishError!bool {
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/takeoff-scoop-{s}-{s}", .{ bucket, version });
    defer allocator.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch return error.WriteError;

    const ssh_cmd = if (ssh_key) |key|
        try std.fmt.allocPrint(allocator, "ssh -i \"{s}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new", .{key})
    else
        null;
    defer if (ssh_cmd) |s| allocator.free(s);

    // Clone
    const clone_cmd = if (ssh_cmd) |s|
        try std.fmt.allocPrint(allocator, "GIT_SSH_COMMAND='{s}' git clone \"{s}\" \"{s}\"", .{ s, clone_url, tmp_dir })
    else
        try std.fmt.allocPrint(allocator, "git clone \"{s}\" \"{s}\"", .{ clone_url, tmp_dir });
    defer allocator.free(clone_cmd);
    try runShell(allocator, io, clone_cmd);

    // Ensure bucket/ directory exists
    const bucket_dir = try std.fs.path.join(allocator, &.{ tmp_dir, "bucket" });
    defer allocator.free(bucket_dir);
    std.Io.Dir.cwd().createDirPath(io, bucket_dir) catch return error.WriteError;

    // Write manifest file
    const dest_path = try std.fs.path.join(allocator, &.{ bucket_dir, manifest_name });
    defer allocator.free(dest_path);
    writeFile(io, dest_path, manifest_content) catch return error.WriteError;

    // Check if the file actually changed (handles both new and modified files)
    const status_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" status --porcelain -- \"bucket/{s}\"",
        .{ tmp_dir, manifest_name },
    );
    defer allocator.free(status_cmd);
    const changed = try runShellReturnsChanged(allocator, io, status_cmd);
    if (!changed) {
        log.info("no changes to {s} in bucket {s}", .{ manifest_name, bucket });
        return false;
    }

    // git add
    const add_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" add \"bucket/{s}\"",
        .{ tmp_dir, manifest_name },
    );
    defer allocator.free(add_cmd);
    try runShell(allocator, io, add_cmd);

    // Commit
    const commit_msg = try std.fmt.allocPrint(
        allocator,
        "{s}: update to {s}",
        .{ project_name, version },
    );
    defer allocator.free(commit_msg);
    const commit_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" commit -m \"{s}\"",
        .{ tmp_dir, commit_msg },
    );
    defer allocator.free(commit_cmd);
    try runShell(allocator, io, commit_cmd);

    // Push
    const push_cmd = if (ssh_cmd) |s|
        try std.fmt.allocPrint(allocator, "GIT_SSH_COMMAND='{s}' git -C \"{s}\" push", .{ s, tmp_dir })
    else
        try std.fmt.allocPrint(allocator, "git -C \"{s}\" push", .{tmp_dir});
    defer allocator.free(push_cmd);
    try runShell(allocator, io, push_cmd);

    log.info("pushed {s} to bucket {s}", .{ manifest_name, bucket });
    return true;
}

fn runShell(allocator: std.mem.Allocator, io: std.Io, command: []const u8) ScoopPublishError!void {
    // Use page_allocator for process spawning (spawnPosix needs standard allocator)
    const run = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return error.ProcessError;
    defer {
        std.heap.page_allocator.free(run.stdout);
        std.heap.page_allocator.free(run.stderr);
    }
    if (run.term != .exited or run.term.exited != 0) {
        if (run.stderr.len > 0) log.err("command failed: {s}\n{s}", .{ command, run.stderr });
        return error.PushFailed;
    }
    _ = allocator;
}

fn runShellReturnsChanged(allocator: std.mem.Allocator, io: std.Io, command: []const u8) ScoopPublishError!bool {
    // Use page_allocator for process spawning
    const run = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.ProcessError;
    defer {
        std.heap.page_allocator.free(run.stdout);
        std.heap.page_allocator.free(run.stderr);
    }
    // git status --porcelain outputs nothing if there are no changes,
    // or lines like "?? bucket/file.json" for new/modified files.
    _ = allocator;
    return run.stdout.len > 0;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) ScoopPublishError!void {
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return error.WriteError;
    defer f.close(io);
    f.writeStreamingAll(io, content) catch return error.WriteError;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "findWindowsZipByArch finds x86_64 zip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a fake x86_64 Windows zip
    try tmp.dir.writeFile(io, .{ .sub_path = "mytool-1.0.0-windows-x86_64.zip", .data = "fake" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build absolute path to tmp dir
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..n];
    const tmp_path_owned = try a.dupe(u8, tmp_path);

    const result = try findWindowsZipByArch(a, tmp_path_owned, "mytool", "x86_64");
    defer {
        a.free(result.file_name);
        a.free(result.full_path);
    }

    try std.testing.expectEqualStrings("mytool-1.0.0-windows-x86_64.zip", result.file_name);
    try std.testing.expect(std.mem.endsWith(u8, result.full_path, "mytool-1.0.0-windows-x86_64.zip"));
}

test "findWindowsZipByArch finds aarch64 zip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "mytool-1.0.0-windows-aarch64.zip", .data = "fake" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..n];
    const tmp_path_owned = try a.dupe(u8, tmp_path);

    const result = try findWindowsZipByArch(a, tmp_path_owned, "mytool", "aarch64");
    defer {
        a.free(result.file_name);
        a.free(result.full_path);
    }

    try std.testing.expectEqualStrings("mytool-1.0.0-windows-aarch64.zip", result.file_name);
}

test "findWindowsZipByArch returns ArtifactNotFound when arch missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Only x86_64 present — aarch64 lookup must fail
    try tmp.dir.writeFile(io, .{ .sub_path = "mytool-1.0.0-windows-x86_64.zip", .data = "fake" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..n];
    const tmp_path_owned = try a.dupe(u8, tmp_path);

    const result = findWindowsZipByArch(a, tmp_path_owned, "mytool", "aarch64");
    try std.testing.expectError(error.ArtifactNotFound, result);
}

test "publishScoopManifest dry-run generates manifest with both architectures" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create fake zip artifacts (content doesn't matter for SHA-256 correctness check,
    // but we verify it ends up in the manifest)
    try tmp.dir.writeFile(io, .{ .sub_path = "mytool-1.0.0-windows-x86_64.zip", .data = "x64content" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mytool-1.0.0-windows-aarch64.zip", .data = "arm64content" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..n];
    const tmp_path_owned = try a.dupe(u8, tmp_path);

    var result = try publishScoopManifest(a, io, .{
        .bucket = "vmvarela/scoop-bucket",
        .owner = "vmvarela",
        .repo = "mytool",
        .tag = "v1.0.0",
        .project_name = "mytool",
        .description = "My tool description",
        .homepage = "https://github.com/vmvarela/mytool",
        .license = "MIT",
        .dist_dir = tmp_path_owned,
        .dry_run = true,
    });
    defer result.deinit(a);

    try std.testing.expect(result.success);
    try std.testing.expect(!result.pushed);

    // Read and validate the generated manifest
    const manifest_content = std.Io.Dir.cwd().readFileAlloc(
        io,
        result.manifest_path,
        a,
        .limited(1024 * 1024),
    ) catch return error.ReadError;

    // Must contain 64bit URL
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "mytool-1.0.0-windows-x86_64.zip") != null);
    // Must contain arm64 URL
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "mytool-1.0.0-windows-aarch64.zip") != null);
    // Must contain both arch keys
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "\"64bit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "\"arm64\"") != null);
    // Must contain version and metadata
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "\"version\": \"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "\"license\": \"MIT\"") != null);
}

test "publishScoopManifest dry-run generates manifest with x64 only when no arm64 artifact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Only x86_64 artifact
    try tmp.dir.writeFile(io, .{ .sub_path = "mytool-2.0.0-windows-x86_64.zip", .data = "x64only" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..n];
    const tmp_path_owned = try a.dupe(u8, tmp_path);

    var result = try publishScoopManifest(a, io, .{
        .bucket = "vmvarela/scoop-bucket",
        .owner = "vmvarela",
        .repo = "mytool",
        .tag = "v2.0.0",
        .project_name = "mytool",
        .description = "My tool description",
        .homepage = "https://github.com/vmvarela/mytool",
        .license = "MIT",
        .dist_dir = tmp_path_owned,
        .dry_run = true,
    });
    defer result.deinit(a);

    try std.testing.expect(result.success);
    try std.testing.expect(!result.pushed);

    const manifest_content = std.Io.Dir.cwd().readFileAlloc(
        io,
        result.manifest_path,
        a,
        .limited(1024 * 1024),
    ) catch return error.ReadError;

    // Must contain 64bit URL
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "mytool-2.0.0-windows-x86_64.zip") != null);
    // Must NOT contain arm64 block
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "\"arm64\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest_content, "\"version\": \"2.0.0\"") != null);
}

test "findWindowsZipByArch does not confuse x86_64 and aarch64" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both arches present
    try tmp.dir.writeFile(io, .{ .sub_path = "tool-1.0.0-windows-x86_64.zip", .data = "x64data" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tool-1.0.0-windows-aarch64.zip", .data = "arm64data" });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const tmp_path = buf[0..n];
    const tmp_path_owned = try a.dupe(u8, tmp_path);

    const x64 = try findWindowsZipByArch(a, tmp_path_owned, "tool", "x86_64");
    defer {
        a.free(x64.file_name);
        a.free(x64.full_path);
    }
    try std.testing.expect(std.mem.indexOf(u8, x64.file_name, "x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, x64.file_name, "aarch64") == null);

    const arm = try findWindowsZipByArch(a, tmp_path_owned, "tool", "aarch64");
    defer {
        a.free(arm.file_name);
        a.free(arm.full_path);
    }
    try std.testing.expect(std.mem.indexOf(u8, arm.file_name, "aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, arm.file_name, "x86_64") == null);
}
