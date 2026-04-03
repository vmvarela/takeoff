//! Chocolatey packager — generates a `.nupkg` (ZIP) containing a `.nuspec`
//! XML metadata file and a `tools/chocolateyInstall.ps1` PowerShell install
//! script that downloads the Windows zip from GitHub releases.
//!
//! No external tool (`choco`) is required — the entire package is assembled
//! in Zig using `std.zip`.
//!
//! Format references:
//!   - Nuspec schema: https://docs.microsoft.com/en-us/nuget/reference/nuspec
//!   - Chocolatey package structure: https://docs.chocolatey.org/en-us/create/create-packages/
//!   - CCR moderation rules: https://docs.chocolatey.org/en-us/community-repository/moderation/package-validator/rules/

const std = @import("std");

const log = std.log.scoped(.chocolatey);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Error set for Chocolatey package generation.
pub const ChocolateyError = error{
    WriteError,
    InvalidConfig,
    OutOfMemory,
};

/// Configuration for generating a Chocolatey package.
pub const ChocolateyConfig = struct {
    /// Package ID (e.g. "takeoff" or "takeoff.portable").
    package_id: []const u8,
    /// Version string (e.g. "1.0.0").
    version: []const u8,
    /// Human-readable title (must differ from package_id — CPMR0050).
    title: []const u8,
    /// Project authors (e.g. "vmvarela").
    authors: []const u8,
    /// Short summary (≥ 30 chars — CPMR0032).
    summary: []const u8,
    /// Longer description (30–4000 chars — CPMR0026).
    description: []const u8,
    /// Project homepage URL (CPMR0009).
    project_url: []const u8,
    /// License URL (CPMR0039).
    license_url: []const u8,
    /// Project source URL (CPMR0041).
    project_source_url: []const u8,
    /// Bug tracker URL.
    bug_tracker_url: []const u8,
    /// Package source URL (CPMR0040).
    package_source_url: []const u8,
    /// Space-separated tags (no commas — CPMR0014).
    tags: []const u8,
    /// Release notes URL (CPMR0042).
    release_notes: []const u8,
    /// Icon URL (optional, PNG/SVG recommended — CPMR0058).
    icon_url: ?[]const u8 = null,
    /// GitHub download URL for Windows x64 zip.
    url_x64: []const u8,
    /// SHA-256 hash of x64 zip (uppercase hex, for PowerShell).
    sha256_x64: []const u8,
    /// GitHub download URL for Windows arm64 zip (optional).
    url_arm64: ?[]const u8 = null,
    /// SHA-256 hash of arm64 zip (optional).
    sha256_arm64: ?[]const u8 = null,
    /// Binary name inside the zip (e.g. "takeoff.exe").
    binary_name: []const u8,
    /// Where to write the `.nupkg` file.
    output_path: []const u8,
};

/// Generate a Chocolatey `.nupkg` package.
///
/// This creates a ZIP archive containing:
///   - `{package_id}.nuspec` — XML metadata
///   - `tools/chocolateyInstall.ps1` — install script
///
/// No `choco` CLI is required.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: ChocolateyConfig,
) ChocolateyError!void {
    if (cfg.package_id.len == 0) return error.InvalidConfig;
    if (cfg.version.len == 0) return error.InvalidConfig;
    if (cfg.title.len == 0) return error.InvalidConfig;

    // Render the nuspec and install script.
    const nuspec = try renderNuspec(allocator, cfg);
    defer allocator.free(nuspec);

    const install_script = try renderInstallScript(allocator, cfg);
    defer allocator.free(install_script);

    // Build the nuspec filename.
    const nuspec_filename = try std.fmt.allocPrint(allocator, "{s}.nuspec", .{cfg.package_id});
    defer allocator.free(nuspec_filename);

    // Create the output file.
    const file = std.Io.Dir.cwd().createFile(io, cfg.output_path, .{ .truncate = true }) catch |err| {
        log.err("failed to create output file {s}: {}", .{ cfg.output_path, err });
        return error.WriteError;
    };
    defer file.close(io);

    // Write the ZIP (nupkg) with two entries.
    writeNupkgZip(file, io, nuspec_filename, nuspec, install_script) catch |err| {
        log.warn("failed to write nupkg zip: {}", .{err});
        return error.WriteError;
    };
}

