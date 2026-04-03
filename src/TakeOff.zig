const std = @import("std");
const build_options = @import("build_options");

const log = std.log.scoped(.TakeOff);

/// Version of takeoff, injected at build time from build.zig.zon.
pub const VERSION: []const u8 = build_options.version;

pub const config = @import("config.zig");
pub const build = @import("build.zig");
pub const parallel_build = @import("parallel_build.zig");
pub const git = @import("git.zig");
pub const progress = @import("progress.zig");
pub const archive = @import("archive.zig");
pub const packager = @import("packager.zig");
pub const packagers = @import("packagers/mod.zig");
pub const checksum = @import("checksum.zig");
pub const verify = @import("verify.zig");
pub const changelog = @import("changelog.zig");
pub const version = @import("version.zig");
pub const publishers = @import("publishers/mod.zig");
pub const metadata = @import("metadata.zig");
pub const release_context = @import("release/context.zig");

pub const CliError = error{
    InvalidArguments,
    UnknownCommand,
};

pub const Command = union(enum) {
    version,
    help,
    check,

    /// Parse CLI arguments into a Command. Returns `.help` for empty args.
    pub fn fromArgs(args: []const []const u8) CliError!Command {
        if (args.len == 0) return .help;

        const arg = args[0];

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))
            return .version;

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            return .help;

        if (std.mem.eql(u8, arg, "check"))
            return .check;

        return CliError.UnknownCommand;
    }
};

test "VERSION is non-empty" {
    try std.testing.expect(VERSION.len > 0);
}

test "Command.fromArgs parses --version" {
    const cmd = try Command.fromArgs(&[_][]const u8{"--version"});
    try std.testing.expectEqual(Command.version, cmd);
}

test "Command.fromArgs parses -v" {
    const cmd = try Command.fromArgs(&[_][]const u8{"-v"});
    try std.testing.expectEqual(Command.version, cmd);
}

test "Command.fromArgs parses --help" {
    const cmd = try Command.fromArgs(&[_][]const u8{"--help"});
    try std.testing.expectEqual(Command.help, cmd);
}

test "Command.fromArgs parses -h" {
    const cmd = try Command.fromArgs(&[_][]const u8{"-h"});
    try std.testing.expectEqual(Command.help, cmd);
}

test "Command.fromArgs returns help for empty args" {
    const cmd = try Command.fromArgs(&[_][]const u8{});
    try std.testing.expectEqual(Command.help, cmd);
}

test "Command.fromArgs parses check" {
    const cmd = try Command.fromArgs(&[_][]const u8{"check"});
    try std.testing.expectEqual(Command.check, cmd);
}

test "Command.fromArgs returns error for unknown command" {
    try std.testing.expectError(
        CliError.UnknownCommand,
        Command.fromArgs(&[_][]const u8{"unknown"}),
    );
}
