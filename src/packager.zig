const std = @import("std");
const archive = @import("archive.zig");
const config = @import("config.zig");
const checksum = @import("checksum.zig");
const packagers = @import("packagers/mod.zig");

const log = std.log.scoped(.packager);

/// Error set for packaging operations.
pub const PackageError = error{
    NoPackageConfig,
    InvalidFormat,
    BuildFailed,
} || archive.ArchiveError;

/// Result of packaging operations for a single target.
pub const PackageResult = struct {
    target: []const u8,
    success: bool,
    archive_path: ?[]const u8,
    /// Path to the generated `.deb` package, if one was produced.
    deb_path: ?[]const u8,
    /// Path to the generated `.rpm` package, if one was produced.
    rpm_path: ?[]const u8,
    /// Path to the generated `.apk` package, if one was produced.
    apk_path: ?[]const u8,
    /// Path to the generated Scoop manifest JSON, if produced (set once, not per-target).
    scoop_path: ?[]const u8,
    /// Path to the generated Winget manifest directory, if produced (set once, not per-target).
    winget_path: ?[]const u8,
    /// Path to the generated Chocolatey .nupkg package, if produced (set once, not per-target).
    chocolatey_path: ?[]const u8,
    error_message: ?[]const u8,

    pub fn deinit(self: *PackageResult, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.archive_path) |p| allocator.free(p);
        if (self.deb_path) |p| allocator.free(p);
        if (self.rpm_path) |p| allocator.free(p);
        if (self.apk_path) |p| allocator.free(p);
        if (self.scoop_path) |p| allocator.free(p);
        if (self.winget_path) |p| allocator.free(p);
        if (self.chocolatey_path) |p| allocator.free(p);
        if (self.error_message) |m| allocator.free(m);
    }
};

