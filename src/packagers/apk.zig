//! `.apk` package generator — produces a valid Alpine Linux package (APK v2)
//! entirely in Zig, without requiring `abuild` or any other external tool.
//!
//! Format references:
//!   - APK v2 spec:  https://wiki.alpinelinux.org/wiki/Apk_spec
//!   - PKGINFO:      https://wiki.alpinelinux.org/wiki/Apk_spec#PKGINFO_Format
//!   - tar/USTAR:    POSIX 1003.1 / IEEE Std 1003.1-2008
//!   - gzip:         RFC 1952
//!   - PAX headers:  POSIX.1-2001 (IEEE Std 1003.1-2001 §10.1.1)
//!
//! APK v2 file layout (three concatenated gzip streams):
//!   Stream 1 — Signature tar segment  (optional; omit for --allow-untrusted)
//!   Stream 2 — Control tar segment    (contains .PKGINFO; no end-of-tar blocks)
//!   Stream 3 — Data tarball           (contains installed files; full tar with EOA)
//!
//! When the signature stream is absent the package can still be installed with
//! `apk add --allow-untrusted`.  This generator produces stream 2 + stream 3
//! only, which is sufficient for local installation and CI testing without
//! requiring the private signing key infrastructure.
//!
//! PAX per-file checksum headers (required by apk-tools):
//!   Each regular file in the data tarball must be preceded by a PAX extended
//!   header entry (type 'x') containing the key APK-TOOLS.checksum.SHA1 with
//!   the hex-encoded SHA1 digest of the file content.  Without these
//!   headers apk-tools installs the package but does not register any files in
//!   its installed database, so nothing is extractable.  abuild-tar adds them
//!   via `--hash`; we produce them inline.

const std = @import("std");

const log = std.log.scoped(.apk);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Error set for .apk generation operations.
pub const ApkError = error{
    WriteError,
    ReadError,
    InvalidConfig,
} || std.mem.Allocator.Error;

/// Configuration for generating a single .apk package.
pub const ApkConfig = struct {
    /// Package name (e.g. "myapp").
    name: []const u8,
    /// Package version string including release (e.g. "1.0.0-r0").
    version: []const u8,
    /// APK architecture string (e.g. "x86_64", "aarch64").
    /// Use `apkArch` to convert from a Zig cross-compilation target arch.
    arch: []const u8,
    /// One-line package description (pkgdesc field).
    description: []const u8 = "",
    /// SPDX license identifier.
    license: []const u8 = "unknown",
    /// Maintainer field — "Full Name <email@example.com>".
    maintainer: []const u8 = "Unknown <unknown@example.com>",
    /// URL for the project's home page.
    url: []const u8 = "",
    /// Path to the compiled binary that will be installed.
    binary_path: []const u8,
    /// Where to write the generated `.apk` file.
    output_path: []const u8,
};

/// Convert a Zig cross-compilation target arch string to an APK arch string.
///
/// Known mappings:
///   - `x86_64`  → `x86_64`
///   - `aarch64` → `aarch64`
///   - `armv7a`  → `armv7`
///   - `riscv64` → `riscv64`
///
/// Unrecognised arch values are returned unchanged.
pub fn apkArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "x86_64";
    if (std.mem.eql(u8, arch, "aarch64")) return "aarch64";
    if (std.mem.eql(u8, arch, "armv7a")) return "armv7";
    if (std.mem.eql(u8, arch, "riscv64")) return "riscv64";
    return arch;
}

