//! Winget (Windows Package Manager) publisher — generates the three-file YAML
//! manifest structure, then submits them to the user's fork of
//! `microsoft/winget-pkgs` entirely via the GitHub Contents API (no git clone
//! required) and opens a PR via the GitHub Pull-Request API.
//!
//! Directory structure in winget-pkgs:
//!   manifests/{first-letter}/{publisher}/{name}/{version}/
//!     {publisher}.{name}.yaml
//!     {publisher}.{name}.locale.en-US.yaml
//!     {publisher}.{name}.installer.yaml

const std = @import("std");
const github = @import("github.zig");

const log = std.log.scoped(.winget_publish);

const ReleaseContext = @import("../release/context.zig").ReleaseContext;

/// Error set for Winget manifest publishing.
pub const WingetPublishError = error{
    InvalidConfig,
    ArtifactNotFound,
    AssetNotFound,
    InvalidManifest,
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
    /// GitHub owner — used for GitHub API calls (fork detection, PR).
    /// For asset URLs, use `ctx.assetUrl()` instead.
    owner: []const u8,
    /// GitHub repo — used for GitHub API calls (fork detection, PR).
    repo: []const u8,
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
    /// GitHub fork repo for pushing (e.g. "vmvarela/winget-pkgs").
    /// If null, the publisher auto-detects the fork via the GitHub API.
    fork_repo: ?[]const u8 = null,
    /// GitHub token for API calls (PR creation, fork detection, content upload).
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
    const version = if (opts.ctx.tag.len > 0 and opts.ctx.tag[0] == 'v')
        opts.ctx.tag[1..]
    else
        opts.ctx.tag;

    // Find the Windows zip artifacts for SHA-256
    const x64_artifact = try findWindowsZip(allocator, io, opts.dist_dir, opts.project_name, "x86_64");
    defer {
        allocator.free(x64_artifact.file_name);
        allocator.free(x64_artifact.full_path);
    }

    const sha256_x64 = try computeSha256(allocator, x64_artifact.full_path);
    defer allocator.free(sha256_x64);

    const download_url_x64 = try opts.ctx.assetUrl(allocator, x64_artifact.file_name);
    defer allocator.free(download_url_x64);

    // Try to find arm64 artifact (optional)
    var download_url_arm64: ?[]const u8 = null;
    var sha256_arm64: ?[]const u8 = null;
    if (findWindowsZip(allocator, io, opts.dist_dir, opts.project_name, "aarch64")) |arm64_artifact| {
        defer {
            allocator.free(arm64_artifact.file_name);
            allocator.free(arm64_artifact.full_path);
        }
        const url = try opts.ctx.assetUrl(allocator, arm64_artifact.file_name);
        download_url_arm64 = url;
        sha256_arm64 = try computeSha256(allocator, arm64_artifact.full_path);
    } else |_| {
        // arm64 is optional — ignore the error
    }
    defer if (download_url_arm64) |u| allocator.free(u);
    defer if (sha256_arm64) |h| allocator.free(h);

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

    // Upload manifests via GitHub Contents API, then create PR
    const package_id = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ opts.publisher, opts.project_name },
    );
    defer allocator.free(package_id);

    const pr_url = try pushViaContentsApi(
        allocator,
        io,
        opts.github_token,
        fork_repo,
        package_id,
        opts.publisher,
        opts.project_name,
        version,
        winget_dir,
    );
    defer allocator.free(pr_url);

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
// Fork detection via GitHub API
// ---------------------------------------------------------------------------

