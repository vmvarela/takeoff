const std = @import("std");

const log = std.log.scoped(.archive);

/// Archive format types supported.
pub const ArchiveFormat = enum {
    tar_gz,
    zip,
};

/// Error set for archive operations.
pub const ArchiveError = error{
    FileNotFound,
    ReadError,
    WriteError,
    InvalidFormat,
    UnsupportedFormat,
} || std.mem.Allocator.Error;

/// Configuration for creating an archive.
pub const ArchiveConfig = struct {
    /// Name of the project (used in directory structure)
    name: []const u8,
    /// Version of the project
    version: []const u8,
    /// Target triple (e.g., "linux-x86_64")
    target: []const u8,
    /// Path to the binary artifact
    binary_path: []const u8,
    /// Path where the archive should be written
    output_path: []const u8,
    /// Extra files to include (paths relative to project root)
    extra_files: []const []const u8 = &.{},
    /// Optional path to man pages directory
    man_pages: ?[]const u8 = null,
    /// Optional path to completions directory
    completions: ?[]const u8 = null,
    /// Archive format
    format: ArchiveFormat = .tar_gz,
};

/// Result of an archive creation operation.
pub const ArchiveResult = struct {
    success: bool,
    output_path: ?[]const u8,
    error_message: ?[]const u8,

    pub fn deinit(self: *ArchiveResult, allocator: std.mem.Allocator) void {
        if (self.output_path) |p| allocator.free(p);
        if (self.error_message) |m| allocator.free(m);
    }
};

/// Entry in the archive with its content.
pub const ArchiveEntry = struct {
    path: []const u8,
    content: []const u8,
    mode: u32,
    is_directory: bool,

    pub fn deinit(self: *const ArchiveEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

/// Collection of entries to be archived.
pub const ArchiveEntries = struct {
    entries: std.ArrayListUnmanaged(ArchiveEntry) = .empty,

    pub fn deinit(self: *ArchiveEntries, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            entry.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }

    pub fn addEntry(
        self: *ArchiveEntries,
        allocator: std.mem.Allocator,
        path: []const u8,
        content: []const u8,
        mode: u32,
        is_directory: bool,
    ) ArchiveError!void {
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        const content_copy = try allocator.dupe(u8, content);
        errdefer allocator.free(content_copy);

        try self.entries.append(allocator, .{
            .path = path_copy,
            .content = content_copy,
            .mode = mode,
            .is_directory = is_directory,
        });
    }

    /// Sort entries alphabetically by path for reproducibility.
    pub fn sort(self: *ArchiveEntries) void {
        const S = struct {
            fn lessThan(_: @This(), a: ArchiveEntry, b: ArchiveEntry) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        };
        std.mem.sort(ArchiveEntry, self.entries.items, S{}, S.lessThan);
    }
};

/// Collect all files that need to be archived.
fn collectEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ArchiveConfig,
) ArchiveError!ArchiveEntries {
    var entries: ArchiveEntries = .{};
    errdefer entries.deinit(allocator);

    // Root directory prefix: {name}-{version}
    const prefix = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ config.name, config.version });
    defer allocator.free(prefix);

    // Add bin directory marker
    const bin_dir = try std.fmt.allocPrint(allocator, "{s}/bin/", .{prefix});
    defer allocator.free(bin_dir);
    try entries.addEntry(allocator, bin_dir, "", 0o755, true);

    // Read binary file
    const binary_content = try readFile(allocator, io, config.binary_path);
    defer allocator.free(binary_content);

    // Get binary name from path
    const binary_name = std.fs.path.basename(config.binary_path);
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/bin/{s}", .{ prefix, binary_name });
    defer allocator.free(bin_path);

    try entries.addEntry(allocator, bin_path, binary_content, 0o755, false);

    // Add man pages if configured
    if (config.man_pages) |man_dir| {
        try addDirectoryContents(
            allocator,
            io,
            &entries,
            man_dir,
            prefix,
            "man",
        );
    }

    // Add completions if configured
    if (config.completions) |comp_dir| {
        try addDirectoryContents(
            allocator,
            io,
            &entries,
            comp_dir,
            prefix,
            "completions",
        );
    }

    // Add extra files
    for (config.extra_files) |extra_file| {
        const content = try readFile(allocator, io, extra_file);
        defer allocator.free(content);

        const extra_name = std.fs.path.basename(extra_file);
        const extra_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, extra_name });
        defer allocator.free(extra_path);

        try entries.addEntry(allocator, extra_path, content, 0o644, false);
    }

    // Sort entries for reproducibility
    entries.sort();

    return entries;
}

