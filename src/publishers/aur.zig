const std = @import("std");

const log = std.log.scoped(.aur);

/// Error set for AUR publishing operations.
pub const AurError = error{
    InvalidConfig,
    ArtifactNotFound,
    ReadError,
    WriteError,
    ProcessError,
    PushFailed,
} || std.mem.Allocator.Error;

/// Options for generating (and optionally pushing) an AUR package repository.
pub const AurPublishOptions = struct {
    /// AUR package name (e.g. `takeoff` or `takeoff-bin`).
    aur_repo: []const u8,
    /// Optional SSH private key path to push to AUR.
    /// If null, `AUR_SSH_KEY` environment variable is used if present.
    aur_ssh_key: ?[]const u8 = null,
    /// Maintainer string for the PKGBUILD header (e.g. "Name <email at domain dot tld>").
    maintainer: ?[]const u8 = null,
    /// GitHub owner used to build source URL.
    owner: []const u8,
    /// GitHub repo used to build source URL.
    repo: []const u8,
    /// Release tag used to build source URL.
    tag: []const u8,
    /// Project binary name (installed to /usr/bin/<name>).
    project_name: []const u8,
    /// Package description.
    description: []const u8,
    /// Package license (SPDX identifier).
    license: []const u8,
    /// Project homepage.
    url: []const u8,
    /// Dist directory containing release artifacts.
    dist_dir: []const u8,
    /// If true, only generate files and report actions.
    dry_run: bool = false,
};

/// Result of AUR publish operation.
pub const AurPublishResult = struct {
    success: bool,
    pkgbuild_path: []const u8,
    srcinfo_path: []const u8,
    pushed: bool,
    message: []const u8,

    pub fn deinit(self: *AurPublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.pkgbuild_path);
        allocator.free(self.srcinfo_path);
        allocator.free(self.message);
    }
};

const ArtifactInfo = struct {
    file_name: []const u8,
    full_path: []const u8,
    sha256: [32]u8,
};

/// 0BSD license for AUR package sources (per RFC 40 / RFC 52).
const aurLicenseContent =
    \\Permission to use, copy, modify, and/or distribute this software
    \\for any purpose with or without fee is hereby granted.
    \\
    \\THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
    \\WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
    \\WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
    \\AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
    \\CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
    \\LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
    \\NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
    \\CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
;

/// REUSE.toml for AUR package sources (per RFC 52).
const reuseTomlContent =
    \\version = 1
    \\
    \\[[annotations]]
    \\path = ["PKGBUILD", ".SRCINFO"]
    \\precedence = "aggregate"
    \\SPDX-FileCopyrightText = "NONE"
    \\SPDX-License-Identifier = "0BSD"
;

const AurMetadata = struct {
    pkgname: []const u8,
    pkgver: []const u8,
    pkgrel: []const u8,
    pkgdesc: []const u8,
    arch: []const u8,
    url: []const u8,
    license: []const u8,
    source_url: []const u8,
    source_file: []const u8,
    sha256: []const u8,
    project_name: []const u8,
    maintainer: ?[]const u8 = null,
};

