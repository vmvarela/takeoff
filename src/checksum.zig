const std = @import("std");

const log = std.log.scoped(.checksum);

/// Error set for checksum operations.
pub const ChecksumError = error{
    FileNotFound,
    ReadError,
    WriteError,
    InvalidFormat,
    ChecksumMismatch,
} || std.mem.Allocator.Error;

/// Supported hash algorithms.
pub const HashAlgorithm = enum {
    sha256,
    blake3,

    /// Returns the standard filename suffix for this algorithm.
    pub fn fileSuffix(self: HashAlgorithm) []const u8 {
        return switch (self) {
            .sha256 => "sha256",
            .blake3 => "blake3",
        };
    }

    /// Returns a display name for this algorithm.
    pub fn displayName(self: HashAlgorithm) []const u8 {
        return switch (self) {
            .sha256 => "SHA-256",
            .blake3 => "BLAKE3",
        };
    }
};

/// Configuration for generating checksums.
pub const ChecksumConfig = struct {
    /// Output directory for checksum files
    output_dir: []const u8,
    /// Algorithm to use
    algorithm: HashAlgorithm,
};

/// Result of computing a single file's checksum.
pub const FileChecksum = struct {
    filename: []const u8,
    hash: []const u8,

    pub fn deinit(self: FileChecksum, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.hash);
    }
};

/// Result of generating checksums for multiple files.
pub const ChecksumResult = struct {
    algorithm: HashAlgorithm,
    output_path: []const u8,
    files_checked: usize,

    pub fn deinit(self: ChecksumResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_path);
    }
};

/// Summary of checksum generation for all algorithms.
pub const ChecksumSummary = struct {
    sha256_result: ?ChecksumResult,
    blake3_result: ?ChecksumResult,

    pub fn deinit(self: ChecksumSummary, allocator: std.mem.Allocator) void {
        if (self.sha256_result) |result| {
            result.deinit(allocator);
        }
        if (self.blake3_result) |result| {
            result.deinit(allocator);
        }
    }

    pub fn hasAnyFailed(self: ChecksumSummary) bool {
        _ = self;
        return false;
    }

    pub fn print(self: ChecksumSummary, writer: anytype) !void {
        try writer.print("\nChecksum Summary:\n", .{});
        try writer.print("==================\n", .{});

        if (self.sha256_result) |result| {
            try writer.print("  ✅ {s}: {s} ({d} files)\n", .{
                result.algorithm.displayName(),
                result.output_path,
                result.files_checked,
            });
        }

        if (self.blake3_result) |result| {
            try writer.print("  ✅ {s}: {s} ({d} files)\n", .{
                result.algorithm.displayName(),
                result.output_path,
                result.files_checked,
            });
        }

        if (self.sha256_result == null and self.blake3_result == null) {
            try writer.print("  (no checksums generated)\n", .{});
        }
    }
};