/// Read a file into memory.
fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ArchiveError![]u8 {
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024)) catch |err| {
        log.err("failed to read file {s}: {}", .{ path, err });
        return ArchiveError.FileNotFound;
    };

    return content;
}

/// Recursively add directory contents to entries.
fn addDirectoryContents(
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: *ArchiveEntries,
    source_dir: []const u8,
    prefix: []const u8,
    target_subdir: []const u8,
) ArchiveError!void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, source_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            log.warn("directory not found, skipping: {s}", .{source_dir});
            return;
        }
        log.err("failed to open directory {s}: {}", .{ source_dir, err });
        return ArchiveError.FileNotFound;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch |err| {
        log.err("failed to iterate directory {s}: {}", .{ source_dir, err });
        return ArchiveError.ReadError;
    }) |entry| {
        const source_path = try std.fs.path.join(allocator, &.{ source_dir, entry.name });
        defer allocator.free(source_path);

        const target_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}",
            .{ prefix, target_subdir, entry.name },
        );
        defer allocator.free(target_path);

        switch (entry.kind) {
            .directory => {
                const target_dir = try std.fmt.allocPrint(allocator, "{s}/", .{target_path});
                defer allocator.free(target_dir);
                try entries.addEntry(allocator, target_dir, "", 0o755, true);

                const new_subdir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target_subdir, entry.name });
                defer allocator.free(new_subdir);
                try addDirectoryContents(
                    allocator,
                    io,
                    entries,
                    source_path,
                    prefix,
                    new_subdir,
                );
            },
            .file => {
                const content = try readFile(allocator, io, source_path);
                defer allocator.free(content);
                try entries.addEntry(allocator, target_path, content, 0o644, false);
            },
            else => {
                log.warn("skipping unsupported entry type: {s}", .{source_path});
            },
        }
    }
}

/// Write a tar archive to a buffer.
fn writeTarToBuffer(
    allocator: std.mem.Allocator,
    entries: ArchiveEntries,
) ArchiveError![]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(allocator);

    for (entries.entries.items) |entry| {
        if (entry.is_directory) {
            try writeTarEntry(allocator, &buffer, entry.path, "", entry.mode, 0, true);
        } else {
            try writeTarEntry(allocator, &buffer, entry.path, entry.content, entry.mode, entry.content.len, false);
        }
    }

    // Write two empty blocks to mark end of archive
    const empty_block: [512]u8 = .{0} ** 512;
    try buffer.appendSlice(allocator, &empty_block);
    try buffer.appendSlice(allocator, &empty_block);

    return buffer.toOwnedSlice(allocator);
}

