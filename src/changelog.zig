const std = @import("std");

const log = std.log.scoped(.changelog);

/// Error set for changelog operations.
pub const ChangelogError = error{
    FileNotFound,
    ReadError,
    ParseError,
    InvalidVersion,
} || std.mem.Allocator.Error;

/// Extract release notes for a specific version from CHANGELOG.md.
/// Supports multiple common changelog formats:
/// - ## [v1.0.0]
/// - ## [1.0.0]
/// - ## v1.0.0
/// - ## 1.0.0
/// - ## [v1.0.0] - 2024-01-01
/// - ## [1.0.0] - 2024-01-01
///
/// Returns null if the version is not found.
/// Caller owns the returned memory.
pub fn extractVersionNotes(
    allocator: std.mem.Allocator,
    io: std.Io,
    changelog_path: []const u8,
    version: []const u8,
) ChangelogError!?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, changelog_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            log.debug("changelog not found: {s}", .{changelog_path});
            return null;
        }
        log.err("failed to open changelog: {}", .{err});
        return error.ReadError;
    };
    defer allocator.free(content);

    return try extractNotesFromContent(allocator, content, version);
}

/// Extract notes from changelog content.
/// Caller owns the returned memory.
fn extractNotesFromContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    version: []const u8,
) ChangelogError!?[]const u8 {
    // Find the section header for this version
    const header_patterns = [_][]const u8{
        try std.fmt.allocPrint(allocator, "## [{s}]", .{version}),
        try std.fmt.allocPrint(allocator, "## {s}", .{version}),
    };
    defer {
        for (header_patterns) |pattern| allocator.free(pattern);
    }

    var section_start: ?usize = null;
    var pattern_used: []const u8 = "";

    for (header_patterns) |pattern| {
        if (std.mem.indexOf(u8, content, pattern)) |pos| {
            section_start = pos;
            pattern_used = pattern;
            break;
        }
    }

    if (section_start == null) {
        // Try without 'v' prefix if version starts with 'v'
        if (std.mem.startsWith(u8, version, "v")) {
            const version_without_v = version[1..];
            const alt_pattern = try std.fmt.allocPrint(
                allocator,
                "## [{s}]",
                .{version_without_v},
            );
            defer allocator.free(alt_pattern);

            if (std.mem.indexOf(u8, content, alt_pattern)) |pos| {
                section_start = pos;
                pattern_used = alt_pattern;
            }
        }

        // Try with 'v' prefix if version doesn't start with 'v'
        if (section_start == null and !std.mem.startsWith(u8, version, "v")) {
            const alt_pattern = try std.fmt.allocPrint(
                allocator,
                "## [v{s}]",
                .{version},
            );
            defer allocator.free(alt_pattern);

            if (std.mem.indexOf(u8, content, alt_pattern)) |pos| {
                section_start = pos;
                pattern_used = alt_pattern;
            }
        }
    }

    if (section_start == null) {
        log.debug("version {s} not found in changelog", .{version});
        return null;
    }

    // Find the start of content (after the header line)
    var content_start = section_start.? + pattern_used.len;

    // Skip the date suffix if present (e.g., " - 2024-01-01")
    if (content_start < content.len and content[content_start] == ' ') {
        const line_end = std.mem.indexOfScalar(u8, content[content_start..], '\n') orelse
            content.len - content_start;
        content_start += line_end;
    }

    // Skip to next line
    if (content_start < content.len and content[content_start] == '\n') {
        content_start += 1;
    }
    if (content_start < content.len and content[content_start] == '\r') {
        content_start += 1;
    }

    // Find the end of this section (next ## header or end of file)
    const section_end = blk: {
        const next_header = std.mem.indexOf(u8, content[content_start..], "\n##");
        if (next_header) |pos| {
            break :blk content_start + pos;
        }
        break :blk content.len;
    };

    // Extract the section content
    const section_content = std.mem.trim(u8, content[content_start..section_end], " \n\r\t");

    if (section_content.len == 0) {
        return null;
    }

    return try allocator.dupe(u8, section_content);
}