// ---------------------------------------------------------------------------
// Nuspec rendering
// ---------------------------------------------------------------------------

/// Render the `.nuspec` XML metadata file.
pub fn renderNuspec(
    allocator: std.mem.Allocator,
    cfg: ChocolateyConfig,
) ![]const u8 {
    const icon_block: []const u8 = if (cfg.icon_url) |url| blk: {
        break :blk try std.fmt.allocPrint(
            allocator,
            "        <iconUrl>{s}</iconUrl>\n",
            .{url},
        );
    } else "";
    defer if (cfg.icon_url != null) allocator.free(icon_block);

    return try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
        \\  <metadata>
        \\    <id>{s}</id>
        \\    <version>{s}</version>
        \\    <title>{s}</title>
        \\    <authors>{s}</authors>
        \\    <owners>{s}</owners>
        \\    <projectUrl>{s}</projectUrl>
        \\    <licenseUrl>{s}</licenseUrl>
        \\    <projectSourceUrl>{s}</projectSourceUrl>
        \\    <bugTrackerUrl>{s}</bugTrackerUrl>
        \\    <packageSourceUrl>{s}</packageSourceUrl>
        \\{s}        <tags>{s}</tags>
        \\    <summary>{s}</summary>
        \\    <description>{s}</description>
        \\    <releaseNotes>{s}</releaseNotes>
        \\  </metadata>
        \\  <files>
        \\    <file src="tools\**" target="tools" />
        \\  </files>
        \\</package>
    , .{
        cfg.package_id,
        cfg.version,
        cfg.title,
        cfg.authors,
        cfg.authors,
        cfg.project_url,
        cfg.license_url,
        cfg.project_source_url,
        cfg.bug_tracker_url,
        cfg.package_source_url,
        icon_block,
        cfg.tags,
        cfg.summary,
        cfg.description,
        cfg.release_notes,
    });
}

// ---------------------------------------------------------------------------
// Install script rendering
// ---------------------------------------------------------------------------

/// Render the `chocolateyInstall.ps1` PowerShell install script.
///
/// Uses `Get-ChocolateyWebFile` + `Install-ChocolateyZipPackage` pattern
/// for portable packages that download from GitHub releases.
pub fn renderInstallScript(
    allocator: std.mem.Allocator,
    cfg: ChocolateyConfig,
) ![]const u8 {
    if (cfg.url_arm64) |arm_url| {
        const arm_hash = cfg.sha256_arm64 orelse "";
        // Multi-arch script: detect architecture and use appropriate URL.
        return try std.fmt.allocPrint(allocator,
            \\$ErrorActionPreference = 'Stop'
            \\$toolsDir = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
            \\
            \\$packageArgs = @{{
            \\    packageName    = '{s}'
            \\    unzipLocation  = $toolsDir
            \\    url            = '{s}'
            \\    checksum       = '{s}'
            \\    checksumType   = 'sha256'
            \\    url64bit       = '{s}'
            \\    checksum64     = '{s}'
            \\    checksumType64 = 'sha256'
            \\}}
            \\
            \\# Use ARM64 URL on ARM64 systems
            \\if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {{
            \\    $packageArgs.url64bit = '{s}'
            \\    $packageArgs.checksum64 = '{s}'
            \\}}
            \\
            \\Install-ChocolateyZipPackage @packageArgs
            \\
        , .{
            cfg.package_id,
            cfg.url_x64,
            cfg.sha256_x64,
            cfg.url_x64,
            cfg.sha256_x64,
            arm_url,
            arm_hash,
        });
    } else {
        // Single-arch (x64 only).
        return try std.fmt.allocPrint(allocator,
            \\$ErrorActionPreference = 'Stop'
            \\$toolsDir = "$(Split-Path -parent $MyInvocation.MyCommand.Definition)"
            \\
            \\$packageArgs = @{{
            \\    packageName    = '{s}'
            \\    unzipLocation  = $toolsDir
            \\    url64bit       = '{s}'
            \\    checksum64     = '{s}'
            \\    checksumType64 = 'sha256'
            \\}}
            \\
            \\Install-ChocolateyZipPackage @packageArgs
            \\
        , .{
            cfg.package_id,
            cfg.url_x64,
            cfg.sha256_x64,
        });
    }
}