/// Summary of all packaging operations.
pub const PackageSummary = struct {
    succeeded: usize,
    failed: usize,
    total: usize,
    results: []const PackageResult,

    pub fn print(self: PackageSummary, writer: anytype) !void {
        try writer.print("\nPackage Summary:\n", .{});
        try writer.print("=================\n", .{});
        try writer.print("Total: {d}\n", .{self.total});
        try writer.print("  ✅ Succeeded: {d}\n", .{self.succeeded});
        try writer.print("  ❌ Failed: {d}\n", .{self.failed});
        try writer.print("\n", .{});

        for (self.results) |result| {
            const icon = if (result.success) "✅" else "❌";
            try writer.print("{s} {s}\n", .{ icon, result.target });

            if (result.success) {
                if (result.archive_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
                if (result.deb_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
                if (result.rpm_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
                if (result.apk_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
                if (result.scoop_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
                if (result.winget_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
                if (result.chocolatey_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
            } else {
                if (result.error_message) |msg| {
                    try writer.print("   Error: {s}\n", .{msg});
                }
            }
        }
    }

    pub fn allSucceeded(self: PackageSummary) bool {
        return self.succeeded == self.total and self.failed == 0;
    }

    pub fn anyFailed(self: PackageSummary) bool {
        return self.failed > 0;
    }
};

/// Determine the archive format based on target OS and config.
///
/// Windows always produces a `.zip` regardless of the configured tarball
/// format, because Scoop and Winget require zip archives on Windows.
fn determineFormat(target_os: []const u8, pkg_config: ?config.TarballPackage) archive.ArchiveFormat {
    // Windows always uses zip — required by Scoop and Winget.
    if (std.mem.eql(u8, target_os, "windows")) return .zip;

    if (pkg_config) |cfg| {
        const fmt = cfg.getFormat();
        if (std.mem.eql(u8, fmt, "zip")) return .zip;
        if (std.mem.eql(u8, fmt, "tar.gz")) return .tar_gz;
    }

    return .tar_gz;
}

/// Format the target triple for use in filenames.
fn formatTargetTriple(allocator: std.mem.Allocator, target: config.Target) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ target.os, target.arch });
}

/// Ensure a directory exists, creating it if necessary.
fn ensureDirectory(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

/// Package a single target.
fn packageTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: config.Target,
    binary_path: []const u8,
    project_name: []const u8,
    version: []const u8,
    output_dir: []const u8,
    pkg_config: ?config.TarballPackage,
    deb_config: ?config.DebPackage,
    rpm_config: ?config.RpmPackage,
    apk_config: ?config.ApkPackage,
) PackageError!PackageResult {
    const target_triple = try formatTargetTriple(allocator, target);
    errdefer allocator.free(target_triple);

    // Determine format and extension
    const format = determineFormat(target.os, pkg_config);
    const extension: []const u8 = switch (format) {
        .zip => ".zip",
        .tar_gz => ".tar.gz",
    };

    // Build output path: {output_dir}/{name}-{version}-{os}-{arch}.{ext}
    const archive_name = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}{s}",
        .{ project_name, version, target_triple, extension },
    );
    defer allocator.free(archive_name);

    const output_path = try std.fs.path.join(allocator, &.{ output_dir, archive_name });
    defer allocator.free(output_path);

    // Ensure output directory exists
    ensureDirectory(io, output_dir) catch |err| {
        const error_msg = try std.fmt.allocPrint(
            allocator,
            "Failed to create output directory: {}",
            .{err},
        );
        return PackageResult{
            .target = target_triple,
            .success = false,
            .archive_path = null,
            .deb_path = null,
            .rpm_path = null,
            .apk_path = null,
            .scoop_path = null,
            .winget_path = null,
            .chocolatey_path = null,
            .error_message = error_msg,
        };
    };

    // Prepare extra files list
    var extra_files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (extra_files.items) |f| allocator.free(f);
        extra_files.deinit(allocator);
    }

    if (pkg_config) |cfg| {
        for (cfg.extra_files) |f| {
            const copy = try allocator.dupe(u8, f);
            try extra_files.append(allocator, copy);
        }
    }

    // Create archive config
    const archive_config = archive.ArchiveConfig{
        .name = project_name,
        .version = version,
        .target = target_triple,
        .binary_path = binary_path,
        .output_path = output_path,
        .extra_files = extra_files.items,
        .man_pages = if (pkg_config) |cfg| cfg.man_pages else null,
        .completions = if (pkg_config) |cfg| cfg.completions else null,
        .format = format,
    };

    // Create the archive
    const archive_result = try archive.createArchive(allocator, io, archive_config);

    if (!archive_result.success) {
        const error_copy = if (archive_result.error_message) |m|
            try allocator.dupe(u8, m)
        else
            null;
        return PackageResult{
            .target = target_triple,
            .success = false,
            .archive_path = null,
            .deb_path = null,
            .rpm_path = null,
            .apk_path = null,
            .scoop_path = null,
            .winget_path = null,
            .chocolatey_path = null,
            .error_message = error_copy,
        };
    }

    const path_copy = if (archive_result.output_path) |p|
        try allocator.dupe(u8, p)
    else
        null;

    // Generate a .deb package for Linux targets when deb config is present.
    var deb_path_copy: ?[]const u8 = null;
    if (deb_config != null and std.mem.eql(u8, target.os, "linux")) {
        deb_path_copy = try packageTargetDeb(
            allocator,
            io,
            target,
            binary_path,
            project_name,
            version,
            output_dir,
            deb_config.?,
        );
    }

    // Generate a .rpm package for Linux targets when rpm config is present.
    var rpm_path_copy: ?[]const u8 = null;
    if (rpm_config != null and std.mem.eql(u8, target.os, "linux")) {
        rpm_path_copy = try packageTargetRpm(
            allocator,
            io,
            target,
            binary_path,
            project_name,
            version,
            output_dir,
            rpm_config.?,
        );
    }

    // Generate a .apk package for Linux targets when apk config is present.
    var apk_path_copy: ?[]const u8 = null;
    if (apk_config != null and std.mem.eql(u8, target.os, "linux")) {
        apk_path_copy = try packageTargetApk(
            allocator,
            io,
            target,
            binary_path,
            project_name,
            version,
            output_dir,
            apk_config.?,
        );
    }

    return PackageResult{
        .target = target_triple,
        .success = true,
        .archive_path = path_copy,
        .deb_path = deb_path_copy,
        .rpm_path = rpm_path_copy,
        .apk_path = apk_path_copy,
        .scoop_path = null,
        .winget_path = null,
        .chocolatey_path = null,
        .error_message = null,
    };
}

/// Generate a `.deb` package for a single Linux target.
///
/// Returns the output path on success, or null if generation failed (error is
/// logged but does not abort the tarball packaging result).
fn packageTargetDeb(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: config.Target,
    binary_path: []const u8,
    project_name: []const u8,
    version: []const u8,
    output_dir: []const u8,
    deb_cfg: config.DebPackage,
) !?[]const u8 {
    const deb_arch = packagers.deb.debArch(target.arch);
    const deb_name = try std.fmt.allocPrint(
        allocator,
        "{s}_{s}_{s}.deb",
        .{ project_name, version, deb_arch },
    );
    defer allocator.free(deb_name);

    const deb_output = try std.fs.path.join(allocator, &.{ output_dir, deb_name });
    errdefer allocator.free(deb_output);

    const deb_gen_cfg = packagers.deb.DebConfig{
        .name = project_name,
        .version = version,
        .arch = deb_arch,
        .maintainer = deb_cfg.getMaintainer(),
        .license = deb_cfg.license orelse "unknown",
        .binary_path = binary_path,
        .output_path = deb_output,
    };

    packagers.deb.generate(allocator, io, deb_gen_cfg) catch |err| {
        log.err("failed to generate .deb for {s}-{s}: {}", .{ target.os, target.arch, err });
        allocator.free(deb_output);
        return null;
    };

    log.info("generated {s}", .{deb_output});
    return deb_output;
}

/// Generate a `.rpm` package for a single Linux target.
///
/// Returns the output path on success, or null if generation failed (error is
/// logged but does not abort the tarball packaging result).
fn packageTargetRpm(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: config.Target,
    binary_path: []const u8,
    project_name: []const u8,
    version: []const u8,
    output_dir: []const u8,
    rpm_cfg: config.RpmPackage,
) !?[]const u8 {
    const rpm_arch = packagers.rpm.rpmArch(target.arch);
    const rpm_name = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}.{s}.rpm",
        .{ project_name, version, rpm_cfg.getRelease(), rpm_arch },
    );
    defer allocator.free(rpm_name);

    const rpm_output = try std.fs.path.join(allocator, &.{ output_dir, rpm_name });
    errdefer allocator.free(rpm_output);

    const rpm_gen_cfg = packagers.rpm.RpmConfig{
        .name = project_name,
        .version = version,
        .release = rpm_cfg.getRelease(),
        .arch = rpm_arch,
        .summary = rpm_cfg.summary orelse project_name,
        .description = rpm_cfg.description orelse rpm_cfg.summary orelse project_name,
        .license = rpm_cfg.license orelse "unknown",
        .packager = rpm_cfg.getPackager(),
        .url = rpm_cfg.url orelse "",
        .binary_path = binary_path,
        .output_path = rpm_output,
    };

    packagers.rpm.generate(allocator, io, rpm_gen_cfg) catch |err| {
        log.err("failed to generate .rpm for {s}-{s}: {}", .{ target.os, target.arch, err });
        allocator.free(rpm_output);
        return null;
    };

    log.info("generated {s}", .{rpm_output});
    return rpm_output;
}