/// Generate a `.apk` package and write it to `cfg.output_path`.
///
/// The binary at `cfg.binary_path` is installed to `/usr/bin/<cfg.name>`.
/// All package metadata is derived from `cfg`.
///
/// The produced file contains only the control and data gzip streams (no
/// signature stream).  It can be installed with:
///   `apk add --allow-untrusted <file>.apk`
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: ApkConfig,
) ApkError!void {
    if (cfg.name.len == 0) return error.InvalidConfig;
    if (cfg.version.len == 0) return error.InvalidConfig;
    if (cfg.arch.len == 0) return error.InvalidConfig;

    // Read the binary from disk.
    const binary_data = readFile(allocator, io, cfg.binary_path) catch |err| {
        log.err("failed to read binary {s}: {}", .{ cfg.binary_path, err });
        return error.ReadError;
    };
    defer allocator.free(binary_data);

    // Build data tarball first so we know its SHA-256 hash for PKGINFO.
    const data_gz = try buildDataTarGz(allocator, cfg, binary_data);
    defer allocator.free(data_gz);

    // SHA-256 of the data tarball (datahash field in PKGINFO).
    var data_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data_gz, &data_hash, .{});
    const data_hash_hex = std.fmt.bytesToHex(data_hash, .lower);

    // Build control tar segment.
    const control_gz = try buildControlTarGz(allocator, cfg, binary_data.len, &data_hash_hex);
    defer allocator.free(control_gz);

    // Write output: control stream ++ data stream.
    const file = std.Io.Dir.cwd().createFile(io, cfg.output_path, .{ .truncate = true }) catch |err| {
        log.err("failed to create output file {s}: {}", .{ cfg.output_path, err });
        return error.WriteError;
    };
    defer file.close(io);

    file.writeStreamingAll(io, control_gz) catch return error.WriteError;
    file.writeStreamingAll(io, data_gz) catch return error.WriteError;
}

// ---------------------------------------------------------------------------
// Control tar segment
// ---------------------------------------------------------------------------

/// Build the control gzip stream: a tar *segment* (no end-of-archive blocks)
/// containing the `.PKGINFO` metadata file.
fn buildControlTarGz(
    allocator: std.mem.Allocator,
    cfg: ApkConfig,
    binary_size: usize,
    data_hash_hex: *const [64]u8,
) ApkError![]u8 {
    // Installed size in bytes (apk uses exact byte count, not KiB).
    const pkginfo = try std.fmt.allocPrint(
        allocator,
        "# Generated by takeoff\n" ++
            "pkgname = {s}\n" ++
            "pkgver = {s}\n" ++
            "arch = {s}\n" ++
            "size = {d}\n" ++
            "pkgdesc = {s}\n" ++
            "url = {s}\n" ++
            "builddate = 0\n" ++
            "packager = {s}\n" ++
            "maintainer = {s}\n" ++
            "license = {s}\n" ++
            "datahash = {s}\n",
        .{
            cfg.name,
            cfg.version,
            cfg.arch,
            binary_size,
            cfg.description,
            cfg.url,
            cfg.maintainer,
            cfg.maintainer,
            cfg.license,
            data_hash_hex,
        },
    );
    defer allocator.free(pkginfo);

    // Build tar segment: single entry for .PKGINFO, no end-of-archive blocks.
    var tar: std.ArrayListUnmanaged(u8) = .empty;
    defer tar.deinit(allocator);

    try writeTarEntry(allocator, &tar, ".PKGINFO", pkginfo, 0o644, false);
    // Deliberately omit the two 512-byte zero-block end-of-archive marker
    // so this becomes a valid tar *segment* (as required by APK v2 spec).

    return gzipWrap(allocator, tar.items);
}

// ---------------------------------------------------------------------------
// Data tarball
// ---------------------------------------------------------------------------

