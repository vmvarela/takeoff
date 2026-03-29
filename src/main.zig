const std = @import("std");
const ZigReleaser = @import("ZigReleaser");
const config = @import("ZigReleaser").config;
const build_mod = @import("ZigReleaser").build;
const parallel_build = @import("ZigReleaser").parallel_build;

const log = std.log.scoped(.main);

pub const WriteError = std.fs.File.WriteError;

const MainError = error{
    OutOfMemory,
    WriteError,
} || ZigReleaser.CliError;

/// Build options parsed from CLI.
pub const BuildOptions = struct {
    /// Number of parallel jobs (0 = use CPU count)
    jobs: usize = 0,
    /// Optimization level: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
    optimize: []const u8 = "ReleaseSafe",
    /// Enable verbose output
    verbose: bool = false,
    /// Skip building (dry run)
    dry_run: bool = false,
    /// Build timeout in seconds (0 = no timeout)
    timeout: u64 = 0,
};

/// Verify options parsed from CLI.
pub const VerifyOptions = struct {
    /// Path to checksums file (null = auto-detect)
    checksums_file: ?[]const u8 = null,
    /// Hash algorithm (null = auto-detect from filename)
    algorithm: ?ZigReleaser.checksum.HashAlgorithm = null,
    /// Base directory for relative paths
    base_dir: ?[]const u8 = null,
};

/// Release options parsed from CLI.
pub const ReleaseOptions = struct {
    /// Tag for release (default: git describe --tags)
    tag: ?[]const u8 = null,
    /// Release notes (default: CHANGELOG.md entry)
    notes: ?[]const u8 = null,
    /// Create as draft
    draft: bool = false,
    /// Mark as prerelease
    prerelease: bool = false,
    /// Show what would be done without executing
    dry_run: bool = false,
    /// Delete existing assets before uploading
    clean_assets: bool = false,
    /// Path to dist directory (default: "dist")
    dist_dir: []const u8 = "dist",
    /// Path to CHANGELOG.md (default: "CHANGELOG.md")
    changelog_path: []const u8 = "CHANGELOG.md",
};

