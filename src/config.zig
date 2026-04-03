const std = @import("std");
const json = std.json;
const jsonc = @import("jsonc.zig");

const log = std.log.scoped(.config);

pub const ParseError = error{
    FileNotFound,
    InvalidJson,
    InvalidJsonc,
    ValidationFailed,
    ReadError,
    UnterminatedString,
    UnterminatedBlockComment,
    OutOfMemory,
};

pub const ValidationError = error{
    MissingProjectName,
    MissingBuildTarget,
    InvalidTargetOs,
    InvalidTargetArch,
    MissingGitHubOwner,
    MissingGitHubRepo,
};

pub const TemplateError = error{
    InvalidSyntax,
    UnknownVariable,
    UnterminatedExpression,
    EmptyExpression,
};

pub const Project = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    license: ?[]const u8 = null,
};

pub const Build = struct {
    zig_version: ?[]const u8 = null,
    output: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    flags: []const []const u8 = &.{},
};

pub const Target = struct {
    os: []const u8,
    arch: []const u8,
    cpu: ?[]const u8 = null,
    abi: ?[]const u8 = null,
};

pub const TarballPackage = struct {
    format: ?[]const u8 = null,
    extra_files: []const []const u8 = &.{},
    man_pages: ?[]const u8 = null,
    completions: ?[]const u8 = null,

    pub fn getFormat(self: @This()) []const u8 {
        return self.format orelse "tar.gz";
    }

    pub fn getExtension(self: @This()) []const u8 {
        const fmt = self.getFormat();
        if (std.mem.eql(u8, fmt, "tar.gz")) return ".tar.gz";
        if (std.mem.eql(u8, fmt, "zip")) return ".zip";
        return ".tar.gz";
    }
};

/// Configuration for generating `.deb` packages (Debian/Ubuntu).
pub const DebPackage = struct {
    /// Maintainer field — "Full Name <email@example.com>".
    maintainer: ?[]const u8 = null,
    /// SPDX license identifier written to the `License` control field.
    license: ?[]const u8 = null,

    pub fn getMaintainer(self: @This()) []const u8 {
        return self.maintainer orelse "Unknown <unknown@example.com>";
    }
};

/// Configuration for generating `.apk` packages (Alpine Linux).
pub const ApkPackage = struct {
    /// One-line package description (pkgdesc field).
    description: ?[]const u8 = null,
    /// SPDX license identifier.
    license: ?[]const u8 = null,
    /// Maintainer field — "Full Name <email@example.com>".
    maintainer: ?[]const u8 = null,
    /// URL for the project's home page.
    url: ?[]const u8 = null,

    pub fn getMaintainer(self: @This()) []const u8 {
        return self.maintainer orelse "Unknown <unknown@example.com>";
    }
};

/// Configuration for generating `.rpm` packages (Fedora/RHEL/openSUSE).
pub const RpmPackage = struct {
    /// RPM release string (e.g. "1"). Defaults to "1".
    release: ?[]const u8 = null,
    /// One-line package summary shown in `rpm -qi`.
    summary: ?[]const u8 = null,
    /// Multi-line description shown in `rpm -qi`.
    description: ?[]const u8 = null,
    /// SPDX license identifier.
    license: ?[]const u8 = null,
    /// Packager field — "Full Name <email@example.com>".
    packager: ?[]const u8 = null,
    /// URL for the project's home page.
    url: ?[]const u8 = null,

    pub fn getRelease(self: @This()) []const u8 {
        return self.release orelse "1";
    }

    pub fn getPackager(self: @This()) []const u8 {
        return self.packager orelse "Unknown <unknown@example.com>";
    }
};

/// Configuration for generating a Homebrew formula (macOS/Linux).
pub const HomebrewPackage = struct {
    /// Tap repository — "owner/tap-repo" or just "tap-repo".
    /// The formula is written to Formula/<name>.rb inside this repo.
    tap: ?[]const u8 = null,
    /// Override the default description (falls back to project.description).
    description: ?[]const u8 = null,
    /// Override the default homepage (falls back to GitHub repo URL).
    homepage: ?[]const u8 = null,
    /// Tap SSH key for pushing (falls back to HOMEBREW_TAP_SSH_KEY env).
    tap_ssh_key: ?[]const u8 = null,

    pub fn getTap(self: @This()) []const u8 {
        return self.tap orelse "";
    }
};