// ---------------------------------------------------------------------------
// ZIP / .nupkg writing
// ---------------------------------------------------------------------------

const LocalFileHeader = extern struct {
    signature: [4]u8 align(1),
    version_needed_to_extract: u16 align(1),
    flags: ZipGeneralPurposeFlags align(1),
    compression_method: std.zip.CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
};

const CentralDirectoryHeader = extern struct {
    signature: [4]u8 align(1),
    version_made_by: u16 align(1),
    version_needed_to_extract: u16 align(1),
    flags: ZipGeneralPurposeFlags align(1),
    compression_method: std.zip.CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
    comment_len: u16 align(1),
    disk_number: u16 align(1),
    internal_file_attributes: u16 align(1),
    external_file_attributes: u32 align(1),
    local_header_offset: u32 align(1),
};

const ZipGeneralPurposeFlags = packed struct(u16) {
    encrypted: bool = false,
    _: u15 = 0,
};

const CentralDirEntry = struct {
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename: []const u8,
    local_header_offset: u64,
};

/// Write a `.nupkg` ZIP with the nuspec and install script.
///
/// Structure:
///   {package_id}.nuspec
///   tools/chocolateyInstall.ps1
fn writeNupkgZip(
    file: std.Io.File,
    io: std.Io,
    nuspec_filename: []const u8,
    nuspec_content: []const u8,
    install_script: []const u8,
) !void {
    const entries = [_]struct {
        filename: []const u8,
        content: []const u8,
    }{
        .{ .filename = nuspec_filename, .content = nuspec_content },
        .{ .filename = "tools/chocolateyInstall.ps1", .content = install_script },
    };

    var cd_entries: std.ArrayListUnmanaged(CentralDirEntry) = .empty;
    defer cd_entries.deinit(std.heap.page_allocator);

    var local_header_offset: u64 = 0;

    // Write local file headers and data.
    for (entries) |entry| {
        const crc = std.hash.Crc32.hash(entry.content);

        const local_header = LocalFileHeader{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = crc,
            .compressed_size = @intCast(entry.content.len),
            .uncompressed_size = @intCast(entry.content.len),
            .filename_len = @intCast(entry.filename.len),
            .extra_len = 0,
        };

        try file.writeStreamingAll(io, std.mem.asBytes(&local_header));
        try file.writeStreamingAll(io, entry.filename);
        try file.writeStreamingAll(io, entry.content);

        try cd_entries.append(std.heap.page_allocator, .{
            .crc32 = crc,
            .compressed_size = @intCast(entry.content.len),
            .uncompressed_size = @intCast(entry.content.len),
            .filename = entry.filename,
            .local_header_offset = local_header_offset,
        });

        local_header_offset += @sizeOf(LocalFileHeader) + entry.filename.len + entry.content.len;
    }

    // Write central directory.
    const cd_start = local_header_offset;
    for (cd_entries.items) |cd_entry| {
        const cd_header = CentralDirectoryHeader{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = cd_entry.crc32,
            .compressed_size = cd_entry.compressed_size,
            .uncompressed_size = cd_entry.uncompressed_size,
            .filename_len = @intCast(cd_entry.filename.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_header_offset = @intCast(cd_entry.local_header_offset),
        };

        try file.writeStreamingAll(io, std.mem.asBytes(&cd_header));
        try file.writeStreamingAll(io, cd_entry.filename);

        local_header_offset += @sizeOf(CentralDirectoryHeader) + cd_entry.filename.len;
    }

    const cd_size = local_header_offset - cd_start;

    // Write end of central directory record.
    const end_record = std.zip.EndRecord{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(cd_entries.items.len),
        .record_count_total = @intCast(cd_entries.items.len),
        .central_directory_size = @intCast(cd_size),
        .central_directory_offset = @intCast(cd_start),
        .comment_len = 0,
    };

    try file.writeStreamingAll(io, std.mem.asBytes(&end_record));
}

// ---------------------------------------------------------------------------
// Architecture mapping
// ---------------------------------------------------------------------------

/// Map a Zig architecture name to the Chocolatey architecture string.
pub fn chocolateyArch(zig_arch: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, zig_arch, "x86_64")) return "x64";
    if (std.mem.eql(u8, zig_arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, zig_arch, "x86")) return "x86";
    return null;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "chocolateyArch maps x86_64 to x64" {
    try std.testing.expectEqualStrings("x64", chocolateyArch("x86_64").?);
}

