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

pub const Packages = struct {
    tarball: ?TarballPackage = null,
};

pub const GitHubRelease = struct {
    owner: []const u8,
    repo: []const u8,
    draft: bool = false,
    prerelease: bool = false,
};

pub const Release = struct {
    github: ?GitHubRelease = null,
};

pub const Config = struct {
    project: Project,
    build: Build = .{},
    targets: []const Target = &.{},
    packages: ?Packages = null,
    release: ?Release = null,
};

const config_paths = [_][]const u8{
    "zr.json",
    "zr.jsonc",
    ".zr.json",
    ".zr.jsonc",
    ".config/zr.json",
    ".config/zr.jsonc",
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
        break :blk Packages{ .tarball = tarball };
    } else null;

    const release: ?Release = if (src.release) |rel| blk: {
        const github: ?GitHubRelease = if (rel.github) |gh| GitHubRelease{
            .owner = try allocator.dupe(u8, gh.owner),
            .repo = try allocator.dupe(u8, gh.repo),
            .draft = gh.draft,
            .prerelease = gh.prerelease,
        } else null;
        break :blk Release{ .github = github };
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

test "resolveTemplate returns error for empty expression" {
    const allocator = std.testing.allocator;

    var env_map = std.BufMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.EmptyExpression, resolveTemplate(allocator, "{{}}", ctx));
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

test "find discovers zr.json in current directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "zr.json", .data = "{\"project\":{\"name\":\"test\"}}" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const path = find(allocator, io) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(path);

    try std.testing.expect(std.mem.eql(u8, path, "zr.json"));
}

test "find discovers zr.jsonc in current directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "zr.jsonc", .data = "{//config\n\"project\":{\"name\":\"test\"}}" });

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const path = find(allocator, io) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(path);

    try std.testing.expect(std.mem.eql(u8, path, "zr.jsonc"));
}