/// Auto-detect the user's fork of microsoft/winget-pkgs via the GitHub API.
///
/// Strategy: fetch GET /user (to get the authenticated username), then probe
/// GET /repos/{login}/winget-pkgs directly and verify fork=true and
/// parent.full_name == "{upstream_owner}/{upstream_repo}".
/// This avoids paginating /user/repos (which omits the parent field).
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

    var client = github.GitHubClient.initWithOptions(
        arena_alloc,
        io,
        token,
        .{ .timeout_ms = 30_000 },
    ) catch return error.ForkNotFound;
    defer client.deinit();

    // Step 1: get the authenticated user's login
    const user_response = client.makeRequest(.GET, "/user", null) catch return error.ForkNotFound;
    defer client.allocator.free(user_response);

    const user_parsed = std.json.parseFromSlice(
        std.json.Value,
        arena_alloc,
        user_response,
        .{ .ignore_unknown_fields = true },
    ) catch return error.ForkNotFound;

    const login = if (user_parsed.value == .object)
        if (user_parsed.value.object.get("login")) |v|
            if (v == .string) v.string else return error.ForkNotFound
        else
            return error.ForkNotFound
    else
        return error.ForkNotFound;

    // Step 2: probe /repos/{login}/{upstream_repo} and verify it is a fork of upstream
    const repo_path = try std.fmt.allocPrint(arena_alloc, "/repos/{s}/{s}", .{ login, upstream_repo });

    const repo_response = client.makeRequest(.GET, repo_path, null) catch return error.ForkNotFound;
    defer client.allocator.free(repo_response);

    const repo_parsed = std.json.parseFromSlice(
        std.json.Value,
        arena_alloc,
        repo_response,
        .{ .ignore_unknown_fields = true },
    ) catch return error.ForkNotFound;

    if (repo_parsed.value != .object) return error.ForkNotFound;
    const obj = repo_parsed.value.object;

    // Must be a fork
    const is_fork = if (obj.get("fork")) |v| if (v == .bool) v.bool else false else false;
    if (!is_fork) return error.ForkNotFound;

    // Parent must match upstream
    const parent = obj.get("parent") orelse return error.ForkNotFound;
    if (parent != .object) return error.ForkNotFound;
    const parent_full_name = if (parent.object.get("full_name")) |v|
        if (v == .string) v.string else ""
    else
        "";

    const expected = try std.fmt.allocPrint(arena_alloc, "{s}/{s}", .{ upstream_owner, upstream_repo });
    if (!std.mem.eql(u8, parent_full_name, expected)) return error.ForkNotFound;

    // Return "{login}/{upstream_repo}"
    const full_name = if (obj.get("full_name")) |v| if (v == .string) v.string else "" else "";
    if (full_name.len == 0) return error.ForkNotFound;
    return try allocator.dupe(u8, full_name);
}

// ---------------------------------------------------------------------------
// GitHub Contents API: create branch + upload files + create PR
// ---------------------------------------------------------------------------