test "chocolateyArch maps aarch64 to arm64" {
    try std.testing.expectEqualStrings("arm64", chocolateyArch("aarch64").?);
}

test "chocolateyArch maps x86 to x86" {
    try std.testing.expectEqualStrings("x86", chocolateyArch("x86").?);
}

test "chocolateyArch returns null for unknown arch" {
    try std.testing.expect(chocolateyArch("riscv64") == null);
}

test "renderNuspec produces valid XML with required fields" {
    const allocator = std.testing.allocator;
    const cfg = ChocolateyConfig{
        .package_id = "takeoff",
        .version = "1.0.0",
        .title = "Takeoff",
        .authors = "vmvarela",
        .summary = "Release automation for Zig projects",
        .description = "Cross-compiles binaries for all targets on a single Linux runner, then packages them into native formats.",
        .project_url = "https://github.com/vmvarela/takeoff",
        .license_url = "https://github.com/vmvarela/takeoff/blob/main/LICENSE",
        .project_source_url = "https://github.com/vmvarela/takeoff",
        .bug_tracker_url = "https://github.com/vmvarela/takeoff/issues",
        .package_source_url = "https://github.com/vmvarela/takeoff",
        .tags = "takeoff portable cli",
        .release_notes = "https://github.com/vmvarela/takeoff/releases",
        .url_x64 = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip",
        .sha256_x64 = "ABC123DEF456",
        .binary_name = "takeoff.exe",
        .output_path = "test.nupkg",
    };

    const xml = try renderNuspec(allocator, cfg);
    defer allocator.free(xml);

    // Verify required fields are present.
    try std.testing.expect(std.mem.indexOf(u8, xml, "<id>takeoff</id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<version>1.0.0</version>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<title>Takeoff</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<authors>vmvarela</authors>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<summary>Release automation for Zig projects</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<projectUrl>https://github.com/vmvarela/takeoff</projectUrl>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<licenseUrl>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<releaseNotes>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<tags>takeoff portable cli</tags>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<packageSourceUrl>") != null);

    // Title != Id (CPMR0050).
    try std.testing.expect(std.mem.indexOf(u8, xml, "<title>takeoff</title>") == null);

    // No commas in tags (CPMR0014).
    try std.testing.expect(std.mem.indexOf(u8, xml, "<tags>") != null);
    const tags_start = std.mem.indexOf(u8, xml, "<tags>").? + 6;
    const tags_end = std.mem.indexOf(u8, xml, "</tags>").?;
    const tags = xml[tags_start..tags_end];
    try std.testing.expect(std.mem.indexOf(u8, tags, ",") == null);

    // UTF-8 declaration (CPMR0054).
    try std.testing.expect(std.mem.indexOf(u8, xml, "encoding=\"utf-8\"") != null);

    // Icon URL should NOT be present when not configured.
    try std.testing.expect(std.mem.indexOf(u8, xml, "<iconUrl>") == null);
}

