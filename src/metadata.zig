//! Metadata resolver — applies fallback precedence rules across project and
//! per-package configuration so publishers never need to inline this logic.
//!
//! Precedence for every field (highest to lowest):
//!   1. Package-specific value (e.g. packages.homebrew.description)
//!   2. project.<field> fallback (project.maintainer, project.url, project.description)
//!   3. Hard-coded default (if any)
//!
//! For homepage/url the rule is: homepage > url.  When a package has a
//! `homepage` field and it is non-null, that wins.  Otherwise `url` (if
//! present on the package) is tried, then project.url, then a provided
//! GitHub-derived default.

const std = @import("std");
const config = @import("config.zig");

/// Fully-resolved metadata ready for use by any publisher or packager.
pub const ResolvedMetadata = struct {
    /// One-line description of the package.
    description: []const u8,
    /// Maintainer/packager display string (e.g. "Name <email@example.com>").
    maintainer: []const u8,
    /// Homepage URL.
    homepage: []const u8,
    /// SPDX license identifier.
    license: []const u8,
};

/// Package-level optional overrides.  All fields mirror the common subset
/// shared by HomebrewPackage, ScoopPackage, WingetPackage, etc.  Pass a
/// zero-initialised value when there are no package-specific overrides.
pub const PackageOverrides = struct {
    description: ?[]const u8 = null,
    maintainer: ?[]const u8 = null,
    /// Preferred URL field for homepage (e.g. packages.homebrew.homepage).
    homepage: ?[]const u8 = null,
    /// Secondary URL field for homepage (e.g. packages.apk.url).
    url: ?[]const u8 = null,
};

/// Resolve metadata for a given publisher/packager.
///
/// `project` is the global project configuration block.
/// `overrides` carries any per-package values (may be all-null).
/// `github_url` is an optional pre-computed GitHub repo URL used as the
///   last-resort homepage fallback (e.g. "https://github.com/owner/repo").
///   Pass `null` when no GitHub context is available.
pub fn resolve(
    project: config.Project,
    overrides: PackageOverrides,
    github_url: ?[]const u8,
) ResolvedMetadata {
    const description = overrides.description orelse
        project.description orelse
        project.name;

    const maintainer = overrides.maintainer orelse
        project.maintainer orelse
        "Unknown <unknown@example.com>";

    // homepage > url precedence (package-level), then project.url, then GitHub fallback.
    const homepage = overrides.homepage orelse
        overrides.url orelse
        project.url orelse
        github_url orelse
        "";

    const license = project.license orelse "unknown";

    return .{
        .description = description,
        .maintainer = maintainer,
        .homepage = homepage,
        .license = license,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolve uses package-specific description over project.description" {
    const proj = config.Project{ .name = "mypkg", .description = "Project desc" };
    const ovr = PackageOverrides{ .description = "Package desc" };
    const md = resolve(proj, ovr, null);
    try std.testing.expectEqualStrings("Package desc", md.description);
}

test "resolve falls back to project.description when package description is null" {
    const proj = config.Project{ .name = "mypkg", .description = "Project desc" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("Project desc", md.description);
}

test "resolve falls back to project.name when both descriptions are null" {
    const proj = config.Project{ .name = "mypkg" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("mypkg", md.description);
}

test "resolve uses package maintainer over project.maintainer" {
    const proj = config.Project{ .name = "mypkg", .maintainer = "Global <global@example.com>" };
    const ovr = PackageOverrides{ .maintainer = "Pkg <pkg@example.com>" };
    const md = resolve(proj, ovr, null);
    try std.testing.expectEqualStrings("Pkg <pkg@example.com>", md.maintainer);
}

test "resolve falls back to project.maintainer when package maintainer is null" {
    const proj = config.Project{ .name = "mypkg", .maintainer = "Global <global@example.com>" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("Global <global@example.com>", md.maintainer);
}

test "resolve uses default maintainer when both are null" {
    const proj = config.Project{ .name = "mypkg" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("Unknown <unknown@example.com>", md.maintainer);
}

test "resolve homepage beats url in package overrides" {
    const proj = config.Project{ .name = "mypkg" };
    const ovr = PackageOverrides{
        .homepage = "https://homepage.example.com",
        .url = "https://url.example.com",
    };
    const md = resolve(proj, ovr, null);
    try std.testing.expectEqualStrings("https://homepage.example.com", md.homepage);
}

test "resolve falls back to package url when homepage is null" {
    const proj = config.Project{ .name = "mypkg" };
    const ovr = PackageOverrides{ .url = "https://url.example.com" };
    const md = resolve(proj, ovr, null);
    try std.testing.expectEqualStrings("https://url.example.com", md.homepage);
}

test "resolve falls back to project.url when package has no homepage/url" {
    const proj = config.Project{ .name = "mypkg", .url = "https://project.example.com" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("https://project.example.com", md.homepage);
}

test "resolve falls back to github_url when no url configured anywhere" {
    const proj = config.Project{ .name = "mypkg" };
    const md = resolve(proj, .{}, "https://github.com/owner/mypkg");
    try std.testing.expectEqualStrings("https://github.com/owner/mypkg", md.homepage);
}

test "resolve homepage is empty string when nothing is configured" {
    const proj = config.Project{ .name = "mypkg" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("", md.homepage);
}

test "resolve license falls back to 'unknown' when project.license is null" {
    const proj = config.Project{ .name = "mypkg" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("unknown", md.license);
}

test "resolve uses project.license" {
    const proj = config.Project{ .name = "mypkg", .license = "MIT" };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("MIT", md.license);
}

test "resolve returns all fields from project when no overrides" {
    const proj = config.Project{
        .name = "tool",
        .description = "A handy tool",
        .maintainer = "Dev <dev@example.com>",
        .url = "https://example.com/tool",
        .license = "Apache-2.0",
    };
    const md = resolve(proj, .{}, null);
    try std.testing.expectEqualStrings("A handy tool", md.description);
    try std.testing.expectEqualStrings("Dev <dev@example.com>", md.maintainer);
    try std.testing.expectEqualStrings("https://example.com/tool", md.homepage);
    try std.testing.expectEqualStrings("Apache-2.0", md.license);
}
