//! Winget (Windows Package Manager) publisher — generates the three-file YAML
//! manifest structure, clones the user's fork of `microsoft/winget-pkgs`,
//! commits the files, pushes to the fork, and opens a PR via the GitHub API.
//!
//! Directory structure in winget-pkgs:
//!   manifests/{first-letter}/{publisher}/{name}/{version}/
//!     {publisher}.{name}.yaml
//!     {publisher}.{name}.locale.en-US.yaml
//!     {publisher}.{name}.installer.yaml

const std = @import("std");
const publishers = @import("github.zig");

const log = std.log.scoped(.winget_publish);

/// Error set for Winget manifest publishing.
pub const WingetPublishError = error{
    InvalidConfig,
    ReadError,
    WriteError,
    ProcessError,
    PushFailed,
    PrFailed,
    ForkNotFound,
    NetworkError,
} || std.mem.Allocator.Error;

/// Options for generating and submitting a Winget manifest.
pub const WingetPublishOptions = struct {
    /// Publisher name for PackageIdentifier (e.g. "vmvarela").
    publisher: []const u8,
    /// GitHub owner (for building URLs and API calls).
    owner: []const u8,
    /// GitHub repo (for building URLs and API calls).
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
    /// GitHub fork repo for pushing (e.g. "vmvarela/winget-pkgs").
    /// If null, the publisher auto-detects the fork via the GitHub API.
    fork_repo: ?[]const u8 = null,
    /// Optional SSH private key for pushing to the fork.
    /// Falls back to WINGET_FORK_SSH_KEY env var.
    fork_ssh_key: ?[]const u8 = null,
    /// GitHub token for API calls (PR creation, fork detection).
    github_token: []const u8,
    /// If true, only generate and report — do not push or create PR.
    dry_run: bool = false,
};

/// Result of Winget publish operation.
pub const WingetPublishResult = struct {
    success: bool,
    /// Path to the generated manifest directory.
    manifest_dir: []const u8,
    /// Whether a PR was created (false in dry-run or no changes).
    pr_created: bool,
    /// URL of the created PR, or empty string.
    pr_url: []const u8,
    message: []const u8,

    pub fn deinit(self: *WingetPublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_dir);
        allocator.free(self.pr_url);
        allocator.free(self.message);
    }
};