test "renderNuspec includes iconUrl when configured" {
    const allocator = std.testing.allocator;
    var cfg = ChocolateyConfig{
        .package_id = "myapp",
        .version = "2.0.0",
        .title = "My App",
        .authors = "test",
        .summary = "A test application for verification",
        .description = "This is a longer description that satisfies the minimum character requirement for CCR moderation rules.",
        .project_url = "https://example.com",
        .license_url = "https://example.com/license",
        .project_source_url = "https://example.com",
        .bug_tracker_url = "https://example.com/issues",
        .package_source_url = "https://example.com",
        .tags = "myapp portable",
        .release_notes = "https://example.com/releases",
        .icon_url = "https://example.com/icon.png",
        .url_x64 = "https://example.com/myapp.zip",
        .sha256_x64 = "HASH123",
        .binary_name = "myapp.exe",
        .output_path = "test.nupkg",
    };
    cfg.icon_url = "https://example.com/icon.png";

    const xml = try renderNuspec(allocator, cfg);
    defer allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "<iconUrl>https://example.com/icon.png</iconUrl>") != null);
}

test "renderInstallScript generates valid PowerShell (x64 only)" {
    const allocator = std.testing.allocator;
    const cfg = ChocolateyConfig{
        .package_id = "takeoff",
        .version = "1.0.0",
        .title = "Takeoff",
        .authors = "vmvarela",
        .summary = "Release automation for Zig projects",
        .description = "Cross-compiles binaries for all targets on a single Linux runner.",
        .project_url = "https://github.com/vmvarela/takeoff",
        .license_url = "https://github.com/vmvarela/takeoff/blob/main/LICENSE",
        .project_source_url = "https://github.com/vmvarela/takeoff",
        .bug_tracker_url = "https://github.com/vmvarela/takeoff/issues",
        .package_source_url = "https://github.com/vmvarela/takeoff",
        .tags = "takeoff portable",
        .release_notes = "https://github.com/vmvarela/takeoff/releases",
        .url_x64 = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip",
        .sha256_x64 = "ABC123DEF456",
        .binary_name = "takeoff.exe",
        .output_path = "test.nupkg",
    };

    const script = try renderInstallScript(allocator, cfg);
    defer allocator.free(script);

    // Key elements must be present.
    try std.testing.expect(std.mem.indexOf(u8, script, "$ErrorActionPreference = 'Stop'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Install-ChocolateyZipPackage") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "checksum64") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ABC123DEF456") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "unzipLocation") != null);

    // ARM64 detection block should NOT be present.
    try std.testing.expect(std.mem.indexOf(u8, script, "PROCESSOR_ARCHITECTURE") == null);
}

test "renderInstallScript includes ARM64 detection when both architectures provided" {
    const allocator = std.testing.allocator;
    const cfg = ChocolateyConfig{
        .package_id = "takeoff",
        .version = "1.0.0",
        .title = "Takeoff",
        .authors = "vmvarela",
        .summary = "Release automation for Zig projects",
        .description = "Cross-compiles binaries for all targets on a single Linux runner.",
        .project_url = "https://github.com/vmvarela/takeoff",
        .license_url = "https://github.com/vmvarela/takeoff/blob/main/LICENSE",
        .project_source_url = "https://github.com/vmvarela/takeoff",
        .bug_tracker_url = "https://github.com/vmvarela/takeoff/issues",
        .package_source_url = "https://github.com/vmvarela/takeoff",
        .tags = "takeoff portable",
        .release_notes = "https://github.com/vmvarela/takeoff/releases",
        .url_x64 = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-x86_64.zip",
        .sha256_x64 = "HASH64",
        .url_arm64 = "https://github.com/vmvarela/takeoff/releases/download/v1.0.0/takeoff-1.0.0-windows-aarch64.zip",
        .sha256_arm64 = "HASHARM",
        .binary_name = "takeoff.exe",
        .output_path = "test.nupkg",
    };

    const script = try renderInstallScript(allocator, cfg);
    defer allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "PROCESSOR_ARCHITECTURE") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ARM64") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "HASHARM") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "HASH64") != null);
}