/// Generate a `.apk` package for a single Linux target.
///
/// Returns the output path on success, or null if generation failed (error is
/// logged but does not abort the tarball packaging result).
fn packageTargetApk(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: config.Target,
    binary_path: []const u8,
    project_name: []const u8,
    version: []const u8,
    output_dir: []const u8,
    apk_cfg: config.ApkPackage,
) !?[]const u8 {
    const apk_arch = packagers.apk.apkArch(target.arch);
    // APK version strings conventionally include a release suffix like "-r0".
    const apk_version = try std.fmt.allocPrint(allocator, "{s}-r0", .{version});
    defer allocator.free(apk_version);

    const apk_name = try std.fmt.allocPrint(
        allocator,
        "{s}-{s}.apk",
        .{ project_name, apk_version },
    );
    defer allocator.free(apk_name);

    const apk_output = try std.fs.path.join(allocator, &.{ output_dir, apk_name });
    errdefer allocator.free(apk_output);

    const apk_gen_cfg = packagers.apk.ApkConfig{
        .name = project_name,
        .version = apk_version,
        .arch = apk_arch,
        .description = apk_cfg.description orelse project_name,
        .license = apk_cfg.license orelse "unknown",
        .maintainer = apk_cfg.getMaintainer(),
        .url = apk_cfg.url orelse "",
        .binary_path = binary_path,
        .output_path = apk_output,
    };

    packagers.apk.generate(allocator, io, apk_gen_cfg) catch |err| {
        log.err("failed to generate .apk for {s}-{s}: {}", .{ target.os, target.arch, err });
        allocator.free(apk_output);
        return null;
    };

    log.info("generated {s}", .{apk_output});
    return apk_output;
}

/// Generate a Scoop manifest JSON file.
///
/// This is called once after all targets are packaged, using the Windows zip
/// archives to compute SHA-256 hashes. Returns the output path on success,
/// or null if generation failed.
pub fn generateScoopManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    version: []const u8,
    output_dir: []const u8,
    results: []const PackageResult,
) !?[]const u8 {
    const scoop_cfg = if (cfg.packages) |p| p.scoop else null;
    if (scoop_cfg == null) return null;

    // Find the Windows zip archives in the results
    var url_64bit: ?[]const u8 = null;
    var sha256_64bit: ?[]const u8 = null;
    var url_arm64: ?[]const u8 = null;
    var sha256_arm64: ?[]const u8 = null;

    for (results) |result| {
        if (!result.success) continue;
        const archive_path = result.archive_path orelse continue;

        // Determine architecture from the target string
        const is_windows_x86_64 = std.mem.indexOf(u8, result.target, "windows-x86_64") != null;
        const is_windows_arm64 = std.mem.indexOf(u8, result.target, "windows-aarch64") != null;

        if (is_windows_x86_64) {
            url_64bit = try buildDownloadUrl(allocator, cfg, version, archive_path);
            sha256_64bit = try computeFileSha256(allocator, archive_path);
        } else if (is_windows_arm64) {
            url_arm64 = try buildDownloadUrl(allocator, cfg, version, archive_path);
            sha256_arm64 = try computeFileSha256(allocator, archive_path);
        }
    }

    // Need at least the 64-bit archive
    if (url_64bit == null or sha256_64bit == null) return null;
    defer {
        if (url_64bit) |u| allocator.free(u);
        if (sha256_64bit) |h| allocator.free(h);
    }

    // Determine binary name
    const binary_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{cfg.project.name});
    defer allocator.free(binary_name);

    // Determine homepage
    const homepage = if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (homepage) |h| allocator.free(h);

    // Determine description and license
    const description = cfg.project.description orelse cfg.project.name;
    const license = cfg.project.license orelse "Unknown";

    // Build output path: {output_dir}/bucket/{name}.json
    const bucket_dir = try std.fs.path.join(allocator, &.{ output_dir, "bucket" });
    defer allocator.free(bucket_dir);
    const manifest_name = try std.fmt.allocPrint(allocator, "{s}.json", .{cfg.project.name});
    defer allocator.free(manifest_name);
    const output_path = try std.fs.path.join(allocator, &.{ bucket_dir, manifest_name });
    defer allocator.free(output_path);

    const scoop_gen_cfg = packagers.scoop.ScoopConfig{
        .project_name = cfg.project.name,
        .version = version,
        .description = description,
        .homepage = homepage orelse "",
        .license = license,
        .url_64bit = url_64bit.?,
        .sha256_64bit = sha256_64bit.?,
        .url_arm64 = url_arm64,
        .sha256_arm64 = sha256_arm64,
        .binary_name = binary_name,
        .output_path = output_path,
    };

    packagers.scoop.generate(allocator, io, scoop_gen_cfg) catch |err| {
        log.err("failed to generate Scoop manifest: {}", .{err});
        return null;
    };

    log.info("generated Scoop manifest: {s}", .{output_path});
    return try allocator.dupe(u8, output_path);
}

