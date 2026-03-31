//! `.rpm` package generator — produces a valid RPM v3/v4 binary package
//! entirely in Zig, without requiring `rpmbuild` or any other external tool.
//!
//! Format references:
//!   - RPM v4 file format: https://rpm-software-management.github.io/rpm/manual/format.html
//!   - RPM header format:  https://rpm-software-management.github.io/rpm/manual/hdr_format.html
//!   - RPM tags:           https://rpm-software-management.github.io/rpm/manual/tags.html
//!   - cpio SVR4 (newc):   https://people.freebsd.org/~kientzle/libarchive/man/cpio.5.txt
//!   - gzip:               RFC 1952
//!
//! RPM file layout:
//!   Lead (96 bytes)
//!   Signature (header-format; padded to 8-byte boundary after the intro)
//!   Header (header-format; no padding requirement)
//!   Payload (cpio SVR4 newc archive, gzip-compressed)

const std = @import("std");

const log = std.log.scoped(.rpm);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Error set for .rpm generation operations.
pub const RpmError = error{
    WriteError,
    ReadError,
    InvalidConfig,
} || std.mem.Allocator.Error;

/// Configuration for generating a single .rpm package.
pub const RpmConfig = struct {
    /// Package name (e.g. "myapp").
    name: []const u8,
    /// Package version string (e.g. "1.0.0").
    version: []const u8,
    /// RPM release string (e.g. "1").
    release: []const u8 = "1",
    /// RPM architecture string (e.g. "x86_64", "aarch64").
    /// Use `rpmArch` to convert from a Zig cross-compilation target arch.
    arch: []const u8,
    /// One-line package summary (shown in `rpm -qi`).
    summary: []const u8 = "",
    /// Multi-line description (shown in `rpm -qi`).
    description: []const u8 = "",
    /// SPDX license identifier.
    license: []const u8 = "unknown",
    /// Packager field — "Full Name <email@example.com>".
    packager: []const u8 = "Unknown <unknown@example.com>",
    /// URL for the project's home page.
    url: []const u8 = "",
    /// Path to the compiled binary that will be installed.
    binary_path: []const u8,
    /// Where to write the generated `.rpm` file.
    output_path: []const u8,
};

/// Convert a Zig cross-compilation target arch string to an RPM arch string.
///
/// Known mappings:
///   - `x86_64`  → `x86_64`
///   - `aarch64` → `aarch64`
///   - `armv7a`  → `armv7hl`
///   - `riscv64` → `riscv64`
///
/// Unrecognised arch values are returned unchanged.
pub fn rpmArch(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "x86_64")) return "x86_64";
    if (std.mem.eql(u8, arch, "aarch64")) return "aarch64";
    if (std.mem.eql(u8, arch, "armv7a")) return "armv7hl";
    if (std.mem.eql(u8, arch, "riscv64")) return "riscv64";
    return arch;
}

/// Generate a `.rpm` package and write it to `cfg.output_path`.
///
/// The binary at `cfg.binary_path` is installed to `/usr/bin/<cfg.name>`.
/// All package metadata is derived from `cfg`.
pub fn generate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: RpmConfig,
) RpmError!void {
    if (cfg.name.len == 0) return error.InvalidConfig;
    if (cfg.version.len == 0) return error.InvalidConfig;
    if (cfg.arch.len == 0) return error.InvalidConfig;

    // Read the binary from disk.
    const binary_data = readFile(allocator, io, cfg.binary_path) catch |err| {
        log.err("failed to read binary {s}: {}", .{ cfg.binary_path, err });
        return error.ReadError;
    };
    defer allocator.free(binary_data);

    // Build payload: cpio archive, then gzip-wrapped.
    const payload = try buildPayload(allocator, cfg, binary_data);
    defer allocator.free(payload);

    // Compute MD5 of the payload for the signature section.
    var md5_digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(payload, &md5_digest, .{});

    // Build the main header.
    const header = try buildHeader(allocator, cfg, binary_data, payload.len);
    defer allocator.free(header);

    // Compute MD5 of header+payload for signature.
    var combined_md5: [16]u8 = undefined;
    {
        var h = std.crypto.hash.Md5.init(.{});
        h.update(header);
        h.update(payload);
        h.final(&combined_md5);
    }

    // Build the signature section.
    const signature = try buildSignature(allocator, header.len + payload.len, &combined_md5);
    defer allocator.free(signature);

    // Compute total RPM file size and open output.
    const file = std.Io.Dir.cwd().createFile(io, cfg.output_path, .{ .truncate = true }) catch |err| {
        log.err("failed to create output file {s}: {}", .{ cfg.output_path, err });
        return error.WriteError;
    };
    defer file.close(io);

    // Write: lead | signature | header | payload
    const lead = buildLead(cfg);

    file.writeStreamingAll(io, &lead) catch return error.WriteError;
    file.writeStreamingAll(io, signature) catch return error.WriteError;
    file.writeStreamingAll(io, header) catch return error.WriteError;
    file.writeStreamingAll(io, payload) catch return error.WriteError;
}