/// Write a single tar entry with proper USTAR format.
fn writeTarEntry(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    content: []const u8,
    mode: u32,
    size: usize,
    is_dir: bool,
) !void {
    var header: [512]u8 = .{0} ** 512;

    // Name (bytes 0-99) - handle long names with prefix
    if (path.len <= 100) {
        @memcpy(header[0..path.len], path);
    } else {
        // Split into prefix (131 chars max) and name (100 chars max)
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const name = path[last_slash + 1 ..];
        const prefix = path[0..last_slash];

        if (name.len > 100 or prefix.len > 155) {
            // Name too long, truncate (warning: may cause issues)
            const truncated = path[0..@min(path.len, 100)];
            @memcpy(header[0..truncated.len], truncated);
        } else {
            @memcpy(header[0..name.len], name);
            @memcpy(header[100..][0..@min(prefix.len, 155)], prefix);
        }
    }

    // Mode (bytes 100-107) - 8 bytes: octal number with null terminator
    // Format: 0000755\0 (8 chars)
    _ = std.fmt.bufPrint(header[100..108], "{o:0>7}\x00", .{mode}) catch unreachable;

    // UID (bytes 108-115) - 8 bytes
    @memcpy(header[108..116], "0000000\x00");

    // GID (bytes 116-123) - 8 bytes
    @memcpy(header[116..124], "0000000\x00");

    // Size (bytes 124-135) - 12 bytes: octal number with null terminator
    _ = std.fmt.bufPrint(header[124..136], "{o:0>11}\x00", .{size}) catch unreachable;

    // Mtime (bytes 136-147) - 12 bytes: 0 for reproducible builds
    @memcpy(header[136..148], "00000000000\x00");

    // Checksum placeholder (bytes 148-155) - 8 bytes: spaces for calculation
    @memcpy(header[148..156], "        ");

    // Type flag (byte 156)
    header[156] = if (is_dir) '5' else '0';

    // Link name (bytes 157-256) - empty for regular files/dirs
    // USTAR magic (bytes 257-262)
    @memcpy(header[257..263], "ustar\x00");

    // USTAR version (bytes 263-264)
    @memcpy(header[263..265], "00");

    // User name (bytes 265-296) - empty
    // Group name (bytes 297-328) - empty

    // Calculate checksum (sum of all bytes with checksum field treated as spaces)
    var checksum: u32 = 0;
    for (header[0..148]) |byte| checksum += byte;
    checksum += 8 * ' '; // Checksum field is 8 spaces
    for (header[156..]) |byte| checksum += byte;

    // Write checksum as octal with space terminator
    _ = std.fmt.bufPrint(header[148..154], "{o:0>6}", .{checksum}) catch unreachable;
    header[154] = ' '; // Space terminator for checksum
    header[155] = 0;

    try buffer.appendSlice(allocator, &header);

    // Write content and padding
    if (!is_dir and content.len > 0) {
        try buffer.appendSlice(allocator, content);

        // Pad to 512-byte boundary
        const padding = (512 - (content.len % 512)) % 512;
        if (padding > 0) {
            const pad: [512]u8 = .{0} ** 512;
            try buffer.appendSlice(allocator, pad[0..padding]);
        }
    }
}

/// Create a tar.gz archive with reproducible settings.
fn createTarGz(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ArchiveConfig,
) ArchiveError!ArchiveResult {
    // Collect all entries
    var entries = try collectEntries(allocator, io, config);
    defer entries.deinit(allocator);

    // Write tar to buffer
    const tar_data = try writeTarToBuffer(allocator, entries);
    defer allocator.free(tar_data);

    // Create output file
    const file = std.Io.Dir.cwd().createFile(io, config.output_path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to create archive: {}", .{err});
        return ArchiveResult{
            .success = false,
            .output_path = null,
            .error_message = msg,
        };
    };
    defer file.close(io);

    // Write gzip header (reproducible - mtime = 0)
    // GZIP header format: https://datatracker.ietf.org/doc/html/rfc1952#page-5
    const gzip_header = [_]u8{
        0x1f, 0x8b, // Magic number
        0x08, // Compression method (deflate)
        0x00, // Flags (no extra, no filename, no comment)
        0x00, 0x00, 0x00, 0x00, // MTIME (0 for reproducible)
        0x00, // Extra flags
        0xff, // OS (unknown)
    };
    file.writeStreamingAll(io, &gzip_header) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to write gzip header: {}", .{err});
        return ArchiveResult{
            .success = false,
            .output_path = null,
            .error_message = msg,
        };
    };

    // Compress data using deflate
    const compressed = try compressGzip(allocator, tar_data);
    defer allocator.free(compressed);

    file.writeStreamingAll(io, compressed) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to write compressed data: {}", .{err});
        return ArchiveResult{
            .success = false,
            .output_path = null,
            .error_message = msg,
        };
    };

    // Write gzip footer (CRC32 and uncompressed size)
    const crc = std.hash.Crc32.hash(tar_data);
    var footer: [8]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], crc, .little);
    std.mem.writeInt(u32, footer[4..8], @intCast(tar_data.len), .little);

    file.writeStreamingAll(io, &footer) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to write gzip footer: {}", .{err});
        return ArchiveResult{
            .success = false,
            .output_path = null,
            .error_message = msg,
        };
    };

    const output_path_copy = try allocator.dupe(u8, config.output_path);
    return ArchiveResult{
        .success = true,
        .output_path = output_path_copy,
        .error_message = null,
    };
}