/// Compute SHA-256 hash of a file.
/// Returns a hex-encoded string that must be freed by the caller.
pub fn computeSha256(allocator: std.mem.Allocator, file_path: []const u8) ChecksumError![]const u8 {
    const io = std.Options.debug_io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| {
        log.err("failed to read file {s}: {}", .{ file_path, err });
        return ChecksumError.ReadError;
    };
    defer allocator.free(content);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);

    var hash_bytes: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash_bytes);

    // Convert to hex string
    const hex_len = hash_bytes.len * 2;
    const hex_str = try allocator.alloc(u8, hex_len);
    const hex_chars = "0123456789abcdef";
    for (hash_bytes, 0..) |byte, i| {
        hex_str[i * 2] = hex_chars[byte >> 4];
        hex_str[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return hex_str;
}

/// Compute BLAKE3 hash of a file.
/// Returns a hex-encoded string that must be freed by the caller.
pub fn computeBlake3(allocator: std.mem.Allocator, file_path: []const u8) ChecksumError![]const u8 {
    const io = std.Options.debug_io;
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| {
        log.err("failed to read file {s}: {}", .{ file_path, err });
        return ChecksumError.ReadError;
    };
    defer allocator.free(content);

    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(content);

    var hash_bytes: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    hasher.final(&hash_bytes);

    // Convert to hex string
    const hex_len = hash_bytes.len * 2;
    const hex_str = try allocator.alloc(u8, hex_len);
    const hex_chars = "0123456789abcdef";
    for (hash_bytes, 0..) |byte, i| {
        hex_str[i * 2] = hex_chars[byte >> 4];
        hex_str[i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return hex_str;
}

/// Compute checksum for a single file using the specified algorithm.
pub fn computeChecksum(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    algorithm: HashAlgorithm,
) ChecksumError![]const u8 {
    return switch (algorithm) {
        .sha256 => computeSha256(allocator, file_path),
        .blake3 => computeBlake3(allocator, file_path),
    };
}

/// Ensure directory exists.
fn ensureDirectory(path: []const u8) ChecksumError!void {
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, path) catch {
        return ChecksumError.WriteError;
    };
}

/// Get the basename of a path for use in checksum file.
fn getFileName(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return allocator.dupe(u8, std.fs.path.basename(path));
}

/// Generate checksums file for a list of file paths using specified algorithm.
/// Format: {hash}  {filename} (sha256sum-compatible with two spaces)
pub fn generateChecksumFile(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    config: ChecksumConfig,
) ChecksumError!ChecksumResult {
    if (file_paths.len == 0) {
        return ChecksumError.InvalidFormat;
    }

    // Ensure output directory exists
    try ensureDirectory(config.output_dir);

    // Build output file path: {output_dir}/checksums-{suffix}.txt
    const output_filename = try std.fmt.allocPrint(
        allocator,
        "checksums-{s}.txt",
        .{config.algorithm.fileSuffix()},
    );
    defer allocator.free(output_filename);

    const output_path = try std.fs.path.join(allocator, &.{ config.output_dir, output_filename });
    errdefer allocator.free(output_path);

    // Create output file
    const io = std.Options.debug_io;
    const file = std.Io.Dir.cwd().createFile(io, output_path, .{}) catch |err| {
        log.err("failed to create checksum file {s}: {}", .{ output_path, err });
        return ChecksumError.WriteError;
    };
    defer file.close(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    // Write checksums for each file
    var files_checked: usize = 0;
    for (file_paths) |file_path| {
        const hash = try computeChecksum(allocator, file_path, config.algorithm);
        defer allocator.free(hash);

        const filename = try getFileName(allocator, file_path);
        defer allocator.free(filename);

        // Write in sha256sum format: {hash}  {filename}\n
        const line = try std.fmt.allocPrint(allocator, "{s}  {s}\n", .{ hash, filename });
        defer allocator.free(line);

        try output.appendSlice(allocator, line);

        files_checked += 1;

        log.debug("computed {s} for {s}: {s}", .{
            config.algorithm.displayName(),
            filename,
            hash,
        });
    }

    file.writeStreamingAll(io, output.items) catch {
        return ChecksumError.WriteError;
    };

    log.info("generated {s} checksums file: {s} ({d} files)", .{
        config.algorithm.displayName(),
        output_path,
        files_checked,
    });

    return ChecksumResult{
        .algorithm = config.algorithm,
        .output_path = output_path,
        .files_checked = files_checked,
    };
}

/// Generate checksum files for all supported algorithms.
pub fn generateChecksums(
    allocator: std.mem.Allocator,
    file_paths: []const []const u8,
    output_dir: []const u8,
) ChecksumError!ChecksumSummary {
    if (file_paths.len == 0) {
        return ChecksumSummary{
            .sha256_result = null,
            .blake3_result = null,
        };
    }

    // Generate SHA-256 checksums
    const sha256_result = generateChecksumFile(allocator, file_paths, .{
        .output_dir = output_dir,
        .algorithm = .sha256,
    }) catch |err| {
        log.err("failed to generate SHA-256 checksums: {}", .{err});
        return err;
    };

    // Generate BLAKE3 checksums
    const blake3_result = generateChecksumFile(allocator, file_paths, .{
        .output_dir = output_dir,
        .algorithm = .blake3,
    }) catch |err| {
        log.err("failed to generate BLAKE3 checksums: {}", .{err});
        // Clean up SHA-256 result on failure
        sha256_result.deinit(allocator);
        return err;
    };

    return ChecksumSummary{
        .sha256_result = sha256_result,
        .blake3_result = blake3_result,
    };
}

/// Parse a checksum line in sha256sum format.
/// Format: {hash}  {filename}
fn parseChecksumLine(line: []const u8) ?struct { hash: []const u8, filename: []const u8 } {
    // Skip empty lines and comments
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    if (trimmed.len == 0 or trimmed[0] == '#') return null;

    // Find the two spaces separating hash and filename
    const hash_end = std.mem.indexOf(u8, trimmed, "  ");
    if (hash_end == null) return null;

    const hash = trimmed[0..hash_end.?];
    const filename = trimmed[hash_end.? + 2 ..];

    return .{
        .hash = hash,
        .filename = filename,
    };
}

/// Verify a single file against its expected checksum.
pub fn verifyFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    filename: []const u8,
    expected_hash: []const u8,
    algorithm: HashAlgorithm,
) ChecksumError!void {
    const file_path = try std.fs.path.join(allocator, &.{ base_dir, filename });
    defer allocator.free(file_path);

    const computed_hash = try computeChecksum(allocator, file_path, algorithm);
    defer allocator.free(computed_hash);

    if (!std.mem.eql(u8, computed_hash, expected_hash)) {
        log.err("checksum mismatch for {s}:", .{filename});
        log.err("  expected: {s}", .{expected_hash});
        log.err("  computed: {s}", .{computed_hash});
        return ChecksumError.ChecksumMismatch;
    }

    log.info("✓ {s} verified", .{filename});
}

/// Verify all checksums in a checksums file.
/// Returns the number of files successfully verified.
pub fn verifyChecksumFile(
    allocator: std.mem.Allocator,
    checksums_file: []const u8,
    base_dir: ?[]const u8,
    algorithm: HashAlgorithm,
) ChecksumError!usize {
    const actual_base_dir = base_dir orelse std.fs.path.dirname(checksums_file) orelse ".";

    const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, checksums_file, allocator, .limited(1024 * 1024)) catch {
        return ChecksumError.ReadError;
    };
    defer allocator.free(content);

    var files_verified: usize = 0;
    var line_no: usize = 0;

    log.info("verifying checksums from {s}...", .{checksums_file});

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_no += 1;

        const parsed = parseChecksumLine(line) orelse continue;

        verifyFile(
            allocator,
            actual_base_dir,
            parsed.filename,
            parsed.hash,
            algorithm,
        ) catch |err| {
            log.err("line {d}: failed to verify {s}", .{ line_no, parsed.filename });
            return err;
        };

        files_verified += 1;
    }

    log.info("verified {d} file(s)", .{files_verified});

    return files_verified;
}