/// Generate PKGBUILD + .SRCINFO for AUR, and optionally push to AUR.
pub fn publishAurPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: AurPublishOptions,
) AurError!AurPublishResult {
    if (opts.aur_repo.len == 0) return error.InvalidConfig;

    const artifact = try findLinuxX8664Tarball(allocator, io, opts.dist_dir, opts.project_name);
    defer {
        allocator.free(artifact.file_name);
        allocator.free(artifact.full_path);
    }

    const pkgver = try normalizePkgver(allocator, opts.tag);
    defer allocator.free(pkgver);

    const source_url = try std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ opts.owner, opts.repo, opts.tag, artifact.file_name },
    );
    defer allocator.free(source_url);

    const source_file = artifact.file_name;
    const sha256 = std.fmt.bytesToHex(artifact.sha256, .lower);

    const md = AurMetadata{
        .pkgname = opts.aur_repo,
        .pkgver = pkgver,
        .pkgrel = "1",
        .pkgdesc = opts.description,
        .arch = "x86_64",
        .url = opts.url,
        .license = opts.license,
        .source_url = source_url,
        .source_file = source_file,
        .sha256 = &sha256,
        .project_name = opts.project_name,
        .maintainer = opts.maintainer,
    };

    const aur_dir = try std.fs.path.join(allocator, &.{ opts.dist_dir, "aur", opts.aur_repo });
    defer allocator.free(aur_dir);
    std.Io.Dir.cwd().createDirPath(io, aur_dir) catch return error.WriteError;

    const pkgbuild_content = try renderPkgbuild(allocator, md);
    defer allocator.free(pkgbuild_content);

    const pkgbuild_path = try std.fs.path.join(allocator, &.{ aur_dir, "PKGBUILD" });
    errdefer allocator.free(pkgbuild_path);
    try writeFile(io, pkgbuild_path, pkgbuild_content);

    const srcinfo_path = try std.fs.path.join(allocator, &.{ aur_dir, ".SRCINFO" });
    errdefer allocator.free(srcinfo_path);

    // Generate .SRCINFO from PKGBUILD using makepkg when available; fallback to
    // deterministic renderer if makepkg is unavailable.
    const srcinfo_content = generateSrcInfoFromPkgbuild(allocator, io, aur_dir, md) catch try renderSrcinfo(allocator, md);
    defer allocator.free(srcinfo_content);
    try writeFile(io, srcinfo_path, srcinfo_content);

    // Write LICENSE (0BSD) per AUR submission guidelines (RFC 40 / RFC 52)
    const license_path = try std.fs.path.join(allocator, &.{ aur_dir, "LICENSE" });
    errdefer allocator.free(license_path);
    try writeFile(io, license_path, aurLicenseContent);

    // Write REUSE.toml per AUR submission guidelines (RFC 52)
    const reuse_path = try std.fs.path.join(allocator, &.{ aur_dir, "REUSE.toml" });
    errdefer allocator.free(reuse_path);
    try writeFile(io, reuse_path, reuseTomlContent);

    if (opts.dry_run) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "generated PKGBUILD, .SRCINFO, LICENSE, and REUSE.toml (dry-run, no push): {s}",
            .{aur_dir},
        );
        return .{
            .success = true,
            .pkgbuild_path = pkgbuild_path,
            .srcinfo_path = srcinfo_path,
            .pushed = false,
            .message = msg,
        };
    }

    const ssh_key = resolveSshKey(allocator, opts.aur_ssh_key) catch null;
    defer if (ssh_key) |k| allocator.free(k);

    const push_ok = pushToAur(allocator, io, opts.aur_repo, ssh_key, aur_dir, pkgver) catch {
        const msg = try allocator.dupe(u8, "generated PKGBUILD/.SRCINFO but failed to push to AUR");
        return .{
            .success = false,
            .pkgbuild_path = pkgbuild_path,
            .srcinfo_path = srcinfo_path,
            .pushed = false,
            .message = msg,
        };
    };

    if (!push_ok) {
        const msg = try allocator.dupe(u8, "generated PKGBUILD/.SRCINFO; no AUR push needed (no changes)");
        return .{
            .success = true,
            .pkgbuild_path = pkgbuild_path,
            .srcinfo_path = srcinfo_path,
            .pushed = false,
            .message = msg,
        };
    }

    const msg = try allocator.dupe(u8, "generated PKGBUILD/.SRCINFO and pushed changes to AUR");
    return .{
        .success = true,
        .pkgbuild_path = pkgbuild_path,
        .srcinfo_path = srcinfo_path,
        .pushed = true,
        .message = msg,
    };
}

fn findLinuxX8664Tarball(
    allocator: std.mem.Allocator,
    io: std.Io,
    dist_dir: []const u8,
    project_name: []const u8,
) AurError!ArtifactInfo {
    var dir = std.Io.Dir.cwd().openDir(io, dist_dir, .{ .iterate = true }) catch return error.ArtifactNotFound;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch return error.ReadError) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "-linux-x86_64.tar.gz")) continue;
        if (!std.mem.startsWith(u8, entry.name, project_name)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dist_dir, entry.name });
        errdefer allocator.free(full_path);
        const file_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(file_name);

        const data = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(512 * 1024 * 1024)) catch return error.ReadError;
        defer allocator.free(data);

        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &sha, .{});

        return .{
            .file_name = file_name,
            .full_path = full_path,
            .sha256 = sha,
        };
    }

    return error.ArtifactNotFound;
}