// ---------------------------------------------------------------------------
// RPM Lead (96 bytes)
// ---------------------------------------------------------------------------

/// Build the 96-byte RPM lead.
///
/// Lead layout:
///   [0..3]   magic: 0xED 0xAB 0xEE 0xDB
///   [4]      major version: 3
///   [5]      minor version: 0
///   [6..7]   type: 0 = binary (big-endian)
///   [8..9]   archnum (big-endian): 1 = x86_64/generic, 9 = aarch64
///   [10..75] name: null-padded, 66 bytes
///   [76..77] osnum (big-endian): 1 = Linux
///   [78..79] signature_type (big-endian): 5 = header signature
///   [80..95] reserved: zeros
fn buildLead(cfg: RpmConfig) [96]u8 {
    var lead: [96]u8 = .{0} ** 96;

    // Magic
    lead[0] = 0xED;
    lead[1] = 0xAB;
    lead[2] = 0xEE;
    lead[3] = 0xDB;

    // Major / minor version
    lead[4] = 3;
    lead[5] = 0;

    // Type: 0 = binary package (big-endian u16)
    lead[6] = 0;
    lead[7] = 0;

    // Archnum: 1 = x86_64, 9 = aarch64, 12 = armv7hl, 1 = riscv64 (treat as generic)
    const archnum: u16 = rpmArchNum(cfg.arch);
    std.mem.writeInt(u16, lead[8..10], archnum, .big);

    // Name field: 66 bytes, null-padded
    const name_len = @min(cfg.name.len, 65);
    @memcpy(lead[10 .. 10 + name_len], cfg.name[0..name_len]);

    // OS: 1 = Linux
    std.mem.writeInt(u16, lead[76..78], 1, .big);

    // Signature type: 5 = header-style signature
    std.mem.writeInt(u16, lead[78..80], 5, .big);

    return lead;
}

fn rpmArchNum(arch: []const u8) u16 {
    if (std.mem.eql(u8, arch, "x86_64")) return 1;
    if (std.mem.eql(u8, arch, "aarch64")) return 9;
    if (std.mem.eql(u8, arch, "armv7hl")) return 12;
    if (std.mem.eql(u8, arch, "armv7a")) return 12;
    return 1; // generic fallback
}

// ---------------------------------------------------------------------------
// RPM Header format helpers
// ---------------------------------------------------------------------------

// Tag types used in RPM headers.
const TAG_TYPE_NULL: u32 = 0;
const TAG_TYPE_CHAR: u32 = 1;
const TAG_TYPE_INT8: u32 = 2;
const TAG_TYPE_INT16: u32 = 3;
const TAG_TYPE_INT32: u32 = 4;
const TAG_TYPE_INT64: u32 = 5;
const TAG_TYPE_STRING: u32 = 6;
const TAG_TYPE_BIN: u32 = 7;
const TAG_TYPE_STRING_ARRAY: u32 = 8;
const TAG_TYPE_I18NSTRING: u32 = 9;

