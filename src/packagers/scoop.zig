const std = @import("std");

/// Configuration for generating a Scoop manifest.
pub const ScoopConfig = struct {
    /// Project name (e.g. "takeoff")
    project_name: []const u8,
    /// Version string (e.g. "1.0.0")
    version: []const u8,
    /// Short description of the project
    description: []const u8,
    /// Project homepage URL
    homepage: []const u8,
    /// SPDX license identifier
    license: []const u8,
    /// GitHub download URL for 64-bit zip
    url_64bit: []const u8,
    /// SHA-256 hash of the 64-bit zip
    sha256_64bit: []const u8,
    /// GitHub download URL for ARM64 zip (optional)
    url_arm64: ?[]const u8 = null,
    /// SHA-256 hash of the ARM64 zip (required if url_arm64 is set)
    sha256_arm64: ?[]const u8 = null,
    /// Binary name inside the zip (e.g. "takeoff.exe")
    binary_name: []const u8,
    /// Where to write the generated manifest JSON
    output_path: []const u8,
};

/// Generate a Scoop manifest JSON file.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: ScoopConfig,
) !void {
    const manifest = try renderManifest(allocator, cfg);
    defer allocator.free(manifest);

    const parent_dir = std.fs.path.dirname(cfg.output_path) orelse ".";
    if (parent_dir.len > 0 and !std.mem.eql(u8, parent_dir, ".")) {
        std.Io.Dir.cwd().createDirPath(io, parent_dir) catch {};
    }

    const file = try std.Io.Dir.cwd().createFile(io, cfg.output_path, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, manifest);
}

/// Render a Scoop manifest as a JSON string.
pub fn renderManifest(
    allocator: std.mem.Allocator,
    cfg: ScoopConfig,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const hash_64 = try std.fmt.allocPrint(a, "sha256:{s}", .{cfg.sha256_64bit});
    const au_url_64 = try buildAutoupdateUrl(a, cfg.url_64bit, cfg.version);
    const au_hash_url = try buildAutoupdateHashUrl(a, cfg.homepage);

    const arm64_block: []const u8 = if (cfg.url_arm64) |url| blk: {
        const hash_arm = try std.fmt.allocPrint(a, "sha256:{s}", .{cfg.sha256_arm64 orelse ""});
        break :blk try std.fmt.allocPrint(a,
            \\,
            \\        "arm64": {{
            \\            "url": "{s}",
            \\            "hash": "{s}"
            \\        }}
        , .{ url, hash_arm });
    } else "";

    const au_arm64_block: []const u8 = if (cfg.url_arm64) |url| blk: {
        const au_url = try buildAutoupdateUrl(a, url, cfg.version);
        break :blk try std.fmt.allocPrint(a,
            \\,
            \\                "arm64": {{
            \\                    "url": "{s}"
            \\                }}
        , .{au_url});
    } else "";

    return try std.fmt.allocPrint(allocator,
        \\{{
        \\    "version": "{s}",
        \\    "description": "{s}",
        \\    "homepage": "{s}",
        \\    "license": "{s}",
        \\    "architecture": {{
        \\        "64bit": {{
        \\            "url": "{s}",
        \\            "hash": "{s}"
        \\        }}{s}
        \\    }},
        \\    "bin": "{s}",
        \\    "checkver": {{
        \\        "github": "{s}"
        \\    }},
        \\    "autoupdate": {{
        \\        "architecture": {{
        \\            "64bit": {{
        \\                "url": "{s}"
        \\            }}{s}
        \\        }},
        \\        "hash": {{
        \\            "url": "{s}"
        \\        }}
        \\    }}
        \\}}
    , .{
        cfg.version,
        cfg.description,
        cfg.homepage,
        cfg.license,
        cfg.url_64bit,
        hash_64,
        arm64_block,
        cfg.binary_name,
        cfg.homepage,
        au_url_64,
        au_arm64_block,
        au_hash_url,
    });
}

/// Transform a release URL into an autoupdate URL template with $version.
/// e.g. ".../download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip"
///   -> ".../download/v$version/takeoff-$version-windows-x86_64.zip"
fn buildAutoupdateUrl(allocator: std.mem.Allocator, release_url: []const u8, version: []const u8) ![]const u8 {
    // Replace all occurrences of the version string with $version
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var remaining = release_url;
    while (std.mem.indexOf(u8, remaining, version)) |idx| {
        try result.appendSlice(allocator, remaining[0..idx]);
        try result.appendSlice(allocator, "$version");
        remaining = remaining[idx + version.len ..];
    }
    try result.appendSlice(allocator, remaining);

    return try result.toOwnedSlice(allocator);
}

/// Build the autoupdate hash URL from the project homepage.
fn buildAutoupdateHashUrl(allocator: std.mem.Allocator, homepage: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}/releases/download/v$version/checksums.sha256",
        .{homepage},
    );
}

test "renderManifest generates valid JSON with 64bit only" {
    const cfg = ScoopConfig{
        .project_name = "takeoff",
        .version = "1.0.0",
        .description = "Release automation for Zig projects",
        .homepage = "https://github.com/vmvarela/takeoff",
        .license = "MIT",
        .url_64bit = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip",
        .sha256_64bit = "abc123def456",
        .binary_name = "takeoff.exe",
        .output_path = "test.json",
    };

    const json = try renderManifest(std.testing.allocator, cfg);
    defer std.testing.allocator.free(json);

    // Verify key content is present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\": \"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"description\": \"Release automation for Zig projects\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"homepage\": \"https://github.com/vmvarela/takeoff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"license\": \"MIT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bin\": \"takeoff.exe\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sha256:abc123def456\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"checkver\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"autoupdate\"") != null);

    // arm64 should NOT be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"arm64\"") == null);

    // Autoupdate URL should have $version (in both path and filename)
    try std.testing.expect(std.mem.indexOf(u8, json, "v$version") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "$version-windows-x86_64") != null);
}

test "renderManifest includes arm64 when both architectures provided" {
    const cfg = ScoopConfig{
        .project_name = "takeoff",
        .version = "1.0.0",
        .description = "Release automation for Zig projects",
        .homepage = "https://github.com/vmvarela/takeoff",
        .license = "MIT",
        .url_64bit = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip",
        .sha256_64bit = "abc123",
        .url_arm64 = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-arm64.zip",
        .sha256_arm64 = "def456",
        .binary_name = "takeoff.exe",
        .output_path = "test.json",
    };

    const json = try renderManifest(std.testing.allocator, cfg);
    defer std.testing.allocator.free(json);

    // arm64 should be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"arm64\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "takeoff-1.0.0-windows-arm64.zip") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sha256:def456\"") != null);
}

test "renderManifest includes checkver and autoupdate sections" {
    const cfg = ScoopConfig{
        .project_name = "takeoff",
        .version = "2.0.0",
        .description = "Test project",
        .homepage = "https://github.com/test/project",
        .license = "Apache-2.0",
        .url_64bit = "https://github.com/test/project/releases/download/v2.0.0/project-2.0.0-windows-x86_64.zip",
        .sha256_64bit = "deadbeef",
        .binary_name = "project.exe",
        .output_path = "test.json",
    };

    const json = try renderManifest(std.testing.allocator, cfg);
    defer std.testing.allocator.free(json);

    // checkver with github
    try std.testing.expect(std.mem.indexOf(u8, json, "\"checkver\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"github\": \"https://github.com/test/project\"") != null);

    // autoupdate with hash URL
    try std.testing.expect(std.mem.indexOf(u8, json, "\"autoupdate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "checksums.sha256") != null);
}
