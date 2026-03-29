const std = @import("std");
const checksum = @import("checksum.zig");

const log = std.log.scoped(.verify);

/// Error set for verify operations.
pub const VerifyError = error{
    FileNotFound,
    InvalidChecksumsFile,
    VerificationFailed,
} || checksum.ChecksumError;

/// Configuration for the verify command.
pub const VerifyOptions = struct {
    /// Path to the checksums file (null = auto-detect)
    checksums_file: ?[]const u8,
    /// Hash algorithm to use (null = auto-detect from filename)
    algorithm: ?checksum.HashAlgorithm,
    /// Base directory for relative paths (null = derive from checksums file location)
    base_dir: ?[]const u8,
};

/// Result of a verify operation.
pub const VerifyResult = struct {
    files_verified: usize,
    algorithm: checksum.HashAlgorithm,
    checksums_file: []const u8,

    pub fn deinit(self: VerifyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.checksums_file);
    }
};

/// Default checksums file paths to try when not specified.
const DEFAULT_CHECKSUMS_PATHS = &[_][]const u8{
    "dist/checksums-sha256.txt",
    "dist/checksums-blake3.txt",
    "checksums-sha256.txt",
    "checksums-blake3.txt",
};

/// Find a checksums file in common locations.
fn findChecksumsFile(allocator: std.mem.Allocator) ?[]const u8 {
    const io = std.Options.debug_io;
    for (DEFAULT_CHECKSUMS_PATHS) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return allocator.dupe(u8, path) catch return null;
    }
    return null;
}

/// Verify checksums from a checksums file.
/// Auto-detects algorithm from filename if not specified.
pub fn verify(
    allocator: std.mem.Allocator,
    options: VerifyOptions,
) VerifyError!VerifyResult {
    // Determine checksums file
    const checksums_file = blk: {
        if (options.checksums_file) |cf| {
            break :blk try allocator.dupe(u8, cf);
        }
        if (findChecksumsFile(allocator)) |found| {
            break :blk found;
        }
        return VerifyError.FileNotFound;
    };
    defer allocator.free(checksums_file);

    // Check if file exists
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().access(io, checksums_file, .{}) catch |err| {
        log.err("checksums file not found: {s}", .{checksums_file});
        return switch (err) {
            error.FileNotFound => VerifyError.FileNotFound,
            error.AccessDenied => VerifyError.FileNotFound,
            error.PermissionDenied => VerifyError.FileNotFound,
            else => VerifyError.FileNotFound,
        };
    };

    // Determine algorithm
    const algorithm = blk: {
        if (options.algorithm) |algo| {
            break :blk algo;
        }
        if (checksum.detectAlgorithmFromFilename(checksums_file)) |algo| {
            log.info("auto-detected algorithm: {s}", .{algo.displayName()});
            break :blk algo;
        }
        log.err("could not auto-detect hash algorithm from filename: {s}", .{checksums_file});
        return VerifyError.InvalidChecksumsFile;
    };

    // Perform verification
    const files_verified = try checksum.verifyChecksumFile(
        allocator,
        checksums_file,
        options.base_dir,
        algorithm,
    );

    if (files_verified == 0) {
        log.warn("no files verified from {s}", .{checksums_file});
        return VerifyError.InvalidChecksumsFile;
    }

    return VerifyResult{
        .files_verified = files_verified,
        .algorithm = algorithm,
        .checksums_file = try allocator.dupe(u8, checksums_file),
    };
}

/// Print verification results.
pub fn printResult(result: VerifyResult, writer: anytype) !void {
    try writer.print("\n✓ Verification complete\n", .{});
    try writer.print("  Algorithm: {s}\n", .{result.algorithm.displayName()});
    try writer.print("  Checksums file: {s}\n", .{result.checksums_file});
    try writer.print("  Files verified: {d}\n", .{result.files_verified});
}

test "VerifyOptions struct" {
    const options = VerifyOptions{
        .checksums_file = "test.txt",
        .algorithm = .sha256,
        .base_dir = ".",
    };

    try std.testing.expectEqualStrings("test.txt", options.checksums_file.?);
    try std.testing.expectEqual(checksum.HashAlgorithm.sha256, options.algorithm.?);
    try std.testing.expectEqualStrings(".", options.base_dir.?);
}

test "VerifyResult stores verification info" {
    const allocator = std.testing.allocator;

    const result = VerifyResult{
        .files_verified = 5,
        .algorithm = .sha256,
        .checksums_file = try allocator.dupe(u8, "checksums.txt"),
    };
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), result.files_verified);
    try std.testing.expectEqual(checksum.HashAlgorithm.sha256, result.algorithm);
}

