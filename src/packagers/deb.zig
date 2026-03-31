//! `.deb` package generator — produces a valid Debian binary package
//! (ar archive containing `debian-binary`, `control.tar.gz`, `data.tar.gz`)
//! entirely in Zig, without requiring `dpkg-deb` or any other external tool.
//!
//! Format references:
//!   - ar(5):    https://manpages.debian.org/bullseye/binutils/ar.5.en.html
//!   - deb(5):   https://manpages.debian.org/bullseye/dpkg-dev/deb.5.en.html
//!   - tar/USTAR: POSIX 1003.1 / IEEE Std 1003.1-2008
//!   - gzip:     RFC 1952

const std = @import("std");

const log = std.log.scoped(.deb);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Error set for .deb generation operations.
pub const DebError = error{
    WriteError,
    ReadError,
    InvalidConfig,
} || std.mem.Allocator.Error;

/// Configuration for generating a single .deb package.
pub const DebConfig = struct {
    /// Package name — lowercase, no spaces (e.g. "myapp").
    name: []const u8,
    /// Package version string (e.g. "1.0.0").
    version: []const u8,
    /// Debian architecture string (e.g. "amd64", "arm64").
    /// Use `debArch` to convert a Zig cross-compilation target arch.
    arch: []const u8,
    /// One-line package description (shown in `apt show`).
    description: []const u8 = "",
    /// Maintainer field — "Full Name <email@example.com>".
    maintainer: []const u8 = "Unknown <unknown@example.com>",
    /// SPDX license identifier written to the `License` control field.
    license: []const u8 = "unknown",
    /// Path to the compiled binary that will be installed.
    binary_path: []const u8,
    /// Where to write the generated `.deb` file.
    output_path: []const u8,
};

/// Convert a Zig cross-compilation target arch string to a Debian arch string.
///
/// Known mappings:
///   - `x86_64`  → `amd64`
///   - `aarch64` → `arm64`
///   - `armv7a`  → `armhf`
///   - `riscv64` → `riscv64`
///
/// Unrecognised arch values are returned unchanged.
pub fn debArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "amd64";
    if (std.mem.eql(u8, arch, "aarch64")) return "arm64";
    if (std.mem.eql(u8, arch, "armv7a")) return "armhf";
    if (std.mem.eql(u8, arch, "riscv64")) return "riscv64";
    return arch;
}

/// Generate a `.deb` package and write it to `cfg.output_path`.
///
/// The binary at `cfg.binary_path` is installed to `/usr/bin/<cfg.name>`.
/// Generates package metadata in the `control` file derived from `cfg`.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: DebConfig,
) DebError!void {
    if (cfg.name.len == 0) return error.InvalidConfig;
    if (cfg.version.len == 0) return error.InvalidConfig;
    if (cfg.arch.len == 0) return error.InvalidConfig;

    // Read the binary from disk.
    const binary_data = readFile(allocator, io, cfg.binary_path) catch |err| {
        log.err("failed to read binary {s}: {}", .{ cfg.binary_path, err });
        return error.ReadError;
    };
    defer allocator.free(binary_data);

    // Build the three ar members in memory.
    const control_gz = try buildControlTarGz(allocator, cfg, binary_data.len);
    defer allocator.free(control_gz);

    const data_gz = try buildDataTarGz(allocator, cfg, binary_data);
    defer allocator.free(data_gz);

    // Write the .deb (ar archive) to disk.
    const file = std.Io.Dir.cwd().createFile(io, cfg.output_path, .{ .truncate = true }) catch |err| {
        log.err("failed to create output file {s}: {}", .{ cfg.output_path, err });
        return error.WriteError;
    };
    defer file.close(io);

    var ar: std.ArrayListUnmanaged(u8) = .empty;
    defer ar.deinit(allocator);

    // ar magic.
    try ar.appendSlice(allocator, "!<arch>\n");

    // debian-binary member.
    try writeArEntry(allocator, &ar, "debian-binary", "2.0\n");
    // control.tar.gz member.
    try writeArEntry(allocator, &ar, "control.tar.gz", control_gz);
    // data.tar.gz member.
    try writeArEntry(allocator, &ar, "data.tar.gz", data_gz);

    file.writeStreamingAll(io, ar.items) catch |err| {
        log.err("failed to write .deb archive: {}", .{err});
        return error.WriteError;
    };
}

// ---------------------------------------------------------------------------
// Internal helpers — not exported
// ---------------------------------------------------------------------------

/// Read the entire contents of `path` into a freshly-allocated slice.
/// Caller owns the returned memory.
fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size = try file.length(io);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    var read_buf: [65536]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try reader.interface.readSliceShort(buf[offset..]);
        if (n == 0) break;
        offset += n;
    }
    return buf[0..offset];
}