pub const Command = union(enum) {
    version,
    help,
    check,
    build: BuildOptions,
    verify: VerifyOptions,
    release: ReleaseOptions,

    /// Parse CLI arguments into a Command. Returns `.help` for empty args.
    pub fn fromArgs(allocator: std.mem.Allocator, args: []const []const u8) (ZigReleaser.CliError || std.mem.Allocator.Error)!Command {
        if (args.len == 0) return .help;

        const arg = args[0];

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))
            return .version;

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            return .help;

        if (std.mem.eql(u8, arg, "check"))
            return .check;

        if (std.mem.eql(u8, arg, "verify")) {
            var options = VerifyOptions{};
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const opt = args[i];
                if (std.mem.eql(u8, opt, "--help") or std.mem.eql(u8, opt, "-h")) {
                    return .help;
                }
                if (std.mem.eql(u8, opt, "--file") or std.mem.eql(u8, opt, "-f")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--file requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.checksums_file = try allocator.dupe(u8, args[i]);
                } else if (std.mem.eql(u8, opt, "--algo") or std.mem.eql(u8, opt, "-a")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--algo requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    const algo = args[i];
                    if (std.mem.eql(u8, algo, "sha256")) {
                        options.algorithm = .sha256;
                    } else if (std.mem.eql(u8, algo, "blake3")) {
                        options.algorithm = .blake3;
                    } else {
                        log.warn("invalid algorithm: {s} (must be sha256 or blake3)", .{algo});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                } else if (std.mem.eql(u8, opt, "--dir") or std.mem.eql(u8, opt, "-d")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--dir requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.base_dir = try allocator.dupe(u8, args[i]);
                } else if (opt.len > 0 and opt[0] != '-') {
                    // Positional argument: checksums file
                    options.checksums_file = try allocator.dupe(u8, opt);
                } else {
                    log.err("unknown verify option: {s}", .{opt});
                    return ZigReleaser.CliError.InvalidArguments;
                }
            }
            return Command{ .verify = options };
        }

        if (std.mem.eql(u8, arg, "build")) {
            var options = BuildOptions{};
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const opt = args[i];
                // Handle help for build command
                if (std.mem.eql(u8, opt, "--help") or std.mem.eql(u8, opt, "-h")) {
                    return .help;
                }
                if (std.mem.eql(u8, opt, "--jobs") or std.mem.eql(u8, opt, "-j")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--jobs requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.jobs = std.fmt.parseInt(usize, args[i], 10) catch {
                        log.warn("invalid value for --jobs: {s}", .{args[i]});
                        return ZigReleaser.CliError.InvalidArguments;
                    };
                } else if (std.mem.eql(u8, opt, "--optimize") or std.mem.eql(u8, opt, "-O")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--optimize requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    const opt_level = args[i];
                    if (!std.mem.eql(u8, opt_level, "Debug") and
                        !std.mem.eql(u8, opt_level, "ReleaseSafe") and
                        !std.mem.eql(u8, opt_level, "ReleaseFast") and
                        !std.mem.eql(u8, opt_level, "ReleaseSmall"))
                    {
                        log.warn("invalid optimize level: {s} (must be Debug, ReleaseSafe, ReleaseFast, or ReleaseSmall)", .{opt_level});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.optimize = try allocator.dupe(u8, opt_level);
                } else if (std.mem.eql(u8, opt, "--verbose") or std.mem.eql(u8, opt, "-v")) {
                    options.verbose = true;
                } else if (std.mem.eql(u8, opt, "--dry-run") or std.mem.eql(u8, opt, "-n")) {
                    options.dry_run = true;
                } else if (std.mem.eql(u8, opt, "--timeout")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--timeout requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.timeout = std.fmt.parseInt(u64, args[i], 10) catch {
                        log.err("invalid value for --timeout: {s}", .{args[i]});
                        return ZigReleaser.CliError.InvalidArguments;
                    };
                } else {
                    log.err("unknown build option: {s}", .{opt});
                    return ZigReleaser.CliError.InvalidArguments;
                }
            }
            return Command{ .build = options };
        }

        if (std.mem.eql(u8, arg, "release")) {
            var options = ReleaseOptions{};
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                const opt = args[i];
                if (std.mem.eql(u8, opt, "--help") or std.mem.eql(u8, opt, "-h")) {
                    return .help;
                }
                if (std.mem.eql(u8, opt, "--tag") or std.mem.eql(u8, opt, "-t")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--tag requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.tag = try allocator.dupe(u8, args[i]);
                } else if (std.mem.eql(u8, opt, "--notes") or std.mem.eql(u8, opt, "-n")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--notes requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.notes = try allocator.dupe(u8, args[i]);
                } else if (std.mem.eql(u8, opt, "--draft") or std.mem.eql(u8, opt, "-d")) {
                    options.draft = true;
                } else if (std.mem.eql(u8, opt, "--prerelease") or std.mem.eql(u8, opt, "-p")) {
                    options.prerelease = true;
                } else if (std.mem.eql(u8, opt, "--dry-run")) {
                    options.dry_run = true;
                } else if (std.mem.eql(u8, opt, "--clean-assets")) {
                    options.clean_assets = true;
                } else if (std.mem.eql(u8, opt, "--dist") or std.mem.eql(u8, opt, "-D")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--dist requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.dist_dir = try allocator.dupe(u8, args[i]);
                } else if (std.mem.eql(u8, opt, "--changelog") or std.mem.eql(u8, opt, "-c")) {
                    i += 1;
                    if (i >= args.len) {
                        log.err("--changelog requires a value", .{});
                        return ZigReleaser.CliError.InvalidArguments;
                    }
                    options.changelog_path = try allocator.dupe(u8, args[i]);
                } else {
                    log.err("unknown release option: {s}", .{opt});
                    return ZigReleaser.CliError.InvalidArguments;
                }
            }
            return Command{ .release = options };
        }

        log.warn("unknown command: {s}", .{arg});
        return ZigReleaser.CliError.UnknownCommand;
    }

    /// Free any allocated memory in the command.
    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        switch (self) {
            .build => |opts| {
                // Only free if we allocated the optimize string (not the default)
                if (opts.optimize.ptr != "ReleaseSafe".ptr) {
                    allocator.free(opts.optimize);
                }
            },
            .verify => |opts| {
                if (opts.checksums_file) |f| allocator.free(f);
                if (opts.base_dir) |d| allocator.free(d);
            },
            .release => |opts| {
                if (opts.tag) |t| allocator.free(t);
                if (opts.notes) |n| allocator.free(n);
                // Only free if we allocated the dist_dir string (not the default)
                if (opts.dist_dir.ptr != "dist".ptr) {
                    allocator.free(opts.dist_dir);
                }
                // Only free if we allocated the changelog_path string (not the default)
                if (opts.changelog_path.ptr != "CHANGELOG.md".ptr) {
                    allocator.free(opts.changelog_path);
                }
            },
            else => {},
        }
    }
};

