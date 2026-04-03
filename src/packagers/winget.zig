//! Winget (Windows Package Manager) packager.
//!
//! Generates the three-file YAML manifest structure required by
//! `microsoft/winget-pkgs`:
//!   - `{publisher}.{name}.yaml`         — version manifest
//!   - `{publisher}.{name}.locale.en-US.yaml` — locale manifest
//!   - `{publisher}.{name}.installer.yaml`    — installer manifest
//!
//! Uses schema version 1.12.0 and InstallerType "portable" for CLI tools
//! distributed as zip archives.

const std = @import("std");

/// Current Winget manifest schema version.
pub const MANIFEST_VERSION = "1.12.0";

/// Configuration for generating Winget manifests.
pub const WingetConfig = struct {
    /// Publisher name for PackageIdentifier (e.g. "vmvarela").
    publisher: []const u8,
    /// Project binary name (e.g. "takeoff").
    project_name: []const u8,
    /// Version string without 'v' prefix (e.g. "1.0.0").
    version: []const u8,
    /// Short description of the project.
    description: []const u8,
    /// Project homepage URL.
    homepage: []const u8,
    /// SPDX license identifier.
    license: []const u8,
    /// GitHub download URL for Windows x64 zip.
    url_x64: []const u8,
    /// SHA-256 hash of the x64 zip (uppercase hex).
    sha256_x64: []const u8,
    /// GitHub download URL for Windows arm64 zip (optional).
    url_arm64: ?[]const u8 = null,
    /// SHA-256 hash of the arm64 zip (optional, required if url_arm64 is set).
    sha256_arm64: ?[]const u8 = null,
    /// Binary name inside the zip (e.g. "takeoff.exe").
    binary_name: []const u8,
    /// Directory where the three YAML files are written.
    output_dir: []const u8,
};

/// Error set for Winget manifest generation.
pub const WingetError = error{
    WriteError,
    OutOfMemory,
};

/// Generate the three-file Winget manifest structure.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: WingetConfig,
) WingetError!void {
    // Ensure output directory exists
    std.Io.Dir.cwd().createDirPath(io, cfg.output_dir) catch return error.WriteError;

    const package_id = try std.fmt.allocPrint(
        allocator,
        "{s}.{s}",
        .{ cfg.publisher, cfg.project_name },
    );
    defer allocator.free(package_id);

    // Generate version manifest
    const version_content = try renderVersionManifest(allocator, package_id, cfg);
    defer allocator.free(version_content);
    const version_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.yaml",
        .{ cfg.output_dir, package_id },
    );
    defer allocator.free(version_path);
    try writeFile(io, version_path, version_content);

    // Generate locale manifest
    const locale_content = try renderLocaleManifest(allocator, package_id, cfg);
    defer allocator.free(locale_content);
    const locale_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.locale.en-US.yaml",
        .{ cfg.output_dir, package_id },
    );
    defer allocator.free(locale_path);
    try writeFile(io, locale_path, locale_content);

    // Generate installer manifest
    const installer_content = try renderInstallerManifest(allocator, package_id, cfg);
    defer allocator.free(installer_content);
    const installer_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}.installer.yaml",
        .{ cfg.output_dir, package_id },
    );
    defer allocator.free(installer_path);
    try writeFile(io, installer_path, installer_content);
}

// ---------------------------------------------------------------------------
// Version manifest
// ---------------------------------------------------------------------------

/// Render the version manifest YAML.
pub fn renderVersionManifest(
    allocator: std.mem.Allocator,
    package_id: []const u8,
    cfg: WingetConfig,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\PackageIdentifier: {s}
        \\PackageVersion: {s}
        \\DefaultLocale: en-US
        \\ManifestType: version
        \\ManifestVersion: {s}
        \\
    , .{ package_id, cfg.version, MANIFEST_VERSION });
}

// ---------------------------------------------------------------------------
// Locale manifest
// ---------------------------------------------------------------------------