/// Find all artifact files in the dist directory.
/// Caller owns the returned array and its contents.
pub fn findArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    dist_dir: []const u8,
) ChangelogError![][]const u8 {
    var artifacts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (artifacts.items) |item| allocator.free(item);
        artifacts.deinit(allocator);
    }

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dist_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            log.debug("dist directory not found: {s}", .{dist_dir});
            return artifacts.toOwnedSlice(allocator);
        }
        log.err("failed to open dist directory: {}", .{err});
        return error.FileNotFound;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch |err| {
        log.err("failed to iterate dist directory: {}", .{err});
        return error.ReadError;
    }) |entry| {
        if (entry.kind != .file) continue;

        // Include package files and checksums
        if (isArtifactFile(entry.name)) {
            const path = try std.fs.path.join(allocator, &.{ dist_dir, entry.name });
            try artifacts.append(allocator, path);
        }
    }

    return artifacts.toOwnedSlice(allocator);
}

/// Check if a filename is an artifact file.
fn isArtifactFile(filename: []const u8) bool {
    // Include tar.gz, zip, and checksum files
    const extensions = [_][]const u8{
        ".tar.gz",
        ".tgz",
        ".zip",
        "-sha256.txt",
        "-blake3.txt",
        "-checksums.txt",
    };

    for (extensions) |ext| {
        if (std.mem.endsWith(u8, filename, ext)) return true;
    }

    // Also check for checksums-sha256.txt, checksums-blake3.txt patterns
    if (std.mem.startsWith(u8, filename, "checksums-")) return true;

    return false;
}

/// Free memory for artifact list.
pub fn freeArtifacts(allocator: std.mem.Allocator, artifacts: [][]const u8) void {
    for (artifacts) |artifact| {
        allocator.free(artifact);
    }
    allocator.free(artifacts);
}

test "extractNotesFromContent finds version with brackets" {
    const allocator = std.testing.allocator;

    const content =
        \\# Changelog
        \\
        \\
        \\## [v1.0.0]
        \\
        \\- First release
        \\- Initial features
        \\
        \\
        \\## [v0.9.0]
        \\
        \\- Beta release
        \\
    ;

    const notes = try extractNotesFromContent(allocator, content, "v1.0.0");
    defer if (notes) |n| allocator.free(n);

    try std.testing.expect(notes != null);
    try std.testing.expectEqualStrings("- First release\n- Initial features", notes.?);
}

test "extractNotesFromContent finds version without brackets" {
    const allocator = std.testing.allocator;

    const content =
        \\# Changelog
        \\
        \\
        \\## v1.0.0
        \\
        \\- First release
        \\
    ;

    const notes = try extractNotesFromContent(allocator, content, "v1.0.0");
    defer if (notes) |n| allocator.free(n);

    try std.testing.expect(notes != null);
    try std.testing.expectEqualStrings("- First release", notes.?);
}

test "extractNotesFromContent handles version with date" {
    const allocator = std.testing.allocator;

    const content =
        \\# Changelog
        \\
        \\
        \\## [v1.0.0] - 2024-01-15
        \\
        \\- First release
        \\
    ;

    const notes = try extractNotesFromContent(allocator, content, "v1.0.0");
    defer if (notes) |n| allocator.free(n);

    try std.testing.expect(notes != null);
    try std.testing.expectEqualStrings("- First release", notes.?);
}

test "extractNotesFromContent returns null for missing version" {
    const allocator = std.testing.allocator;

    const content =
        \\# Changelog
        \\
        \\
        \\## [v1.0.0]
        \\
        \\- First release
        \\
    ;

    const notes = try extractNotesFromContent(allocator, content, "v2.0.0");
    defer if (notes) |n| allocator.free(n);

    try std.testing.expect(notes == null);
}

test "extractNotesFromContent handles v prefix matching" {
    const allocator = std.testing.allocator;

    const content =
        \\# Changelog
        \\
        \\
        \\## [1.0.0]
        \\
        \\- First release
        \\
    ;

    // Should match version "v1.0.0" to "## [1.0.0]"
    const notes = try extractNotesFromContent(allocator, content, "v1.0.0");
    defer if (notes) |n| allocator.free(n);

    try std.testing.expect(notes != null);
}

test "isArtifactFile recognizes artifact extensions" {
    try std.testing.expect(isArtifactFile("package.tar.gz"));
    try std.testing.expect(isArtifactFile("package.tgz"));
    try std.testing.expect(isArtifactFile("package.zip"));
    try std.testing.expect(isArtifactFile("checksums-sha256.txt"));
    try std.testing.expect(isArtifactFile("checksums-blake3.txt"));
    try std.testing.expect(!isArtifactFile("main.zig"));
    try std.testing.expect(!isArtifactFile("README.md"));
}