/// Generate Winget manifest YAML files.
///
/// This is called once after all targets are packaged, using the Windows zip
/// archives to compute SHA-256 hashes. Returns the output directory path on
/// success, or null if generation failed or winget is not configured.
pub fn generateWingetManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    version: []const u8,
    output_dir: []const u8,
    results: []const PackageResult,
) !?[]const u8 {
    const winget_cfg = if (cfg.packages) |p| p.winget else null;
    if (winget_cfg == null) return null;

    // Find the Windows zip archives in the results
    var url_x64: ?[]const u8 = null;
    var sha256_x64: ?[]const u8 = null;
    var url_arm64: ?[]const u8 = null;
    var sha256_arm64: ?[]const u8 = null;

    for (results) |result| {
        if (!result.success) continue;
        const archive_path = result.archive_path orelse continue;

        // Determine architecture from the target string
        const is_windows_x86_64 = std.mem.indexOf(u8, result.target, "windows-x86_64") != null;
        const is_windows_arm64 = std.mem.indexOf(u8, result.target, "windows-aarch64") != null;

        if (is_windows_x86_64) {
            url_x64 = try buildDownloadUrl(allocator, cfg, version, archive_path);
            sha256_x64 = try computeFileSha256(allocator, archive_path);
        } else if (is_windows_arm64) {
            url_arm64 = try buildDownloadUrl(allocator, cfg, version, archive_path);
            sha256_arm64 = try computeFileSha256(allocator, archive_path);
        }
    }

    // Need at least the x64 archive
    if (url_x64 == null or sha256_x64 == null) return null;
    defer {
        if (url_x64) |u| allocator.free(u);
        if (sha256_x64) |h| allocator.free(h);
    }

    // Determine publisher — fallback to GitHub owner
    const publisher = if (winget_cfg.?.publisher) |p| p else blk: {
        if (cfg.release) |rel| {
            if (rel.github) |gh| break :blk gh.owner;
        }
        return null;
    };

    // Determine binary name
    const binary_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{cfg.project.name});
    defer allocator.free(binary_name);

    // Determine homepage
    const homepage = if (winget_cfg.?.homepage) |h| h else if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (homepage) |h| allocator.free(h);

    // Determine description and license
    const description = winget_cfg.?.description orelse cfg.project.description orelse cfg.project.name;
    const license = cfg.project.license orelse "Unknown";

    // Build output directory: {output_dir}/winget/
    const winget_dir = try std.fs.path.join(allocator, &.{ output_dir, "winget" });
    defer allocator.free(winget_dir);

    const winget_gen_cfg = packagers.winget.WingetConfig{
        .publisher = publisher,
        .project_name = cfg.project.name,
        .version = version,
        .description = description,
        .homepage = homepage orelse "",
        .license = license,
        .url_x64 = url_x64.?,
        .sha256_x64 = try allocator.dupe(u8, sha256_x64.?),
        .url_arm64 = url_arm64,
        .sha256_arm64 = sha256_arm64,
        .binary_name = binary_name,
        .output_dir = winget_dir,
    };
    defer if (winget_gen_cfg.sha256_x64.ptr != sha256_x64.?.ptr) allocator.free(winget_gen_cfg.sha256_x64);

    packagers.winget.generate(allocator, io, winget_gen_cfg) catch |err| {
        log.err("failed to generate Winget manifest: {}", .{err});
        return null;
    };

    log.info("generated Winget manifest: {s}", .{winget_dir});
    return try allocator.dupe(u8, winget_dir);
}