/// Push the three manifest files to the fork via the GitHub Contents API
/// (no git clone) and open a PR to microsoft/winget-pkgs.
///
/// Returns the PR URL (caller must free), or an empty string (also allocated,
/// caller must free) when there are no changes to submit.
fn pushViaContentsApi(
    allocator: std.mem.Allocator,
    io: std.Io,
    token: []const u8,
    fork_repo: []const u8,
    package_id: []const u8,
    publisher: []const u8,
    project_name: []const u8,
    version: []const u8,
    winget_dir: []const u8,
) WingetPublishError![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var client = github.GitHubClient.initWithOptions(
        a,
        io,
        token,
        .{ .timeout_ms = 60_000 },
    ) catch return error.NetworkError;
    defer client.deinit();

    // Step 1: Get the fork's default branch and its SHA
    const repo_path = try std.fmt.allocPrint(a, "/repos/{s}", .{fork_repo});
    const repo_resp = client.makeRequest(.GET, repo_path, null) catch return error.NetworkError;
    defer client.allocator.free(repo_resp);

    const repo_val = std.json.parseFromSlice(
        std.json.Value,
        a,
        repo_resp,
        .{ .ignore_unknown_fields = true },
    ) catch return error.NetworkError;

    const default_branch = if (repo_val.value == .object)
        if (repo_val.value.object.get("default_branch")) |v|
            if (v == .string) v.string else "master"
        else
            "master"
    else
        "master";

    // GET /repos/{fork}/branches/{default_branch} to obtain the HEAD SHA
    const branch_path = try std.fmt.allocPrint(a, "/repos/{s}/branches/{s}", .{ fork_repo, default_branch });
    const branch_resp = client.makeRequest(.GET, branch_path, null) catch return error.NetworkError;
    defer client.allocator.free(branch_resp);

    const branch_val = std.json.parseFromSlice(
        std.json.Value,
        a,
        branch_resp,
        .{ .ignore_unknown_fields = true },
    ) catch return error.NetworkError;

    const base_sha: []const u8 = if (branch_val.value == .object)
        if (branch_val.value.object.get("commit")) |c|
            if (c == .object)
                if (c.object.get("sha")) |s|
                    if (s == .string) s.string else return error.NetworkError
                else
                    return error.NetworkError
            else
                return error.NetworkError
        else
            return error.NetworkError
    else
        return error.NetworkError;

    // Step 2: Create a new branch in the fork
    const branch_name = try std.fmt.allocPrint(a, "takeoff-{s}-{s}", .{ project_name, version });
    const new_ref = try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch_name});
    const create_ref_path = try std.fmt.allocPrint(a, "/repos/{s}/git/refs", .{fork_repo});
    const create_ref_body = try std.fmt.allocPrint(
        a,
        "{{\"ref\":\"{s}\",\"sha\":\"{s}\"}}",
        .{ new_ref, base_sha },
    );

    // 422 (AlreadyExists) means the branch already exists — that's fine, we'll
    // just overwrite the files on it.
    _ = client.makeRequest(.POST, create_ref_path, create_ref_body) catch |err| switch (err) {
        error.AlreadyExists => {
            log.info("branch {s} already exists in fork — will reuse it", .{branch_name});
        },
        else => {
            log.err("failed to create branch {s}: {}", .{ branch_name, err });
            return error.PushFailed;
        },
    };

    // Step 3: Upload each manifest file via PUT /repos/{fork}/contents/{path}
    const first_letter_upper = try std.fmt.allocPrint(a, "{c}", .{std.ascii.toUpper(publisher[0])});
    const manifests_base = try std.fmt.allocPrint(
        a,
        "manifests/{s}/{s}/{s}/{s}",
        .{ first_letter_upper, publisher, project_name, version },
    );

    const file_names = [_][]const u8{
        try std.fmt.allocPrint(a, "{s}.yaml", .{package_id}),
        try std.fmt.allocPrint(a, "{s}.locale.en-US.yaml", .{package_id}),
        try std.fmt.allocPrint(a, "{s}.installer.yaml", .{package_id}),
    };

    var any_change = false;

    for (file_names) |filename| {
        const local_path = try std.fs.path.join(a, &.{ winget_dir, filename });
        const content_raw = std.Io.Dir.cwd().readFileAlloc(
            std.Options.debug_io,
            local_path,
            a,
            .limited(64 * 1024),
        ) catch return error.ReadError;

        // Base64-encode the file content for the GitHub Contents API
        const b64_len = std.base64.standard.Encoder.calcSize(content_raw.len);
        const b64_buf = try a.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64_buf, content_raw);

        const repo_file_path = try std.fmt.allocPrint(
            a,
            "{s}/{s}",
            .{ manifests_base, filename },
        );
        const contents_api_path = try std.fmt.allocPrint(
            a,
            "/repos/{s}/contents/{s}",
            .{ fork_repo, repo_file_path },
        );

        // Check if the file already exists (to get its SHA for updates)
        var existing_sha: ?[]const u8 = null;
        if (client.makeRequest(.GET, contents_api_path, null)) |resp| {
            defer client.allocator.free(resp);
            const val = std.json.parseFromSlice(
                std.json.Value,
                a,
                resp,
                .{ .ignore_unknown_fields = true },
            ) catch null;
            if (val) |v| {
                if (v.value == .object) {
                    if (v.value.object.get("sha")) |s| {
                        if (s == .string) existing_sha = s.string;
                    }
                }
            }
        } else |_| {
            // File doesn't exist yet — that's fine
        }

        // Build JSON body for PUT /contents
        const commit_msg = try std.fmt.allocPrint(
            a,
            "New version: {s} {s}",
            .{ package_id, version },
        );
        const escaped_msg = try escapeJsonValue(a, commit_msg);
        const escaped_b64 = try escapeJsonValue(a, b64_buf);
        const escaped_branch = try escapeJsonValue(a, branch_name);

        const put_body = if (existing_sha) |sha|
            try std.fmt.allocPrint(
                a,
                "{{\"message\":\"{s}\",\"content\":\"{s}\",\"branch\":\"{s}\",\"sha\":\"{s}\"}}",
                .{ escaped_msg, escaped_b64, escaped_branch, sha },
            )
        else
            try std.fmt.allocPrint(
                a,
                "{{\"message\":\"{s}\",\"content\":\"{s}\",\"branch\":\"{s}\"}}",
                .{ escaped_msg, escaped_b64, escaped_branch },
            );

        _ = client.makeRequest(.PUT, contents_api_path, put_body) catch |err| {
            log.err("failed to upload {s}: {}", .{ filename, err });
            return error.PushFailed;
        };

        log.info("uploaded manifest file: {s}", .{filename});
        any_change = true;
    }

    if (!any_change) {
        return try allocator.dupe(u8, "");
    }

    // Step 4: Create the PR
    const pr_url = try createPr(
        allocator,
        io,
        token,
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
        "New version: {s} {s}",
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const escaped_title = try escapeJsonValue(a, title);
    const escaped_body = try escapeJsonValue(a, body_text);
    const escaped_head = try escapeJsonValue(a, head);

    const json_body = try std.fmt.allocPrint(
        a,
        "{{\"title\":\"{s}\",\"body\":\"{s}\",\"head\":\"{s}\",\"base\":\"master\"}}",
        .{ escaped_title, escaped_body, escaped_head },
    );

    var client = github.GitHubClient.initWithOptions(
        a,
        io,
        token,
        .{ .timeout_ms = 30_000 },
    ) catch return error.NetworkError;
    defer client.deinit();

    const response = client.makeRequest(.POST, "/repos/microsoft/winget-pkgs/pulls", json_body) catch |err| {
        log.err("PR creation failed: {}", .{err});
        return error.PrFailed;
    };
    defer client.allocator.free(response);

    // Parse PR URL from response
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        a,
        response,
        .{ .ignore_unknown_fields = true },
    ) catch return error.PrFailed;

    const html_url = if (parsed.value == .object)
        if (parsed.value.object.get("html_url")) |v|
            if (v == .string) v.string else ""
        else
            ""
    else
        "";

    if (html_url.len == 0) return error.PrFailed;

    return try allocator.dupe(u8, html_url);
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