// Main header tag numbers (RPMTAG_*).
const TAG_NAME: u32 = 1000;
const TAG_VERSION: u32 = 1001;
const TAG_RELEASE: u32 = 1002;
const TAG_SUMMARY: u32 = 1004;
const TAG_DESCRIPTION: u32 = 1005;
const TAG_BUILDTIME: u32 = 1006;
const TAG_SIZE: u32 = 1009;
const TAG_LICENSE: u32 = 1014;
const TAG_PACKAGER: u32 = 1015;
const TAG_URL: u32 = 1020;
const TAG_OS: u32 = 1021;
const TAG_ARCH: u32 = 1022;
const TAG_FILESIZES: u32 = 1028;
const TAG_FILEMODES: u32 = 1030;
const TAG_FILERDEVS: u32 = 1033;
const TAG_FILEMTIMES: u32 = 1034;
const TAG_FILEDIGESTS: u32 = 1035;
const TAG_FILELINKTOS: u32 = 1036;
const TAG_FILEFLAGS: u32 = 1037;
const TAG_FILEUSERNAME: u32 = 1039;
const TAG_FILEGROUPNAME: u32 = 1040;
const TAG_FILEINODES: u32 = 1096;
const TAG_FILELANGS: u32 = 1097;
const TAG_DIRINDEXES: u32 = 1116;
const TAG_BASENAMES: u32 = 1117;
const TAG_DIRNAMES: u32 = 1118;
const TAG_PAYLOADFORMAT: u32 = 1124;
const TAG_PAYLOADCOMPRESSOR: u32 = 1125;
const TAG_FILEDIGESTALGO: u32 = 5011;

// Signature tag numbers (RPMSIGTAG_*).
const SIGTAG_SIZE: u32 = 1000;
const SIGTAG_MD5: u32 = 1004;
const SIGTAG_PAYLOADSIZE: u32 = 1007;

// Header magic bytes.
const HEADER_MAGIC = [_]u8{ 0x8e, 0xad, 0xe8, 0x01, 0x00, 0x00, 0x00, 0x00 };

/// One entry in an RPM header index.
const IndexEntry = struct {
    tag: u32,
    type: u32,
    offset: i32,
    count: u32,
};

/// Accumulator for building an RPM header section (signature or main header).
const HeaderBuilder = struct {
    entries: std.ArrayListUnmanaged(IndexEntry) = .empty,
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *HeaderBuilder, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.data.deinit(allocator);
    }

    /// Return current data offset (used to record tag offsets).
    fn dataOffset(self: *const HeaderBuilder) i32 {
        return @intCast(self.data.items.len);
    }

    /// Align the data section to `alignment` bytes, padding with zeros.
    fn alignData(self: *HeaderBuilder, allocator: std.mem.Allocator, alignment: usize) !void {
        const rem = self.data.items.len % alignment;
        if (rem != 0) {
            const pad = alignment - rem;
            for (0..pad) |_| try self.data.append(allocator, 0);
        }
    }

    /// Append a null-terminated string tag (STRING or I18NSTRING).
    fn addString(self: *HeaderBuilder, allocator: std.mem.Allocator, tag: u32, tag_type: u32, s: []const u8) !void {
        try self.entries.append(allocator, .{
            .tag = tag,
            .type = tag_type,
            .offset = self.dataOffset(),
            .count = 1,
        });
        try self.data.appendSlice(allocator, s);
        try self.data.append(allocator, 0); // null terminator
    }

    /// Append a STRING_ARRAY tag (each element is null-terminated).
    fn addStringArray(self: *HeaderBuilder, allocator: std.mem.Allocator, tag: u32, strings: []const []const u8) !void {
        try self.entries.append(allocator, .{
            .tag = tag,
            .type = TAG_TYPE_STRING_ARRAY,
            .offset = self.dataOffset(),
            .count = @intCast(strings.len),
        });
        for (strings) |s| {
            try self.data.appendSlice(allocator, s);
            try self.data.append(allocator, 0);
        }
    }

    /// Append a INT32 array tag (big-endian, 4-byte aligned).
    fn addInt32Array(self: *HeaderBuilder, allocator: std.mem.Allocator, tag: u32, values: []const u32) !void {
        try self.alignData(allocator, 4);
        try self.entries.append(allocator, .{
            .tag = tag,
            .type = TAG_TYPE_INT32,
            .offset = self.dataOffset(),
            .count = @intCast(values.len),
        });
        for (values) |v| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, v, .big);
            try self.data.appendSlice(allocator, &buf);
        }
    }

    /// Append a single INT32 tag (big-endian, 4-byte aligned).
    fn addInt32(self: *HeaderBuilder, allocator: std.mem.Allocator, tag: u32, value: u32) !void {
        try self.addInt32Array(allocator, tag, &[_]u32{value});
    }

    /// Append an INT16 array tag (big-endian, 2-byte aligned).
    fn addInt16Array(self: *HeaderBuilder, allocator: std.mem.Allocator, tag: u32, values: []const u16) !void {
        try self.alignData(allocator, 2);
        try self.entries.append(allocator, .{
            .tag = tag,
            .type = TAG_TYPE_INT16,
            .offset = self.dataOffset(),
            .count = @intCast(values.len),
        });
        for (values) |v| {
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, v, .big);
            try self.data.appendSlice(allocator, &buf);
        }
    }

    /// Append a binary (BIN) tag.
    fn addBin(self: *HeaderBuilder, allocator: std.mem.Allocator, tag: u32, bytes: []const u8) !void {
        try self.entries.append(allocator, .{
            .tag = tag,
            .type = TAG_TYPE_BIN,
            .offset = self.dataOffset(),
            .count = @intCast(bytes.len),
        });
        try self.data.appendSlice(allocator, bytes);
    }

    /// Serialise the header into a complete byte slice (magic + nindex + hsize + index + data).
    /// Tags are sorted ascending by tag number before serialisation.
    fn serialize(self: *HeaderBuilder, allocator: std.mem.Allocator) ![]u8 {
        // Sort index entries by tag number (required by RPM format).
        const S = struct {
            fn lessThan(_: @This(), a: IndexEntry, b: IndexEntry) bool {
                return a.tag < b.tag;
            }
        };
        std.mem.sort(IndexEntry, self.entries.items, S{}, S.lessThan);

        const nindex: u32 = @intCast(self.entries.items.len);
        const hsize: u32 = @intCast(self.data.items.len);

        // Total: 8-byte magic + 4-byte nindex + 4-byte hsize + 16-byte/entry + data
        var out = try std.ArrayListUnmanaged(u8).initCapacity(
            allocator,
            8 + 4 + 4 + nindex * 16 + hsize,
        );
        errdefer out.deinit(allocator);

        // Magic
        try out.appendSlice(allocator, &HEADER_MAGIC);

        // nindex (big-endian u32)
        var buf4: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf4, nindex, .big);
        try out.appendSlice(allocator, &buf4);

        // hsize (big-endian u32)
        std.mem.writeInt(u32, &buf4, hsize, .big);
        try out.appendSlice(allocator, &buf4);

        // Index entries (each 16 bytes, all big-endian)
        for (self.entries.items) |e| {
            std.mem.writeInt(u32, &buf4, e.tag, .big);
            try out.appendSlice(allocator, &buf4);
            std.mem.writeInt(u32, &buf4, e.type, .big);
            try out.appendSlice(allocator, &buf4);
            std.mem.writeInt(i32, &buf4, e.offset, .big);
            try out.appendSlice(allocator, &buf4);
            std.mem.writeInt(u32, &buf4, e.count, .big);
            try out.appendSlice(allocator, &buf4);
        }

        // Data section
        try out.appendSlice(allocator, self.data.items);

        return out.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Signature section
