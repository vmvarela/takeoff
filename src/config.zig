const std = @import("std");
const toml = @import("toml");

const log = std.log.scoped(.config);

pub const ParseError = error{
    FileNotFound,
    InvalidToml,
    ValidationFailed,
    ReadError,
} || std.fs.File.OpenError || std.mem.Allocator.Error;

pub const ValidationError = error{
    MissingProjectName,
    MissingBuildTarget,
    InvalidTargetOs,
    InvalidTargetArch,
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
    flags: []const []const u8 = &.{},
};

pub const Target = struct {
    os: []const u8,
    arch: []const u8,
    cpu: ?[]const u8 = null,
};

pub const TarballPackage = struct {
    format: ?[]const u8 = null,

    pub fn getFormat(self: @This()) []const u8 {
        return self.format orelse "tar.gz";
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

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.project.name);
        if (self.project.version) |v| allocator.free(v);
        if (self.project.description) |d| allocator.free(d);
        if (self.project.license) |l| allocator.free(l);

        if (self.build.zig_version) |v| allocator.free(v);
        if (self.build.output) |o| allocator.free(o);
        for (self.build.flags) |f| allocator.free(f);
        if (self.build.flags.len > 0) allocator.free(self.build.flags);

        for (self.targets) |target| {
            allocator.free(target.os);
            allocator.free(target.arch);
            if (target.cpu) |c| allocator.free(c);
        }
        allocator.free(self.targets);

        if (self.packages) |pkg| {
            if (pkg.tarball) |tb| {
                if (tb.format) |f| allocator.free(f);
            }
        }

        if (self.release) |rel| {
            if (rel.github) |gh| {
                allocator.free(gh.owner);
                allocator.free(gh.repo);
            }
        }
    }
};

const config_paths = [_][]const u8{
    "zr.toml",
    ".zr.toml",
    ".config/zr.toml",
};

pub fn find(allocator: std.mem.Allocator) (std.fs.File.OpenError || std.mem.Allocator.Error)![]const u8 {
    const cwd = std.fs.cwd();
    inline for (config_paths) |path| {
        if (cwd.openFile(path, .{})) |_| {
            return allocator.dupe(u8, path);
        } else |_| {}
    }
    return error.FileNotFound;
}

fn dupeString(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, s);
}

fn dupeOptionalString(allocator: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    if (s) |str| {
        return try allocator.dupe(u8, str);
    }
    return null;
}

fn deepCopyConfig(allocator: std.mem.Allocator, parsed: Config) std.mem.Allocator.Error!Config {
    const project = Project{
        .name = try dupeString(allocator, parsed.project.name),
        .version = try dupeOptionalString(allocator, parsed.project.version),
        .description = try dupeOptionalString(allocator, parsed.project.description),
        .license = try dupeOptionalString(allocator, parsed.project.license),
    };

    const flags = try allocator.alloc([]const u8, parsed.build.flags.len);
    errdefer allocator.free(flags);
    for (parsed.build.flags, 0..) |f, i| {
        flags[i] = try dupeString(allocator, f);
    }

    const build = Build{
        .zig_version = try dupeOptionalString(allocator, parsed.build.zig_version),
        .output = try dupeOptionalString(allocator, parsed.build.output),
        .flags = flags,
    };

    const targets = try allocator.alloc(Target, parsed.targets.len);
    errdefer allocator.free(targets);
    for (parsed.targets, 0..) |t, i| {
        targets[i] = Target{
            .os = try dupeString(allocator, t.os),
            .arch = try dupeString(allocator, t.arch),
            .cpu = try dupeOptionalString(allocator, t.cpu),
        };
    }

    const packages = if (parsed.packages) |pkg| blk: {
        if (pkg.tarball) |tb| {
            break :blk Packages{
                .tarball = TarballPackage{
                    .format = try dupeOptionalString(allocator, tb.format),
                },
            };
        }
        break :blk Packages{};
    } else null;

    const release = if (parsed.release) |rel| blk: {
        if (rel.github) |gh| {
            break :blk Release{
                .github = GitHubRelease{
                    .owner = try dupeString(allocator, gh.owner),
                    .repo = try dupeString(allocator, gh.repo),
                    .draft = gh.draft,
                    .prerelease = gh.prerelease,
                },
            };
        }
        break :blk Release{};
    } else null;

    return Config{
        .project = project,
        .build = build,
        .targets = targets,
        .packages = packages,
        .release = release,
    };
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) (ParseError || std.fs.File.OpenError || error{ReadError})!Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        return error.ReadError;
    };
    defer allocator.free(content);

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = parser.parseString(content) catch |err| {
        if (parser.error_info) |info| {
            switch (info) {
                .parse => |pos| {
                    log.err("parse error at line {d}, position {d}: {}", .{ pos.line, pos.pos, err });
                },
                .struct_mapping => |field_path| {
                    log.err("field error in '{any}': {}", .{ field_path, err });
                },
            }
        } else {
            log.err("failed to parse {s}: {}", .{ path, err });
        }
        return ParseError.InvalidToml;
    };

    const cfg = deepCopyConfig(allocator, result.value) catch |err| {
        result.deinit();
        return err;
    };
    result.deinit();

    return cfg;
}

pub fn loadDefault(allocator: std.mem.Allocator) (ParseError || std.fs.File.OpenError || error{ReadError})!Config {
    const path = try find(allocator);
    defer allocator.free(path);
    return load(allocator, path);
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
}

pub const TemplateContext = struct {
    env_map: *const std.process.EnvMap,
    git_tag: ?[]const u8 = null,
    target: ?[]const u8 = null,
    ext: ?[]const u8 = null,
};

pub fn resolveTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    ctx: TemplateContext,
) (TemplateError || std.mem.Allocator.Error)![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

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
                try result.appendSlice(template[start .. i + 2]);
                return err;
            };
            defer allocator.free(resolved);
            try result.appendSlice(resolved);

            i += 2;
        } else {
            try result.append(template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
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
    };
    try writer.writeAll(msg);
}

pub fn formatParseError(err: ParseError, writer: anytype) !void {
    const msg = switch (err) {
        error.FileNotFound => "configuration file not found",
        error.InvalidToml => "invalid TOML syntax",
        error.ValidationFailed => "configuration validation failed",
        else => @errorName(err),
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

    var env_map = std.process.EnvMap.init(allocator);
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

    var env_map = std.process.EnvMap.init(allocator);
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

    var env_map = std.process.EnvMap.init(allocator);
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

    var env_map = std.process.EnvMap.init(allocator);
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

    var env_map = std.process.EnvMap.init(allocator);
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

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.UnknownVariable, resolveTemplate(allocator, "{{ unknown.var }}", ctx));
}

test "resolveTemplate returns error for unterminated expression" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.UnterminatedExpression, resolveTemplate(allocator, "prefix{{ env.TEST", ctx));
}

test "resolveTemplate returns error for empty expression" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    const ctx = TemplateContext{
        .env_map = &env_map,
    };

    try std.testing.expectError(error.EmptyExpression, resolveTemplate(allocator, "{{}}", ctx));
}

test "resolveTemplate handles multiple templates" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
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

test "find discovers zr.toml in current directory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "zr.toml", .data = "[project]\nname = \"test\"" });

    const original_cwd = std.process.cwd();
    defer std.process.chdir(original_cwd) catch {};

    // Change to temp dir
    try tmp.dir.setAsCwd();

    const path = find(allocator) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(path);

    try std.testing.expect(std.mem.eql(u8, path, "zr.toml"));
}
