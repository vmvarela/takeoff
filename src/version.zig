const std = @import("std");

const changelog = @import("changelog.zig");

const log = std.log.scoped(.version);

/// Error set for version operations.
pub const VersionError = error{
    InvalidVersion,
    FileNotFound,
    ReadError,
    WriteError,
    ParseError,
    VersionMismatch,
} || std.mem.Allocator.Error;

/// Semantic version bump type.
pub const BumpType = enum { major, minor, patch };

/// Options for the bump operation.
pub const BumpOptions = struct {
    /// Explicit version to set (overrides bump_type).
    version: ?[]const u8 = null,
    /// Semantic bump type when no explicit version is given.
    /// null = auto-detect from CHANGELOG.md latest entry.
    bump_type: ?BumpType = null,
    /// Show what would be done without writing files.
    dry_run: bool = false,
    /// Path to CHANGELOG.md.
    changelog_path: []const u8 = "CHANGELOG.md",
    /// Path to build.zig.zon.
    zon_path: []const u8 = "build.zig.zon",
};

/// Result of a bump operation.
pub const BumpResult = struct {
    old_version: []const u8,
    new_version: []const u8,
    zon_updated: bool,
    changelog_has_section: bool,

    pub fn deinit(self: BumpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.old_version);
        allocator.free(self.new_version);
    }
};

/// Parse a version string "X.Y.Z" into a triplet.
/// Strips optional 'v' prefix.
pub fn parseVersion(version: []const u8) VersionError![3]u32 {
    var v = version;
    if (std.mem.startsWith(u8, v, "v")) v = v[1..];

    var parts: [3]u32 = .{ 0, 0, 0 };
    var iter = std.mem.splitScalar(u8, v, '.');

    var i: usize = 0;
    while (iter.next()) |part| : (i += 1) {
        if (i >= 3) return error.InvalidVersion;
        parts[i] = std.fmt.parseInt(u32, part, 10) catch return error.InvalidVersion;
    }
    if (i == 0) return error.InvalidVersion;

    return parts;
}

/// Format a version triplet into a string "X.Y.Z".
/// Caller owns the returned memory.
pub fn formatVersion(allocator: std.mem.Allocator, v: [3]u32) VersionError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{ v[0], v[1], v[2] });
}

/// Bump a version triplet by the given type.
pub fn bumpVersionTriplet(v: [3]u32, bump: BumpType) [3]u32 {
    return switch (bump) {
        .major => .{ v[0] + 1, 0, 0 },
        .minor => .{ v[0], v[1] + 1, 0 },
        .patch => .{ v[0], v[1], v[2] + 1 },
    };
}

/// Read the current version from build.zig.zon.
/// The format is expected to contain: .version = "X.Y.Z"
/// Caller owns the returned memory.
pub fn readZonVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    zon_path: []const u8,
) VersionError![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, zon_path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        log.err("failed to read zon file: {}", .{err});
        return error.ReadError;
    };
    defer allocator.free(content);

    return try extractVersionFromZon(allocator, content);
}

/// Extract version string from build.zig.zon content.
/// Caller owns the returned memory.
fn extractVersionFromZon(
    allocator: std.mem.Allocator,
    content: []const u8,
) VersionError![]const u8 {
    // Look for .version = "X.Y.Z"
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, content, marker) orelse {
        log.err("no .version field found in zon file", .{});
        return error.ParseError;
    };

    const value_start = start + marker.len;
    const end = std.mem.indexOfScalar(u8, content[value_start..], '"') orelse {
        log.err("unterminated version string in zon file", .{});
        return error.ParseError;
    };

    return try allocator.dupe(u8, content[value_start .. value_start + end]);
}

/// Update the version in build.zig.zon.
/// Reads the file, replaces the version string, writes it back.
pub fn updateZonVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    zon_path: []const u8,
    new_version: []const u8,
) VersionError!void {
    const cwd = std.Io.Dir.cwd();

    // Read current content
    const content = cwd.readFileAlloc(io, zon_path, allocator, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.FileNotFound;
        log.err("failed to read zon file for update: {}", .{err});
        return error.ReadError;
    };
    defer allocator.free(content);

    // Find and replace the version string
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, content, marker) orelse return error.ParseError;
    const value_start = start + marker.len;
    const end = std.mem.indexOfScalar(u8, content[value_start..], '"') orelse return error.ParseError;

    // Build new content
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    try result.appendSlice(allocator, content[0..value_start]);
    try result.appendSlice(allocator, new_version);
    try result.appendSlice(allocator, content[value_start + end ..]);

    // Write back
    cwd.writeFile(io, .{ .sub_path = zon_path, .data = result.items }) catch |err| {
        log.err("failed to write zon file: {}", .{err});
        return error.WriteError;
    };

    log.info("updated {s} version to {s}", .{ zon_path, new_version });
}