// ---------------------------------------------------------------------------

/// Build the RPM signature section.
///
/// The signature uses the same header-format as the main header but:
///   - uses SIGTAG_* tag numbers
///   - is padded to an 8-byte boundary after the header structure
///
/// Tags included:
///   SIGTAG_SIZE        (1000, INT32)  — combined size of header + payload
///   SIGTAG_MD5         (1004, BIN)    — MD5 of header + payload
///   SIGTAG_PAYLOADSIZE (1007, INT32)  — uncompressed payload size (approx)
fn buildSignature(
    allocator: std.mem.Allocator,
    header_plus_payload_size: usize,
    md5: *const [16]u8,
) RpmError![]u8 {
    var hb: HeaderBuilder = .{};
    defer hb.deinit(allocator);

    // SIGTAG_SIZE: header + compressed payload size
    try hb.addInt32(allocator, SIGTAG_SIZE, @intCast(header_plus_payload_size));

    // SIGTAG_MD5: MD5 of header + payload (16 bytes)
    try hb.addBin(allocator, SIGTAG_MD5, md5);

    // SIGTAG_PAYLOADSIZE: placeholder (matches SIGTAG_SIZE for simple packages)
    try hb.addInt32(allocator, SIGTAG_PAYLOADSIZE, @intCast(header_plus_payload_size));

    const raw = try hb.serialize(allocator);
    defer allocator.free(raw);

    // Pad signature to 8-byte boundary.
    const padded_len = (raw.len + 7) & ~@as(usize, 7);
    var out = try allocator.alloc(u8, padded_len);
    @memset(out, 0);
    @memcpy(out[0..raw.len], raw);
    return out;
}

// ---------------------------------------------------------------------------
// Main Header
// ---------------------------------------------------------------------------