test "generate creates a valid .nupkg ZIP file" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = ChocolateyConfig{
        .package_id = "testpkg",
        .version = "0.1.0",
        .title = "Test Package",
        .authors = "tester",
        .summary = "A test package for verifying nupkg generation",
        .description = "This package is used to test that the Chocolatey packager produces a valid ZIP with the correct structure.",
        .project_url = "https://example.com",
        .license_url = "https://example.com/license",
        .project_source_url = "https://example.com",
        .bug_tracker_url = "https://example.com/issues",
        .package_source_url = "https://example.com",
        .tags = "testpkg portable cli",
        .release_notes = "https://example.com/releases",
        .url_x64 = "https://example.com/testpkg.zip",
        .sha256_x64 = "SHA256HASH",
        .binary_name = "testpkg.exe",
        .output_path = "testpkg.0.1.0.nupkg",
    };

    try generate(allocator, io, cfg);

    // Read back the .nupkg and verify ZIP structure.
    const data = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, cfg.output_path, .{});
        defer f.close(io);
        var rbuf: [65536]u8 = undefined;
        var r = f.reader(io, &rbuf);
        break :blk try r.interface.allocRemaining(allocator, .unlimited);
    };
    defer allocator.free(data);

    // ZIP local file header signature.
    try std.testing.expectEqual(@as(u32, 0x04034b50), std.mem.readInt(u32, data[0..4], .little));

    // Should contain the nuspec filename.
    try std.testing.expect(std.mem.indexOf(u8, data, "testpkg.nuspec") != null);

    // Should contain the install script path.
    try std.testing.expect(std.mem.indexOf(u8, data, "tools/chocolateyInstall.ps1") != null);

    // Should contain key content from nuspec.
    try std.testing.expect(std.mem.indexOf(u8, data, "<id>testpkg</id>") != null);

    // Should contain key content from install script.
    try std.testing.expect(std.mem.indexOf(u8, data, "Install-ChocolateyZipPackage") != null);
}

test "generate rejects empty package_id" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const cfg = ChocolateyConfig{
        .package_id = "",
        .version = "1.0.0",
        .title = "Test",
        .authors = "test",
        .summary = "A test package for verification purposes",
        .description = "This is a longer description that satisfies the minimum character requirement.",
        .project_url = "https://example.com",
        .license_url = "https://example.com/license",
        .project_source_url = "https://example.com",
        .bug_tracker_url = "https://example.com/issues",
        .package_source_url = "https://example.com",
        .tags = "test portable",
        .release_notes = "https://example.com/releases",
        .url_x64 = "https://example.com/test.zip",
        .sha256_x64 = "HASH",
        .binary_name = "test.exe",
        .output_path = "test.nupkg",
    };
    try std.testing.expectError(error.InvalidConfig, generate(allocator, io, cfg));
}

test "generate rejects empty version" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const cfg = ChocolateyConfig{
        .package_id = "testpkg",
        .version = "",
        .title = "Test",
        .authors = "test",
        .summary = "A test package for verification purposes",
        .description = "This is a longer description that satisfies the minimum character requirement.",
        .project_url = "https://example.com",
        .license_url = "https://example.com/license",
        .project_source_url = "https://example.com",
        .bug_tracker_url = "https://example.com/issues",
        .package_source_url = "https://example.com",
        .tags = "test portable",
        .release_notes = "https://example.com/releases",
        .url_x64 = "https://example.com/test.zip",
        .sha256_x64 = "HASH",
        .binary_name = "test.exe",
        .output_path = "test.nupkg",
    };
    try std.testing.expectError(error.InvalidConfig, generate(allocator, io, cfg));
}