/// Generate Winget manifest and optionally submit a PR to microsoft/winget-pkgs.
pub fn publishWingetManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: WingetPublishOptions,
) WingetPublishError!WingetPublishResult {
    if (opts.publisher.len == 0) return error.InvalidConfig;
    if (opts.owner.len == 0) return error.InvalidConfig;
    if (opts.repo.len == 0) return error.InvalidConfig;
    if (opts.github_token.len == 0) return error.InvalidConfig;

    const packagers = @import("../packagers/winget.zig");

    // Normalise version (strip 'v' prefix)
    const version = if (opts.tag.len > 0 and opts.tag[0] == 'v')
        opts.tag[1..]
    else
        opts.tag;

    // Find the Windows zip artifacts for SHA-256
    const x64_artifact = try findWindowsZip(allocator, io, opts.dist_dir, opts.project_name, "x86_64");
    defer {
        allocator.free(x64_artifact.file_name);
        allocator.free(x64_artifact.full_path);
    }

    const sha256_x64 = try computeSha256(allocator, x64_artifact.full_path);
    defer allocator.free(sha256_x64);

    const download_url_x64 = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ opts.owner, opts.repo, opts.tag, x64_artifact.file_name },
    );
    defer allocator.free(download_url_x64);

    // Try to find arm64 artifact (optional)
    var download_url_arm64: ?[]const u8 = null;
    var sha256_arm64: ?[]const u8 = null;
    if (findWindowsZip(allocator, io, opts.dist_dir, opts.project_name, "aarch64")) |arm64_artifact| {
        defer {
            allocator.free(arm64_artifact.file_name);
            allocator.free(arm64_artifact.full_path);
        }
        download_url_arm64 = try std.fmt.allocPrint(
            allocator,
            "https://github.com/{s}/{s}/releases/download/{s}/{s}",
            .{ opts.owner, opts.repo, opts.tag, arm64_artifact.file_name },
        );
        defer if (download_url_arm64) |u| allocator.free(u);

        sha256_arm64 = try computeSha256(allocator, arm64_artifact.full_path);
        defer if (sha256_arm64) |h| allocator.free(h);
    } else |_| {
        // arm64 is optional
    }

    // Build output directory: {dist_dir}/winget/
    const winget_dir = try std.fs.path.join(allocator, &.{ opts.dist_dir, "winget" });
    defer allocator.free(winget_dir);
    std.Io.Dir.cwd().createDirPath(io, winget_dir) catch return error.WriteError;

    const binary_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{opts.project_name});
    defer allocator.free(binary_name);

    const cfg = packagers.WingetConfig{
        .publisher = opts.publisher,
        .project_name = opts.project_name,
        .version = version,
        .description = opts.description,
        .homepage = opts.homepage,
        .license = opts.license,
        .url_x64 = download_url_x64,
        .sha256_x64 = sha256_x64,
        .url_arm64 = download_url_arm64,
        .sha256_arm64 = sha256_arm64,
        .binary_name = binary_name,
        .output_dir = winget_dir,
    };

    packagers.generate(allocator, io, cfg) catch return error.WriteError;

    // Dry run — just report
    if (opts.dry_run) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "generated Winget manifest (dry-run, no PR): {s}",
            .{winget_dir},
        );
        return .{
            .success = true,
            .manifest_dir = try allocator.dupe(u8, winget_dir),
            .pr_created = false,
            .pr_url = try allocator.dupe(u8, ""),
            .message = msg,
        };
    }

    // Resolve fork repo — use configured value or auto-detect
    const fork_repo = if (opts.fork_repo) |fr| fr else blk: {
        const detected = try detectFork(allocator, io, opts.github_token, opts.owner, opts.repo);
        defer allocator.free(detected);
        break :blk try allocator.dupe(u8, detected);
    };
    defer if (opts.fork_repo == null) allocator.free(fork_repo);

    // Resolve SSH key
    const ssh_key = resolveSshKey(allocator, opts.fork_ssh_key) catch null;
    defer if (ssh_key) |k| allocator.free(k);

    // Clone the fork, commit, push, and create PR
    const pr_url = try pushAndCreatePr(
        allocator,
        io,
        fork_repo,
        ssh_key,
        opts,
        version,
        winget_dir,
        opts.github_token,
    );

    if (pr_url.len > 0) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "generated manifest and created PR: {s}",
            .{pr_url},
        );
        return .{
            .success = true,
            .manifest_dir = try allocator.dupe(u8, winget_dir),
            .pr_created = true,
            .pr_url = try allocator.dupe(u8, pr_url),
            .message = msg,
        };
    } else {
        const msg = try allocator.dupe(
            u8,
            "generated manifest; no PR needed (no changes)",
        );
        return .{
            .success = true,
            .manifest_dir = try allocator.dupe(u8, winget_dir),
            .pr_created = false,
            .pr_url = try allocator.dupe(u8, ""),
            .message = msg,
        };
    }
}

// ---------------------------------------------------------------------------
// Fork detection via GitHub API (uses std.http, paginates)
// ---------------------------------------------------------------------------