/// Generate a Chocolatey `.nupkg` package.
///
/// This is called once after all targets are packaged, using the Windows zip
/// archives to compute SHA-256 hashes. Returns the output path on success,
/// or null if generation failed or chocolatey is not configured.
pub fn generateChocolateyManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    version: []const u8,
    output_dir: []const u8,
    results: []const PackageResult,
) !?[]const u8 {
    const choco_cfg = if (cfg.packages) |p| p.chocolatey else null;
    if (choco_cfg == null) return null;

    // Chocolatey/NuGet package versions must not include a leading 'v'.
    const chocolatey_version = if (std.mem.startsWith(u8, version, "v")) version[1..] else version;

    // Find the Windows zip archives in the results
    var url_x64: ?[]const u8 = null;
    var sha256_x64: ?[]const u8 = null;
    var url_arm64: ?[]const u8 = null;
    var sha256_arm64: ?[]const u8 = null;

    for (results) |result| {
        if (!result.success) continue;
        const archive_path = result.archive_path orelse continue;

        const is_windows_x86_64 = std.mem.indexOf(u8, result.target, "windows-x86_64") != null;
        const is_windows_arm64 = std.mem.indexOf(u8, result.target, "windows-aarch64") != null;

        if (is_windows_x86_64) {
            url_x64 = try buildDownloadUrl(allocator, cfg, version, archive_path);
            sha256_x64 = try computeFileSha256(allocator, archive_path);
        } else if (is_windows_arm64) {
            url_arm64 = try buildDownloadUrl(allocator, cfg, version, archive_path);
            sha256_arm64 = try computeFileSha256(allocator, archive_path);
        }
    }

    // Need at least the x64 archive
    if (url_x64 == null or sha256_x64 == null) return null;
    defer {
        if (url_x64) |u| allocator.free(u);
        if (sha256_x64) |h| allocator.free(h);
    }

    // Determine title (must differ from package_id — CPMR0050)
    const title = try std.fmt.allocPrint(allocator, "{s} (Portable)", .{cfg.project.name});
    defer allocator.free(title);

    // Determine authors — fallback to GitHub owner
    const authors = if (choco_cfg.?.authors) |a| a else if (cfg.release) |rel|
        if (rel.github) |gh| gh.owner else cfg.project.name
    else
        cfg.project.name;

    // Determine homepage
    const homepage = if (choco_cfg.?.homepage) |h| h else if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (homepage) |h| allocator.free(h);

    // Determine description
    const description = choco_cfg.?.description orelse cfg.project.description orelse cfg.project.name;

    // Determine tags
    const tags = if (choco_cfg.?.tags) |t| t else blk: {
        const default_tags = try std.fmt.allocPrint(allocator, "{s} portable cli", .{cfg.project.name});
        break :blk default_tags;
    };
    defer if (choco_cfg.?.tags == null) allocator.free(tags);

    // Determine package source URL
    const package_source_url = if (choco_cfg.?.package_source_url) |u| u else if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (package_source_url) |u| allocator.free(u);

    // Build license and release notes URLs
    const license_url = if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/blob/main/LICENSE", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (license_url) |u| allocator.free(u);

    const release_notes_url = if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/releases", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (release_notes_url) |u| allocator.free(u);

    const bug_tracker_url = if (cfg.release) |rel|
        if (rel.github) |gh|
            try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}/issues", .{ gh.owner, gh.repo })
        else
            null
    else
        null;
    defer if (bug_tracker_url) |u| allocator.free(u);

    // Binary name
    const binary_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{cfg.project.name});
    defer allocator.free(binary_name);

    // Build output path: {output_dir}/chocolatey/{package_id}.{version}.nupkg
    const choco_dir = try std.fs.path.join(allocator, &.{ output_dir, "chocolatey" });
    defer allocator.free(choco_dir);
    std.Io.Dir.cwd().createDirPath(io, choco_dir) catch {};
    const nupkg_name = try std.fmt.allocPrint(allocator, "{s}.{s}.nupkg", .{ cfg.project.name, chocolatey_version });
    defer allocator.free(nupkg_name);
    const output_path = try std.fs.path.join(allocator, &.{ choco_dir, nupkg_name });
    defer allocator.free(output_path);

    const gen_cfg = packagers.chocolatey.ChocolateyConfig{
        .package_id = cfg.project.name,
        .version = chocolatey_version,
        .title = title,
        .authors = authors,
        .summary = description,
        .description = description,
        .project_url = homepage orelse "",
        .license_url = license_url orelse "",
        .project_source_url = homepage orelse "",
        .bug_tracker_url = bug_tracker_url orelse "",
        .package_source_url = package_source_url orelse "",
        .tags = tags,
        .release_notes = release_notes_url orelse "",
        .icon_url = choco_cfg.?.icon_url,
        .url_x64 = url_x64.?,
        .sha256_x64 = sha256_x64.?,
        .url_arm64 = url_arm64,
        .sha256_arm64 = sha256_arm64,
        .binary_name = binary_name,
        .output_path = output_path,
    };

    packagers.chocolatey.generate(allocator, io, gen_cfg) catch |err| {
        log.err("failed to generate Chocolatey package: {}", .{err});
        return null;
    };

    log.info("generated Chocolatey package: {s}", .{output_path});
    return try allocator.dupe(u8, output_path);
}

/// Build a GitHub release download URL from an archive path.
fn buildDownloadUrl(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    version: []const u8,
    archive_path: []const u8,
) ![]const u8 {
    const gh = if (cfg.release) |rel| rel.github else null;
    if (gh == null) {
        // Fallback: just the filename
        return try allocator.dupe(u8, std.fs.path.basename(archive_path));
    }
    const filename = std.fs.path.basename(archive_path);
    return try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ gh.?.owner, gh.?.repo, version, filename },
    );
}

/// Compute SHA-256 hash of a file.
fn computeFileSha256(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const content = try std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(512 * 1024 * 1024), // 512 MB max
    );
    defer allocator.free(content);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);

    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash);

    return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&hash, .lower)});
}

/// Context for parallel packaging workers.
const PackageWorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    version: []const u8,
    output_dir: []const u8,
    /// Parallel view of cfg.targets: null means the build failed, skip packaging.
    binary_paths: []const ?[]const u8,
    results: []PackageResult,
    allocator_mutex: *std.Io.Mutex,
    /// Shared atomic index: each worker claims the next target by incrementing this.
    next_package_index: std.atomic.Value(usize),
};

