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
    error_message: ?[]const u8,

    pub fn deinit(self: *PackageResult, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.archive_path) |p| allocator.free(p);
        if (self.deb_path) |p| allocator.free(p);
        if (self.rpm_path) |p| allocator.free(p);
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
fn determineFormat(target_os: []const u8, pkg_config: ?config.TarballPackage) archive.ArchiveFormat {
    if (pkg_config) |cfg| {
        const fmt = cfg.getFormat();
        if (std.mem.eql(u8, fmt, "zip")) return .zip;
        if (std.mem.eql(u8, fmt, "tar.gz")) return .tar_gz;
    }

    // Default: tar.gz for Unix-like, zip for Windows
    if (std.mem.eql(u8, target_os, "windows")) {
        return .zip;
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
) PackageError!PackageResult {
    const target_triple = try formatTargetTriple(allocator, target);
    errdefer allocator.free(target_triple);

    // Determine format and extension
    const format = determineFormat(target.os, pkg_config);
    const extension = if (pkg_config) |cfg| cfg.getExtension() else ".tar.gz";

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

    return PackageResult{
        .target = target_triple,
        .success = true,
        .archive_path = path_copy,
        .deb_path = deb_path_copy,
        .rpm_path = rpm_path_copy,
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
            .error_message = if (error_msg_temp) |msg| allocator.dupe(u8, msg) catch null else null,
        };
        return;
    };

    defer {
        temp_allocator.free(result.target);
        if (result.archive_path) |path| temp_allocator.free(path);
        if (result.deb_path) |path| temp_allocator.free(path);
        if (result.rpm_path) |path| temp_allocator.free(path);
        if (result.error_message) |msg| temp_allocator.free(msg);
    }

    const copied_target = allocator.dupe(u8, result.target) catch return;
    const copied_archive = if (result.archive_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_deb = if (result.deb_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_rpm = if (result.rpm_path) |path| allocator.dupe(u8, path) catch null else null;
    const copied_error = if (result.error_message) |msg| allocator.dupe(u8, msg) catch null else null;

    context.allocator_mutex.lockUncancelable(context.io);
    defer context.allocator_mutex.unlock(context.io);

    context.results[index] = .{
        .target = copied_target,
        .success = result.success,
        .archive_path = copied_archive,
        .deb_path = copied_deb,
        .rpm_path = copied_rpm,
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
        .error_message = null,
    };

    results[1] = PackageResult{
        .target = try allocator.dupe(u8, "macos-aarch64"),
        .success = false,
        .archive_path = null,
        .deb_path = null,
        .rpm_path = null,
        .error_message = try allocator.dupe(u8, "Build failed"),
    };

    results[2] = PackageResult{
        .target = try allocator.dupe(u8, "windows-x86_64"),
        .success = true,
        .archive_path = try allocator.dupe(u8, "/path/to/archive.zip"),
        .deb_path = null,
        .rpm_path = null,
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