fn normalizePkgver(allocator: std.mem.Allocator, tag: []const u8) std.mem.Allocator.Error![]const u8 {
    const base = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    const out = try allocator.dupe(u8, base);
    for (out) |*c| {
        if (c.* == '-') c.* = '_';
    }
    return out;
}

fn renderPkgbuild(allocator: std.mem.Allocator, md: AurMetadata) std.mem.Allocator.Error![]const u8 {
    const maintainer_line = if (md.maintainer) |m|
        try std.fmt.allocPrint(allocator, "# Maintainer: {s}\n", .{m})
    else
        try allocator.dupe(u8, "# Maintainer: Generated by takeoff\n");
    defer allocator.free(maintainer_line);

    return std.fmt.allocPrint(
        allocator,
        "{s}" ++
            "pkgname={s}\n" ++
            "pkgver={s}\n" ++
            "pkgrel={s}\n" ++
            "pkgdesc=\"{s}\"\n" ++
            "arch=('{s}')\n" ++
            "url=\"{s}\"\n" ++
            "license=('{s}')\n" ++
            "options=('!strip')\n" ++
            "source=(\"{s}\")\n" ++
            "sha256sums=('{s}')\n" ++
            "\n" ++
            "package() {{\n" ++
            "  local _dir=\"{s}-{s}\"\n" ++
            "\n" ++
            "  install -Dm755 \"$srcdir/$_dir/bin/{s}\" \"$pkgdir/usr/bin/{s}\"\n" ++
            "\n" ++
            "  install -Dm644 \"$srcdir/$_dir/LICENSE\" \"$pkgdir/usr/share/licenses/{s}/LICENSE\"\n" ++
            "\n" ++
            "  while IFS= read -r -d '' _f; do\n" ++
            "    local _rel=\"${{_f#*/man/}}\"\n" ++
            "    install -Dm644 \"$_f\" \"$pkgdir/usr/share/man/${{_rel}}\"\n" ++
            "  done < <(find \"$srcdir/$_dir\" -type f -path \"*/man/*\" -print0)\n" ++
            "\n" ++
            "  while IFS= read -r -d '' _f; do\n" ++
            "    if [[ \"$_f\" == */completions/bash/* ]]; then\n" ++
            "      local _rel=\"${{_f#*/completions/bash/}}\"\n" ++
            "      install -Dm644 \"$_f\" \"$pkgdir/usr/share/bash-completion/completions/${{_rel}}\"\n" ++
            "    elif [[ \"$_f\" == */completions/zsh/* ]]; then\n" ++
            "      local _rel=\"${{_f#*/completions/zsh/}}\"\n" ++
            "      install -Dm644 \"$_f\" \"$pkgdir/usr/share/zsh/site-functions/${{_rel}}\"\n" ++
            "    elif [[ \"$_f\" == */completions/fish/* ]]; then\n" ++
            "      local _rel=\"${{_f#*/completions/fish/}}\"\n" ++
            "      install -Dm644 \"$_f\" \"$pkgdir/usr/share/fish/vendor_completions.d/${{_rel}}\"\n" ++
            "    fi\n" ++
            "  done < <(find \"$srcdir/$_dir\" -type f -path \"*/completions/*\" -print0)\n" ++
            "}}\n",
        .{
            maintainer_line,
            md.pkgname,
            md.pkgver,
            md.pkgrel,
            md.pkgdesc,
            md.arch,
            md.url,
            md.license,
            md.source_url,
            md.sha256,
            md.project_name,
            md.pkgver,
            md.project_name,
            md.project_name,
            md.project_name,
        },
    );
}

fn renderSrcinfo(allocator: std.mem.Allocator, md: AurMetadata) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "pkgbase = {s}\n" ++
            "\tpkgdesc = {s}\n" ++
            "\tpkgver = {s}\n" ++
            "\tpkgrel = {s}\n" ++
            "\turl = {s}\n" ++
            "\tarch = {s}\n" ++
            "\tlicense = {s}\n" ++
            "\toptions = !strip\n" ++
            "\tsource = {s}\n" ++
            "\tsha256sums = {s}\n" ++
            "\n" ++
            "pkgname = {s}\n",
        .{
            md.pkgname,
            md.pkgdesc,
            md.pkgver,
            md.pkgrel,
            md.url,
            md.arch,
            md.license,
            md.source_url,
            md.sha256,
            md.pkgname,
        },
    );
}