pub fn main(init: std.process.Init) u8 {
    const allocator = init.arena.allocator();

    const args = init.minimal.args.toSlice(allocator) catch |err| {
        log.err("failed to allocate args: {}", .{err});
        return 1;
    };

    // args[0] is the executable name; skip it.
    const cmd_args: []const []const u8 = if (args.len > 1) blk: {
        var out: []const []const u8 = undefined;
        out.ptr = @ptrCast(args.ptr + 1);
        out.len = args.len - 1;
        break :blk out;
    } else &[_][]const u8{};

    const command = Command.fromArgs(allocator, cmd_args) catch |err| {
        log.err("invalid command: {}", .{err});
        return 1;
    };
    defer command.deinit(allocator);

    return executeCommand(allocator, command);
}

fn executeCommand(allocator: std.mem.Allocator, command: Command) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buffer);
    var stderr_writer = stderr_file.writer(io, &stderr_buffer);
    defer {
        stdout_writer.interface.flush() catch {};
        stderr_writer.interface.flush() catch {};
    }

    switch (command) {
        .version => {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zr {s}\n", .{ZigReleaser.VERSION}) catch {
                log.err("version string too long", .{});
                return 1;
            };
            stdout_writer.interface.writeAll(msg) catch |err| {
                log.err("failed to write version: {}", .{err});
                return 1;
            };
        },
        .help => {
            stdout_writer.interface.writeAll(usage) catch |err| {
                log.err("failed to write usage: {}", .{err});
                return 1;
            };
        },
        .check => {
            const check_allocator = std.heap.smp_allocator;

            var cfg = ZigReleaser.config.loadDefault(check_allocator, io) catch |err| {
                stderr_writer.interface.print("Error: ", .{}) catch {};
                ZigReleaser.config.formatParseError(err, &stderr_writer.interface) catch {};
                stderr_writer.interface.print("\n", .{}) catch {};
                return 1;
            };

            ZigReleaser.config.validate(&cfg) catch |err| {
                stderr_writer.interface.print("Validation error: ", .{}) catch {};
                ZigReleaser.config.formatValidationError(err, &stderr_writer.interface) catch {};
                stderr_writer.interface.print("\n", .{}) catch {};
                return 1;
            };

            stdout_writer.interface.writeAll("✓ zr.jsonc is valid\n") catch |err| {
                log.err("failed to write output: {}", .{err});
                return 1;
            };
        },
        .build => |opts| {
            return executeBuild(allocator, opts);
        },
        .verify => |opts| {
            return executeVerify(allocator, opts);
        },
        .release => |opts| {
            return executeRelease(allocator, opts);
        },
    }
    return 0;
}