/// Escape a string value for safe embedding in a JSON string literal.
/// Returns an allocated string that the caller must free.
fn escapeJsonValue(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
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
// Helpers
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "escapeJsonValue escapes special characters" {
    const allocator = std.testing.allocator;

    const result = try escapeJsonValue(allocator, "hello \"world\"\n");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\n", result);
}

test "escapeJsonValue passes plain strings unchanged" {
    const allocator = std.testing.allocator;

    const result = try escapeJsonValue(allocator, "Test v1.0");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Test v1.0", result);
}

test "escapeJsonValue escapes backslash" {
    const allocator = std.testing.allocator;

    const result = try escapeJsonValue(allocator, "path\\to\\file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result);
}

test "escapeJsonValue escapes tab and carriage return" {
    const allocator = std.testing.allocator;

    const result = try escapeJsonValue(allocator, "a\tb\rc");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a\\tb\\rc", result);
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

test "base64 encoding of manifest content is non-empty" {
    // Verify the base64 encoding logic produces correctly-sized output
    const content = "PackageIdentifier: foo.bar\nManifestType: version\n";
    const b64_len = std.base64.standard.Encoder.calcSize(content.len);
    try std.testing.expect(b64_len > content.len);

    const buf = try std.testing.allocator.alloc(u8, b64_len);
    defer std.testing.allocator.free(buf);
    const result = std.base64.standard.Encoder.encode(buf, content);
    try std.testing.expect(result.len > 0);
    // Base64 alphabet must only contain valid chars (A-Z a-z 0-9 + / =)
    for (result) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=');
    }
}