/// Build the data gzip tarball: a complete gzipped tar archive that installs
/// the binary to `usr/bin/<name>`.
///
/// Each regular file entry is preceded by a PAX extended header (type 'x')
/// that carries the APK-TOOLS.checksum.SHA1 key.  apk-tools requires these
/// headers to record file checksums in the installed database; without them
/// `apk add` succeeds but no files are registered or extracted.
fn buildDataTarGz(
    allocator: std.mem.Allocator,
    cfg: ApkConfig,
    binary_data: []const u8,
) ApkError![]u8 {
    var tar: std.ArrayListUnmanaged(u8) = .empty;
    defer tar.deinit(allocator);

    // Directory entries (no PAX header needed for directories).
    try writeTarEntry(allocator, &tar, "", "", 0o755, true);
    try writeTarEntry(allocator, &tar, "usr/", "", 0o755, true);
    try writeTarEntry(allocator, &tar, "usr/bin/", "", 0o755, true);

    // The binary: PAX header first, then the regular USTAR entry.
    const bin_path = try std.fmt.allocPrint(allocator, "usr/bin/{s}", .{cfg.name});
    defer allocator.free(bin_path);
    try writePaxSha1Header(allocator, &tar, bin_path, binary_data);
    try writeTarEntry(allocator, &tar, bin_path, binary_data, 0o755, false);

    // End-of-archive: two 512-byte zero blocks (full tarball, not segment).
    try writeTarFooter(allocator, &tar);

    return gzipWrap(allocator, tar.items);
}

// ---------------------------------------------------------------------------
// USTAR tar helpers (shared with deb.zig logic, kept self-contained here)
// ---------------------------------------------------------------------------

/// Write one USTAR tar entry (header + data, padded to 512-byte blocks).
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
    var checksum_val: u32 = 0;
    for (header[0..148]) |b| checksum_val += b;
    checksum_val += 8 * ' '; // checksum field = 8 spaces
    for (header[156..]) |b| checksum_val += b;

    // Write checksum: 6 octal digits + NUL + space (POSIX format).
    _ = std.fmt.bufPrint(header[148..154], "{o:0>6}", .{checksum_val}) catch unreachable;
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

/// Append the two 512-byte zero-block end-of-archive marker (full tarball).
fn writeTarFooter(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
    const zeros: [1024]u8 = .{0} ** 1024;
    try buf.appendSlice(allocator, &zeros);
}

// ---------------------------------------------------------------------------
// PAX extended header helpers
// ---------------------------------------------------------------------------

/// Write a PAX extended header entry (type 'x') for `file_path` containing
/// the `APK-TOOLS.checksum.SHA1` key with the hex-encoded SHA1 digest of
/// `file_content`.
///
/// This is required by apk-tools: without it the package installs but apk
/// does not register any files in the installed database.
///
/// PAX record format (POSIX.1-2001 §10.1.1):
///   Each keyword-value pair is encoded as:
///     "<decimal-length> <key>=<value>\n"
///   where <decimal-length> is the total byte count of the entire record
///   including the length field itself and the trailing newline.  The length
///   field must be computed iteratively because it is part of its own value.
fn writePaxSha1Header(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    file_path: []const u8,
    file_content: []const u8,
) !void {
    // Compute SHA1 of the file content.
    var sha1_digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(file_content, &sha1_digest, .{});

    // Encode SHA1 as lowercase hex (apk-tools parses this field as hexdump).
    const sha1_hex = std.fmt.bytesToHex(sha1_digest, .lower);

    // Build the PAX record: "<len> APK-TOOLS.checksum.SHA1=<b64>\n"
    // The length field length itself depends on the total, so compute it.
    const key = "APK-TOOLS.checksum.SHA1";
    // Minimum prefix candidate: "NN <key>=<b64>\n" — we grow until stable.
    const pax_record = try buildPaxRecord(allocator, key, &sha1_hex);
    defer allocator.free(pax_record);

    // The PAX header entry name is typically "PaxHeaders/<filename>" but
    // apk-tools only cares about the content, not the header name.
    // Use "PaxHeaders/<path>" for the synthetic metadata entry name.
    const pax_name = try std.fmt.allocPrint(allocator, "PaxHeaders/{s}", .{file_path});
    defer allocator.free(pax_name);

    try writePaxTarEntry(allocator, buf, pax_name, pax_record);
}

