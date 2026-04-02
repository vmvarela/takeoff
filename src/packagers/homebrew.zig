//! Homebrew formula generator — produces a valid Ruby `.rb` formula file
//! entirely in Zig, without requiring `brew` or any other external tool.
//!
//! The formula references the tarball URL and sha256 from the release
//! artifacts, supports `head` installation, and installs man pages and
//! shell completions when available.
//!
//! Format reference:
//!   - https://docs.brew.sh/Formula-Cookbook
//!   - https://rubydoc.brew.sh/Formula

const std = @import("std");

const log = std.log.scoped(.homebrew);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Error set for Homebrew formula generation.
pub const HomebrewError = error{
    WriteError,
    ReadError,
    InvalidConfig,
    ArtifactNotFound,
} || std.mem.Allocator.Error;

/// Configuration for generating a single Homebrew formula.
pub const HomebrewConfig = struct {
    /// Formula class name (e.g. "Takeoff"). Capitalised by convention.
    formula_name: []const u8,
    /// Project binary name (installed to /opt/homebrew/bin/<name>).
    project_name: []const u8,
    /// Version string (e.g. "0.2.0").
    version: []const u8,
    /// One-line description.
    description: []const u8,
    /// Project homepage URL.
    homepage: []const u8,
    /// SPDX license identifier.
    license: []const u8,
    /// Tarball URL for the stable release.
    tarball_url: []const u8,
    /// SHA-256 hex digest of the tarball.
    tarball_sha256: []const u8,
    /// Git URL for head installs (optional).
    head_url: ?[]const u8 = null,
    /// Path to the compiled binary (for test block).
    binary_path: []const u8,
    /// Where to write the generated `.rb` formula file.
    output_path: []const u8,
    /// Man page glob patterns relative to prefix (optional).
    man_pages: ?[]const u8 = null,
    /// Completions directory relative to prefix (optional).
    completions: ?[]const u8 = null,
};

/// Capitalise the first letter of a string for use as a Ruby class name.
/// Caller owns the returned memory.
pub fn capitaliseName(allocator: std.mem.Allocator, name: []const u8) HomebrewError![]const u8 {
    if (name.len == 0) return error.InvalidConfig;
    const result = try allocator.alloc(u8, name.len);
    errdefer allocator.free(result);
    @memcpy(result, name);
    // Capitalise first character
    const c = result[0];
    if (c >= 'a' and c <= 'z') {
        result[0] = c - 'a' + 'A';
    }
    // Capitalise after hyphens (e.g. "my-tool" → "MyTool")
    var i: usize = 1;
    while (i < result.len) : (i += 1) {
        if (result[i - 1] == '-' and result[i] >= 'a' and result[i] <= 'z') {
            result[i] = result[i] - 'a' + 'A';
            // Remove the hyphen by shifting remaining chars
            const rest = result[i..];
            const dst = result[i - 1 ..];
            @memcpy(dst[0..rest.len], rest);
            result[result.len - 1] = ' '; // will be trimmed
        }
    }
    // Trim trailing spaces
    const trimmed = std.mem.trim(u8, result, " ");
    if (trimmed.len == result.len) return result;
    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(result);
    return copy;
}

/// Generate a Homebrew formula and write it to `cfg.output_path`.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: HomebrewConfig,
) HomebrewError!void {
    if (cfg.formula_name.len == 0) return error.InvalidConfig;
    if (cfg.version.len == 0) return error.InvalidConfig;
    if (cfg.tarball_url.len == 0) return error.InvalidConfig;
    if (cfg.tarball_sha256.len == 0) return error.InvalidConfig;

    const formula_content = try renderFormula(allocator, cfg);
    defer allocator.free(formula_content);

    const cwd = std.Io.Dir.cwd();
    // Ensure parent directory exists
    const parent = std.fs.path.dirname(cfg.output_path) orelse ".";
    cwd.createDirPath(io, parent) catch |err| {
        log.err("failed to create output directory {s}: {}", .{ parent, err });
        return error.WriteError;
    };

    cwd.writeFile(io, .{ .sub_path = cfg.output_path, .data = formula_content }) catch |err| {
        log.err("failed to write formula {s}: {}", .{ cfg.output_path, err });
        return error.WriteError;
    };

    log.info("generated {s}", .{cfg.output_path});
}