/// Scoop bucket package configuration
pub const ScoopPackage = struct {
    /// Scoop bucket repository — "owner/bucket-repo"
    bucket: ?[]const u8 = null,
    /// Override the default description (falls back to project.description)
    description: ?[]const u8 = null,
    /// Override the default homepage (falls back to GitHub repo URL)
    homepage: ?[]const u8 = null,
    /// Bucket SSH key for pushing (falls back to SCOOP_BUCKET_SSH_KEY env, then TAKEOFF_SSH_KEY)
    bucket_ssh_key: ?[]const u8 = null,

    /// Returns the bucket name, or empty string if not configured.
    pub fn getBucket(self: @This()) []const u8 {
        return self.bucket orelse "";
    }
};

/// Configuration for generating a Winget manifest (Windows Package Manager).
pub const WingetPackage = struct {
    /// Publisher name for PackageIdentifier (e.g. "vmvarela").
    /// Falls back to the GitHub owner if not specified.
    publisher: ?[]const u8 = null,
    /// Override description (falls back to project.description).
    description: ?[]const u8 = null,
    /// Override homepage (falls back to GitHub repo URL).
    homepage: ?[]const u8 = null,
    /// GitHub fork repo for pushing (e.g. "vmvarela/winget-pkgs").
    /// If null, the publisher auto-detects the user's fork via the GitHub API.
    fork_repo: ?[]const u8 = null,
    /// SSH key for pushing to the fork (falls back to WINGET_FORK_SSH_KEY env).
    fork_ssh_key: ?[]const u8 = null,

    pub fn getPublisher(self: @This()) []const u8 {
        return self.publisher orelse "";
    }
};

pub const Packages = struct {
    tarball: ?TarballPackage = null,
    deb: ?DebPackage = null,
    rpm: ?RpmPackage = null,
    apk: ?ApkPackage = null,
    homebrew: ?HomebrewPackage = null,
    scoop: ?ScoopPackage = null,
    winget: ?WingetPackage = null,
};

pub const GitHubRelease = struct {
    owner: []const u8,
    repo: []const u8,
    draft: bool = false,
    prerelease: bool = false,
};

/// Configuration for publishing to AUR.
pub const AurRelease = struct {
    /// AUR package name. Defaults to the project name if not specified.
    repo: ?[]const u8 = null,
    /// Maintainer string for the PKGBUILD header (e.g. "Name <email at domain dot tld>").
    maintainer: ?[]const u8 = null,
    /// Optional SSH private key path for pushing to AUR.
    /// If absent, environment variable `AUR_SSH_KEY` is used.
    aur_ssh_key: ?[]const u8 = null,
};

pub const Release = struct {
    github: ?GitHubRelease = null,
    aur: ?AurRelease = null,
};

pub const Config = struct {
    project: Project,
    build: Build = .{},
    targets: []const Target = &.{},
    packages: ?Packages = null,
    release: ?Release = null,
};

const config_paths = [_][]const u8{
    "takeoff.json",
    "takeoff.jsonc",
    ".takeoff.json",
    ".takeoff.jsonc",
    ".config/takeoff.json",
    ".config/takeoff.jsonc",
};

pub fn find(allocator: std.mem.Allocator, io: std.Io) ParseError![]const u8 {
    const cwd = std.Io.Dir.cwd();
    for (config_paths) |path| {
        const file = cwd.openFile(io, path, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            return ParseError.ReadError;
        };
        file.close(io);
        return allocator.dupe(u8, path) catch return ParseError.OutOfMemory;
    }
    return ParseError.FileNotFound;
}

fn isJsoncFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".jsonc");
}

fn dupeOptStr(allocator: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |str| try allocator.dupe(u8, str) else null;
}