/// Build the `control.tar.gz` member: a gzip-wrapped tar containing
/// the `./control` file derived from `cfg`.
fn buildControlTarGz(
    allocator: std.mem.Allocator,
    cfg: DebConfig,
    binary_size: usize,
) DebError![]u8 {
    // Installed-Size is in KiB, rounded up.
    const installed_kib = (binary_size + 1023) / 1024;

    const control_text = try std.fmt.allocPrint(
        allocator,
        "Package: {s}\n" ++
            "Version: {s}\n" ++
            "Architecture: {s}\n" ++
            "Maintainer: {s}\n" ++
            "Installed-Size: {d}\n" ++
            "License: {s}\n" ++
            "Description: {s}\n",
        .{
            cfg.name,
            cfg.version,
            cfg.arch,
            cfg.maintainer,
            installed_kib,
            cfg.license,
            cfg.description,
        },
    );
    defer allocator.free(control_text);

    // Build tar containing just the control file.
    var tar: std.ArrayListUnmanaged(u8) = .empty;
    defer tar.deinit(allocator);

    try writeTarEntry(allocator, &tar, "./control", control_text, 0o644, false);
    try writeTarFooter(allocator, &tar);

    return gzipWrap(allocator, tar.items);
}

/// Build the `data.tar.gz` member: a gzip-wrapped tar that installs the
/// binary to `./usr/bin/<name>`.
fn buildDataTarGz(
    allocator: std.mem.Allocator,
    cfg: DebConfig,
    binary_data: []const u8,
) DebError![]u8 {
    var tar: std.ArrayListUnmanaged(u8) = .empty;
    defer tar.deinit(allocator);

    // Directory entries required for dpkg to correctly register ownership.
    try writeTarEntry(allocator, &tar, "./", "", 0o755, true);
    try writeTarEntry(allocator, &tar, "./usr/", "", 0o755, true);
    try writeTarEntry(allocator, &tar, "./usr/bin/", "", 0o755, true);

    // The binary itself.
    const bin_path = try std.fmt.allocPrint(allocator, "./usr/bin/{s}", .{cfg.name});
    defer allocator.free(bin_path);
    try writeTarEntry(allocator, &tar, bin_path, binary_data, 0o755, false);

    try writeTarFooter(allocator, &tar);

    return gzipWrap(allocator, tar.items);
}

/// Write one USTAR tar entry (header + data, padded to 512-byte blocks).
///
/// `is_dir = true` writes a directory entry (type '5', zero-byte content).
fn writeTarEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    path: []const u8,
    content: []const u8,
    mode: u32,
    is_dir: bool,
) !void {
    var header: [512]u8 = .{0} ** 512;

    // Name field (bytes 0–99): up to 100 bytes, null-padded.
    const name_len = @min(path.len, 100);
    @memcpy(header[0..name_len], path[0..name_len]);

    // Mode field (bytes 100–107): 7 octal digits + NUL.
    _ = std.fmt.bufPrint(header[100..108], "{o:0>7}\x00", .{mode}) catch unreachable;

    // UID / GID fields (8 bytes each): "0000000\0".
    @memcpy(header[108..116], "0000000\x00");
    @memcpy(header[116..124], "0000000\x00");

    // Size field (bytes 124–135): 11 octal digits + NUL.
    const size: usize = if (is_dir) 0 else content.len;
    _ = std.fmt.bufPrint(header[124..136], "{o:0>11}\x00", .{size}) catch unreachable;

    // Mtime field (bytes 136–147): "0" for reproducible builds.
    @memcpy(header[136..148], "00000000000\x00");

    // Checksum placeholder (bytes 148–155): 8 spaces while computing.
    @memset(header[148..156], ' ');

    // Type flag (byte 156): '0' = regular, '5' = directory.
    header[156] = if (is_dir) '5' else '0';

    // USTAR magic + version (bytes 257–264).
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");

    // Compute checksum: sum of all header bytes, checksum field treated as spaces.
    var checksum: u32 = 0;
    for (header[0..148]) |b| checksum += b;
    checksum += 8 * ' '; // checksum field = 8 spaces
    for (header[156..]) |b| checksum += b;

    // Write checksum: 6 octal digits + NUL + space (POSIX format).
    _ = std.fmt.bufPrint(header[148..154], "{o:0>6}", .{checksum}) catch unreachable;
    header[154] = 0;
    header[155] = ' ';

    try buf.appendSlice(allocator, &header);

    if (!is_dir and content.len > 0) {
        try buf.appendSlice(allocator, content);
        // Pad to 512-byte boundary.
        const padding = (512 - (content.len % 512)) % 512;
        if (padding > 0) {
            const zeros: [512]u8 = .{0} ** 512;
            try buf.appendSlice(allocator, zeros[0..padding]);
        }
    }
}