/// Render the Ruby formula content.
/// Caller owns the returned memory.
pub fn renderFormula(
    allocator: std.mem.Allocator,
    cfg: HomebrewConfig,
) HomebrewError![]const u8 {
    const head_block = if (cfg.head_url) |url|
        try std.fmt.allocPrint(allocator,
            \\
            \\  head "{s}"
        , .{url})
    else
        "";
    defer if (cfg.head_url != null) allocator.free(head_block);

    const man_block = if (cfg.man_pages) |pattern|
        try std.fmt.allocPrint(allocator,
            \\
            \\    man.install Dir["{s}"]
        , .{pattern})
    else
        "";
    defer if (cfg.man_pages != null) allocator.free(man_block);

    const completion_blocks = try renderCompletions(allocator, cfg.completions);
    defer allocator.free(completion_blocks);

    // Build the install body: bin.install + optional man + completions
    const extra_installs = if (man_block.len > 0 or completion_blocks.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ man_block, completion_blocks })
    else
        "";
    defer if (man_block.len > 0 or completion_blocks.len > 0) allocator.free(extra_installs);

    return std.fmt.allocPrint(allocator,
        \\class {s} < Formula
        \\  desc "{s}"
        \\  homepage "{s}"
        \\  url "{s}"
        \\  sha256 "{s}"
        \\  license "{s}"
        \\{s}
        \\
        \\  depends_on :macos
        \\
        \\  def install
        \\    bin.install "bin/{s}"{s}
        \\  end
        \\
        \\  test do
        \\    system bin/"{s}", "--version"
        \\  end
        \\end
        \\
    , .{
        cfg.formula_name,
        cfg.description,
        cfg.homepage,
        cfg.tarball_url,
        cfg.tarball_sha256,
        cfg.license,
        head_block,
        cfg.project_name,
        extra_installs,
        cfg.project_name,
    });
}

/// Render completion install lines.
/// Caller owns the returned memory.
fn renderCompletions(
    allocator: std.mem.Allocator,
    completions: ?[]const u8,
) HomebrewError![]const u8 {
    if (completions == null) return try allocator.dupe(u8, "");

    const base = completions.?;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    // bash
    try buf.appendSlice(allocator, "\n    bash_completion.install \"");
    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "/bash/{name}\"");

    // zsh
    try buf.appendSlice(allocator, "\n    zsh_completion.install \"");
    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "/zsh/_{name}\"");

    // fish
    try buf.appendSlice(allocator, "\n    fish_completion.install \"");
    try buf.appendSlice(allocator, base);
    try buf.appendSlice(allocator, "/fish/{name}.fish\"");

    return buf.toOwnedSlice(allocator);
}

/// Find a tarball artifact in the dist directory and return its info.
/// Prefers macOS aarch64, falls back to any tarball.
/// Caller owns the returned memory.
pub const ArtifactInfo = struct {
    file_name: []const u8,
    full_path: []const u8,
    sha256: [32]u8,
};

pub fn findTarball(
    allocator: std.mem.Allocator,
    io: std.Io,
    dist_dir: []const u8,
    project_name: []const u8,
) HomebrewError!ArtifactInfo {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dist_dir, .{ .iterate = true }) catch return error.ArtifactNotFound;
    defer dir.close(io);

    var best_match: ?ArtifactInfo = null;
    errdefer {
        if (best_match) |m| {
            allocator.free(m.file_name);
            allocator.free(m.full_path);
        }
    }

    var iter = dir.iterate();
    while (iter.next(io) catch return error.ReadError) |entry| {
        if (entry.kind != .file) continue;

        // Must be a tarball
        const is_tarball = std.mem.endsWith(u8, entry.name, ".tar.gz") or
            std.mem.endsWith(u8, entry.name, ".tgz");
        if (!is_tarball) continue;

        // Must start with project name
        if (!std.mem.startsWith(u8, entry.name, project_name)) continue;

        // Prefer macOS aarch64 tarball
        const is_macos_aarch64 = std.mem.indexOf(u8, entry.name, "macos-aarch64") != null;
        const is_macos = std.mem.indexOf(u8, entry.name, "macos-") != null;

        // Skip Linux tarballs if we already have a macOS option
        if (!is_macos and best_match != null) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dist_dir, entry.name });
        errdefer allocator.free(full_path);
        const file_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(file_name);

        // Compute sha256
        const data = cwd.readFileAlloc(io, full_path, allocator, .limited(512 * 1024 * 1024)) catch |err| {
            log.err("failed to read {s}: {}", .{ full_path, err });
            allocator.free(file_name);
            allocator.free(full_path);
            continue;
        };
        defer allocator.free(data);

        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &sha, .{});

        const info = ArtifactInfo{
            .file_name = file_name,
            .full_path = full_path,
            .sha256 = sha,
        };

        // If this is macOS aarch64, it's the best match — take it
        if (is_macos_aarch64) {
            if (best_match) |m| {
                allocator.free(m.file_name);
                allocator.free(m.full_path);
            }
            best_match = info;
            break;
        }

        // Otherwise keep it as a candidate
        if (best_match) |m| {
            allocator.free(m.file_name);
            allocator.free(m.full_path);
        }
        best_match = info;
    }

    return best_match orelse error.ArtifactNotFound;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "capitaliseName capitalises first letter" {
    const allocator = std.testing.allocator;
    const result = try capitaliseName(allocator, "takeoff");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Takeoff", result);
}