fn generateSrcInfoFromPkgbuild(
    allocator: std.mem.Allocator,
    io: std.Io,
    aur_dir: []const u8,
    md: AurMetadata,
) AurError![]const u8 {
    _ = md;
    const cmd = try std.fmt.allocPrint(
        allocator,
        "cd \"{s}\" && makepkg --printsrcinfo",
        .{aur_dir},
    );
    defer allocator.free(cmd);

    const run = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", cmd },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return error.ProcessError;
    defer {
        allocator.free(run.stdout);
        allocator.free(run.stderr);
    }

    if (run.term != .exited or run.term.exited != 0 or run.stdout.len == 0) {
        return error.ProcessError;
    }

    return allocator.dupe(u8, run.stdout);
}

fn resolveSshKey(allocator: std.mem.Allocator, configured_key: ?[]const u8) !?[]const u8 {
    if (configured_key) |k| {
        if (k.len == 0) return null;
        return @as(?[]const u8, try allocator.dupe(u8, k));
    }
    const environ = std.Options.debug_threaded_io.?.environ.process_environ;
    return std.process.Environ.getAlloc(environ, allocator, "AUR_SSH_KEY") catch null;
}

fn pushToAur(
    allocator: std.mem.Allocator,
    io: std.Io,
    aur_repo: []const u8,
    ssh_key: ?[]const u8,
    aur_dir: []const u8,
    pkgver: []const u8,
) AurError!bool {
    const tmp_dir = try std.fmt.allocPrint(allocator, "/tmp/takeoff-aur-{s}-{s}", .{ aur_repo, pkgver });
    defer allocator.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch return error.WriteError;

    const repo_url = try std.fmt.allocPrint(allocator, "ssh://aur@aur.archlinux.org/{s}.git", .{aur_repo});
    defer allocator.free(repo_url);

    const ssh_cmd = if (ssh_key) |key|
        try std.fmt.allocPrint(allocator, "ssh -i \"{s}\" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new", .{key})
    else
        null;
    defer if (ssh_cmd) |s| allocator.free(s);

    const clone_cmd = if (ssh_cmd) |s|
        try std.fmt.allocPrint(allocator, "GIT_SSH_COMMAND='{s}' git clone \"{s}\" \"{s}\"", .{ s, repo_url, tmp_dir })
    else
        try std.fmt.allocPrint(allocator, "git clone \"{s}\" \"{s}\"", .{ repo_url, tmp_dir });
    defer allocator.free(clone_cmd);
    try runShell(allocator, io, clone_cmd);

    // Copy all generated files from aur_dir to the cloned repo
    const copy_cmd = try std.fmt.allocPrint(
        allocator,
        "cp \"{s}/PKGBUILD\" \"{s}/.SRCINFO\" \"{s}\"",
        .{ aur_dir, aur_dir, tmp_dir },
    );
    defer allocator.free(copy_cmd);
    try runShell(allocator, io, copy_cmd);

    // Copy LICENSE and REUSE.toml if they exist in aur_dir
    const copy_license_cmd = try std.fmt.allocPrint(
        allocator,
        "test -f \"{s}/LICENSE\" && cp \"{s}/LICENSE\" \"{s}/LICENSE\" || true",
        .{ aur_dir, aur_dir, tmp_dir },
    );
    defer allocator.free(copy_license_cmd);
    try runShell(allocator, io, copy_license_cmd);

    const copy_reuse_cmd = try std.fmt.allocPrint(
        allocator,
        "test -f \"{s}/REUSE.toml\" && cp \"{s}/REUSE.toml\" \"{s}/REUSE.toml\" || true",
        .{ aur_dir, aur_dir, tmp_dir },
    );
    defer allocator.free(copy_reuse_cmd);
    try runShell(allocator, io, copy_reuse_cmd);

    const add_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" add PKGBUILD .SRCINFO && " ++
            "(test -f \"{s}/LICENSE\" && git -C \"{s}\" add LICENSE || true) && " ++
            "(test -f \"{s}/REUSE.toml\" && git -C \"{s}\" add REUSE.toml || true)",
        .{ tmp_dir, tmp_dir, tmp_dir, tmp_dir, tmp_dir },
    );
    defer allocator.free(add_cmd);
    try runShell(allocator, io, add_cmd);

    const diff_cmd = try std.fmt.allocPrint(allocator, "git -C \"{s}\" diff --cached --quiet", .{tmp_dir});
    defer allocator.free(diff_cmd);
    const changed = try runShellReturnsChanged(allocator, io, diff_cmd);
    if (!changed) return false;

    const commit_cmd = try std.fmt.allocPrint(
        allocator,
        "git -C \"{s}\" commit -m \"Update to {s}\"",
        .{ tmp_dir, pkgver },
    );
    defer allocator.free(commit_cmd);
    try runShell(allocator, io, commit_cmd);

    const push_cmd = if (ssh_cmd) |s|
        try std.fmt.allocPrint(allocator, "GIT_SSH_COMMAND='{s}' git -C \"{s}\" push", .{ s, tmp_dir })
    else
        try std.fmt.allocPrint(allocator, "git -C \"{s}\" push", .{tmp_dir});
    defer allocator.free(push_cmd);
    try runShell(allocator, io, push_cmd);

    return true;
}

