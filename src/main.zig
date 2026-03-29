const std = @import("std");
const ZigReleaser = @import("ZigReleaser");
const config = @import("ZigReleaser").config;

const log = std.log.scoped(.main);

pub const WriteError = std.fs.File.WriteError;

const MainError = error{
    OutOfMemory,
    WriteError,
} || ZigReleaser.CliError;

pub fn main() u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer {
        if (gpa.deinit() == .leak) {
            log.err("memory leak detected", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch |err| {
        log.err("failed to allocate args: {}", .{err});
        return 1;
    };
    defer std.process.argsFree(allocator, args);

    // args[0] is the executable name; skip it.
    const cmd_args: []const []const u8 = if (args.len > 1) blk: {
        var out: []const []const u8 = undefined;
        out.ptr = @ptrCast(args.ptr + 1);
        out.len = args.len - 1;
        break :blk out;
    } else &[_][]const u8{};

    const command = ZigReleaser.Command.fromArgs(cmd_args) catch |err| {
        log.err("invalid command: {}", .{err});
        return 1;
    };

    return executeCommand(command);
}

fn executeCommand(command: ZigReleaser.Command) u8 {
    const stdout = std.fs.File.stdout();
    switch (command) {
        .version => {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "zr {s}\n", .{ZigReleaser.VERSION}) catch {
                log.err("version string too long", .{});
                return 1;
            };
            stdout.writeAll(msg) catch |err| {
                log.err("failed to write version: {}", .{err});
                return 1;
            };
        },
        .help => {
            stdout.writeAll(usage) catch |err| {
                log.err("failed to write usage: {}", .{err});
                return 1;
            };
        },
        .check => {
            var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
            defer {
                if (gpa.deinit() == .leak) {
                    log.err("memory leak detected", .{});
                }
            }
            const allocator = gpa.allocator();

            var cfg = ZigReleaser.config.loadDefault(allocator) catch |err| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("Error: ", .{}) catch {};
                ZigReleaser.config.formatParseError(err, stderr) catch {};
                stderr.print("\n", .{}) catch {};
                return 1;
            };
            defer cfg.deinit(allocator);

            ZigReleaser.config.validate(&cfg) catch |err| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("Validation error: ", .{}) catch {};
                ZigReleaser.config.formatValidationError(err, stderr) catch {};
                stderr.print("\n", .{}) catch {};
                return 1;
            };

            stdout.writeAll("✓ zr.toml is valid\n") catch |err| {
                log.err("failed to write output: {}", .{err});
                return 1;
            };
        },
    }
    return 0;
}

const usage =
    \\zr - Release automation for Zig projects
    \\
    \\Usage:
    \\  zr [OPTIONS] [COMMAND]
    \\
    \\Commands:
    \\  check            Validate zr.toml configuration
    \\
    \\Options:
    \\  -v, --version    Print version information
    \\  -h, --help       Print this help message
    \\
;

test "VERSION is non-empty" {
    try std.testing.expectEqualStrings("0.1.0", ZigReleaser.VERSION);
}