/// Append the two 512-byte zero-block end-of-archive marker.
fn writeTarFooter(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
    const zeros: [1024]u8 = .{0} ** 1024;
    try buf.appendSlice(allocator, &zeros);
}

/// Wrap `data` in a gzip stream using deflate stored blocks (no compression).
/// Output is reproducible: mtime = 0, xfl = 0, OS = Unix (3).
fn gzipWrap(allocator: std.mem.Allocator, data: []const u8) DebError![]u8 {
    // Stored-block overhead: 5 bytes per block of up to 65535 bytes.
    const max_block = 65535;
    const n_blocks = if (data.len == 0) 1 else (data.len + max_block - 1) / max_block;
    const deflate_size = n_blocks * 5 + data.len;

    // Total: 10-byte header + deflate payload + 8-byte footer.
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 10 + deflate_size + 8);
    errdefer out.deinit(allocator);

    // gzip header (RFC 1952 §2.3).
    const header = [_]u8{
        0x1f, 0x8b, // magic
        0x08, // CM = deflate
        0x00, // FLG = no name/comment/extra
        0x00, 0x00, 0x00, 0x00, // MTIME = 0 (reproducible)
        0x00, // XFL = 0
        0x03, // OS = Unix
    };
    try out.appendSlice(allocator, &header);

    // Deflate stored blocks (BTYPE = 00).
    var remaining = data;
    while (true) {
        const block_size = @min(remaining.len, max_block);
        const is_final = block_size == remaining.len;

        // BFINAL (1 bit) | BTYPE=00 (2 bits) | padding (5 bits) = 1 byte.
        try out.append(allocator, if (is_final) 0x01 else 0x00);

        const len: u16 = @intCast(block_size);
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, len, .little);
        try out.appendSlice(allocator, &len_buf);
        std.mem.writeInt(u16, &len_buf, len ^ 0xFFFF, .little); // NLEN = ~LEN
        try out.appendSlice(allocator, &len_buf);

        try out.appendSlice(allocator, remaining[0..block_size]);

        if (is_final) break;
        remaining = remaining[block_size..];
    }

    // gzip footer: CRC32 of uncompressed data + size mod 2^32.
    var hasher = std.hash.Crc32.init();
    hasher.update(data);
    var footer: [8]u8 = undefined;
    std.mem.writeInt(u32, footer[0..4], hasher.final(), .little);
    std.mem.writeInt(u32, footer[4..8], @intCast(data.len & 0xFFFFFFFF), .little);
    try out.appendSlice(allocator, &footer);

    return out.toOwnedSlice(allocator);
}

/// Write one `ar` file entry to `buf`.
///
/// Header layout (60 bytes):
///   16 bytes — file identifier, space-padded
///   12 bytes — modification time (decimal), space-padded
///    6 bytes — owner UID (decimal), space-padded
///    6 bytes — owner GID (decimal), space-padded
///    8 bytes — file mode (octal), space-padded
///   10 bytes — file size (decimal), space-padded
///    2 bytes — file magic "`\n"
///
/// If the data length is odd, a `\n` padding byte is appended.
fn writeArEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    data: []const u8,
) !void {
    var header: [60]u8 = undefined;
    @memset(&header, ' ');

    // File identifier: up to 16 chars, space-padded.
    const name_len = @min(name.len, 16);
    @memcpy(header[0..name_len], name[0..name_len]);

    // Modification time: "0" (reproducible).
    header[16] = '0';

    // UID: "0".
    header[28] = '0';

    // GID: "0".
    header[34] = '0';

    // File mode: "100644" (octal rw-r--r--).
    @memcpy(header[40..46], "100644");

    // File size (decimal, right-justified in 10-char field, space-padded).
    const size_str = std.fmt.bufPrint(header[48..58], "{d}", .{data.len}) catch unreachable;
    // Right-justify: shift digits to the right, fill left with spaces.
    if (size_str.len < 10) {
        const shift = 10 - size_str.len;
        std.mem.copyBackwards(u8, header[48 + shift .. 58], header[48 .. 48 + size_str.len]);
        @memset(header[48..][0..shift], ' ');
    }

    // Magic.
    header[58] = '`';
    header[59] = '\n';

    try buf.appendSlice(allocator, &header);
    try buf.appendSlice(allocator, data);

    // Pad to even byte boundary.
    if (data.len % 2 != 0) {
        try buf.append(allocator, '\n');
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "debArch maps known architectures" {
    try std.testing.expectEqualStrings("amd64", debArch("x86_64"));
    try std.testing.expectEqualStrings("arm64", debArch("aarch64"));
    try std.testing.expectEqualStrings("armhf", debArch("armv7a"));
    try std.testing.expectEqualStrings("riscv64", debArch("riscv64"));
}

test "debArch passes through unknown architectures unchanged" {
    try std.testing.expectEqualStrings("mips64", debArch("mips64"));
}

test "gzipWrap produces valid gzip magic" {
    const allocator = std.testing.allocator;
    const gz = try gzipWrap(allocator, "hello");
    defer allocator.free(gz);
    // Check magic bytes and method.
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);
    try std.testing.expectEqual(@as(u8, 0x08), gz[2]); // CM = deflate
}

test "gzipWrap of empty data is valid" {
    const allocator = std.testing.allocator;
    const gz = try gzipWrap(allocator, "");
    defer allocator.free(gz);
    // 10-byte header + 5-byte stored block + 8-byte footer = 23 bytes minimum.
    try std.testing.expect(gz.len >= 23);
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
}

test "writeArEntry produces correct header structure" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeArEntry(allocator, &buf, "debian-binary", "2.0\n");

    // Total: 60-byte header + 4 bytes data (even, no padding).
    try std.testing.expectEqual(@as(usize, 64), buf.items.len);

    // File identifier field (bytes 0–15): "debian-binary   " (space-padded).
    try std.testing.expectEqualStrings("debian-binary   ", buf.items[0..16]);

    // Magic bytes (bytes 58–59).
    try std.testing.expectEqual(@as(u8, '`'), buf.items[58]);
    try std.testing.expectEqual(@as(u8, '\n'), buf.items[59]);

    // Data follows header.
    try std.testing.expectEqualStrings("2.0\n", buf.items[60..64]);
}