/// Auto-detect the user's fork of microsoft/winget-pkgs via the GitHub API.
/// Paginates through all repos if needed.
fn detectFork(
    allocator: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    upstream_owner: []const u8,
    upstream_repo: []const u8,
) WingetPublishError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var client = publishers.GitHubClient.initWithOptions(
        arena_alloc,
        io,
        token,
        .{ .timeout_ms = 30_000 },
    ) catch return error.ForkNotFound;
    defer client.deinit();

    var url: ?[]const u8 = try allocator.dupe(u8, "/user/repos?per_page=100&type=owner");
    defer if (url) |u| allocator.free(u);

    while (url) |current_url| {
        allocator.free(current_url);
        url = null;

        const response = client.makeRequest(.GET, current_url, null) catch |err| switch (err) {
            error.NotFound => return error.ForkNotFound,
            error.AuthenticationFailed => return error.ForkNotFound,
            else => return error.ForkNotFound,
        };
        defer client.allocator.free(response);

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            arena_alloc,
            response,
            .{ .ignore_unknown_fields = true },
        ) catch return error.ForkNotFound;

        if (parsed.value != .array) return error.ForkNotFound;

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;

            // Check if this is a fork
            const is_fork = if (obj.get("fork")) |v|
                if (v == .bool) v.bool else false
            else
                false;
            if (!is_fork) continue;

            // Check parent.full_name matches upstream
            const parent = obj.get("parent") orelse continue;
            if (parent != .object) continue;
            const parent_obj = parent.object;
            const parent_full_name = if (parent_obj.get("full_name")) |v|
                if (v == .string) v.string else ""
            else
                "";

            const expected = try std.fmt.allocPrint(
                arena_alloc,
                "{s}/{s}",
                .{ upstream_owner, upstream_repo },
            );
            if (std.mem.eql(u8, parent_full_name, expected)) {
                const full_name = if (obj.get("full_name")) |v|
                    if (v == .string) v.string else ""
                else
                    "";
                if (full_name.len > 0) {
                    return try allocator.dupe(u8, full_name);
                }
            }
        }

        // Check for next page via Link header
        const link_header = client.last_link_header orelse break;
        const next_url = client.parseLinkHeader(link_header) orelse break;
        defer client.allocator.free(next_url);

        // Convert full URL to path for makeRequest
        const uri = std.Uri.parse(next_url) catch break;
        const path_str = switch (uri.path) {
            .raw => |r| allocator.dupe(u8, r) catch break,
            .percent_encoded => |p| allocator.dupe(u8, p) catch break,
        };
        errdefer allocator.free(path_str);
        url = path_str;
    }

    return error.ForkNotFound;
}

// ---------------------------------------------------------------------------
// Git clone, commit, push, PR creation
// ---------------------------------------------------------------------------