/// Detect algorithm from checksums filename.
pub fn detectAlgorithmFromFilename(filename: []const u8) ?HashAlgorithm {
    if (std.mem.indexOf(u8, filename, "sha256") != null) {
        return .sha256;
    }
    if (std.mem.indexOf(u8, filename, "blake3") != null) {
        return .blake3;
    }
    return null;
}

test "HashAlgorithm enum values" {
    try std.testing.expectEqual(HashAlgorithm.sha256, HashAlgorithm.sha256);
    try std.testing.expectEqual(HashAlgorithm.blake3, HashAlgorithm.blake3);
}

test "HashAlgorithm.fileSuffix returns correct suffix" {
    try std.testing.expectEqualStrings("sha256", HashAlgorithm.sha256.fileSuffix());
    try std.testing.expectEqualStrings("blake3", HashAlgorithm.blake3.fileSuffix());
}

test "parseChecksumLine parses valid line" {
    const line = "6a09e667f3bcbb08a4c5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5  myfile.tar.gz";
    const parsed = parseChecksumLine(line).?;

    try std.testing.expectEqualStrings("6a09e667f3bcbb08a4c5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5", parsed.hash);
    try std.testing.expectEqualStrings("myfile.tar.gz", parsed.filename);
}

test "parseChecksumLine skips empty lines" {
    const line = "   ";
    try std.testing.expect(parseChecksumLine(line) == null);
}

test "parseChecksumLine skips comments" {
    const line = "# This is a comment";
    try std.testing.expect(parseChecksumLine(line) == null);
}