test "findChecksumsFile finds existing files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create one of the default checksums files
    try tmp_dir.dir.writeFile(.{
        .sub_path = "checksums-sha256.txt",
        .data = "test content",
    });

    // Save original cwd and change to temp dir
    const original_cwd = std.process.cwd();
    defer std.process.chdir(original_cwd) catch {};

    try tmp_dir.dir.setAsCwd();

    const found = findChecksumsFile(allocator);
    defer if (found) |f| allocator.free(f);

    try std.testing.expect(found != null);
}

test "verify succeeds with valid checksums" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.txt",
        .data = "Hello, World!\n",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try tmp_dir.dir.realpath("test.txt", &buf);

    // Compute SHA-256 hash
    const hash = try checksum.computeSha256(allocator, test_file_path);
    defer allocator.free(hash);

    // Create checksums file
    const checksums_content = try std.fmt.allocPrint(
        allocator,
        "{s}  test.txt\n",
        .{hash},
    );
    defer allocator.free(checksums_content);

    try tmp_dir.dir.writeFile(.{
        .sub_path = "checksums-sha256.txt",
        .data = checksums_content,
    });

    const checksums_path = try tmp_dir.dir.realpath("checksums-sha256.txt", &buf);

    // Change to the temp dir so relative paths work
    const original_cwd = std.process.cwd();
    defer std.process.chdir(original_cwd) catch {};

    try tmp_dir.dir.setAsCwd();

    // Get relative path for checksums file
    const relative_checksums_path = std.fs.path.basename(checksums_path);

    const result = try verify(allocator, .{
        .checksums_file = relative_checksums_path,
        .algorithm = null,
        .base_dir = null,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.files_verified);
    try std.testing.expectEqual(checksum.HashAlgorithm.sha256, result.algorithm);
}

test "verify auto-detects algorithm from filename" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.txt",
        .data = "Hello, World!\n",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try tmp_dir.dir.realpath("test.txt", &buf);

    // Compute SHA-256 hash
    const hash = try checksum.computeSha256(allocator, test_file_path);
    defer allocator.free(hash);

    // Create checksums file with sha256 in name
    const checksums_content = try std.fmt.allocPrint(
        allocator,
        "{s}  test.txt\n",
        .{hash},
    );
    defer allocator.free(checksums_content);

    try tmp_dir.dir.writeFile(.{
        .sub_path = "checksums-sha256.txt",
        .data = checksums_content,
    });

    const checksums_path = try tmp_dir.dir.realpath("checksums-sha256.txt", &buf);

    // Change to the temp dir so relative paths work
    const original_cwd = std.process.cwd();
    defer std.process.chdir(original_cwd) catch {};

    try tmp_dir.dir.setAsCwd();

    const relative_checksums_path = std.fs.path.basename(checksums_path);

    const result = try verify(allocator, .{
        .checksums_file = relative_checksums_path,
        .algorithm = null, // Auto-detect
        .base_dir = null,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(checksum.HashAlgorithm.sha256, result.algorithm);
}

test "verify returns FileNotFound for missing checksums file" {
    const allocator = std.testing.allocator;

    const result = verify(allocator, .{
        .checksums_file = "nonexistent-checksums.txt",
        .algorithm = .sha256,
        .base_dir = null,
    });

    try std.testing.expectError(error.FileNotFound, result);
}

test "verify detects checksum mismatch" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create a test file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.txt",
        .data = "Hello, World!\n",
    });

    // Create checksums file with wrong hash
    const checksums_content = "0000000000000000000000000000000000000000000000000000000000000000  test.txt\n";

    try tmp_dir.dir.writeFile(.{
        .sub_path = "checksums-sha256.txt",
        .data = checksums_content,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const checksums_path = try tmp_dir.dir.realpath("checksums-sha256.txt", &buf);

    // Change to the temp dir so relative paths work
    const original_cwd = std.process.cwd();
    defer std.process.chdir(original_cwd) catch {};

    try tmp_dir.dir.setAsCwd();

    const relative_checksums_path = std.fs.path.basename(checksums_path);

    const result = verify(allocator, .{
        .checksums_file = relative_checksums_path,
        .algorithm = .sha256,
        .base_dir = null,
    });

    try std.testing.expectError(error.ChecksumMismatch, result);
}