/// Clone the fork, write manifests, commit, push, and create a PR.
fn pushAndCreatePr(
    allocator: std.mem.Allocator,
    io: std.Io,
    fork_repo: []const u8,
    ssh_key: ?[]const u8,
    opts: WingetPublishOptions,
    version: []const u8,
    winget_dir: []const u8,
    github_token: []const u8,
) WingetPublishError![]const u8 {
    const package_id = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ opts.publisher, opts.project_name },
    );
    defer allocator.free(package_id);

    // Target path in winget-pkgs: manifests/{first-letter}/{publisher}/{name}/{version}/
    const first_letter_upper = try std.fmt.allocPrint(
        allocator,
        "{c}",
        .{std.ascii.toUpper(opts.publisher[0])},
    );
    defer allocator.free(first_letter_upper);

    const manifests_path = try std.fs.path.join(
        allocator,
        &.{ "manifests", first_letter_upper, opts.publisher, opts.project_name, version },
    );
    defer allocator.free(manifests_path);

    // Temp directory — include a random suffix to avoid collisions
    var rand_buf: [8]u8 = undefined;
    std.Io.random(io, &rand_buf);
    const tmp_dir = try std.fmt.allocPrint(
        allocator,
        "/tmp/takeoff-winget-{s}-{s}-{s}",
        .{ std.fs.path.basename(fork_repo), version, std.fmt.bytesToHex(rand_buf, .lower) },
    );
    defer allocator.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch return error.WriteError;

    // SSH command
    const ssh_cmd = if (ssh_key) |key|
        try std.fmt.allocPrint(allocator, "ssh -i \"{s}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new", .{key})
    else
        null;
    defer if (ssh_cmd) |s| allocator.free(s);

    // Clone fork
    const clone_url = try buildCloneUrl(allocator, fork_repo);
    defer allocator.free(clone_url);

    const clone_cmd = if (ssh_cmd) |s|
        try std.fmt.allocPrint(allocator, "GIT_SSH_COMMAND='{s}' git clone \"{s}\" \"{s}\"", .{ s, clone_url, tmp_dir })
    else
        try std.fmt.allocPrint(allocator, "git clone \"{s}\" \"{s}\"", .{ clone_url, tmp_dir });
    defer allocator.free(clone_cmd);
    try runShell(allocator, io, clone_cmd);

    // Create target directory
    const target_dir = try std.fs.path.join(allocator, &.{ tmp_dir, manifests_path });
    defer allocator.free(target_dir);
    std.Io.Dir.cwd().createDirPath(io, target_dir) catch return error.WriteError;

    // Copy the three YAML files
    const files = [_][]const u8{
        try std.fmt.allocPrint(allocator, "{s}.yaml", .{package_id}),
        try std.fmt.allocPrint(allocator, "{s}.locale.en-US.yaml", .{package_id}),
        try std.fmt.allocPrint(allocator, "{s}.installer.yaml", .{package_id}),
    };
    defer {
        for (files) |f| allocator.free(f);
    }

    for (files) |filename| {
        const src = try std.fs.path.join(allocator, &.{ winget_dir, filename });
        defer allocator.free(src);
        const dst = try std.fs.path.join(allocator, &.{ target_dir, filename });
        defer allocator.free(dst);

        const content = std.Io.Dir.cwd().readFileAlloc(
            std.Options.debug_io,
            src,
            allocator,
            .limited(64 * 1024),
        ) catch return error.ReadError;
        defer allocator.free(content);

        writeFile(io, dst, content) catch return error.WriteError;
    }

    // git add
    const add_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" add \"{s}/\"",
        .{ tmp_dir, manifests_path },
    );
    defer allocator.free(add_cmd);
    try runShell(allocator, io, add_cmd);

    // Check if there are changes
    const status_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" status --porcelain -- \"{s}/\"",
        .{ tmp_dir, manifests_path },
    );
    defer allocator.free(status_cmd);
    const changed = try runShellReturnsChanged(allocator, io, status_cmd);
    if (!changed) return try allocator.dupe(u8, "");

    // Create a branch
    const branch_name = try std.fmt.allocPrint(
        allocator,
        "takeoff-{s}-{s}",
        .{ opts.project_name, version },
    );
    defer allocator.free(branch_name);

    const branch_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" checkout -b \"{s}\"",
        .{ tmp_dir, branch_name },
    );
    defer allocator.free(branch_cmd);
    try runShell(allocator, io, branch_cmd);

    // Commit
    const commit_msg = try std.fmt.allocPrint(
        allocator,
        "New version: {s} v{s}",
        .{ package_id, version },
    );
    defer allocator.free(commit_msg);

    const commit_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" commit -m \"{s}\"",
        .{ tmp_dir, commit_msg },
    );
    defer allocator.free(commit_cmd);
    try runShell(allocator, io, commit_cmd);

    // Push branch to fork
    const push_cmd = if (ssh_cmd) |s|
        try std.fmt.allocPrint(
            allocator,
            "GIT_SSH_COMMAND='{s}' git -C \"{s}\" push origin \"{s}\"",
            .{ s, tmp_dir, branch_name },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "git -C \"{s}\" push origin \"{s}\"",
            .{ tmp_dir, branch_name },
        );
    defer allocator.free(push_cmd);
    try runShell(allocator, io, push_cmd);

    // Create PR via GitHub API
    const pr_url = try createPr(
        allocator,
        io,
        github_token,
        fork_repo,
        branch_name,
        package_id,
        version,
    );

    return pr_url;
}