fn executeBuild(allocator: std.mem.Allocator, opts: BuildOptions) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buffer);
    var stderr_writer = stderr_file.writer(io, &stderr_buffer);
    defer {
        stdout_writer.interface.flush() catch {};
        stderr_writer.interface.flush() catch {};
    }
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Load configuration
    var cfg = ZigReleaser.config.loadDefault(allocator, io) catch |err| {
        stderr.print("Error: ", .{}) catch {};
        ZigReleaser.config.formatParseError(err, stderr) catch {};
        stderr.print("\n", .{}) catch {};
        return 1;
    };

    // Validate configuration
    ZigReleaser.config.validate(&cfg) catch |err| {
        stderr.print("Validation error: ", .{}) catch {};
        ZigReleaser.config.formatValidationError(err, stderr) catch {};
        stderr.print("\n", .{}) catch {};
        return 1;
    };

    // Determine job count
    const job_count = if (opts.jobs == 0)
        std.Thread.getCpuCount() catch 4
    else
        opts.jobs;

    // Get version from git or use config version
    const version = blk: {
        if (ZigReleaser.git.getVersion(allocator, io) catch null) |git_version| {
            break :blk git_version;
        }
        if (cfg.project.version) |v| {
            break :blk allocator.dupe(u8, v) catch "unknown";
        }
        break :blk "unknown";
    };
    defer if (version.ptr != "unknown".ptr) allocator.free(version);

    if (opts.verbose) {
        stdout.print("Building {s} v{s} for {d} target(s) with {d} parallel job(s)...\n", .{
            cfg.project.name,
            version,
            cfg.targets.len,
            job_count,
        }) catch {};
    }

    // Dry run - just print what would be built
    if (opts.dry_run) {
        stdout.print("\nDry run - would build:\n", .{}) catch {};
        for (cfg.targets) |target| {
            stdout.print("  {s}-{s}\n", .{ target.arch, target.os }) catch {};
        }
        return 0;
    }

    // Run parallel builds
    const summary = parallel_build.runParallelBuilds(
        allocator,
        cfg.targets,
        cfg.project.name,
        cfg.build.output,
        cfg.build.flags,
        version,
        opts.optimize,
        job_count,
        opts.verbose,
    ) catch |err| {
        stderr.print("Build failed: {}\n", .{err}) catch {};
        return 1;
    };
    defer parallel_build.freeBuildSummary(allocator, @constCast(&summary));

    // Print summary
    summary.print(stdout) catch {};

    // Return appropriate exit code
    if (summary.anyFailed()) {
        return 1;
    }

    // Extract artifact paths for packaging
    const artifact_paths = allocator.alloc(?[]const u8, summary.jobs.len) catch |err| {
        stderr.print("Failed to allocate artifact paths: {}\n", .{err}) catch {};
        return 1;
    };
    defer allocator.free(artifact_paths);
    for (summary.jobs, 0..) |job, i| {
        artifact_paths[i] = job.artifact_path;
    }

    // Generate packages
    const package_summary = ZigReleaser.packager.generatePackages(
        allocator,
        cfg,
        version,
        artifact_paths,
        cfg.build.output_dir orelse "dist",
        job_count,
    ) catch |err| {
        stderr.print("Packaging failed: {}\n", .{err}) catch {};
        return 1;
    };
    defer ZigReleaser.packager.freePackageSummary(allocator, @constCast(&package_summary));

    // Print packaging summary if there were any packages
    if (package_summary.total > 0) {
        package_summary.print(stdout) catch {};

        if (package_summary.anyFailed()) {
            return 1;
        }
    }

    return 0;
}