test "detectAlgorithmFromFilename detects SHA-256" {
    try std.testing.expectEqual(HashAlgorithm.sha256, detectAlgorithmFromFilename("checksums-sha256.txt").?);
}

test "detectAlgorithmFromFilename detects BLAKE3" {
    try std.testing.expectEqual(HashAlgorithm.blake3, detectAlgorithmFromFilename("checksums-blake3.txt").?);
}

test "detectAlgorithmFromFilename returns null for unknown" {
    try std.testing.expect(detectAlgorithmFromFilename("checksums.txt") == null);
}

test "ChecksumSummary tracks results" {
    const allocator = std.testing.allocator;

    const sha256_result = ChecksumResult{
        .algorithm = .sha256,
        .output_path = try allocator.dupe(u8, "dist/checksums-sha256.txt"),
        .files_checked = 3,
    };

    const blake3_result = ChecksumResult{
        .algorithm = .blake3,
        .output_path = try allocator.dupe(u8, "dist/checksums-blake3.txt"),
        .files_checked = 3,
    };

    var summary = ChecksumSummary{
        .sha256_result = sha256_result,
        .blake3_result = blake3_result,
    };
    defer summary.deinit(allocator);

    try std.testing.expect(!summary.hasAnyFailed());
}

test "computeSha256 produces consistent hashes" {
    const allocator = std.testing.allocator;

    // Create a test file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.txt",
        .data = "Hello, World!\n",
    });

    const tmp_path = try std.fs.path.join(allocator, &.{"test.txt"});
    defer allocator.free(tmp_path);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try tmp_dir.dir.realpath("test.txt", &buf);

    const hash1 = try computeSha256(allocator, test_file_path);
    defer allocator.free(hash1);

    const hash2 = try computeSha256(allocator, test_file_path);
    defer allocator.free(hash2);

    try std.testing.expectEqualStrings(hash1, hash2);
    try std.testing.expectEqual(@as(usize, 64), hash1.len); // SHA-256 hex is 64 chars
}

test "computeBlake3 produces consistent hashes" {
    const allocator = std.testing.allocator;

    // Create a test file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.txt",
        .data = "Hello, World!\n",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try tmp_dir.dir.realpath("test.txt", &buf);

    const hash1 = try computeBlake3(allocator, test_file_path);
    defer allocator.free(hash1);

    const hash2 = try computeBlake3(allocator, test_file_path);
    defer allocator.free(hash2);

    try std.testing.expectEqualStrings(hash1, hash2);
    try std.testing.expectEqual(@as(usize, 64), hash1.len); // BLAKE3 hex is 64 chars
}

test "generateChecksums produces both files" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test files
    try tmp_dir.dir.writeFile(.{
        .sub_path = "file1.tar.gz",
        .data = "content1",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "file2.zip",
        .data = "content2",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file1_path = try tmp_dir.dir.realpath("file1.tar.gz", &buf);
    const file2_path = try tmp_dir.dir.realpath("file2.zip", &buf);

    const file_paths = &[_][]const u8{ file1_path, file2_path };

    var summary = try generateChecksums(allocator, file_paths, tmp_dir.parent_dir_path.?);
    defer summary.deinit(allocator);

    try std.testing.expect(summary.sha256_result != null);
    try std.testing.expect(summary.blake3_result != null);
    try std.testing.expectEqual(@as(usize, 2), summary.sha256_result.?.files_checked);
    try std.testing.expectEqual(@as(usize, 2), summary.blake3_result.?.files_checked);
}

test "generateChecksums returns empty summary for empty paths" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_paths = &[_][]const u8{};

    var summary = try generateChecksums(allocator, file_paths, tmp_dir.parent_dir_path.?);
    defer summary.deinit(allocator);

    try std.testing.expect(summary.sha256_result == null);
    try std.testing.expect(summary.blake3_result == null);
}

test "verifyChecksumFile verifies correctly" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create test file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "test.txt",
        .data = "Hello, World!\n",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const test_file_path = try tmp_dir.dir.realpath("test.txt", &buf);

    // Compute hash
    const hash = try computeSha256(allocator, test_file_path);
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

    const verified = try verifyChecksumFile(allocator, checksums_path, null, .sha256);
    try std.testing.expectEqual(@as(usize, 1), verified);
}