/// Build the RPM main header with all required package metadata and file info.
fn buildHeader(
    allocator: std.mem.Allocator,
    cfg: RpmConfig,
    binary_data: []const u8,
    payload_size: usize,
) RpmError![]u8 {
    var hb: HeaderBuilder = .{};
    defer hb.deinit(allocator);

    // Scalar string tags
    try hb.addString(allocator, TAG_NAME, TAG_TYPE_STRING, cfg.name);
    try hb.addString(allocator, TAG_VERSION, TAG_TYPE_STRING, cfg.version);
    try hb.addString(allocator, TAG_RELEASE, TAG_TYPE_STRING, cfg.release);

    const summary = if (cfg.summary.len > 0) cfg.summary else cfg.name;
    try hb.addString(allocator, TAG_SUMMARY, TAG_TYPE_I18NSTRING, summary);
    const description = if (cfg.description.len > 0) cfg.description else summary;
    try hb.addString(allocator, TAG_DESCRIPTION, TAG_TYPE_I18NSTRING, description);

    try hb.addString(allocator, TAG_LICENSE, TAG_TYPE_STRING, cfg.license);
    try hb.addString(allocator, TAG_PACKAGER, TAG_TYPE_STRING, cfg.packager);
    try hb.addString(allocator, TAG_URL, TAG_TYPE_STRING, cfg.url);
    try hb.addString(allocator, TAG_OS, TAG_TYPE_STRING, "linux");
    try hb.addString(allocator, TAG_ARCH, TAG_TYPE_STRING, cfg.arch);
    try hb.addString(allocator, TAG_PAYLOADFORMAT, TAG_TYPE_STRING, "cpio");
    try hb.addString(allocator, TAG_PAYLOADCOMPRESSOR, TAG_TYPE_STRING, "gzip");

    // Build time: 0 for reproducible builds
    try hb.addInt32(allocator, TAG_BUILDTIME, 0);

    // Installed package size (sum of file sizes)
    try hb.addInt32(allocator, TAG_SIZE, @intCast(binary_data.len));
    _ = payload_size;

    // --- File metadata arrays ---
    // We install exactly one file: /usr/bin/<name>
    // Directories in cpio do not need entries in these arrays (they are
    // implicit via DIRNAMES + DIRINDEXES).

    const bin_name = cfg.name; // basename
    const dir_name = "/usr/bin/"; // directory (with trailing slash)

    // Basenames: array of file basenames
    const basenames = [_][]const u8{bin_name};
    try hb.addStringArray(allocator, TAG_BASENAMES, &basenames);

    // Dirnames: array of unique directory paths (with trailing slash)
    const dirnames = [_][]const u8{dir_name};
    try hb.addStringArray(allocator, TAG_DIRNAMES, &dirnames);

    // Dirindexes: per-file index into dirnames
    try hb.addInt32Array(allocator, TAG_DIRINDEXES, &[_]u32{0});

    // Filesizes
    try hb.addInt32Array(allocator, TAG_FILESIZES, &[_]u32{@intCast(binary_data.len)});

    // Filemodes: 0o100755 = regular executable
    try hb.addInt16Array(allocator, TAG_FILEMODES, &[_]u16{0o100755});

    // Filerdevs: device number (0 for regular files)
    try hb.addInt16Array(allocator, TAG_FILERDEVS, &[_]u16{0});

    // Filemtimes: 0 for reproducible
    try hb.addInt32Array(allocator, TAG_FILEMTIMES, &[_]u32{0});

    // Filedigests (MD5 hex strings)
    var file_md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(binary_data, &file_md5, .{});
    const md5_hex_arr = std.fmt.bytesToHex(file_md5, .lower);
    const filedigests = [_][]const u8{&md5_hex_arr};
    try hb.addStringArray(allocator, TAG_FILEDIGESTS, &filedigests);

    // Filedigestalgo: 1 = MD5
    try hb.addInt32(allocator, TAG_FILEDIGESTALGO, 1);

    // Filelinktos (empty for non-symlinks)
    const filelinktos = [_][]const u8{""};
    try hb.addStringArray(allocator, TAG_FILELINKTOS, &filelinktos);

    // Fileflags: 0 = no special flags
    try hb.addInt32Array(allocator, TAG_FILEFLAGS, &[_]u32{0});

    // Fileusername / Filegroupname
    const fileusers = [_][]const u8{"root"};
    const filegroups = [_][]const u8{"root"};
    try hb.addStringArray(allocator, TAG_FILEUSERNAME, &fileusers);
    try hb.addStringArray(allocator, TAG_FILEGROUPNAME, &filegroups);

    // Fileinodes: inode number (use 1 as placeholder)
    try hb.addInt32Array(allocator, TAG_FILEINODES, &[_]u32{1});

    // Filelangs (empty string for each file)
    const filelangs = [_][]const u8{""};
    try hb.addStringArray(allocator, TAG_FILELANGS, &filelangs);

    const raw = try hb.serialize(allocator);
    return raw;
}