/// Build a single PAX keyword=value record with the self-referential length
/// field.  Returns an allocated slice; caller must free.
///
/// Algorithm: start with an estimate of the length digit count and iterate
/// until the length is self-consistent (at most 2 iterations in practice).
fn buildPaxRecord(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) ![]u8 {
    // " <key>=<value>\n" fixed part (without the length digits).
    const fixed_len = 1 + key.len + 1 + value.len + 1; // space + key + '=' + value + '\n'

    // Iterate to find the stable digit count for the length field.
    var digit_count: usize = 1;
    while (true) {
        const total = digit_count + fixed_len;
        // How many digits does `total` actually need?
        const needed = countDigits(total);
        if (needed == digit_count) break;
        digit_count = needed;
    }
    const total_len = digit_count + fixed_len;

    const record = try allocator.alloc(u8, total_len);
    errdefer allocator.free(record);

    var pos: usize = 0;
    // Length digits.
    const digits_slice = std.fmt.bufPrint(record[pos..], "{d}", .{total_len}) catch unreachable;
    pos += digits_slice.len;
    // Space.
    record[pos] = ' ';
    pos += 1;
    // Key.
    @memcpy(record[pos..][0..key.len], key);
    pos += key.len;
    // '='.
    record[pos] = '=';
    pos += 1;
    // Value.
    @memcpy(record[pos..][0..value.len], value);
    pos += value.len;
    // Newline.
    record[pos] = '\n';
    pos += 1;

    std.debug.assert(pos == total_len);
    return record;
}

/// Count decimal digits needed to represent `n` (n ≥ 1).
fn countDigits(n: usize) usize {
    var count: usize = 0;
    var v = n;
    while (v > 0) : (v /= 10) count += 1;
    return if (count == 0) 1 else count;
}

/// Write a PAX extended header tar entry (type 'x') to `buf`.
///
/// This is a USTAR header with type flag 'x', followed by the PAX record
/// content, padded to a 512-byte boundary.
fn writePaxTarEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    pax_content: []const u8,
) !void {
    var header: [512]u8 = .{0} ** 512;

    // Name field (bytes 0–99).
    const name_len = @min(name.len, 100);
    @memcpy(header[0..name_len], name[0..name_len]);

    // Mode field: "0000644\0".
    _ = std.fmt.bufPrint(header[100..108], "{o:0>7}\x00", .{@as(u32, 0o644)}) catch unreachable;

    // UID / GID.
    @memcpy(header[108..116], "0000000\x00");
    @memcpy(header[116..124], "0000000\x00");

    // Size: the PAX record content length.
    _ = std.fmt.bufPrint(header[124..136], "{o:0>11}\x00", .{pax_content.len}) catch unreachable;

    // Mtime: 0 (reproducible).
    @memcpy(header[136..148], "00000000000\x00");

    // Checksum placeholder.
    @memset(header[148..156], ' ');

    // Type flag: 'x' = PAX extended header.
    header[156] = 'x';

    // USTAR magic + version.
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");

    // Compute checksum.
    var checksum_val: u32 = 0;
    for (header[0..148]) |b| checksum_val += b;
    checksum_val += 8 * ' ';
    for (header[156..]) |b| checksum_val += b;

    _ = std.fmt.bufPrint(header[148..154], "{o:0>6}", .{checksum_val}) catch unreachable;
    header[154] = 0;
    header[155] = ' ';

    try buf.appendSlice(allocator, &header);
    try buf.appendSlice(allocator, pax_content);

    // Pad to 512-byte boundary.
    const padding = (512 - (pax_content.len % 512)) % 512;
    if (padding > 0) {
        const zeros: [512]u8 = .{0} ** 512;
        try buf.appendSlice(allocator, zeros[0..padding]);
    }
}

// ---------------------------------------------------------------------------
// gzip wrapper (reproducible)
// ---------------------------------------------------------------------------