/// Compress data using deflate with stored blocks (no compression).
/// This produces valid gzip output, though not optimally compressed.
/// The data is split into 65535-byte stored blocks (max for deflate).
fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ArchiveError![]u8 {
    // For stored blocks: each block needs 5 bytes overhead (1 byte header + 2 bytes LEN + 2 bytes NLEN)
    // Max block size is 65535 bytes
    const max_block_size = 65535;
    const num_blocks = (data.len + max_block_size - 1) / max_block_size;
    const worst_case_overhead = num_blocks * 5 + 1024; // Extra space for safety

    var output = try allocator.alloc(u8, data.len + worst_case_overhead);
    var pos: usize = 0;

    var data_pos: usize = 0;
    var remaining: usize = data.len;

    while (remaining > 0) {
        const block_size = @min(remaining, max_block_size);
        const is_final = remaining <= max_block_size;

        // Stored block header:
        // - BFINAL (1 bit): 1 if this is the last block
        // - BTYPE (2 bits): 00 for stored
        // Total: 3 bits, padded to byte boundary
        const header: u8 = if (is_final) 0x01 else 0x00;
        output[pos] = header;
        pos += 1;

        // LEN: number of data bytes (little-endian 16-bit)
        std.mem.writeInt(u16, output[pos..][0..2], @intCast(block_size), .little);
        pos += 2;

        // NLEN: one's complement of LEN (little-endian 16-bit)
        std.mem.writeInt(u16, output[pos..][0..2], @intCast(block_size ^ 0xFFFF), .little);
        pos += 2;

        // Data bytes
        @memcpy(output[pos..][0..block_size], data[data_pos..][0..block_size]);
        pos += block_size;
        data_pos += block_size;
        remaining -= block_size;
    }

    return allocator.realloc(output, pos) catch output[0..pos];
}

/// Create a zip archive with reproducible settings.
fn createZip(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ArchiveConfig,
) ArchiveError!ArchiveResult {
    // Collect all entries
    var entries = try collectEntries(allocator, io, config);
    defer entries.deinit(allocator);

    // Create output file
    const file = std.Io.Dir.cwd().createFile(io, config.output_path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to create archive: {}", .{err});
        return ArchiveResult{
            .success = false,
            .output_path = null,
            .error_message = msg,
        };
    };
    defer file.close(io);

    writeZipFile(file, io, entries) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to write zip file: {}", .{err});
        return ArchiveResult{
            .success = false,
            .output_path = null,
            .error_message = msg,
        };
    };

    const output_path_copy = try allocator.dupe(u8, config.output_path);
    return ArchiveResult{
        .success = true,
        .output_path = output_path_copy,
        .error_message = null,
    };
}