test "writeArEntry pads odd-length data" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    // "abc" is 3 bytes (odd) — should be padded to 4.
    try writeArEntry(allocator, &buf, "test", "abc");
    try std.testing.expectEqual(@as(usize, 60 + 4), buf.items.len);
    try std.testing.expectEqual(@as(u8, '\n'), buf.items[63]);
}

test "buildControlTarGz contains package name in control file" {
    const allocator = std.testing.allocator;
    const cfg = DebConfig{
        .name = "myapp",
        .version = "1.2.3",
        .arch = "amd64",
        .description = "A test application",
        .maintainer = "Tester <test@example.com>",
        .license = "MIT",
        .binary_path = "", // not used here
        .output_path = "",
    };
    const gz = try buildControlTarGz(allocator, cfg, 1024 * 42);
    defer allocator.free(gz);

    // Must be a valid gzip stream.
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);

    // Decompress and look for key strings in the tar payload.
    var input: std.Io.Reader = .fixed(gz);
    var decomp_buf: [65536]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .gzip, &decomp_buf);
    const tar_data = try decomp.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(tar_data);

    // The tar payload should contain the control file text.
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "Package: myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "Version: 1.2.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "Architecture: amd64") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "Maintainer: Tester <test@example.com>") != null);
    // Installed-Size for 42 KiB.
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "Installed-Size: 42") != null);
}

test "generate creates a structurally valid .deb" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    // Create a temporary directory and chdir into it so cwd-relative paths work.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    // Write a fake "binary" (just some bytes).
    const fake_binary = "ELF fake binary content for testing";
    try tmp.dir.writeFile(io, .{ .sub_path = "fakebinary", .data = fake_binary });

    const cfg = DebConfig{
        .name = "testpkg",
        .version = "0.1.0",
        .arch = "amd64",
        .description = "A test package",
        .maintainer = "CI <ci@example.com>",
        .license = "MIT",
        .binary_path = "fakebinary",
        .output_path = "testpkg_0.1.0_amd64.deb",
    };

    try generate(allocator, io, cfg);

    // Read back the .deb and verify the ar magic and structure.
    const deb_data = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, cfg.output_path, .{});
        defer f.close(io);
        var rbuf: [65536]u8 = undefined;
        var r = f.reader(io, &rbuf);
        break :blk try r.interface.allocRemaining(allocator, .unlimited);
    };
    defer allocator.free(deb_data);

    // ar magic (first 8 bytes).
    try std.testing.expectEqualStrings("!<arch>\n", deb_data[0..8]);

    // First ar member name should be "debian-binary".
    try std.testing.expectEqualStrings("debian-binary   ", deb_data[8..24]);

    // Find "2.0\n" (the debian-binary content) after the 60-byte header.
    try std.testing.expectEqualStrings("2.0\n", deb_data[68..72]);

    // Verify control.tar.gz and data.tar.gz member names appear in the archive.
    try std.testing.expect(std.mem.indexOf(u8, deb_data, "control.tar.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, deb_data, "data.tar.gz") != null);
}

test "DebConfig InvalidConfig on empty name" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const cfg = DebConfig{
        .name = "",
        .version = "1.0.0",
        .arch = "amd64",
        .binary_path = "/dev/null",
        .output_path = "/dev/null",
    };
    try std.testing.expectError(error.InvalidConfig, generate(allocator, io, cfg));
}