fn deepCopyConfig(allocator: std.mem.Allocator, src: Config) !Config {
    const name = try allocator.dupe(u8, src.project.name);
    errdefer allocator.free(name);

    const project = Project{
        .name = name,
        .version = try dupeOptStr(allocator, src.project.version),
        .description = try dupeOptStr(allocator, src.project.description),
        .license = try dupeOptStr(allocator, src.project.license),
    };

    const zig_version = try dupeOptStr(allocator, src.build.zig_version);
    const output = try dupeOptStr(allocator, src.build.output);
    const output_dir = try dupeOptStr(allocator, src.build.output_dir);

    const flags = try allocator.alloc([]const u8, src.build.flags.len);
    for (src.build.flags, 0..) |f, i| flags[i] = try allocator.dupe(u8, f);

    const build = Build{
        .zig_version = zig_version,
        .output = output,
        .output_dir = output_dir,
        .flags = flags,
    };

    const targets = try allocator.alloc(Target, src.targets.len);
    for (src.targets, 0..) |t, i| {
        targets[i] = Target{
            .os = try allocator.dupe(u8, t.os),
            .arch = try allocator.dupe(u8, t.arch),
            .cpu = try dupeOptStr(allocator, t.cpu),
            .abi = try dupeOptStr(allocator, t.abi),
        };
    }

    const packages: ?Packages = if (src.packages) |pkg| blk: {
        const tarball: ?TarballPackage = if (pkg.tarball) |tb| blk2: {
            const extra = try allocator.alloc([]const u8, tb.extra_files.len);
            for (tb.extra_files, 0..) |f, i| extra[i] = try allocator.dupe(u8, f);
            break :blk2 TarballPackage{
                .format = try dupeOptStr(allocator, tb.format),
                .extra_files = extra,
                .man_pages = try dupeOptStr(allocator, tb.man_pages),
                .completions = try dupeOptStr(allocator, tb.completions),
            };
        } else null;
        const deb: ?DebPackage = if (pkg.deb) |d| DebPackage{
            .maintainer = try dupeOptStr(allocator, d.maintainer),
            .license = try dupeOptStr(allocator, d.license),
        } else null;
        const rpm: ?RpmPackage = if (pkg.rpm) |r| RpmPackage{
            .release = try dupeOptStr(allocator, r.release),
            .summary = try dupeOptStr(allocator, r.summary),
            .description = try dupeOptStr(allocator, r.description),
            .license = try dupeOptStr(allocator, r.license),
            .packager = try dupeOptStr(allocator, r.packager),
            .url = try dupeOptStr(allocator, r.url),
        } else null;
        const apk: ?ApkPackage = if (pkg.apk) |a| ApkPackage{
            .description = try dupeOptStr(allocator, a.description),
            .license = try dupeOptStr(allocator, a.license),
            .maintainer = try dupeOptStr(allocator, a.maintainer),
            .url = try dupeOptStr(allocator, a.url),
        } else null;
        const homebrew: ?HomebrewPackage = if (pkg.homebrew) |hb| HomebrewPackage{
            .tap = try dupeOptStr(allocator, hb.tap),
            .description = try dupeOptStr(allocator, hb.description),
            .homepage = try dupeOptStr(allocator, hb.homepage),
            .tap_ssh_key = try dupeOptStr(allocator, hb.tap_ssh_key),
        } else null;
        const scoop: ?ScoopPackage = if (pkg.scoop) |sc| ScoopPackage{
            .bucket = try dupeOptStr(allocator, sc.bucket),
            .description = try dupeOptStr(allocator, sc.description),
            .homepage = try dupeOptStr(allocator, sc.homepage),
            .bucket_ssh_key = try dupeOptStr(allocator, sc.bucket_ssh_key),
        } else null;
        const winget: ?WingetPackage = if (pkg.winget) |wg| WingetPackage{
            .publisher = try dupeOptStr(allocator, wg.publisher),
            .description = try dupeOptStr(allocator, wg.description),
            .homepage = try dupeOptStr(allocator, wg.homepage),
            .fork_repo = try dupeOptStr(allocator, wg.fork_repo),
            .fork_ssh_key = try dupeOptStr(allocator, wg.fork_ssh_key),
        } else null;
        break :blk Packages{
            .tarball = tarball,
            .deb = deb,
            .rpm = rpm,
            .apk = apk,
            .homebrew = homebrew,
            .scoop = scoop,
            .winget = winget,
        };
    } else null;

    const release: ?Release = if (src.release) |rel| blk: {
        const github: ?GitHubRelease = if (rel.github) |gh| GitHubRelease{
            .owner = try allocator.dupe(u8, gh.owner),
            .repo = try allocator.dupe(u8, gh.repo),
            .draft = gh.draft,
            .prerelease = gh.prerelease,
        } else null;
        const aur_repo = if (rel.aur) |a| if (a.repo) |r|
            try allocator.dupe(u8, r)
        else
            try allocator.dupe(u8, src.project.name) else null;
        const aur: ?AurRelease = if (aur_repo) |ar| AurRelease{
            .repo = ar,
            .maintainer = try dupeOptStr(allocator, rel.aur.?.maintainer),
            .aur_ssh_key = try dupeOptStr(allocator, rel.aur.?.aur_ssh_key),
        } else null;
        break :blk Release{ .github = github, .aur = aur };
    } else null;

    return Config{
        .project = project,
        .build = build,
        .targets = targets,
        .packages = packages,
        .release = release,
    };
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ParseError!Config {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        return switch (err) {
            error.FileNotFound => ParseError.FileNotFound,
            else => ParseError.ReadError,
        };
    };
    defer allocator.free(content);

    // Strip JSONC comments if needed
    const json_content: []const u8 = if (isJsoncFile(path)) blk: {
        const stripped = jsonc.stripComments(allocator, content) catch |err| {
            log.err("failed to strip comments from {s}: {}", .{ path, err });
            return ParseError.InvalidJsonc;
        };
        break :blk stripped;
    } else content;
    defer if (isJsoncFile(path)) allocator.free(json_content);

    // Parse into a temporary arena, then deep-copy all strings into allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = json.parseFromSlice(Config, arena_alloc, json_content, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err("failed to parse {s}: {}", .{ path, err });
        return ParseError.InvalidJson;
    };

    return deepCopyConfig(allocator, parsed.value) catch return ParseError.OutOfMemory;
}