// ---------------------------------------------------------------------------
// PR creation via GitHub API (uses std.http)
// ---------------------------------------------------------------------------

/// Create a PR to microsoft/winget-pkgs from the user's fork branch.
fn createPr(
    allocator: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    fork_repo: []const u8,
    branch_name: []const u8,
    package_id: []const u8,
    version: []const u8,
) WingetPublishError![]const u8 {
    // Parse fork_repo to get the head in "owner:branch" format
    const fork_owner = blk: {
        const slash = std.mem.indexOfScalar(u8, fork_repo, '/') orelse return error.InvalidConfig;
        break :blk fork_repo[0..slash];
    };

    const head = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ fork_owner, branch_name });
    defer allocator.free(head);

    const title = try std.fmt.allocPrint(
        allocator,
        "New version: {s} v{s}",
        .{ package_id, version },
    );
    defer allocator.free(title);

    const body_text = try std.fmt.allocPrint(
        allocator,
        "Automated submission via takeoff.\n\n" ++
            "**Package:** {s}\n" ++
            "**Version:** {s}\n\n" ++
            "Manifest files:\n" ++
            "- `{s}.yaml` (version)\n" ++
            "- `{s}.locale.en-US.yaml` (locale)\n" ++
            "- `{s}.installer.yaml` (installer)\n",
        .{ package_id, version, package_id, package_id, package_id },
    );
    defer allocator.free(body_text);

    // Build JSON body manually using allocPrint
    var json_parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (json_parts.items) |p| allocator.free(p);
        json_parts.deinit(allocator);
    }

    try json_parts.append(allocator, try std.fmt.allocPrint(allocator, "{{\"title\":\"", .{}));
    try json_parts.append(allocator, try escapeJsonValue(allocator, title));
    try json_parts.append(allocator, try std.fmt.allocPrint(allocator, "\",\"body\":\"", .{}));
    try json_parts.append(allocator, try escapeJsonValue(allocator, body_text));
    try json_parts.append(allocator, try std.fmt.allocPrint(allocator, "\",\"head\":\"", .{}));
    try json_parts.append(allocator, try escapeJsonValue(allocator, head));
    try json_parts.append(allocator, try std.fmt.allocPrint(allocator, "\",\"base\":\"master\"}}", .{}));

    // Join all parts
    var json_body: std.ArrayList(u8) = .empty;
    defer json_body.deinit(allocator);
    for (json_parts.items) |part| {
        try json_body.appendSlice(allocator, part);
    }

    // Use std.http via GitHubClient
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var client = publishers.GitHubClient.initWithOptions(
        arena_alloc,
        io,
        token,
        .{ .timeout_ms = 30_000 },
    ) catch return error.NetworkError;
    defer client.deinit();

    const response = client.makeRequest(.POST, "/repos/microsoft/winget-pkgs/pulls", json_body.items) catch |err| {
        log.err("PR creation failed: {}", .{err});
        return error.PrFailed;
    };
    defer client.allocator.free(response);

    // Parse PR URL from response
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        arena_alloc,
        response,
        .{ .ignore_unknown_fields = true },
    ) catch return error.PrFailed;

    const html_url = if (parsed.value.object.get("html_url")) |v|
        if (v == .string) v.string else ""
    else
        "";

    if (html_url.len == 0) return error.PrFailed;

    return try allocator.dupe(u8, html_url);
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Escape a string value for safe embedding in a JSON string.
/// Returns an allocated string that the caller must free.
fn escapeJsonValue(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Worst case: every char needs escaping (2 bytes each)
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers (mirrored from scoop.zig)
// ---------------------------------------------------------------------------

/// Find a Windows zip artifact for a specific architecture.
fn findWindowsZip(
    allocator: std.mem.Allocator,
    io: std.Io,
    dist_dir: []const u8,
    project_name: []const u8,
    arch: []const u8,
) WingetPublishError!struct {
    file_name: []const u8,
    full_path: []const u8,
} {
    _ = io;
    const dir = std.Io.Dir.cwd().openDir(std.Options.debug_io, dist_dir, .{ .iterate = true }) catch |err| {
        log.err("cannot open dist directory {s}: {}", .{ dist_dir, err });
        return error.ReadError;
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
            return .{
                .file_name = file_name,
                .full_path = full_path,
            };
        }
    }

    return error.ReadError;
}