/// Generate packages for all targets in parallel, respecting `job_count` concurrency.
///
/// `job_count == 0` means "use all available CPUs". Otherwise at most
/// `job_count` packaging operations run simultaneously.
pub fn generatePackages(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    version: []const u8,
    binary_paths: []const ?[]const u8,
    output_dir: []const u8,
    job_count: usize,
) PackageError!PackageSummary {
    // Check if packaging is configured
    const pkg_config: ?config.TarballPackage = if (cfg.packages) |p|
        p.tarball
    else
        null;

    if (pkg_config == null) {
        // No packaging config, return empty summary
        return PackageSummary{
            .succeeded = 0,
            .failed = 0,
            .total = 0,
            .results = &.{},
        };
    }

    // Create results array
    const results = try allocator.alloc(PackageResult, cfg.targets.len);
    errdefer {
        for (results) |*r| {
            r.deinit(allocator);
        }
        allocator.free(results);
    }

    // Pre-populate failure results for targets without a binary (main thread,
    // no mutex needed). Workers will skip these indices.
    for (cfg.targets, 0..) |target, i| {
        if (binary_paths[i] == null) {
            const target_triple = try formatTargetTriple(allocator, target);
            results[i] = PackageResult{
                .target = target_triple,
                .success = false,
                .archive_path = null,
                .deb_path = null,
                .rpm_path = null,
                .apk_path = null,
                .scoop_path = null,
                .winget_path = null,
                .chocolatey_path = null,
                .error_message = try allocator.dupe(u8, "Build failed - no binary available"),
            };
        }
    }

    // Determine number of concurrent workers.
    // job_count == 0  → one worker per logical CPU (fully parallel)
    // job_count >= 1  → cap at job_count, never exceeding available targets
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const desired_workers: usize = if (job_count == 0) cpu_count else job_count;
    const num_workers = @min(desired_workers, cfg.targets.len);

    var allocator_mutex: std.Io.Mutex = .init;
    var context = PackageWorkerContext{
        .allocator = allocator,
        .io = io,
        .cfg = cfg,
        .version = version,
        .output_dir = output_dir,
        .binary_paths = binary_paths,
        .results = results,
        .allocator_mutex = &allocator_mutex,
        .next_package_index = .init(0),
    };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    // Launch exactly `num_workers` concurrent workers. Each worker loops,
    // atomically claiming the next target index, until all targets are consumed.
    for (0..num_workers) |_| {
        group.concurrent(io, packageWorkerLoop, .{&context}) catch |err| {
            log.warn("Failed to spawn packaging worker: {}", .{err});
        };
    }

    _ = group.await(io) catch {};

    // Generate Scoop manifest (once, after all targets are packaged).
    // This needs the Windows zip archives to exist so it can compute SHA-256.
    const scoop_path = generateScoopManifest(
        allocator,
        io,
        cfg,
        version,
        output_dir,
        results,
    ) catch |err| blk: {
        log.err("failed to generate Scoop manifest: {}", .{err});
        break :blk null;
    };

    // Attach scoop_path to the first successful result for tracking.
    if (scoop_path) |sp| {
        for (results) |*r| {
            if (r.success) {
                r.scoop_path = sp;
                break;
            }
        }
    }

    // Generate Winget manifest (once, after all targets are packaged).
    // This needs the Windows zip archives to exist so it can compute SHA-256.
    const winget_path = generateWingetManifest(
        allocator,
        io,
        cfg,
        version,
        output_dir,
        results,
    ) catch |err| blk: {
        log.err("failed to generate Winget manifest: {}", .{err});
        break :blk null;
    };

    // Attach winget_path to the first successful result for tracking.
    if (winget_path) |wp| {
        for (results) |*r| {
            if (r.success) {
                r.winget_path = wp;
                break;
            }
        }
    }

    // Generate Chocolatey package (once, after all targets are packaged).
    // This needs the Windows zip archives to exist so it can compute SHA-256.
    const chocolatey_path = generateChocolateyManifest(
        allocator,
        io,
        cfg,
        version,
        output_dir,
        results,
    ) catch |err| blk: {
        log.err("failed to generate Chocolatey package: {}", .{err});
        break :blk null;
    };

    // Attach chocolatey_path to the first successful result for tracking.
    if (chocolatey_path) |cp| {
        for (results) |*r| {
            if (r.success) {
                r.chocolatey_path = cp;
                break;
            }
        }
    }

    // Calculate summary
    var summary = PackageSummary{
        .succeeded = 0,
        .failed = 0,
        .total = cfg.targets.len,
        .results = results,
    };

    for (results) |result| {
        if (result.success) {
            summary.succeeded += 1;
        } else {
            summary.failed += 1;
        }
    }

    // Generate checksums if we have successful packages
    if (summary.succeeded > 0) {
        // Collect all artifact paths (tarball + deb) for checksum generation.
        var all_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        defer all_paths.deinit(allocator);

        for (results) |result| {
            if (!result.success) continue;
            if (result.archive_path) |p| try all_paths.append(allocator, p);
            if (result.deb_path) |p| try all_paths.append(allocator, p);
            if (result.rpm_path) |p| try all_paths.append(allocator, p);
            if (result.apk_path) |p| try all_paths.append(allocator, p);
        }

        const checksum_summary = checksum.generateChecksums(
            allocator,
            all_paths.items,
            output_dir,
        ) catch |err| blk: {
            log.err("failed to generate checksums: {}", .{err});
            // Don't fail the build if checksum generation fails
            // Just log the error and continue
            break :blk null;
        };

        if (checksum_summary) |cs| {
            defer cs.deinit(allocator);
            if (cs.sha256_result) |r| {
                log.info("generated {s} checksums: {s} ({d} files)", .{
                    r.algorithm.displayName(),
                    r.output_path,
                    r.files_checked,
                });
            }
            if (cs.blake3_result) |r| {
                log.info("generated {s} checksums: {s} ({d} files)", .{
                    r.algorithm.displayName(),
                    r.output_path,
                    r.files_checked,
                });
            }
        }
    }

    return summary;
}