fn executeVerify(allocator: std.mem.Allocator, opts: VerifyOptions) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buffer);
    var stderr_writer = stderr_file.writer(io, &stderr_buffer);
    defer {
        stdout_writer.interface.flush() catch {};
        stderr_writer.interface.flush() catch {};
    }
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const result = ZigReleaser.verify.verify(allocator, .{
        .checksums_file = opts.checksums_file,
        .algorithm = opts.algorithm,
        .base_dir = opts.base_dir,
    }) catch |err| {
        stderr.print("Verification failed: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    defer result.deinit(allocator);

    ZigReleaser.verify.printResult(result, stdout) catch {};

    return 0;
}

fn executeRelease(allocator: std.mem.Allocator, opts: ReleaseOptions) u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buffer);
    var stderr_writer = stderr_file.writer(io, &stderr_buffer);
    defer {
        stdout_writer.interface.flush() catch {};
        stderr_writer.interface.flush() catch {};
    }
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Load configuration
    var cfg = ZigReleaser.config.loadDefault(allocator, io) catch |err| {
        stderr.print("Error: ", .{}) catch {};
        ZigReleaser.config.formatParseError(err, stderr) catch {};
        stderr.print("\n", .{}) catch {};
        return 1;
    };

    // Validate configuration
    ZigReleaser.config.validate(&cfg) catch |err| {
        stderr.print("Validation error: ", .{}) catch {};
        ZigReleaser.config.formatValidationError(err, stderr) catch {};
        stderr.print("\n", .{}) catch {};
        return 1;
    };

    // Check if GitHub release is configured
    const github_config = if (cfg.release) |r| r.github else {
        stderr.print("Error: No GitHub release configuration found in zr.jsonc\n", .{}) catch {};
        stderr.print("Add release.github with owner and repo fields\n", .{}) catch {};
        return 1;
    };

    if (github_config == null) {
        stderr.print("Error: No GitHub release configuration found in zr.jsonc\n", .{}) catch {};
        return 1;
    }

    const gh = github_config.?;

    // Get the tag
    const tag = if (opts.tag) |t|
        allocator.dupe(u8, t) catch {
            stderr.print("Error: Out of memory\n", .{}) catch {};
            return 1;
        }
    else blk: {
        if (ZigReleaser.git.getVersion(allocator, io) catch null) |git_version| {
            break :blk git_version;
        }
        stderr.print("Error: Could not determine tag from git. Use --tag to specify.\n", .{}) catch {};
        return 1;
    };
    defer allocator.free(tag);

    // Verify tag exists
    const tag_exists = ZigReleaser.git.tagExists(allocator, io, tag) catch |err| {
        stderr.print("Error: Failed to check if tag exists: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    if (!tag_exists) {
        stderr.print("Error: Tag '{s}' does not exist in this repository.\n", .{tag}) catch {};
        stderr.print("Create the tag first with: git tag {s}\n", .{tag}) catch {};
        return 1;
    }

    // Get release notes
    const notes = if (opts.notes) |n|
        allocator.dupe(u8, n) catch {
            stderr.print("Error: Out of memory\n", .{}) catch {};
            return 1;
        }
    else blk: {
        if (ZigReleaser.changelog.extractVersionNotes(
            allocator,
            io,
            opts.changelog_path,
            tag,
        ) catch null) |changelog_notes| {
            break :blk changelog_notes;
        }
        const release_notes = std.fmt.allocPrint(allocator, "Release {s}", .{tag}) catch {
            stderr.print("Error: Out of memory\n", .{}) catch {};
            return 1;
        };
        break :blk release_notes;
    };
    defer allocator.free(notes);

    // Find artifacts to upload
    const artifacts = ZigReleaser.changelog.findArtifacts(allocator, io, opts.dist_dir) catch |err| {
        stderr.print("Error: Failed to find artifacts: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    defer ZigReleaser.changelog.freeArtifacts(allocator, artifacts);

    if (artifacts.len == 0) {
        stderr.print("Error: No artifacts found in {s}\n", .{opts.dist_dir}) catch {};
        stderr.print("Run 'zr build' first to generate artifacts.\n", .{}) catch {};
        return 1;
    }

    // Convert artifact paths to relative names for upload
    const asset_names = allocator.alloc([]const u8, artifacts.len) catch {
        stderr.print("Error: Out of memory\n", .{}) catch {};
        return 1;
    };
    defer allocator.free(asset_names);

    for (artifacts, 0..) |artifact, i| {
        asset_names[i] = std.fs.path.basename(artifact);
    }

    // Dry run - just print what would be done
    if (opts.dry_run) {
        stdout.print("\nDry run - would release:\n", .{}) catch {};
        stdout.print("  Repository: {s}/{s}\n", .{ gh.owner, gh.repo }) catch {};
        stdout.print("  Tag: {s}\n", .{tag}) catch {};
        stdout.print("  Draft: {}\n", .{opts.draft}) catch {};
        stdout.print("  Prerelease: {}\n", .{opts.prerelease}) catch {};
        stdout.print("  Clean assets: {}\n", .{opts.clean_assets}) catch {};
        stdout.print("\nRelease notes:\n{s}\n\n", .{notes}) catch {};
        stdout.print("Artifacts to upload:\n", .{}) catch {};
        for (artifacts) |artifact| {
            stdout.print("  - {s}\n", .{std.fs.path.basename(artifact)}) catch {};
        }
        return 0;
    }

    // Publish the release
    const release_opts = ZigReleaser.publishers.ReleaseOptions{
        .owner = gh.owner,
        .repo = gh.repo,
        .tag = tag,
        .name = tag,
        .body = notes,
        .draft = opts.draft,
        .prerelease = opts.prerelease,
    };

    const result = ZigReleaser.publishers.publishRelease(
        allocator,
        release_opts,
        opts.dist_dir,
        asset_names,
        opts.clean_assets,
    ) catch |err| {
        stderr.print("Error: Release failed: {s}\n", .{@errorName(err)}) catch {};
        return 1;
    };
    defer @constCast(&result).deinit(allocator);

    if (result.success) {
        stdout.print("\n✅ Release published successfully!\n", .{}) catch {};
        stdout.print("   URL: {s}\n", .{result.html_url}) catch {};
        if (result.deleted_assets > 0) {
            stdout.print("   Assets deleted: {d}\n", .{result.deleted_assets}) catch {};
        }
        stdout.print("   Assets uploaded: {d}\n", .{result.uploaded_assets}) catch {};
        return 0;
    } else {
        stdout.print("\n⚠️  Release completed with errors:\n", .{}) catch {};
        stdout.print("   URL: {s}\n", .{result.html_url}) catch {};
        if (result.deleted_assets > 0) {
            stdout.print("   Assets deleted: {d}\n", .{result.deleted_assets}) catch {};
        }
        stdout.print("   Assets uploaded: {d}\n", .{result.uploaded_assets}) catch {};
        if (result.errors.len > 0) {
            stdout.print("\n   Errors:\n", .{}) catch {};
            for (result.errors) |err| {
                stdout.print("   - {s}\n", .{err}) catch {};
            }
        }
        return 1;
    }
}

const usage =
    \\zr - Release automation for Zig projects
    \\
    \\Usage:
    \\  zr [OPTIONS] [COMMAND]
    \\
    \\Commands:
    \\  check            Validate zr.jsonc configuration
    \\  build            Build all targets in parallel
    \\  verify           Verify checksums against checksums file
    \\  release          Publish a GitHub release with artifacts
    \\
    \\Build Options:
    \\  -j, --jobs N     Number of parallel build jobs (default: CPU count)
    \\  -O, --optimize   Optimization level: Debug, ReleaseSafe (default),
    \\                   ReleaseFast, ReleaseSmall
    \\  -v, --verbose    Enable verbose output
    \\  -n, --dry-run    Show what would be built without building
    \\      --timeout S  Build timeout in seconds (default: 0 = no timeout)
    \\
    \\Verify Options:
    \\  [FILE]           Path to checksums file (default: auto-detect)
    \\  -f, --file       Path to checksums file
    \\  -a, --algo       Hash algorithm: sha256 or blake3 (auto-detect by default)
    \\  -d, --dir        Base directory for relative paths
    \\
    \\Release Options:
    \\  -t, --tag TAG    Tag for release (default: git describe --tags)
    \\  -n, --notes STR  Release notes (default: CHANGELOG.md entry)
    \\  -d, --draft      Create as draft release
    \\  -p, --prerelease Mark as prerelease
    \\      --dry-run    Show what would be done without publishing
    \\      --clean-assets Delete existing assets before uploading
    \\  -D, --dist DIR   Path to dist directory (default: "dist")
    \\  -c, --changelog  Path to CHANGELOG.md (default: "CHANGELOG.md")
    \\
    \\General Options:
    \\  -v, --version    Print version information
    \\  -h, --help       Print this help message
    \\
;

test "VERSION is non-empty" {
    try std.testing.expectEqualStrings("0.1.0", ZigReleaser.VERSION);
}

test "Command.fromArgs parses --version" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"--version"});
    defer cmd.deinit(allocator);
    try std.testing.expectEqual(Command.version, cmd);
}