pub fn loadDefault(allocator: std.mem.Allocator, io: std.Io) ParseError!Config {
    const path = try find(allocator, io);
    defer allocator.free(path);
    return load(allocator, io, path);
}

pub fn validate(config: *const Config) ValidationError!void {
    if (config.project.name.len == 0) {
        return error.MissingProjectName;
    }

    if (config.targets.len == 0) {
        return error.MissingBuildTarget;
    }

    const valid_os = [_][]const u8{ "linux", "macos", "windows", "freebsd", "netbsd", "openbsd" };
    const valid_arch = [_][]const u8{ "x86_64", "aarch64", "arm", "riscv64", "x86" };

    for (config.targets) |target| {
        var os_valid = false;
        for (valid_os) |os| {
            if (std.mem.eql(u8, target.os, os)) {
                os_valid = true;
                break;
            }
        }
        if (!os_valid) return error.InvalidTargetOs;

        var arch_valid = false;
        for (valid_arch) |arch| {
            if (std.mem.eql(u8, target.arch, arch)) {
                arch_valid = true;
                break;
            }
        }
        if (!arch_valid) return error.InvalidTargetArch;
    }

    if (config.release) |release| {
        if (release.github) |github| {
            if (github.owner.len == 0) {
                return error.MissingGitHubOwner;
            }
            if (github.repo.len == 0) {
                return error.MissingGitHubRepo;
            }
        }
        // AUR repo defaults to project.name if not specified
    }
}

pub const TemplateContext = struct {
    env_map: *const std.BufMap,
    git_tag: ?[]const u8 = null,
    target: ?[]const u8 = null,
    ext: ?[]const u8 = null,
};