/// Wrap `data` in a gzip stream using deflate stored blocks (no compression).
/// Output is reproducible: mtime = 0, xfl = 0, OS = Unix (3).
fn gzipWrap(allocator: std.mem.Allocator, data: []const u8) ApkError![]u8 {
    const max_block = 65535;
    const n_blocks = if (data.len == 0) 1 else (data.len + max_block - 1) / max_block;
    const deflate_size = n_blocks * 5 + data.len;

    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 10 + deflate_size + 8);
    errdefer out.deinit(allocator);

    // gzip header (RFC 1952 §2.3).
    const gz_header = [_]u8{
        0x1f, 0x8b, // magic
        0x08, // CM = deflate
        0x00, // FLG = no name/comment/extra
        0x00, 0x00, 0x00, 0x00, // MTIME = 0 (reproducible)
        0x00, // XFL = 0
        0x03, // OS = Unix
    };
    try out.appendSlice(allocator, &gz_header);

    // Deflate stored blocks (BTYPE = 00).
    var remaining = data;
    while (true) {
        const block_size = @min(remaining.len, max_block);
        const is_final = block_size == remaining.len;

        try out.append(allocator, if (is_final) 0x01 else 0x00);

        const len: u16 = @intCast(block_size);
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, len, .little);
        try out.appendSlice(allocator, &len_buf);
        std.mem.writeInt(u16, &len_buf, len ^ 0xFFFF, .little);
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

// ---------------------------------------------------------------------------
// Internal I/O helper
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "apkArch maps known architectures" {
    try std.testing.expectEqualStrings("x86_64", apkArch("x86_64"));
    try std.testing.expectEqualStrings("aarch64", apkArch("aarch64"));
    try std.testing.expectEqualStrings("armv7", apkArch("armv7a"));
    try std.testing.expectEqualStrings("riscv64", apkArch("riscv64"));
}

test "apkArch passes through unknown architectures unchanged" {
    try std.testing.expectEqualStrings("mips64", apkArch("mips64"));
}

test "gzipWrap produces valid gzip magic" {
    const allocator = std.testing.allocator;
    const gz = try gzipWrap(allocator, "hello");
    defer allocator.free(gz);
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);
    try std.testing.expectEqual(@as(u8, 0x08), gz[2]);
}

test "gzipWrap mtime is zero (reproducible)" {
    const allocator = std.testing.allocator;
    const gz = try gzipWrap(allocator, "data");
    defer allocator.free(gz);
    // Bytes 4–7 = MTIME, must all be 0.
    try std.testing.expectEqual(@as(u8, 0), gz[4]);
    try std.testing.expectEqual(@as(u8, 0), gz[5]);
    try std.testing.expectEqual(@as(u8, 0), gz[6]);
    try std.testing.expectEqual(@as(u8, 0), gz[7]);
}

test "writeTarEntry produces correct magic and padded length" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeTarEntry(allocator, &buf, ".PKGINFO", "pkgname = test\n", 0o644, false);

    // First 7 bytes of path field = ".PKGINFO".
    try std.testing.expectEqualStrings(".PKGINFO", buf.items[0..8]);

    // Total length must be a multiple of 512.
    try std.testing.expectEqual(@as(usize, 0), buf.items.len % 512);
}

test "buildControlTarGz contains PKGINFO with package name" {
    const allocator = std.testing.allocator;
    const cfg = ApkConfig{
        .name = "myapp",
        .version = "1.2.3-r0",
        .arch = "x86_64",
        .description = "A test application",
        .license = "MIT",
        .maintainer = "Tester <test@example.com>",
        .url = "https://example.com",
        .binary_path = "",
        .output_path = "",
    };
    const fake_hash = [_]u8{'0'} ** 64;
    const gz = try buildControlTarGz(allocator, cfg, 4096, &fake_hash);
    defer allocator.free(gz);

    // Must start with gzip magic.
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);

    // Decompress and look for PKGINFO content.
    var input: std.Io.Reader = .fixed(gz);
    var decomp_buf: [65536]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .gzip, &decomp_buf);
    const tar_data = try decomp.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(tar_data);

    try std.testing.expect(std.mem.indexOf(u8, tar_data, "pkgname = myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "pkgver = 1.2.3-r0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "arch = x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "license = MIT") != null);
}

test "buildDataTarGz contains binary at correct path" {
    const allocator = std.testing.allocator;
    const cfg = ApkConfig{
        .name = "myprog",
        .version = "1.0.0-r0",
        .arch = "x86_64",
        .binary_path = "",
        .output_path = "",
    };
    const fake_binary = "ELF fake binary";
    const gz = try buildDataTarGz(allocator, cfg, fake_binary);
    defer allocator.free(gz);

    // Must start with gzip magic.
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);

    // Decompress and look for the binary path in the tar.
    var input: std.Io.Reader = .fixed(gz);
    var decomp_buf: [65536]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .gzip, &decomp_buf);
    const tar_data = try decomp.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(tar_data);

    try std.testing.expect(std.mem.indexOf(u8, tar_data, "usr/bin/myprog") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "ELF fake binary") != null);
}

