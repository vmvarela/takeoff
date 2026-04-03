//! ReleaseContext — single source of truth for asset download URLs.
//!
//! A `ReleaseContext` is built once after assets are published (or loaded from
//! a manifest file) and then passed read-only to every secondary publisher.
//! Publishers call `assetUrl` to get the download URL for an artifact filename
//! instead of assembling GitHub-specific URLs themselves.
//!
//! Two sources are supported:
//!   * **github** — URLs are computed from owner/repo/tag on demand.
//!   * **manifest** — URLs are loaded from a JSON file; the GitHub formula is
//!     never used, enabling releases hosted outside GitHub.

const std = @import("std");

const log = std.log.scoped(.release_context);

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const ReleaseContextError = error{
    /// An asset was requested that is neither in the map nor computable from
    /// the GitHub formula (e.g. manifest source with missing entry).
    AssetNotFound,
    /// The manifest JSON is malformed or missing required fields.
    InvalidManifest,
    /// The manifest file could not be read.
    ReadError,
} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// GitHub source metadata — kept inside ReleaseContext for on-demand URL computation.
// ---------------------------------------------------------------------------

pub const GitHubSource = struct {
    owner: []const u8,
    repo: []const u8,
};

// ---------------------------------------------------------------------------
// ReleaseContext
// ---------------------------------------------------------------------------