pub fn resolveTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    ctx: TemplateContext,
) (TemplateError || std.mem.Allocator.Error)![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const start = i;
            i += 2;

            const expr_start = i;
            while (i < template.len) {
                if (i + 1 < template.len and template[i] == '}' and template[i + 1] == '}') {
                    break;
                }
                i += 1;
            }

            if (i >= template.len or i + 1 >= template.len) {
                return error.UnterminatedExpression;
            }

            const expr = std.mem.trim(u8, template[expr_start..i], " \t\n");
            if (expr.len == 0) {
                return error.EmptyExpression;
            }

            const resolved = resolveVariable(allocator, expr, ctx) catch |err| {
                try result.appendSlice(allocator, template[start .. i + 2]);
                return err;
            };
            defer allocator.free(resolved);
            try result.appendSlice(allocator, resolved);

            i += 2;
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn resolveVariable(
    allocator: std.mem.Allocator,
    expr: []const u8,
    ctx: TemplateContext,
) (TemplateError || std.mem.Allocator.Error)![]const u8 {
    if (std.mem.startsWith(u8, expr, "env.")) {
        const var_name = expr[4..];
        if (ctx.env_map.get(var_name)) |value| {
            return allocator.dupe(u8, value);
        }
        return allocator.dupe(u8, "");
    }

    if (std.mem.eql(u8, expr, "git.tag")) {
        if (ctx.git_tag) |tag| {
            return allocator.dupe(u8, tag);
        }
        return allocator.dupe(u8, "");
    }

    if (std.mem.eql(u8, expr, "target")) {
        if (ctx.target) |target| {
            return allocator.dupe(u8, target);
        }
        return allocator.dupe(u8, "");
    }

    if (std.mem.eql(u8, expr, "ext")) {
        if (ctx.ext) |ext| {
            return allocator.dupe(u8, ext);
        }
        return allocator.dupe(u8, "");
    }

    return error.UnknownVariable;
}

pub fn formatValidationError(err: ValidationError, writer: anytype) !void {
    const msg = switch (err) {
        error.MissingProjectName => "missing required field: project.name",
        error.MissingBuildTarget => "missing required field: at least one [[targets]]",
        error.InvalidTargetOs => "invalid target os (must be one of: linux, macos, windows, freebsd, netbsd, openbsd)",
        error.InvalidTargetArch => "invalid target arch (must be one of: x86_64, aarch64, arm, riscv64, x86)",
        error.MissingGitHubOwner => "missing required field: release.github.owner",
        error.MissingGitHubRepo => "missing required field: release.github.repo",
    };
    try writer.writeAll(msg);
}

pub fn formatParseError(err: ParseError, writer: anytype) !void {
    const msg = switch (err) {
        error.FileNotFound => "configuration file not found",
        error.InvalidJson => "invalid JSON syntax",
        error.InvalidJsonc => "invalid JSONC syntax",
        error.ValidationFailed => "configuration validation failed",
        error.UnterminatedString => "unterminated string in configuration",
        error.UnterminatedBlockComment => "unterminated block comment in configuration",
        error.ReadError => "error reading configuration file",
        error.OutOfMemory => "out of memory",
    };
    try writer.writeAll(msg);
}

test "validate accepts valid config" {
    const config = Config{
        .project = .{
            .name = "test",
        },
        .targets = &[_]Target{
            .{ .os = "linux", .arch = "x86_64" },
        },
    };

    try validate(&config);
}

test "validate rejects missing project name" {
    const config = Config{
        .project = .{
            .name = "",
        },
        .targets = &[_]Target{
            .{ .os = "linux", .arch = "x86_64" },
        },
    };

    try std.testing.expectError(error.MissingProjectName, validate(&config));
}

test "validate rejects missing targets" {
    const config = Config{
        .project = .{
            .name = "test",
        },
        .targets = &.{},
    };

    try std.testing.expectError(error.MissingBuildTarget, validate(&config));
}

test "validate rejects invalid os" {
    const config = Config{
        .project = .{
            .name = "test",
        },
        .targets = &[_]Target{
            .{ .os = "invalid", .arch = "x86_64" },
        },
    };

    try std.testing.expectError(error.InvalidTargetOs, validate(&config));
}

test "validate rejects invalid arch" {
    const config = Config{
        .project = .{
            .name = "test",
        },
        .targets = &[_]Target{
            .{ .os = "linux", .arch = "invalid" },
        },
    };

    try std.testing.expectError(error.InvalidTargetArch, validate(&config));
}

test "resolveTemplate handles env variables" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("TEST_VAR", "test_value");

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    const result = try resolveTemplate(allocator, "prefix{{ env.TEST_VAR }}suffix", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("prefixtest_valuesuffix", result);
}

test "resolveTemplate handles git.tag" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
        .git_tag = "v1.0.0",
    };

    const result = try resolveTemplate(allocator, "{{ git.tag }}", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("v1.0.0", result);
}

test "resolveTemplate handles target" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
        .target = "x86_64-linux",
    };

    const result = try resolveTemplate(allocator, "binary-{{ target }}", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("binary-x86_64-linux", result);
}