/// Check if CHANGELOG.md has an entry for the given version.
pub fn changelogHasVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    changelog_path: []const u8,
    version: []const u8,
) VersionError!bool {
    const notes = changelog.extractVersionNotes(allocator, io, changelog_path, version) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    if (notes) |n| {
        allocator.free(n);
        return true;
    }
    return false;
}

/// Get the latest version from CHANGELOG.md (first ## header).
/// Returns the version string without 'v' prefix if present.
/// Caller owns the returned memory.
pub fn getLatestChangelogVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    changelog_path: []const u8,
) VersionError!?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, changelog_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return null;
        log.err("failed to read changelog: {}", .{err});
        return error.ReadError;
    };
    defer allocator.free(content);

    // Find first "## [" header
    var line_start: usize = 0;
    while (line_start < content.len) {
        const remaining = content[line_start..];
        const line_end_rel = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
        const line = remaining[0..line_end_rel];

        // Match "## [vX.Y.Z]" or "## [X.Y.Z]" or "## vX.Y.Z" or "## X.Y.Z"
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            const after_hash = std.mem.trim(u8, trimmed[2..], " \t");
            var version_str = after_hash;

            // Strip brackets if present
            if (std.mem.startsWith(u8, version_str, "[")) {
                const close = std.mem.indexOfScalar(u8, version_str, ']') orelse {
                    line_start = line_start + line_end_rel + 1;
                    continue;
                };
                version_str = version_str[1..close];
            }

            // Strip 'v' prefix if present
            if (std.mem.startsWith(u8, version_str, "v")) {
                version_str = version_str[1..];
            }

            // Validate it looks like a version
            if (parseVersion(version_str)) |parsed| {
                _ = parsed;
                return try allocator.dupe(u8, version_str);
            } else |_| {
                // Not a version line, continue
                line_start = line_start + line_end_rel + 1;
                continue;
            }
        }

        line_start = line_start + line_end_rel + 1;
    }

    return null;
}