/// Immutable release metadata shared by all secondary publishers.
///
/// Lifecycle: created by `fromGitHub` or `fromManifest`; owned by the caller
/// (typically `main.zig`). Publishers receive `*const ReleaseContext` and must
/// not call `deinit` on it.
pub const ReleaseContext = struct {
    allocator: std.mem.Allocator,

    /// Release tag, e.g. `"v1.2.3"`.
    tag: []const u8,

    /// Full URL of the release page (human-readable).
    release_page_url: []const u8,

    /// Base URL of the source repository, e.g. `"https://github.com/foo/bar"`.
    /// Used by publishers that need the repo clone URL (Homebrew `head` URL).
    repo_url: []const u8,

    /// Populated for GitHub-sourced releases; used to compute asset URLs on demand.
    github: ?GitHubSource,

    /// Explicit asset map: basename → full download URL.
    /// Takes precedence over the GitHub formula when present.
    asset_map: std.StringHashMap([]const u8),

    // -----------------------------------------------------------------------
    // Construction
    // -----------------------------------------------------------------------

    /// Build a ReleaseContext for a GitHub-hosted release.
    ///
    /// Asset URLs are computed on demand via `assetUrl`; no pre-population
    /// of `asset_map` is needed for the GitHub source.
    pub fn fromGitHub(
        allocator: std.mem.Allocator,
        owner: []const u8,
        repo: []const u8,
        tag: []const u8,
        release_page_url: []const u8,
    ) ReleaseContextError!ReleaseContext {
        const tag_owned = try allocator.dupe(u8, tag);
        errdefer allocator.free(tag_owned);

        const rpu_owned = try allocator.dupe(u8, release_page_url);
        errdefer allocator.free(rpu_owned);

        const repo_url = try std.fmt.allocPrint(
            allocator,
            "https://github.com/{s}/{s}",
            .{ owner, repo },
        );
        errdefer allocator.free(repo_url);

        const owner_owned = try allocator.dupe(u8, owner);
        errdefer allocator.free(owner_owned);

        const repo_owned = try allocator.dupe(u8, repo);
        errdefer allocator.free(repo_owned);

        return ReleaseContext{
            .allocator = allocator,
            .tag = tag_owned,
            .release_page_url = rpu_owned,
            .repo_url = repo_url,
            .github = .{ .owner = owner_owned, .repo = repo_owned },
            .asset_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Parse a manifest JSON file and build a ReleaseContext.
    ///
    /// Expected JSON format:
    /// ```json
    /// {
    ///   "tag": "v1.2.3",
    ///   "release_page_url": "https://example.com/releases/v1.2.3",
    ///   "repo_url": "https://github.com/owner/repo",
    ///   "assets": [
    ///     { "name": "foo-v1.2.3-linux-x86_64.tar.gz", "url": "https://..." }
    ///   ]
    /// }
    /// ```
    /// All fields are required. `assets` may be an empty array.
    pub fn fromManifest(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) ReleaseContextError!ReleaseContext {
        const content = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            allocator,
            .limited(1024 * 1024),
        ) catch return error.ReadError;
        defer allocator.free(content);

        return fromManifestJson(allocator, content);
    }

    /// Parse a manifest from an in-memory JSON string.  Exposed separately
    /// so unit tests can avoid touching the filesystem.
    pub fn fromManifestJson(
        allocator: std.mem.Allocator,
        json: []const u8,
    ) ReleaseContextError!ReleaseContext {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json,
            .{},
        ) catch return error.InvalidManifest;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return error.InvalidManifest,
        };

        const tag_raw = (root.get("tag") orelse return error.InvalidManifest).string;
        const rpu_raw = (root.get("release_page_url") orelse return error.InvalidManifest).string;
        const ru_raw = (root.get("repo_url") orelse return error.InvalidManifest).string;

        const tag = try allocator.dupe(u8, tag_raw);
        errdefer allocator.free(tag);
        const rpu = try allocator.dupe(u8, rpu_raw);
        errdefer allocator.free(rpu);
        const ru = try allocator.dupe(u8, ru_raw);
        errdefer allocator.free(ru);

        var asset_map = std.StringHashMap([]const u8).init(allocator);
        errdefer {
            var it = asset_map.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            asset_map.deinit();
        }

        if (root.get("assets")) |assets_val| {
            const assets = switch (assets_val) {
                .array => |a| a,
                else => return error.InvalidManifest,
            };
            for (assets.items) |item| {
                const obj = switch (item) {
                    .object => |o| o,
                    else => return error.InvalidManifest,
                };
                const name_raw = (obj.get("name") orelse return error.InvalidManifest).string;
                const url_raw = (obj.get("url") orelse return error.InvalidManifest).string;

                const name = try allocator.dupe(u8, name_raw);
                errdefer allocator.free(name);
                const url = try allocator.dupe(u8, url_raw);
                errdefer allocator.free(url);

                try asset_map.put(name, url);
            }
        }

        return ReleaseContext{
            .allocator = allocator,
            .tag = tag,
            .release_page_url = rpu,
            .repo_url = ru,
            .github = null,
            .asset_map = asset_map,
        };
    }

    // -----------------------------------------------------------------------
    // Accessors
    // -----------------------------------------------------------------------

    /// Return an allocated download URL for `name`.
    ///
    /// Lookup order:
    ///   1. `asset_map` (manifest entries take precedence)
    ///   2. GitHub formula: `https://github.com/{owner}/{repo}/releases/download/{tag}/{name}`
    ///
    /// Returns `error.AssetNotFound` if neither source can supply a URL.
    /// The returned slice is owned by the caller and must be freed.
    pub fn assetUrl(
        self: *const ReleaseContext,
        allocator: std.mem.Allocator,
        name: []const u8,
    ) ReleaseContextError![]const u8 {
        if (self.asset_map.get(name)) |url| {
            return allocator.dupe(u8, url);
        }
        if (self.github) |gh| {
            return std.fmt.allocPrint(
                allocator,
                "https://github.com/{s}/{s}/releases/download/{s}/{s}",
                .{ gh.owner, gh.repo, self.tag, name },
            );
        }
        log.warn("assetUrl: '{s}' not found in manifest and no GitHub source configured", .{name});
        return error.AssetNotFound;
    }

    /// Return an allocated git clone URL for the repository (`repo_url` + `.git`).
    /// Used by Homebrew for the `head` URL.
    /// The returned slice is owned by the caller and must be freed.
    pub fn repoGitUrl(
        self: *const ReleaseContext,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}.git", .{self.repo_url});
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Free all memory owned by this context.
    pub fn deinit(self: *ReleaseContext) void {
        self.allocator.free(self.tag);
        self.allocator.free(self.release_page_url);
        self.allocator.free(self.repo_url);
        if (self.github) |gh| {
            self.allocator.free(gh.owner);
            self.allocator.free(gh.repo);
        }
        var it = self.asset_map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.asset_map.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ReleaseContext.fromGitHub computes asset URL" {
    const allocator = std.testing.allocator;

    var ctx = try ReleaseContext.fromGitHub(
        allocator,
        "acme",
        "myapp",
        "v1.2.3",
        "https://github.com/acme/myapp/releases/tag/v1.2.3",
    );
    defer ctx.deinit();

    try std.testing.expectEqualStrings("v1.2.3", ctx.tag);
    try std.testing.expectEqualStrings("https://github.com/acme/myapp", ctx.repo_url);
    try std.testing.expectEqualStrings("acme", ctx.github.?.owner);

    const url = try ctx.assetUrl(allocator, "myapp-v1.2.3-linux-x86_64.tar.gz");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/acme/myapp/releases/download/v1.2.3/myapp-v1.2.3-linux-x86_64.tar.gz",
        url,
    );
}