test "Command.fromArgs parses -v" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"-v"});
    defer cmd.deinit(allocator);
    try std.testing.expectEqual(Command.version, cmd);
}

test "Command.fromArgs parses --help" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"--help"});
    defer cmd.deinit(allocator);
    try std.testing.expectEqual(Command.help, cmd);
}

test "Command.fromArgs parses -h" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"-h"});
    defer cmd.deinit(allocator);
    try std.testing.expectEqual(Command.help, cmd);
}

test "Command.fromArgs returns help for empty args" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{});
    defer cmd.deinit(allocator);
    try std.testing.expectEqual(Command.help, cmd);
}

test "Command.fromArgs parses check" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"check"});
    defer cmd.deinit(allocator);
    try std.testing.expectEqual(Command.check, cmd);
}

test "Command.fromArgs parses build" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"build"});
    defer cmd.deinit(allocator);
    switch (cmd) {
        .build => |opts| {
            try std.testing.expectEqual(@as(usize, 0), opts.jobs);
            try std.testing.expectEqualStrings("ReleaseSafe", opts.optimize);
            try std.testing.expect(!opts.verbose);
            try std.testing.expect(!opts.dry_run);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses build with --jobs" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "build", "--jobs", "4" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .build => |opts| {
            try std.testing.expectEqual(@as(usize, 4), opts.jobs);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses build with -j" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "build", "-j", "8" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .build => |opts| {
            try std.testing.expectEqual(@as(usize, 8), opts.jobs);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses build with --optimize" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "build", "--optimize", "ReleaseFast" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .build => |opts| {
            try std.testing.expectEqualStrings("ReleaseFast", opts.optimize);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses build with --verbose" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "build", "--verbose" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .build => |opts| {
            try std.testing.expect(opts.verbose);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses build with --dry-run" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "build", "--dry-run" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .build => |opts| {
            try std.testing.expect(opts.dry_run);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs returns error for unknown command" {
    const prev_log_level = std.testing.log_level;
    defer std.testing.log_level = prev_log_level;
    std.testing.log_level = .err;

    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ZigReleaser.CliError.UnknownCommand,
        Command.fromArgs(allocator, &[_][]const u8{"unknown"}),
    );
}