fn runShell(allocator: std.mem.Allocator, io: std.Io, command: []const u8) AurError!void {
    const run = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch return error.ProcessError;
    defer {
        allocator.free(run.stdout);
        allocator.free(run.stderr);
    }
    if (run.term != .exited or run.term.exited != 0) {
        if (run.stderr.len > 0) log.err("command failed: {s}\n{s}", .{ command, run.stderr });
        return error.PushFailed;
    }
}

/// Returns true if there are staged changes (exit code 1), false if clean (exit 0).
fn runShellReturnsChanged(allocator: std.mem.Allocator, io: std.Io, command: []const u8) AurError!bool {
    const run = std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", command },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.ProcessError;
    defer {
        allocator.free(run.stdout);
        allocator.free(run.stderr);
    }

    if (run.term == .exited and run.term.exited == 0) return false;
    if (run.term == .exited and run.term.exited == 1) return true;
    return error.ProcessError;
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) AurError!void {
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return error.WriteError;
    defer f.close(io);
    f.writeStreamingAll(io, content) catch return error.WriteError;
}

test "normalizePkgver strips leading v and maps hyphen to underscore" {
    const allocator = std.testing.allocator;
    const out = try normalizePkgver(allocator, "v1.2.3-rc1");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1.2.3_rc1", out);
}

test "renderPkgbuild includes required install paths" {
    const allocator = std.testing.allocator;
    const md = AurMetadata{
        .pkgname = "mytool",
        .pkgver = "1.0.0",
        .pkgrel = "1",
        .pkgdesc = "My tool",
        .arch = "x86_64",
        .url = "https://example.com",
        .license = "MIT",
        .source_url = "https://github.com/o/r/releases/download/v1.0.0/mytool-1.0.0-linux-x86_64.tar.gz",
        .source_file = "mytool-1.0.0-linux-x86_64.tar.gz",
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .project_name = "mytool",
    };

    const content = try renderPkgbuild(allocator, md);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "pkgname=mytool") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "install -Dm755") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/usr/share/man") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/usr/share/bash-completion/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "$srcdir/$_dir/bin/mytool") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "/usr/share/licenses/mytool/LICENSE") != null);
    // Must NOT contain redundant provides/conflicts for self
    try std.testing.expect(std.mem.indexOf(u8, content, "provides=") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "conflicts=") == null);
}

test "renderSrcinfo includes pkgbase and pkgname" {
    const allocator = std.testing.allocator;
    const md = AurMetadata{
        .pkgname = "mytool",
        .pkgver = "1.0.0",
        .pkgrel = "1",
        .pkgdesc = "My tool",
        .arch = "x86_64",
        .url = "https://example.com",
        .license = "MIT",
        .source_url = "https://github.com/o/r/releases/download/v1.0.0/mytool-1.0.0-linux-x86_64.tar.gz",
        .source_file = "mytool-1.0.0-linux-x86_64.tar.gz",
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .project_name = "mytool",
    };

    const content = try renderSrcinfo(allocator, md);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "pkgbase = mytool") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "pkgname = mytool") != null);
    // Must NOT contain redundant provides/conflicts for self
    try std.testing.expect(std.mem.indexOf(u8, content, "provides =") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "conflicts =") == null);
}