// ---------------------------------------------------------------------------
// Payload: cpio SVR4 newc + gzip
// ---------------------------------------------------------------------------

/// Build the RPM payload: a gzip-wrapped cpio SVR4 (newc) archive.
///
/// The archive contains:
///   - directory entries for /usr, /usr/bin
///   - the binary at /usr/bin/<name>
///   - TRAILER!!! sentinel
fn buildPayload(
    allocator: std.mem.Allocator,
    cfg: RpmConfig,
    binary_data: []const u8,
) RpmError![]u8 {
    var cpio: std.ArrayListUnmanaged(u8) = .empty;
    defer cpio.deinit(allocator);

    // Directory entries (mode = 040755 = directory, rwxr-xr-x)
    try writeCpioEntry(allocator, &cpio, ".", 2, 0o040755, &.{});
    try writeCpioEntry(allocator, &cpio, "usr", 3, 0o040755, &.{});
    try writeCpioEntry(allocator, &cpio, "usr/bin", 4, 0o040755, &.{});

    // The binary file
    const bin_path = try std.fmt.allocPrint(allocator, "usr/bin/{s}", .{cfg.name});
    defer allocator.free(bin_path);
    try writeCpioEntry(allocator, &cpio, bin_path, 5, 0o100755, binary_data);

    // TRAILER!!!
    try writeCpioTrailer(allocator, &cpio);

    return gzipWrap(allocator, cpio.items);
}

/// Write a single cpio SVR4 newc entry.
///
/// SVR4 newc header format (110 bytes, all ASCII hex):
///   magic    "070701"  (6 bytes)
///   ino      8 hex digits
///   mode     8 hex digits
///   uid      8 hex digits  (0 = root)
///   gid      8 hex digits  (0 = root)
///   nlink    8 hex digits  (1 for files, 2 for dirs)
///   mtime    8 hex digits  (0 for reproducible)
///   filesize 8 hex digits
///   devmajor 8 hex digits  (0)
///   devminor 8 hex digits  (0)
///   rdevmajor 8 hex digits (0)
///   rdevminor 8 hex digits (0)
///   namesize 8 hex digits  (includes null terminator)
///   check    8 hex digits  (0 for newc)
/// Followed by: name (namesize bytes, null-terminated), padded to 4-byte boundary
/// Followed by: file data, padded to 4-byte boundary
fn writeCpioEntry(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    ino: u32,
    mode: u32,
    data: []const u8,
) !void {
    const namesize: u32 = @intCast(name.len + 1); // includes null terminator
    const filesize: u32 = @intCast(data.len);
    const nlink: u32 = if (mode & 0o170000 == 0o040000) 2 else 1; // dirs have nlink=2

    var hdr: [110]u8 = undefined;
    _ = std.fmt.bufPrint(&hdr, "070701" ++
        "{x:0>8}" ++ // ino
        "{x:0>8}" ++ // mode
        "{x:0>8}" ++ // uid
        "{x:0>8}" ++ // gid
        "{x:0>8}" ++ // nlink
        "{x:0>8}" ++ // mtime
        "{x:0>8}" ++ // filesize
        "{x:0>8}" ++ // devmajor
        "{x:0>8}" ++ // devminor
        "{x:0>8}" ++ // rdevmajor
        "{x:0>8}" ++ // rdevminor
        "{x:0>8}" ++ // namesize
        "{x:0>8}", // check
        .{
            ino,
            mode,
            @as(u32, 0), // uid
            @as(u32, 0), // gid
            nlink,
            @as(u32, 0), // mtime = 0 (reproducible)
            filesize,
            @as(u32, 0), // devmajor
            @as(u32, 0), // devminor
            @as(u32, 0), // rdevmajor
            @as(u32, 0), // rdevminor
            namesize,
            @as(u32, 0), // check (0 for newc)
        }) catch unreachable;

    try buf.appendSlice(allocator, &hdr);

    // Name + null terminator
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);

    // Pad header + name to 4-byte boundary.
    // Header is 110 bytes; (110 + namesize) must be padded to next multiple of 4.
    const header_name_len = 110 + namesize;
    const name_pad = (4 - (header_name_len % 4)) % 4;
    for (0..name_pad) |_| try buf.append(allocator, 0);

    // File data
    if (filesize > 0) {
        try buf.appendSlice(allocator, data);
        // Pad data to 4-byte boundary.
        const data_pad = (4 - (filesize % 4)) % 4;
        for (0..data_pad) |_| try buf.append(allocator, 0);
    }
}

