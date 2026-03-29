const std = @import("std");

const log = std.log.scoped(.git);

/// Error set for git operations.
pub const GitError = error{
    NotAGitRepository,
    NoGitTag,
    GitCommandFailed,
} || std.mem.Allocator.Error;

/// Get the current git tag or commit hash.
/// Returns null if not in a git repo or if git command fails.
/// Caller owns the returned memory.
pub fn getVersion(allocator: std.mem.Allocator, io: std.Io) GitError!?[]const u8 {
    if (!isGitRepo(allocator, io)) {
        return null;
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "describe", "--tags", "--always" },
    }) catch |err| {
        log.debug("Failed to run git describe: {}", .{err});
        return null;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (trimmed.len == 0) {
        return null;
    }

    return @constCast(try allocator.dupe(u8, trimmed));
}

/// Check if we're inside a git repository.
fn isGitRepo(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--is-inside-work-tree" },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term == .exited and result.term.exited == 0;
}

test "isGitRepo detects git repository" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expect(isGitRepo(allocator, io));
}

test "getVersion returns git version" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const version = try getVersion(allocator, io);
    if (version) |v| {
        defer allocator.free(v);
        try std.testing.expect(v.len > 0);
    }
}

/// Verify that a specific tag exists in the repository.
/// Returns true if the tag exists, false otherwise.
pub fn tagExists(allocator: std.mem.Allocator, io: std.Io, tag: []const u8) GitError!bool {
    if (!isGitRepo(allocator, io)) {
        return false;
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--verify", tag },
    }) catch return false;
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    return result.term == .exited and result.term.exited == 0;
}

/// Get the commit SHA for a tag.
/// Returns null if the tag doesn't exist.
/// Caller owns the returned memory.
pub fn getTagCommit(allocator: std.mem.Allocator, io: std.Io, tag: []const u8) GitError!?[]const u8 {
    if (!try tagExists(allocator, io, tag)) {
        return null;
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-list", "-n", "1", tag },
    }) catch |err| {
        log.debug("Failed to run git rev-list: {}", .{err});
        return null;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term != .exited or result.term.exited != 0) {
        return null;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (trimmed.len == 0) {
        return null;
    }

    return allocator.dupe(u8, trimmed);
}

test "tagExists detects existing tags" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const current_version = try getVersion(allocator, io);
    if (current_version) |version| {
        defer allocator.free(version);

        const exists = try tagExists(allocator, io, version);
        try std.testing.expect(exists);
    }

    const non_existent = try tagExists(allocator, io, "v999.999.999");
    try std.testing.expect(!non_existent);
}

test "getTagCommit returns commit for valid tag" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();

    const current_version = try getVersion(allocator, io);
    if (current_version) |version| {
        defer allocator.free(version);

        const commit = try getTagCommit(allocator, io, version);
        if (commit) |c| {
            defer allocator.free(c);
            try std.testing.expectEqual(@as(usize, 40), c.len);
        }
    }

    const non_existent = try getTagCommit(allocator, io, "v999.999.999");
    try std.testing.expect(non_existent == null);
}