/// Main bump operation.
///
/// Strategy:
/// 1. If explicit version given, use it.
/// 2. Otherwise, read current version from build.zig.zon and bump.
/// 3. Verify CHANGELOG.md has an entry for the new version.
/// 4. Update build.zig.zon.
pub fn bumpVersion(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: BumpOptions,
) VersionError!BumpResult {
    // Determine new version
    const new_version: []const u8 = if (opts.version) |v|
        try allocator.dupe(u8, v)
    else blk: {
        const current = try readZonVersion(allocator, io, opts.zon_path);
        defer allocator.free(current);

        const triplet = try parseVersion(current);
        const bump_type = opts.bump_type orelse .patch;
        const new_triplet = bumpVersionTriplet(triplet, bump_type);
        break :blk try formatVersion(allocator, new_triplet);
    };
    defer allocator.free(new_version);

    // Read old version for reporting
    const old_version = try readZonVersion(allocator, io, opts.zon_path);

    // Check changelog has entry for new version
    const has_changelog = try changelogHasVersion(allocator, io, opts.changelog_path, new_version);

    if (opts.dry_run) {
        log.info("dry-run: would bump {s} -> {s}", .{ old_version, new_version });
        log.info("dry-run: changelog entry for {s}: {}", .{ new_version, has_changelog });
        return BumpResult{
            .old_version = old_version,
            .new_version = try allocator.dupe(u8, new_version),
            .zon_updated = false,
            .changelog_has_section = has_changelog,
        };
    }

    if (!has_changelog) {
        log.warn("no changelog entry found for version {s}", .{new_version});
        // We still proceed — the user may want to add the entry later.
    }

    // Update build.zig.zon
    try updateZonVersion(allocator, io, opts.zon_path, new_version);

    return BumpResult{
        .old_version = old_version,
        .new_version = try allocator.dupe(u8, new_version),
        .zon_updated = true,
        .changelog_has_section = has_changelog,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parseVersion parses simple version" {
    const v = try parseVersion("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 3), v[2]);
}

test "parseVersion strips v prefix" {
    const v = try parseVersion("v0.2.0");
    try std.testing.expectEqual(@as(u32, 0), v[0]);
    try std.testing.expectEqual(@as(u32, 2), v[1]);
    try std.testing.expectEqual(@as(u32, 0), v[2]);
}

test "parseVersion rejects empty string" {
    try std.testing.expectError(error.InvalidVersion, parseVersion(""));
}

test "parseVersion rejects non-numeric" {
    try std.testing.expectError(error.InvalidVersion, parseVersion("a.b.c"));
}

test "formatVersion formats triplet" {
    const allocator = std.testing.allocator;
    const s = try formatVersion(allocator, .{ 0, 2, 0 });
    defer allocator.free(s);
    try std.testing.expectEqualStrings("0.2.0", s);
}

test "bumpVersionTriplet bumps major" {
    const r = bumpVersionTriplet(.{ 1, 2, 3 }, .major);
    try std.testing.expectEqual(@as(u32, 2), r[0]);
    try std.testing.expectEqual(@as(u32, 0), r[1]);
    try std.testing.expectEqual(@as(u32, 0), r[2]);
}

test "bumpVersionTriplet bumps minor" {
    const r = bumpVersionTriplet(.{ 1, 2, 3 }, .minor);
    try std.testing.expectEqual(@as(u32, 1), r[0]);
    try std.testing.expectEqual(@as(u32, 3), r[1]);
    try std.testing.expectEqual(@as(u32, 0), r[2]);
}

test "bumpVersionTriplet bumps patch" {
    const r = bumpVersionTriplet(.{ 1, 2, 3 }, .patch);
    try std.testing.expectEqual(@as(u32, 1), r[0]);
    try std.testing.expectEqual(@as(u32, 2), r[1]);
    try std.testing.expectEqual(@as(u32, 4), r[2]);
}

test "extractVersionFromZon parses version" {
    const allocator = std.testing.allocator;
    const content =
        \\.{
        \\    .name = .takeoff,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x700432851e8b7674,
        \\}
    ;
    const v = try extractVersionFromZon(allocator, content);
    defer allocator.free(v);
    try std.testing.expectEqualStrings("0.1.0", v);
}

test "updateZonVersion updates version in temp file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zon_content =
        \\.{
        \\    .name = .takeoff,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x700432851e8b7674,
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.zon", .data = zon_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    try updateZonVersion(allocator, io, "test.zon", "0.2.0");

    const updated = try tmp.dir.readFileAlloc(io, "test.zon", allocator, .limited(64 * 1024));
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, ".version = \"0.2.0\"") != null);
}

test "readZonVersion reads from temp file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zon_content =
        \\.{
        \\    .name = .takeoff,
        \\    .version = "1.5.3",
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.zon", .data = zon_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const v = try readZonVersion(allocator, io, "test.zon");
    defer allocator.free(v);
    try std.testing.expectEqualStrings("1.5.3", v);
}

test "changelogHasVersion detects existing version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const changelog_content =
        \\# Changelog
        \\
        \\## [v0.2.0] - 2026-03-31
        \\
        \\- New feature
        \\
        \\## [v0.1.0] - 2026-03-29
        \\
        \\- Initial release
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = changelog_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const has = try changelogHasVersion(allocator, io, "CHANGELOG.md", "v0.2.0");
    try std.testing.expect(has);

    const missing = try changelogHasVersion(allocator, io, "CHANGELOG.md", "v9.9.9");
    try std.testing.expect(!missing);
}

test "getLatestChangelogVersion finds first version" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const changelog_content =
        \\# Changelog
        \\
        \\## [v0.2.0] - 2026-03-31
        \\
        \\- New feature
        \\
        \\## [v0.1.0] - 2026-03-29
        \\
        \\- Initial release
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = changelog_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const v = try getLatestChangelogVersion(allocator, io, "CHANGELOG.md");
    defer if (v) |ver| allocator.free(ver);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("0.2.0", v.?);
}

test "getLatestChangelogVersion handles no brackets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const changelog_content =
        \\# Changelog
        \\
        \\## v1.0.0
        \\
        \\- Release
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = changelog_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const v = try getLatestChangelogVersion(allocator, io, "CHANGELOG.md");
    defer if (v) |ver| allocator.free(ver);
    try std.testing.expect(v != null);
    try std.testing.expectEqualStrings("1.0.0", v.?);
}

test "getLatestChangelogVersion returns null for empty changelog" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "CHANGELOG.md", .data = "# Changelog\n\nNo versions yet.\n" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const v = try getLatestChangelogVersion(allocator, io, "CHANGELOG.md");
    defer if (v) |ver| allocator.free(ver);
    try std.testing.expect(v == null);
}