/// Write the cpio TRAILER!!! entry (signals end of archive).
fn writeCpioTrailer(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8)) !void {
    try writeCpioEntry(allocator, buf, "TRAILER!!!", 0, 0, &.{});
}

// ---------------------------------------------------------------------------
// gzip wrapper (reproducible)
// ---------------------------------------------------------------------------

/// Wrap `data` in a gzip stream using deflate stored blocks (no compression).
/// Output is reproducible: mtime = 0, xfl = 0, OS = Unix (3).
fn gzipWrap(allocator: std.mem.Allocator, data: []const u8) RpmError![]u8 {
    const max_block = 65535;
    const n_blocks = if (data.len == 0) 1 else (data.len + max_block - 1) / max_block;
    const deflate_size = n_blocks * 5 + data.len;

    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 10 + deflate_size + 8);
    errdefer out.deinit(allocator);

    // gzip header (RFC 1952 §2.3)
    const gz_header = [_]u8{
        0x1f, 0x8b, // magic
        0x08, // CM = deflate
        0x00, // FLG = no name/comment/extra
        0x00, 0x00, 0x00, 0x00, // MTIME = 0 (reproducible)
        0x00, // XFL = 0
        0x03, // OS = Unix
    };
    try out.appendSlice(allocator, &gz_header);

    // Deflate stored blocks (BTYPE = 00)
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

    // gzip footer: CRC32 of uncompressed data + size mod 2^32
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

test "rpmArch maps known architectures" {
    try std.testing.expectEqualStrings("x86_64", rpmArch("x86_64"));
    try std.testing.expectEqualStrings("aarch64", rpmArch("aarch64"));
    try std.testing.expectEqualStrings("armv7hl", rpmArch("armv7a"));
    try std.testing.expectEqualStrings("riscv64", rpmArch("riscv64"));
}

test "rpmArch passes through unknown architectures unchanged" {
    try std.testing.expectEqualStrings("mips64", rpmArch("mips64"));
}

test "buildLead produces correct magic and length" {
    const cfg = RpmConfig{
        .name = "testpkg",
        .version = "1.0.0",
        .arch = "x86_64",
        .binary_path = "",
        .output_path = "",
    };
    const lead = buildLead(cfg);

    // Magic
    try std.testing.expectEqual(@as(u8, 0xED), lead[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), lead[1]);
    try std.testing.expectEqual(@as(u8, 0xEE), lead[2]);
    try std.testing.expectEqual(@as(u8, 0xDB), lead[3]);
    // Major version = 3
    try std.testing.expectEqual(@as(u8, 3), lead[4]);
    // Lead is exactly 96 bytes
    try std.testing.expectEqual(@as(usize, 96), lead.len);
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
    // Bytes 4–7 = MTIME, must all be 0
    try std.testing.expectEqual(@as(u8, 0), gz[4]);
    try std.testing.expectEqual(@as(u8, 0), gz[5]);
    try std.testing.expectEqual(@as(u8, 0), gz[6]);
    try std.testing.expectEqual(@as(u8, 0), gz[7]);
}

test "writeCpioEntry produces correct magic and padded length" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeCpioEntry(allocator, &buf, "hello", 1, 0o100644, "world");

    // First 6 bytes = "070701"
    try std.testing.expectEqualStrings("070701", buf.items[0..6]);

    // Total length must be a multiple of 4
    try std.testing.expectEqual(@as(usize, 0), buf.items.len % 4);
}

