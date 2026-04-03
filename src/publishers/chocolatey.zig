//! Chocolatey publisher — pushes a `.nupkg` to the Chocolatey Community
//! Repository via the NuGet v2 push API.
//!
//! Requires the `CHOCOLATEY_API_KEY` environment variable.
//!
//! API reference: https://docs.chocolatey.org/en-us/create/commands/push/

const std = @import("std");

const log = std.log.scoped(.chocolatey_publisher);

/// Options for publishing a Chocolatey package.
pub const ChocolateyPublishOptions = struct {
    /// Path to the `.nupkg` file to push.
    nupkg_path: []const u8,
    /// Chocolatey API key (from CHOCOLATEY_API_KEY env var).
    api_key: []const u8,
    /// If true, only report what would be done — do not push.
    dry_run: bool = false,
};

/// Result of a Chocolatey publish operation.
pub const ChocolateyPublishResult = struct {
    success: bool,
    /// Human-readable message describing the outcome.
    message: []const u8,

    pub fn deinit(self: *ChocolateyPublishResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// Error set for Chocolatey publish operations.
pub const ChocolateyPublishError = error{
    FileNotFound,
    ReadError,
    NetworkError,
    ApiError,
    MissingApiKey,
    OutOfMemory,
};

/// Push a `.nupkg` to the Chocolatey Community Repository.
pub fn publishChocolateyPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: ChocolateyPublishOptions,
) ChocolateyPublishError!ChocolateyPublishResult {
    if (opts.api_key.len == 0) return error.MissingApiKey;

    const nupkg_name = std.fs.path.basename(opts.nupkg_path);

    if (opts.dry_run) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "generated package (dry-run, no push): {s}",
            .{opts.nupkg_path},
        );
        return ChocolateyPublishResult{
            .success = true,
            .message = msg,
        };
    }

    // Read the .nupkg file into memory.
    const nupkg_data = std.Io.Dir.cwd().readFileAlloc(
        io,
        opts.nupkg_path,
        allocator,
        .limited(100 * 1024 * 1024), // 100 MB max
    ) catch |err| {
        log.err("failed to read {s}: {}", .{ opts.nupkg_path, err });
        return error.FileNotFound;
    };
    defer allocator.free(nupkg_data);

    // Build multipart/form-data body.
    // The NuGet v2 API accepts the raw .nupkg bytes as the POST body
    // (not multipart). See: https://docs.microsoft.com/en-us/nuget/api/package-publish-resource
    // The body IS the raw .nupkg bytes, content-type: application/octet-stream.

    // Create HTTP client.
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse("https://push.chocolatey.org/") catch {
        log.err("invalid push URL", .{});
        return error.NetworkError;
    };

    var request = client.request(.PUT, uri, .{
        .extra_headers = &.{
            .{ .name = "X-NuGet-ApiKey", .value = opts.api_key },
            .{ .name = "Content-Type", .value = "application/octet-stream" },
        },
    }) catch |err| {
        log.err("failed to create request: {}", .{err});
        return error.NetworkError;
    };
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = nupkg_data.len };
    var body_writer = request.sendBodyUnflushed(&.{}) catch |err| {
        log.err("failed to start body: {}", .{err});
        return error.NetworkError;
    };
    body_writer.writer.writeAll(nupkg_data) catch |err| {
        log.err("failed to write body: {}", .{err});
        return error.NetworkError;
    };
    body_writer.end() catch |err| {
        log.err("failed to end body: {}", .{err});
        return error.NetworkError;
    };
    request.connection.?.flush() catch |err| {
        log.err("failed to flush: {}", .{err});
        return error.NetworkError;
    };

    var redirect_buffer: [1024]u8 = undefined;
    const response = request.receiveHead(&redirect_buffer) catch |err| {
        log.err("failed to receive response: {}", .{err});
        return error.NetworkError;
    };

    const status: u10 = @intFromEnum(response.head.status);

    if (status >= 200 and status < 300) {
        const msg = try std.fmt.allocPrint(
            allocator,
            "pushed {s} to chocolatey.org (HTTP {d})",
            .{ nupkg_name, status },
        );
        log.info("pushed {s} successfully", .{nupkg_name});
        return ChocolateyPublishResult{
            .success = true,
            .message = msg,
        };
    } else {
        const msg = try std.fmt.allocPrint(
            allocator,
            "push failed (HTTP {d})",
            .{status},
        );
        log.err("push failed for {s}: HTTP {d}", .{ nupkg_name, status });
        return ChocolateyPublishResult{
            .success = false,
            .message = msg,
        };
    }
}