/// Compute SHA-256 hex digest of a file (lowercase hex, matching packager).
fn computeSha256(allocator: std.mem.Allocator, path: []const u8) WingetPublishError![]const u8 {
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

/// Build the SSH clone URL for the fork repo.
fn buildCloneUrl(
    allocator: std.mem.Allocator,
    fork_repo: []const u8,
) WingetPublishError![]const u8 {
    const slash = std.mem.indexOfScalar(u8, fork_repo, '/') orelse {
        return try std.fmt.allocPrint(allocator, "git@github.com:{s}/{s}.git", .{ fork_repo, fork_repo });
    };
    const owner = fork_repo[0..slash];
    const repo = fork_repo[slash + 1 ..];
    return try std.fmt.allocPrint(allocator, "git@github.com:{s}/{s}.git", .{ owner, repo });
}

/// Resolve the SSH key from config or environment.
fn resolveSshKey(allocator: std.mem.Allocator, configured_key: ?[]const u8) !?[]const u8 {
    if (configured_key) |k| {
        if (k.len == 0) return null;
        return try allocator.dupe(u8, k);
    }
    const environ = std.Options.debug_threaded_io.?.environ.process_environ;
    if (std.process.Environ.getAlloc(environ, allocator, "WINGET_FORK_SSH_KEY") catch null) |key| {
        return key;
    }
    return std.process.Environ.getAlloc(environ, allocator, "TAKEOFF_SSH_KEY") catch null;
}

fn runShell(allocator: std.mem.Allocator, io: std.Io, command: []const u8) WingetPublishError!void {
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

fn runShellReturnsChanged(allocator: std.mem.Allocator, io: std.Io, command: []const u8) WingetPublishError!bool {
    const run = std.process.run(std.heap.page_allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.ProcessError;
    defer {
        std.heap.page_allocator.free(run.stdout);
        std.heap.page_allocator.free(run.stderr);
    }
    _ = allocator;
    return run.stdout.len > 0;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) WingetPublishError!void {
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return error.WriteError;
    defer f.close(io);
    f.writeStreamingAll(io, content) catch return error.WriteError;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildCloneUrl parses owner/repo" {
    const allocator = std.testing.allocator;
    const url = try buildCloneUrl(allocator, "vmvarela/winget-pkgs");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("git@github.com:vmvarela/winget-pkgs.git", url);
}

test "buildCloneUrl handles bare repo name" {
    const allocator = std.testing.allocator;
    const url = try buildCloneUrl(allocator, "winget-pkgs");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("git@github.com:winget-pkgs/winget-pkgs.git", url);
}

test "escapeJsonValue escapes special characters" {
    const allocator = std.testing.allocator;

    const result = try escapeJsonValue(allocator, "hello \"world\"\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\n", result);
}

test "escapeJsonValue produces valid JSON for PR body" {
    const allocator = std.testing.allocator;

    const result = try escapeJsonValue(allocator, "Test v1.0");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Test v1.0", result);
}

test "computeSha256 produces lowercase hex" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "test.bin", .data = "hello" });

    const path = "test.bin";

    const hash = try computeSha256(allocator, path);
    defer allocator.free(hash);

    // SHA-256 of "hello" is 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hash);
}