test "capitaliseName handles hyphenated names" {
    const allocator = std.testing.allocator;
    const result = try capitaliseName(allocator, "my-tool");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("MyTool", result);
}

test "capitaliseName rejects empty name" {
    try std.testing.expectError(error.InvalidConfig, capitaliseName(std.testing.allocator, ""));
}

test "renderFormula generates valid Ruby formula" {
    const allocator = std.testing.allocator;

    const cfg = HomebrewConfig{
        .formula_name = "Takeoff",
        .project_name = "takeoff",
        .version = "0.2.0",
        .description = "Release automation for Zig projects",
        .homepage = "https://github.com/vmvarela/takeoff",
        .license = "MIT",
        .tarball_url = "https://github.com/vmvarela/takeoff/releases/download/v0.2.0/takeoff-0.2.0-macos-aarch64.tar.gz",
        .tarball_sha256 = "abc123def456",
        .binary_path = "/dev/null",
        .output_path = "/tmp/takeoff.rb",
    };

    const content = try renderFormula(allocator, cfg);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "class Takeoff < Formula") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "desc \"Release automation for Zig projects\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "homepage \"https://github.com/vmvarela/takeoff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "sha256 \"abc123def456\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "license \"MIT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "bin.install \"bin/takeoff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "system bin/\"takeoff\", \"--version\"") != null);
}

test "renderFormula includes head block when head_url is set" {
    const allocator = std.testing.allocator;

    const cfg = HomebrewConfig{
        .formula_name = "Takeoff",
        .project_name = "takeoff",
        .version = "0.2.0",
        .description = "Test",
        .homepage = "https://example.com",
        .license = "MIT",
        .tarball_url = "https://example.com/tarball.tar.gz",
        .tarball_sha256 = "abc123",
        .head_url = "https://github.com/vmvarela/takeoff.git",
        .binary_path = "/dev/null",
        .output_path = "/tmp/takeoff.rb",
    };

    const content = try renderFormula(allocator, cfg);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "head \"https://github.com/vmvarela/takeoff.git\"") != null);
}

test "renderFormula includes man page install when man_pages is set" {
    const allocator = std.testing.allocator;

    const cfg = HomebrewConfig{
        .formula_name = "Takeoff",
        .project_name = "takeoff",
        .version = "0.2.0",
        .description = "Test",
        .homepage = "https://example.com",
        .license = "MIT",
        .tarball_url = "https://example.com/tarball.tar.gz",
        .tarball_sha256 = "abc123",
        .man_pages = "share/man/man1/*",
        .binary_path = "/dev/null",
        .output_path = "/tmp/takeoff.rb",
    };

    const content = try renderFormula(allocator, cfg);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "man.install Dir[\"share/man/man1/*\"]") != null);
}

test "findTarball finds tarball in temp directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a fake tarball
    try tmp.dir.writeFile(io, .{
        .sub_path = "takeoff-0.2.0-macos-aarch64.tar.gz",
        .data = "fake tarball content for sha256",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "takeoff-0.2.0-linux-x86_64.tar.gz",
        .data = "fake linux tarball",
    });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const info = try findTarball(allocator, io, ".", "takeoff");
    defer {
        allocator.free(info.file_name);
        allocator.free(info.full_path);
    }

    try std.testing.expectEqualStrings("takeoff-0.2.0-macos-aarch64.tar.gz", info.file_name);
}

test "findTarball returns ArtifactNotFound when no tarball exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "nothing here" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    try std.testing.expectError(error.ArtifactNotFound, findTarball(allocator, io, ".", "takeoff"));
}

test "generate writes formula to temp file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg = HomebrewConfig{
        .formula_name = "Takeoff",
        .project_name = "takeoff",
        .version = "0.2.0",
        .description = "Release automation for Zig projects",
        .homepage = "https://github.com/vmvarela/takeoff",
        .license = "MIT",
        .tarball_url = "https://github.com/vmvarela/takeoff/releases/download/v0.2.0/takeoff-0.2.0-macos-aarch64.tar.gz",
        .tarball_sha256 = "abc123def456",
        .binary_path = "/dev/null",
        .output_path = "Formula/takeoff.rb",
    };

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    try generate(allocator, io, cfg);

    const content = try tmp.dir.readFileAlloc(io, allocator, "Formula/takeoff.rb", .limited(64 * 1024));
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "class Takeoff < Formula") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "sha256 \"abc123def456\"") != null);
}