test "generate creates a structurally valid .apk" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var original_cwd = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer original_cwd.close(io);
    try std.process.setCurrentDir(io, tmp.dir);
    defer std.process.setCurrentDir(io, original_cwd) catch {};

    const fake_binary = "ELF fake binary content for testing";
    try tmp.dir.writeFile(io, .{ .sub_path = "fakebinary", .data = fake_binary });

    const cfg = ApkConfig{
        .name = "testpkg",
        .version = "0.1.0-r0",
        .arch = "x86_64",
        .description = "A test package",
        .license = "MIT",
        .maintainer = "CI <ci@example.com>",
        .url = "https://example.com",
        .binary_path = "fakebinary",
        .output_path = "testpkg-0.1.0-r0.apk",
    };

    try generate(allocator, io, cfg);

    // Read back the .apk and validate.
    const apk_data = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, cfg.output_path, .{});
        defer f.close(io);
        var rbuf: [65536 * 4]u8 = undefined;
        var r = f.reader(io, &rbuf);
        break :blk try r.interface.allocRemaining(allocator, .unlimited);
    };
    defer allocator.free(apk_data);

    // File must start with gzip magic (control stream).
    try std.testing.expectEqual(@as(u8, 0x1f), apk_data[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), apk_data[1]);

    // There must be at least two gzip streams (control + data).
    // The second gzip stream starts after the first: find second 1F 8B marker.
    const second_gz = std.mem.indexOf(u8, apk_data[2..], &[_]u8{ 0x1f, 0x8b });
    try std.testing.expect(second_gz != null);

    // The full file must contain .PKGINFO and the binary path.
    try std.testing.expect(std.mem.indexOf(u8, apk_data, ".PKGINFO") != null);
    try std.testing.expect(std.mem.indexOf(u8, apk_data, "usr/bin/testpkg") != null);
}

test "ApkConfig InvalidConfig on empty name" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const cfg = ApkConfig{
        .name = "",
        .version = "1.0.0-r0",
        .arch = "x86_64",
        .binary_path = "/dev/null",
        .output_path = "/dev/null",
    };
    try std.testing.expectError(error.InvalidConfig, generate(allocator, io, cfg));
}

test "countDigits returns correct digit counts" {
    try std.testing.expectEqual(@as(usize, 1), countDigits(1));
    try std.testing.expectEqual(@as(usize, 1), countDigits(9));
    try std.testing.expectEqual(@as(usize, 2), countDigits(10));
    try std.testing.expectEqual(@as(usize, 2), countDigits(99));
    try std.testing.expectEqual(@as(usize, 3), countDigits(100));
    try std.testing.expectEqual(@as(usize, 3), countDigits(999));
}

test "buildPaxRecord produces self-consistent length field" {
    const allocator = std.testing.allocator;
    const key = "APK-TOOLS.checksum.SHA1";
    const value = "abc123==";

    const record = try buildPaxRecord(allocator, key, value);
    defer allocator.free(record);

    // Record must end with '\n'.
    try std.testing.expectEqual('\n', record[record.len - 1]);

    // Parse the leading decimal length and verify it matches record.len.
    var end: usize = 0;
    while (end < record.len and record[end] != ' ') end += 1;
    const stated_len = try std.fmt.parseInt(usize, record[0..end], 10);
    try std.testing.expectEqual(record.len, stated_len);

    // Record must contain "key=value".
    const expected_kv = key ++ "=" ++ value;
    try std.testing.expect(std.mem.indexOf(u8, record, expected_kv) != null);
}