test "ReleaseContext.fromGitHub repoGitUrl appends .git" {
    const allocator = std.testing.allocator;

    var ctx = try ReleaseContext.fromGitHub(
        allocator,
        "acme",
        "myapp",
        "v1.0.0",
        "https://github.com/acme/myapp/releases/tag/v1.0.0",
    );
    defer ctx.deinit();

    const git_url = try ctx.repoGitUrl(allocator);
    defer allocator.free(git_url);
    try std.testing.expectEqualStrings("https://github.com/acme/myapp.git", git_url);
}

test "ReleaseContext.fromManifestJson parses and resolves URLs" {
    const allocator = std.testing.allocator;

    const json =
        \\{
        \\  "tag": "v2.0.0",
        \\  "release_page_url": "https://example.com/releases/v2.0.0",
        \\  "repo_url": "https://example.com/acme/myapp",
        \\  "assets": [
        \\    { "name": "myapp-v2.0.0-linux-x86_64.tar.gz", "url": "https://cdn.example.com/myapp-v2.0.0-linux.tar.gz" },
        \\    { "name": "myapp-v2.0.0-windows-x86_64.zip",  "url": "https://cdn.example.com/myapp-v2.0.0-windows.zip" }
        \\  ]
        \\}
    ;

    var ctx = try ReleaseContext.fromManifestJson(allocator, json);
    defer ctx.deinit();

    try std.testing.expectEqualStrings("v2.0.0", ctx.tag);
    try std.testing.expectEqualStrings("https://example.com/releases/v2.0.0", ctx.release_page_url);
    try std.testing.expectEqualStrings("https://example.com/acme/myapp", ctx.repo_url);
    try std.testing.expectEqual(null, ctx.github);

    const linux_url = try ctx.assetUrl(allocator, "myapp-v2.0.0-linux-x86_64.tar.gz");
    defer allocator.free(linux_url);
    try std.testing.expectEqualStrings("https://cdn.example.com/myapp-v2.0.0-linux.tar.gz", linux_url);

    const win_url = try ctx.assetUrl(allocator, "myapp-v2.0.0-windows-x86_64.zip");
    defer allocator.free(win_url);
    try std.testing.expectEqualStrings("https://cdn.example.com/myapp-v2.0.0-windows.zip", win_url);
}

test "ReleaseContext.fromManifestJson rejects malformed input" {
    const allocator = std.testing.allocator;

    // Missing required fields
    try std.testing.expectError(
        error.InvalidManifest,
        ReleaseContext.fromManifestJson(allocator, "{}"),
    );

    // Missing repo_url
    try std.testing.expectError(
        error.InvalidManifest,
        ReleaseContext.fromManifestJson(allocator,
            \\{ "tag": "v1.0.0", "release_page_url": "https://x.com" }
        ),
    );

    // Not an object
    try std.testing.expectError(
        error.InvalidManifest,
        ReleaseContext.fromManifestJson(allocator, "[]"),
    );
}

test "ReleaseContext.assetUrl returns AssetNotFound for manifest source with missing asset" {
    const allocator = std.testing.allocator;

    const json =
        \\{ "tag": "v1.0.0", "release_page_url": "https://x.com/r/v1.0.0", "repo_url": "https://x.com/r", "assets": [] }
    ;

    var ctx = try ReleaseContext.fromManifestJson(allocator, json);
    defer ctx.deinit();

    try std.testing.expectError(
        error.AssetNotFound,
        ctx.assetUrl(allocator, "not-in-manifest.tar.gz"),
    );
}

test "ReleaseContext asset_map overrides GitHub formula" {
    const allocator = std.testing.allocator;

    // GitHub source, but with an explicit map entry overriding the formula.
    var ctx = try ReleaseContext.fromGitHub(
        allocator,
        "acme",
        "myapp",
        "v1.0.0",
        "https://github.com/acme/myapp/releases/tag/v1.0.0",
    );
    defer ctx.deinit();

    // Manually insert an override (simulates what fromManifest would do).
    const k = try allocator.dupe(u8, "myapp-v1.0.0-linux-x86_64.tar.gz");
    const v = try allocator.dupe(u8, "https://cdn.custom.com/myapp.tar.gz");
    try ctx.asset_map.put(k, v);

    const url = try ctx.assetUrl(allocator, "myapp-v1.0.0-linux-x86_64.tar.gz");
    defer allocator.free(url);
    // Should return the map entry, NOT the GitHub formula.
    try std.testing.expectEqualStrings("https://cdn.custom.com/myapp.tar.gz", url);
}