/// Write a simple ZIP file with stored (uncompressed) entries.
fn writeZipFile(
    file: std.Io.File,
    io: std.Io,
    entries: ArchiveEntries,
) !void {
    // Track offsets for central directory
    var cd_entries: std.ArrayListUnmanaged(CentralDirEntry) = .empty;
    defer cd_entries.deinit(std.heap.page_allocator);

    var local_header_offset: u64 = 0;

    // Write local file headers and file data
    for (entries.entries.items) |entry| {
        if (entry.is_directory) continue; // Skip directories in ZIP

        const crc = std.hash.Crc32.hash(entry.content);

        // Local file header
        const local_header = LocalFileHeader{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false },
            .compression_method = .store,
            .last_modification_time = 0, // Reproducible
            .last_modification_date = 0, // Reproducible
            .crc32 = crc,
            .compressed_size = @intCast(entry.content.len),
            .uncompressed_size = @intCast(entry.content.len),
            .filename_len = @intCast(entry.path.len),
            .extra_len = 0,
        };

        try file.writeStreamingAll(io, std.mem.asBytes(&local_header));
        try file.writeStreamingAll(io, entry.path);
        try file.writeStreamingAll(io, entry.content);

        // Record central directory entry info
        try cd_entries.append(std.heap.page_allocator, .{
            .crc32 = crc,
            .compressed_size = @intCast(entry.content.len),
            .uncompressed_size = @intCast(entry.content.len),
            .filename = entry.path,
            .local_header_offset = local_header_offset,
        });

        local_header_offset += @sizeOf(LocalFileHeader) + entry.path.len + entry.content.len;
    }

    // Write central directory
    const cd_start = local_header_offset;
    for (cd_entries.items) |cd_entry| {
        const cd_header = CentralDirectoryHeader{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = cd_entry.crc32,
            .compressed_size = cd_entry.compressed_size,
            .uncompressed_size = cd_entry.uncompressed_size,
            .filename_len = @intCast(cd_entry.filename.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_header_offset = @intCast(cd_entry.local_header_offset),
        };

        try file.writeStreamingAll(io, std.mem.asBytes(&cd_header));
        try file.writeStreamingAll(io, cd_entry.filename);
    }

    const cd_size = local_header_offset - cd_start;

    // Write end of central directory record
    const end_record = std.zip.EndRecord{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(cd_entries.items.len),
        .record_count_total = @intCast(cd_entries.items.len),
        .central_directory_size = @intCast(cd_size),
        .central_directory_offset = @intCast(cd_start),
        .comment_len = 0,
    };

    try file.writeStreamingAll(io, std.mem.asBytes(&end_record));
}

const CentralDirEntry = struct {
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    filename: []const u8,
    local_header_offset: u64,
};

const ZipGeneralPurposeFlags = packed struct(u16) {
    encrypted: bool = false,
    _: u15 = 0,
};

const LocalFileHeader = extern struct {
    signature: [4]u8 align(1),
    version_needed_to_extract: u16 align(1),
    flags: ZipGeneralPurposeFlags align(1),
    compression_method: std.zip.CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
};

const CentralDirectoryHeader = extern struct {
    signature: [4]u8 align(1),
    version_made_by: u16 align(1),
    version_needed_to_extract: u16 align(1),
    flags: ZipGeneralPurposeFlags align(1),
    compression_method: std.zip.CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
    comment_len: u16 align(1),
    disk_number: u16 align(1),
    internal_file_attributes: u16 align(1),
    external_file_attributes: u32 align(1),
    local_header_offset: u32 align(1),
};

/// Create an archive based on the specified configuration.
pub fn createArchive(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ArchiveConfig,
) ArchiveError!ArchiveResult {
    return switch (config.format) {
        .tar_gz => createTarGz(allocator, io, config),
        .zip => createZip(allocator, io, config),
    };
}

test "ArchiveFormat enum values" {
    try std.testing.expectEqual(ArchiveFormat.tar_gz, ArchiveFormat.tar_gz);
    try std.testing.expectEqual(ArchiveFormat.zip, ArchiveFormat.zip);
}

test "ArchiveEntries add and sort" {
    const allocator = std.testing.allocator;

    var entries: ArchiveEntries = .{};
    defer entries.deinit(allocator);

    try entries.addEntry(allocator, "b/file", "content b", 0o644, false);
    try entries.addEntry(allocator, "a/file", "content a", 0o644, false);
    try entries.addEntry(allocator, "c/file", "content c", 0o644, false);

    // Before sorting, order is insertion order
    try std.testing.expectEqualStrings("b/file", entries.entries.items[0].path);

    // After sorting, should be alphabetical
    entries.sort();
    try std.testing.expectEqualStrings("a/file", entries.entries.items[0].path);
    try std.testing.expectEqualStrings("b/file", entries.entries.items[1].path);
    try std.testing.expectEqualStrings("c/file", entries.entries.items[2].path);
}