/// Render the locale manifest YAML.
pub fn renderLocaleManifest(
    allocator: std.mem.Allocator,
    package_id: []const u8,
    cfg: WingetConfig,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\PackageIdentifier: {s}
        \\PackageVersion: {s}
        \\PackageLocale: en-US
        \\Publisher: {s}
        \\PackageName: {s}
        \\License: {s}
        \\ShortDescription: {s}
        \\ManifestType: locale
        \\ManifestVersion: {s}
        \\
    , .{
        package_id,
        cfg.version,
        cfg.publisher,
        cfg.project_name,
        cfg.license,
        cfg.description,
        MANIFEST_VERSION,
    });
}

// ---------------------------------------------------------------------------
// Installer manifest
// ---------------------------------------------------------------------------

/// Render the installer manifest YAML.
pub fn renderInstallerManifest(
    allocator: std.mem.Allocator,
    package_id: []const u8,
    cfg: WingetConfig,
) ![]const u8 {
    // Use arena for intermediate arm64_block allocation to avoid leak
    // when it gets embedded into the final result string.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const arm64_block: []const u8 = if (cfg.url_arm64) |url| blk: {
        const hash = cfg.sha256_arm64 orelse "";
        break :blk try std.fmt.allocPrint(a,
            \\  - Architecture: arm64
            \\    InstallerType: portable
            \\    InstallerUrl: {s}
            \\    InstallerSha256: {s}
            \\    Commands:
            \\      - {s}
            \\
        , .{ url, hash, cfg.binary_name });
    } else "";

    return try std.fmt.allocPrint(allocator,
        \\PackageIdentifier: {s}
        \\PackageVersion: {s}
        \\Installers:
        \\  - Architecture: x64
        \\    InstallerType: portable
        \\    InstallerUrl: {s}
        \\    InstallerSha256: {s}
        \\    Commands:
        \\      - {s}
        \\{s}ManifestType: installer
        \\ManifestVersion: {s}
        \\
    , .{
        package_id,
        cfg.version,
        cfg.url_x64,
        cfg.sha256_x64,
        cfg.binary_name,
        arm64_block,
        MANIFEST_VERSION,
    });
}

// ---------------------------------------------------------------------------
// Architecture mapping
// ---------------------------------------------------------------------------

/// Map a Zig architecture name to the Winget architecture string.
pub fn wingetArch(zig_arch: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, zig_arch, "x86_64")) return "x64";
    if (std.mem.eql(u8, zig_arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, zig_arch, "x86")) return "x86";
    return null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn writeFile(io: std.Io, path: []const u8, content: []const u8) WingetError!void {
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return error.WriteError;
    defer f.close(io);
    f.writeStreamingAll(io, content) catch return error.WriteError;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "wingetArch maps x86_64 to x64" {
    try std.testing.expectEqualStrings("x64", wingetArch("x86_64").?);
}

test "wingetArch maps aarch64 to arm64" {
    try std.testing.expectEqualStrings("arm64", wingetArch("aarch64").?);
}

test "wingetArch maps x86 to x86" {
    try std.testing.expectEqualStrings("x86", wingetArch("x86").?);
}

test "wingetArch returns null for unknown arch" {
    try std.testing.expect(wingetArch("riscv64") == null);
}

test "renderVersionManifest produces valid YAML" {
    const allocator = std.testing.allocator;
    const cfg = WingetConfig{
        .publisher = "vmvarela",
        .project_name = "takeoff",
        .version = "1.0.0",
        .description = "Test",
        .homepage = "https://example.com",
        .license = "MIT",
        .url_x64 = "https://example.com/takeoff.zip",
        .sha256_x64 = "ABC123",
        .binary_name = "takeoff.exe",
        .output_dir = "test",
    };

    const yaml = try renderVersionManifest(allocator, "vmvarela.takeoff", cfg);
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageIdentifier: vmvarela.takeoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageVersion: 1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "DefaultLocale: en-US") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ManifestType: version") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ManifestVersion: 1.12.0") != null);
}

test "renderLocaleManifest produces valid YAML" {
    const allocator = std.testing.allocator;
    const cfg = WingetConfig{
        .publisher = "vmvarela",
        .project_name = "takeoff",
        .version = "1.0.0",
        .description = "Release automation for Zig projects",
        .homepage = "https://github.com/vmvarela/takeoff",
        .license = "MIT",
        .url_x64 = "https://example.com/takeoff.zip",
        .sha256_x64 = "ABC123",
        .binary_name = "takeoff.exe",
        .output_dir = "test",
    };

    const yaml = try renderLocaleManifest(allocator, "vmvarela.takeoff", cfg);
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageIdentifier: vmvarela.takeoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageVersion: 1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageLocale: en-US") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Publisher: vmvarela") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageName: takeoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "License: MIT") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ShortDescription: Release automation for Zig projects") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ManifestType: locale") != null);
}