/// Worker loop: atomically claims target indices and runs packaging until none remain.
/// Skips indices whose binary_paths entry is null (pre-populated as failed in main thread).
fn packageWorkerLoop(context: *PackageWorkerContext) std.Io.Cancelable!void {
    while (true) {
        // Claim the next target index atomically.
        const i = context.next_package_index.fetchAdd(1, .seq_cst);
        if (i >= context.cfg.targets.len) break;

        // Skip targets that didn't build successfully (result already pre-populated).
        if (context.binary_paths[i] == null) continue;

        try packageWorker(context, context.cfg.targets[i], context.binary_paths[i].?, i);
    }
}

/// Worker function for parallel packaging.
fn packageWorker(
    context: *const PackageWorkerContext,
    target: config.Target,
    binary_path: []const u8,
    index: usize,
) std.Io.Cancelable!void {
    const allocator = context.allocator;
    const temp_allocator = std.heap.smp_allocator;

    const result = packageTarget(
        temp_allocator,
        context.io,
        target,
        binary_path,
        context.cfg.project.name,
        context.version,
        context.output_dir,
        if (context.cfg.packages) |p| p.tarball else null,
        if (context.cfg.packages) |p| p.deb else null,
        if (context.cfg.packages) |p| p.rpm else null,
        if (context.cfg.packages) |p| p.apk else null,
    ) catch |err| {
        const target_triple_temp = formatTargetTriple(temp_allocator, target) catch {
            return;
        };
        defer temp_allocator.free(target_triple_temp);
        const error_msg_temp = std.fmt.allocPrint(
            temp_allocator,
            "Packaging failed: {}",
            .{err},
        ) catch null;
        defer if (error_msg_temp) |msg| temp_allocator.free(msg);

        context.allocator_mutex.lockUncancelable(context.io);
        defer context.allocator_mutex.unlock(context.io);

        context.results[index] = PackageResult{
            .target = allocator.dupe(u8, target_triple_temp) catch return,
            .success = false,
            .archive_path = null,
            .deb_path = null,
            .rpm_path = null,
            .apk_path = null,
            .scoop_path = null,
            .winget_path = null,
            .chocolatey_path = null,
            .error_message = if (error_msg_temp) |msg| allocator.dupe(u8, msg) catch null else null,
        };
        return;
    };

    defer {
        temp_allocator.free(result.target);
        if (result.archive_path) |path| temp_allocator.free(path);
        if (result.deb_path) |path| temp_allocator.free(path);
        if (result.rpm_path) |path| temp_allocator.free(path);
        if (result.apk_path) |path| temp_allocator.free(path);
        if (result.scoop_path) |path| temp_allocator.free(path);
        if (result.winget_path) |path| temp_allocator.free(path);
        if (result.error_message) |msg| temp_allocator.free(msg);
    }

    const copied_target = allocator.dupe(u8, result.target) catch return;
    const copied_archive = if (result.archive_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_deb = if (result.deb_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_rpm = if (result.rpm_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_apk = if (result.apk_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_scoop = if (result.scoop_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_winget = if (result.winget_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_chocolatey = if (result.chocolatey_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_error = if (result.error_message) |msg| allocator.dupe(u8, msg) catch null else null;

    context.allocator_mutex.lockUncancelable(context.io);
    defer context.allocator_mutex.unlock(context.io);

    context.results[index] = .{
        .target = copied_target,
        .success = result.success,
        .archive_path = copied_archive,
        .deb_path = copied_deb,
        .rpm_path = copied_rpm,
        .apk_path = copied_apk,
        .scoop_path = copied_scoop,
        .winget_path = copied_winget,
        .chocolatey_path = copied_chocolatey,
        .error_message = copied_error,
    };

    return;
}

/// Free memory associated with a package summary.
pub fn freePackageSummary(allocator: std.mem.Allocator, summary: *const PackageSummary) void {
    for (summary.results) |result| {
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
    allocator.free(summary.results);
}

test "determineFormat returns correct format" {
    const allocator = std.testing.allocator;

    // Windows without config → zip
    const win_result = determineFormat("windows", null);
    try std.testing.expectEqual(archive.ArchiveFormat.zip, win_result);

    // Linux without config → tar.gz
    const linux_result = determineFormat("linux", null);
    try std.testing.expectEqual(archive.ArchiveFormat.tar_gz, linux_result);

    // macOS without config → tar.gz
    const macos_result = determineFormat("macos", null);
    try std.testing.expectEqual(archive.ArchiveFormat.tar_gz, macos_result);

    // Explicit zip config overrides OS default
    const zip_config = config.TarballPackage{
        .format = try allocator.dupe(u8, "zip"),
        .extra_files = &.{},
        .man_pages = null,
        .completions = null,
    };
    defer allocator.free(zip_config.format.?);

    const explicit_zip = determineFormat("linux", zip_config);
    try std.testing.expectEqual(archive.ArchiveFormat.zip, explicit_zip);
}

test "formatTargetTriple formats correctly" {
    const allocator = std.testing.allocator;

    const target = config.Target{
        .os = "linux",
        .arch = "x86_64",
        .cpu = null,
    };

    const triple = try formatTargetTriple(allocator, target);
    defer allocator.free(triple);

    try std.testing.expectEqualStrings("linux-x86_64", triple);
}

test "PackageSummary calculates correctly" {
    const allocator = std.testing.allocator;

    var results = try allocator.alloc(PackageResult, 3);
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    results[0] = PackageResult{
        .target = try allocator.dupe(u8, "linux-x86_64"),
        .success = true,
        .archive_path = try allocator.dupe(u8, "/path/to/archive.tar.gz"),
        .deb_path = null,
        .rpm_path = null,
        .apk_path = null,
        .scoop_path = null,
        .winget_path = null,
        .chocolatey_path = null,
        .error_message = null,
    };

    results[1] = PackageResult{
        .target = try allocator.dupe(u8, "macos-aarch64"),
        .success = false,
        .archive_path = null,
        .deb_path = null,
        .rpm_path = null,
        .apk_path = null,
        .scoop_path = null,
        .winget_path = null,
        .chocolatey_path = null,
        .error_message = try allocator.dupe(u8, "Build failed"),
    };

    results[2] = PackageResult{
        .target = try allocator.dupe(u8, "windows-x86_64"),
        .success = true,
        .archive_path = try allocator.dupe(u8, "/path/to/archive.zip"),
        .deb_path = null,
        .rpm_path = null,
        .apk_path = null,
        .scoop_path = null,
        .winget_path = null,
        .chocolatey_path = null,
        .error_message = null,
    };

    const summary = PackageSummary{
        .succeeded = 2,
        .failed = 1,
        .total = 3,
        .results = results,
    };

    try std.testing.expect(!summary.allSucceeded());
    try std.testing.expect(summary.anyFailed());
    try std.testing.expectEqual(@as(usize, 2), summary.succeeded);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
}

test "generatePackages with no config returns empty summary" {
    const allocator = std.testing.allocator;

    const cfg = config.Config{
        .project = .{ .name = "test" },
        .targets = &.{},
        .packages = null,
    };

    const summary = try generatePackages(
        allocator,
        std.Options.debug_io,
        cfg,
        "1.0.0",
        &.{},
        "dist",
        1,
    );

    try std.testing.expectEqual(@as(usize, 0), summary.total);
    try std.testing.expect(summary.allSucceeded());
}

test "packageWorkerLoop claims all indices with bounded workers" {
    // Verify that num_workers < num_targets still processes every target slot.
    // We use all-null binary_paths so workers skip packaging (pre-populated in
    // main thread) and just advance the atomic index — giving us a fast,
    // deterministic test with no I/O.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const targets = [_]config.Target{
        .{ .os = "linux", .arch = "x86_64", .cpu = null },
        .{ .os = "linux", .arch = "aarch64", .cpu = null },
        .{ .os = "macos", .arch = "aarch64", .cpu = null },
        .{ .os = "windows", .arch = "x86_64", .cpu = null },
        .{ .os = "linux", .arch = "riscv64", .cpu = null },
    };
    const num_targets = targets.len;
    const job_count = 2; // fewer workers than targets

    // All binary_paths are null → all results pre-populated as failures.
    const binary_paths = [_]?[]const u8{ null, null, null, null, null };

    var results = try allocator.alloc(PackageResult, num_targets);
    // Pre-populate as the main thread would (mirrors generatePackages logic).
    for (targets, 0..) |target, i| {
        results[i] = PackageResult{
            .target = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ target.os, target.arch }),
            .success = false,
            .archive_path = null,
            .deb_path = null,
            .rpm_path = null,
            .apk_path = null,
            .scoop_path = null,
            .winget_path = null,
            .chocolatey_path = null,
            .error_message = try allocator.dupe(u8, "Build failed - no binary available"),
        };
    }
    defer {
        for (results) |*r| r.deinit(allocator);
        allocator.free(results);
    }

    var allocator_mutex: std.Io.Mutex = .init;
    var ctx = PackageWorkerContext{
        .allocator = allocator,
        .io = io,
        .cfg = .{
            .project = .{ .name = "test" },
            .targets = &targets,
            .packages = null,
        },
        .version = "0.0.0",
        .output_dir = "dist",
        .binary_paths = &binary_paths,
        .results = results,
        .allocator_mutex = &allocator_mutex,
        .next_package_index = .init(0),
    };

    // Spawn min(job_count, num_targets) workers — same formula as generatePackages.
    const num_workers = @min(job_count, num_targets);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..num_workers) |_| {
        try group.concurrent(io, packageWorkerLoop, .{&ctx});
    }
    _ = group.await(io) catch {};

    // All target slots must have been visited: the atomic index must be >= num_targets.
    const final_index = ctx.next_package_index.load(.seq_cst);
    try std.testing.expect(final_index >= num_targets);
}