test "resolveTemplate handles ext" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
        .ext = ".exe",
    };

    const result = try resolveTemplate(allocator, "binary{{ ext }}", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("binary.exe", result);
}

test "resolveTemplate returns empty for unset env" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    const result = try resolveTemplate(allocator, "{{ env.UNSET_VAR }}", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "resolveTemplate returns error for unknown variable" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.UnknownVariable, resolveTemplate(allocator, "{{ unknown.var }}", ctx));
}

test "resolveTemplate returns error for unterminated expression" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.UnterminatedExpression, resolveTemplate(allocator, "prefix{{ env.TEST", ctx));
}

test "load parses packages.deb config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json_content =
        \\{
        \\  "project": {"name": "mypkg"},
        \\  "targets": [{"os": "linux", "arch": "x86_64"}],
        \\  "packages": {
        \\    "deb": {
        \\      "maintainer": "Alice <alice@example.com>",
        \\      "license": "MIT"
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = json_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = try load(allocator, io, "test.json");

    try std.testing.expect(cfg.packages != null);
    try std.testing.expect(cfg.packages.?.deb != null);
    const deb = cfg.packages.?.deb.?;
    try std.testing.expectEqualStrings("Alice <alice@example.com>", deb.getMaintainer());
    try std.testing.expectEqualStrings("MIT", deb.license.?);
}

test "DebPackage getMaintainer returns default when nil" {
    const d = DebPackage{};
    try std.testing.expectEqualStrings("Unknown <unknown@example.com>", d.getMaintainer());
}

test "RpmPackage getRelease returns default when nil" {
    const r = RpmPackage{};
    try std.testing.expectEqualStrings("1", r.getRelease());
}

test "RpmPackage getPackager returns default when nil" {
    const r = RpmPackage{};
    try std.testing.expectEqualStrings("Unknown <unknown@example.com>", r.getPackager());
}

test "load parses packages.rpm config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json_content =
        \\{
        \\  "project": {"name": "mypkg"},
        \\  "targets": [{"os": "linux", "arch": "x86_64"}],
        \\  "packages": {
        \\    "rpm": {
        \\      "release": "2",
        \\      "summary": "My package",
        \\      "license": "Apache-2.0",
        \\      "packager": "Bob <bob@example.com>"
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = json_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = try load(allocator, io, "test.json");

    try std.testing.expect(cfg.packages != null);
    try std.testing.expect(cfg.packages.?.rpm != null);
    const r = cfg.packages.?.rpm.?;
    try std.testing.expectEqualStrings("2", r.getRelease());
    try std.testing.expectEqualStrings("My package", r.summary.?);
    try std.testing.expectEqualStrings("Apache-2.0", r.license.?);
    try std.testing.expectEqualStrings("Bob <bob@example.com>", r.getPackager());
}

test "resolveTemplate returns error for empty expression" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.EmptyExpression, resolveTemplate(allocator, "{{}}", ctx));
}

test "ApkPackage getMaintainer returns default when nil" {
    const a = ApkPackage{};
    try std.testing.expectEqualStrings("Unknown <unknown@example.com>", a.getMaintainer());
}

test "load parses packages.apk config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json_content =
        \\{
        \\  "project": {"name": "mypkg"},
        \\  "targets": [{"os": "linux", "arch": "x86_64"}],
        \\  "packages": {
        \\    "apk": {
        \\      "description": "My Alpine package",
        \\      "license": "MIT",
        \\      "maintainer": "Carol <carol@example.com>",
        \\      "url": "https://example.com"
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = json_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = try load(allocator, io, "test.json");

    try std.testing.expect(cfg.packages != null);
    try std.testing.expect(cfg.packages.?.apk != null);
    const a = cfg.packages.?.apk.?;
    try std.testing.expectEqualStrings("Carol <carol@example.com>", a.getMaintainer());
    try std.testing.expectEqualStrings("MIT", a.license.?);
    try std.testing.expectEqualStrings("My Alpine package", a.description.?);
}

test "aur repo defaults to project name when not specified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json_content =
        \\{
        \\  "project": {"name": "mypkg"},
        \\  "targets": [{"os": "linux", "arch": "x86_64"}],
        \\  "release": {
        \\    "aur": {}
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = json_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = try load(allocator, io, "test.json");
    try std.testing.expect(cfg.release != null);
    try std.testing.expect(cfg.release.?.aur != null);
    try std.testing.expectEqualStrings("mypkg", cfg.release.?.aur.?.repo.?);
}

test "load parses release.aur config with explicit repo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json_content =
        \\{
        \\  "project": {"name": "mypkg"},
        \\  "targets": [{"os": "linux", "arch": "x86_64"}],
        \\  "release": {
        \\    "aur": {
        \\      "repo": "mypkg-bin",
        \\      "aur_ssh_key": "/home/user/.ssh/aur"
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = json_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = try load(allocator, io, "test.json");
    try std.testing.expect(cfg.release != null);
    try std.testing.expect(cfg.release.?.aur != null);
    try std.testing.expectEqualStrings("mypkg-bin", cfg.release.?.aur.?.repo.?);
    try std.testing.expectEqualStrings("/home/user/.ssh/aur", cfg.release.?.aur.?.aur_ssh_key.?);
}

test "resolveTemplate handles multiple templates" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    try env_map.put("PREFIX", "pre");
    try env_map.put("SUFFIX", "suf");

    const ctx = TemplateContext{
        .env_map = &env_map,
        .target = "x86_64-linux",
    };

    const result = try resolveTemplate(allocator, "{{ env.PREFIX }}-{{ target }}-{{ env.SUFFIX }}", ctx);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("pre-x86_64-linux-suf", result);
}

test "load parses valid JSON config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = "{\"project\":{\"name\":\"test\"},\"targets\":[{\"os\":\"linux\",\"arch\":\"x86_64\"}]}" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const config = try load(allocator, io, "test.json");

    try std.testing.expectEqualStrings("test", config.project.name);
    try std.testing.expectEqual(@as(usize, 1), config.targets.len);
    try std.testing.expectEqualStrings("linux", config.targets[0].os);
    try std.testing.expectEqualStrings("x86_64", config.targets[0].arch);
}

test "load parses valid JSONC config with comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const jsonc_content =
        \\{
        \\  // Project configuration
        \\  "project": {
        \\    "name": "test" /* name here */
        \\  },
        \\  "targets": [
        \\    {"os": "linux", "arch": "x86_64"}
        \\  ]
        \\}
    ;

    try tmp.dir.writeFile(io, .{ .sub_path = "test.jsonc", .data = jsonc_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const config = try load(allocator, io, "test.jsonc");

    try std.testing.expectEqualStrings("test", config.project.name);
    try std.testing.expectEqual(@as(usize, 1), config.targets.len);
}

test "find discovers takeoff.json in current directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "takeoff.json", .data = "{\"project\":{\"name\":\"test\"}}" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const path = find(allocator, io) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(path);

    try std.testing.expect(std.mem.eql(u8, path, "takeoff.json"));
}

test "find discovers takeoff.jsonc in current directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "takeoff.jsonc", .data = "{//config\n\"project\":{\"name\":\"test\"}}" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const path = find(allocator, io) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(path);

    try std.testing.expect(std.mem.eql(u8, path, "takeoff.jsonc"));
}

test "WingetPackage getPublisher returns default when nil" {
    const w = WingetPackage{};
    try std.testing.expectEqualStrings("", w.getPublisher());
}

test "load parses packages.winget config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json_content =
        \\{
        \\  "project": {"name": "mypkg"},
        \\  "targets": [{"os": "linux", "arch": "x86_64"}],
        \\  "packages": {
        \\    "winget": {
        \\      "publisher": "MyCompany",
        \\      "description": "My awesome package",
        \\      "homepage": "https://example.com",
        \\      "fork_repo": "myuser/winget-pkgs"
        \\    }
        \\  }
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "test.json", .data = json_content });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const cfg = try load(allocator, io, "test.json");

    try std.testing.expect(cfg.packages != null);
    try std.testing.expect(cfg.packages.?.winget != null);
    const w = cfg.packages.?.winget.?;
    try std.testing.expectEqualStrings("MyCompany", w.publisher.?);
    try std.testing.expectEqualStrings("My awesome package", w.description.?);
    try std.testing.expectEqualStrings("https://example.com", w.homepage.?);
    try std.testing.expectEqualStrings("myuser/winget-pkgs", w.fork_repo.?);
}