test "Command.fromArgs returns error for invalid --jobs value" {
    const prev_log_level = std.testing.log_level;
    defer std.testing.log_level = prev_log_level;
    std.testing.log_level = .err;

    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ZigReleaser.CliError.InvalidArguments,
        Command.fromArgs(allocator, &[_][]const u8{ "build", "--jobs", "invalid" }),
    );
}

test "Command.fromArgs returns error for invalid optimize level" {
    const prev_log_level = std.testing.log_level;
    defer std.testing.log_level = prev_log_level;
    std.testing.log_level = .err;

    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ZigReleaser.CliError.InvalidArguments,
        Command.fromArgs(allocator, &[_][]const u8{ "build", "--optimize", "Invalid" }),
    );
}

test "Command.fromArgs parses verify" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{"verify"});
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expect(opts.checksums_file == null);
            try std.testing.expect(opts.algorithm == null);
            try std.testing.expect(opts.base_dir == null);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with positional file" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "checksums-sha256.txt" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqualStrings("checksums-sha256.txt", opts.checksums_file.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with --file" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "--file", "dist/checksums.txt" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqualStrings("dist/checksums.txt", opts.checksums_file.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with -f" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "-f", "my-checksums.txt" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqualStrings("my-checksums.txt", opts.checksums_file.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with --algo sha256" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "--algo", "sha256" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqual(ZigReleaser.checksum.HashAlgorithm.sha256, opts.algorithm.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with --algo blake3" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "--algo", "blake3" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqual(ZigReleaser.checksum.HashAlgorithm.blake3, opts.algorithm.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with --dir" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "--dir", "dist" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqualStrings("dist", opts.base_dir.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs parses verify with multiple options" {
    const allocator = std.testing.allocator;
    const cmd = try Command.fromArgs(allocator, &[_][]const u8{ "verify", "--file", "checksums.txt", "--algo", "sha256", "--dir", "dist" });
    defer cmd.deinit(allocator);
    switch (cmd) {
        .verify => |opts| {
            try std.testing.expectEqualStrings("checksums.txt", opts.checksums_file.?);
            try std.testing.expectEqual(ZigReleaser.checksum.HashAlgorithm.sha256, opts.algorithm.?);
            try std.testing.expectEqualStrings("dist", opts.base_dir.?);
        },
        else => return error.UnexpectedCommand,
    }
}

test "Command.fromArgs returns error for invalid verify algo" {
    const prev_log_level = std.testing.log_level;
    defer std.testing.log_level = prev_log_level;
    std.testing.log_level = .err;

    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ZigReleaser.CliError.InvalidArguments,
        Command.fromArgs(allocator, &[_][]const u8{ "verify", "--algo", "md5" }),
    );
}
