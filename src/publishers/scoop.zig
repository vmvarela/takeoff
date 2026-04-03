//! Scoop bucket publisher — generates a manifest JSON, clones the bucket repo,
//! commits the manifest file, and pushes via SSH.
//!
//! The bucket repo can host multiple manifests — each project writes to
//! bucket/<project_name>.json inside the shared repo.

const std = @import("std");

const log = std.log.scoped(.scoop_publish);

/// Error set for Scoop bucket publishing.
pub const ScoopPublishError = error{
    InvalidConfig,
    ArtifactNotFound,
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
    if (opts.owner.len == 0) return error.InvalidConfig;
    if (opts.repo.len == 0) return error.InvalidConfig;

    const packagers = @import("../packagers/scoop.zig");

    // Find the Windows zip artifact
    const artifact = try findWindowsZip(allocator, io, opts.dist_dir, opts.project_name);
    defer {
        allocator.free(artifact.file_name);
        allocator.free(artifact.full_path);
    }

    // Normalise version (strip 'v' prefix)
    const version = if (opts.tag.len > 0 and opts.tag[0] == 'v')
        opts.tag[1..]
    else
        opts.tag;

    // Compute SHA-256 of the zip
    const sha256 = try computeSha256(allocator, artifact.full_path);
    defer allocator.free(sha256);

    // Build download URL
    const download_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ opts.owner, opts.repo, opts.tag, artifact.file_name },
    );
    defer allocator.free(download_url);

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
        .url_64bit = download_url,
        .sha256_64bit = sha256,
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

/// Find a Windows zip artifact in the dist directory.
pub fn findWindowsZip(
    allocator: std.mem.Allocator,
    io: std.Io,
    dist_dir: []const u8,
    project_name: []const u8,
) ScoopPublishError!struct {
    file_name: []const u8,
    full_path: []const u8,
} {
    _ = io;
    const dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dist_dir, .{ .iterate = true }) catch |err| {
        log.err("cannot open dist directory {s}: {}", .{ dist_dir, err });
        return error.ArtifactNotFound;
    };
    defer dir.close(std.Options.debug_io);

    var iter = dir.iterate();

    // Collect all matching Windows zips so we can prefer x86_64 over arm64
    var matches: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit(allocator);
    }

    while (iter.next(std.Options.debug_io) catch null) |entry| {
        const name = entry.name;
        if (std.mem.startsWith(u8, name, project_name) and
            std.mem.endsWith(u8, name, ".zip") and
            std.mem.indexOf(u8, name, "windows") != null)
        {
            const copy = try allocator.dupe(u8, name);
            try matches.append(allocator, copy);
        }
    }

    // Prefer x86_64, then arm64/aarch64
    for (matches.items) |name| {
        if (std.mem.indexOf(u8, name, "x86_64") != null) {
            const file_name = try allocator.dupe(u8, name);
            errdefer allocator.free(file_name);
            const full_path = try std.fs.path.join(allocator, &.{ dist_dir, name });
            errdefer allocator.free(full_path);
            return .{
                .file_name = file_name,
                .full_path = full_path,
            };
        }
    }
    for (matches.items) |name| {
        if (std.mem.indexOf(u8, name, "arm64") != null or std.mem.indexOf(u8, name, "aarch64") != null) {
            const file_name = try allocator.dupe(u8, name);
            errdefer allocator.free(file_name);
            const full_path = try std.fs.path.join(allocator, &.{ dist_dir, name });
            errdefer allocator.free(full_path);
            return .{
                .file_name = file_name,
                .full_path = full_path,
            };
        }
    }

    // Fallback: return the first match
    if (matches.items.len > 0) {
        const name = matches.items[0];
        const file_name = try allocator.dupe(u8, name);
        errdefer allocator.free(file_name);
        const full_path = try std.fs.path.join(allocator, &.{ dist_dir, name });
        errdefer allocator.free(full_path);
        return .{
            .file_name = file_name,
            .full_path = full_path,
        };
    }

    log.err("no Windows zip found in {s} for {s}", .{ dist_dir, project_name });
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