test "renderInstallerManifest produces valid YAML with x64 only" {
    const allocator = std.testing.allocator;
    const cfg = WingetConfig{
        .publisher = "vmvarela",
        .project_name = "takeoff",
        .version = "1.0.0",
        .description = "Test",
        .homepage = "https://example.com",
        .license = "MIT",
        .url_x64 = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip",
        .sha256_x64 = "ABC123DEF456",
        .binary_name = "takeoff.exe",
        .output_dir = "test",
    };

    const yaml = try renderInstallerManifest(allocator, "vmvarela.takeoff", cfg);
    defer allocator.free(yaml);

    try std.testing.expect(std.mem.indexOf(u8, yaml, "PackageIdentifier: vmvarela.takeoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Architecture: x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "InstallerType: portable") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "InstallerSha256: ABC123DEF456") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Commands:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "- takeoff.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ManifestType: installer") != null);
    // arm64 should NOT be present
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Architecture: arm64") == null);
}

test "renderInstallerManifest includes arm64 when both architectures provided" {
    const allocator = std.testing.allocator;
    const cfg = WingetConfig{
        .publisher = "vmvarela",
        .project_name = "takeoff",
        .version = "1.0.0",
        .description = "Test",
        .homepage = "https://example.com",
        .license = "MIT",
        .url_x64 = "https://example.com/takeoff-x64.zip",
        .sha256_x64 = "HASH64",
        .url_arm64 = "https://example.com/takeoff-arm64.zip",
        .sha256_arm64 = "HASHARM",
        .binary_name = "takeoff.exe",
        .output_dir = "test",
    };

    const yaml = try renderInstallerManifest(allocator, "vmvarela.takeoff", cfg);
    defer allocator.free(yaml);

    // Both architectures must be present
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Architecture: x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "Architecture: arm64") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "InstallerSha256: HASH64") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "InstallerSha256: HASHARM") != null);
}

test "generate writes three YAML files to output directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_dir = "winget-out";

    const cfg = WingetConfig{
        .publisher = "testpub",
        .project_name = "mytool",
        .version = "2.0.0",
        .description = "A test tool",
        .homepage = "https://example.com",
        .license = "Apache-2.0",
        .url_x64 = "https://example.com/mytool-2.0.0-windows-x86_64.zip",
        .sha256_x64 = "SHA256HASH",
        .binary_name = "mytool.exe",
        .output_dir = output_dir,
    };

    try generate(allocator, io, cfg);

    // Verify all three files exist and have content
    const version_path = try std.fs.path.join(allocator, &.{ output_dir, "testpub.mytool.yaml" });
    defer allocator.free(version_path);
    const locale_path = try std.fs.path.join(allocator, &.{ output_dir, "testpub.mytool.locale.en-US.yaml" });
    defer allocator.free(locale_path);
    const installer_path = try std.fs.path.join(allocator, &.{ output_dir, "testpub.mytool.installer.yaml" });
    defer allocator.free(installer_path);

    const version_content = std.Io.Dir.cwd().readFileAlloc(io, version_path, allocator, .limited(4096)) catch {
        return error.FileNotFound;
    };
    defer allocator.free(version_content);
    try std.testing.expect(std.mem.indexOf(u8, version_content, "ManifestType: version") != null);

    const locale_content = std.Io.Dir.cwd().readFileAlloc(io, locale_path, allocator, .limited(4096)) catch {
        return error.FileNotFound;
    };
    defer allocator.free(locale_content);
    try std.testing.expect(std.mem.indexOf(u8, locale_content, "ManifestType: locale") != null);

    const installer_content = std.Io.Dir.cwd().readFileAlloc(io, installer_path, allocator, .limited(4096)) catch {
        return error.FileNotFound;
    };
    defer allocator.free(installer_content);
    try std.testing.expect(std.mem.indexOf(u8, installer_content, "ManifestType: installer") != null);
}