test "buildPaxRecord handles length field whose digit count changes total length" {
    // Use a key+value long enough that the total crosses a digit boundary.
    // 10-char key, 80-char value: total is likely 2 or 3 digits.
    const allocator = std.testing.allocator;
    const key = "test.key10";
    const value = "A" ** 80;

    const record = try buildPaxRecord(allocator, key, value);
    defer allocator.free(record);

    // Verify self-consistency.
    var end: usize = 0;
    while (end < record.len and record[end] != ' ') end += 1;
    const stated_len = try std.fmt.parseInt(usize, record[0..end], 10);
    try std.testing.expectEqual(record.len, stated_len);
}

test "writePaxSha1Header writes a type-x tar entry with SHA1 checksum" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const file_path = "usr/bin/hello";
    const file_content = "ELF binary data";

    try writePaxSha1Header(allocator, &buf, file_path, file_content);

    // Must be a multiple of 512 bytes.
    try std.testing.expectEqual(@as(usize, 0), buf.items.len % 512);

    // Type flag at byte 156 must be 'x' (PAX extended header).
    try std.testing.expectEqual(@as(u8, 'x'), buf.items[156]);

    // USTAR magic at bytes 257–262.
    try std.testing.expectEqualStrings("ustar", buf.items[257..262]);

    // The PAX content (bytes 512..) must contain the SHA1 key.
    try std.testing.expect(std.mem.indexOf(u8, buf.items[512..], "APK-TOOLS.checksum.SHA1=") != null);
}

test "writePaxSha1Header SHA1 value is correct hex of content SHA1" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const content = "hello";
    try writePaxSha1Header(allocator, &buf, "usr/bin/hello", content);

    // Compute expected SHA1 independently.
    var expected_digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(content, &expected_digest, .{});
    const expected_hex = std.fmt.bytesToHex(expected_digest, .lower);

    // The PAX record in buf (after the 512-byte header) should contain it.
    const pax_content = buf.items[512..];
    try std.testing.expect(std.mem.indexOf(u8, pax_content, &expected_hex) != null);
}

test "buildDataTarGz includes PAX entry before binary entry" {
    const allocator = std.testing.allocator;
    const cfg = ApkConfig{
        .name = "myprog",
        .version = "1.0.0-r0",
        .arch = "x86_64",
        .binary_path = "",
        .output_path = "",
    };
    const fake_binary = "ELF fake binary";
    const gz = try buildDataTarGz(allocator, cfg, fake_binary);
    defer allocator.free(gz);

    // Decompress and look for PAX key in the tar.
    var input: std.Io.Reader = .fixed(gz);
    var decomp_buf: [65536]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .gzip, &decomp_buf);
    const tar_data = try decomp.reader.allocRemaining(allocator, .unlimited);
    defer allocator.free(tar_data);

    // The data tarball must contain the PAX SHA1 key.
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "APK-TOOLS.checksum.SHA1=") != null);

    // A 'x' type-flag byte must appear (at byte 156 of the PAX header block).
    // In the decompressed tar the PAX block is immediately after the 3 directory entries.
    // 3 dirs × 512 bytes each = 1536 bytes in.
    try std.testing.expectEqual(@as(u8, 'x'), tar_data[1536 + 156]);

    // The binary entry follows the PAX entry (at offset 1536 + 512 + padding).
    // Its type flag should be '0' (regular file).
    // PAX content size = len(pax_record) padded to 512; pax entry = 512+512=1024 typical.
    // Rather than hard-code the offset, just verify the path appears.
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "usr/bin/myprog") != null);
    try std.testing.expect(std.mem.indexOf(u8, tar_data, "ELF fake binary") != null);
}