test "HeaderBuilder serializes valid header magic" {
    const allocator = std.testing.allocator;
    var hb: HeaderBuilder = .{};
    defer hb.deinit(allocator);

    try hb.addString(allocator, TAG_NAME, TAG_TYPE_STRING, "testpkg");

    const raw = try hb.serialize(allocator);
    defer allocator.free(raw);

    // Header magic: 8E AD E8 01 00 00 00 00
    try std.testing.expectEqual(@as(u8, 0x8e), raw[0]);
    try std.testing.expectEqual(@as(u8, 0xad), raw[1]);
    try std.testing.expectEqual(@as(u8, 0xe8), raw[2]);
    try std.testing.expectEqual(@as(u8, 0x01), raw[3]);
}

test "HeaderBuilder sorts tags ascending" {
    const allocator = std.testing.allocator;
    var hb: HeaderBuilder = .{};
    defer hb.deinit(allocator);

    // Add in reverse order
    try hb.addString(allocator, TAG_VERSION, TAG_TYPE_STRING, "1.0");
    try hb.addString(allocator, TAG_NAME, TAG_TYPE_STRING, "pkg");

    const raw = try hb.serialize(allocator);
    defer allocator.free(raw);

    // Index starts at offset 16 (8 magic + 4 nindex + 4 hsize)
    // First entry tag (big-endian u32 at offset 16): should be TAG_NAME = 1000
    const first_tag = std.mem.readInt(u32, raw[16..20], .big);
    try std.testing.expectEqual(@as(u32, TAG_NAME), first_tag);
    const second_tag = std.mem.readInt(u32, raw[32..36], .big);
    try std.testing.expectEqual(@as(u32, TAG_VERSION), second_tag);
}

test "buildPayload produces valid gzip-wrapped cpio" {
    const allocator = std.testing.allocator;
    const cfg = RpmConfig{
        .name = "mypkg",
        .version = "1.0.0",
        .arch = "x86_64",
        .binary_path = "",
        .output_path = "",
    };
    const fake_binary = "ELF fake binary";
    const payload = try buildPayload(allocator, cfg, fake_binary);
    defer allocator.free(payload);

    // Must start with gzip magic
    try std.testing.expectEqual(@as(u8, 0x1f), payload[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), payload[1]);
}

test "generate creates a structurally valid .rpm" {
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

    const cfg = RpmConfig{
        .name = "testpkg",
        .version = "0.1.0",
        .release = "1",
        .arch = "x86_64",
        .summary = "A test package",
        .description = "A package built for testing",
        .license = "MIT",
        .packager = "CI <ci@example.com>",
        .binary_path = "fakebinary",
        .output_path = "testpkg-0.1.0-1.x86_64.rpm",
    };

    try generate(allocator, io, cfg);

    // Read back the .rpm and validate.
    const rpm_data = blk: {
        const f = try std.Io.Dir.cwd().openFile(io, cfg.output_path, .{});
        defer f.close(io);
        var rbuf: [65536 * 4]u8 = undefined;
        var r = f.reader(io, &rbuf);
        break :blk try r.interface.allocRemaining(allocator, .unlimited);
    };
    defer allocator.free(rpm_data);

    // Lead magic (bytes 0–3)
    try std.testing.expectEqual(@as(u8, 0xED), rpm_data[0]);
    try std.testing.expectEqual(@as(u8, 0xAB), rpm_data[1]);
    try std.testing.expectEqual(@as(u8, 0xEE), rpm_data[2]);
    try std.testing.expectEqual(@as(u8, 0xDB), rpm_data[3]);

    // Major version = 3 (byte 4)
    try std.testing.expectEqual(@as(u8, 3), rpm_data[4]);

    // After lead (96 bytes), the signature header magic should follow
    try std.testing.expectEqual(@as(u8, 0x8e), rpm_data[96]);
    try std.testing.expectEqual(@as(u8, 0xad), rpm_data[97]);
    try std.testing.expectEqual(@as(u8, 0xe8), rpm_data[98]);
    try std.testing.expectEqual(@as(u8, 0x01), rpm_data[99]);

    // Somewhere in the file there should be gzip magic (payload)
    const gzip_magic_pos = std.mem.indexOf(u8, rpm_data, &[_]u8{ 0x1f, 0x8b });
    try std.testing.expect(gzip_magic_pos != null);
}

test "RpmConfig InvalidConfig on empty name" {
    const allocator = std.testing.allocator;
    const io = std.Options.debug_io;
    const cfg = RpmConfig{
        .name = "",
        .version = "1.0.0",
        .arch = "x86_64",
        .binary_path = "/dev/null",
        .output_path = "/dev/null",
    };
    try std.testing.expectError(error.InvalidConfig, generate(allocator, io, cfg));
}
