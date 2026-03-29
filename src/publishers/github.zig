const std = @import("std");

const log = std.log.scoped(.github);

/// Error set for GitHub API operations.
pub const GitHubError = error{
    NetworkError,
    AuthenticationFailed,
    RateLimited,
    NotFound,
    ServerError,
    AlreadyExists,
    ParseError,
    FileError,
    MissingToken,
    UploadFailed,
    Timeout,
} || std.mem.Allocator.Error || std.Io.File.OpenError;

/// Options for creating or updating a release.
pub const ReleaseOptions = struct {
    owner: []const u8,
    repo: []const u8,
    tag: []const u8,
    target_commitish: ?[]const u8 = null,
    name: ?[]const u8 = null,
    body: []const u8,
    draft: bool = false,
    prerelease: bool = false,
};

/// Information about a GitHub release returned by the API.
pub const ReleaseInfo = struct {
    id: u64,
    tag_name: []const u8,
    name: []const u8,
    body: []const u8,
    draft: bool,
    prerelease: bool,
    html_url: []const u8,
    upload_url: []const u8,
    assets: []const AssetInfo,

    pub fn deinit(self: *ReleaseInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.tag_name);
        if (self.name.ptr != self.tag_name.ptr) {
            allocator.free(self.name);
        }
        allocator.free(self.body);
        allocator.free(self.html_url);
        allocator.free(self.upload_url);
        for (self.assets) |asset| {
            var mutable_asset = asset;
            mutable_asset.deinit(allocator);
        }
        allocator.free(self.assets);
    }
};

/// Information about a release asset.
pub const AssetInfo = struct {
    id: u64,
    name: []const u8,
    content_type: []const u8,
    size: usize,
    browser_download_url: []const u8,

    pub fn deinit(self: *AssetInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content_type);
        allocator.free(self.browser_download_url);
    }
};

/// Result of a release operation.
pub const ReleaseResult = struct {
    success: bool,
    release_id: u64,
    html_url: []const u8,
    uploaded_assets: usize,
    deleted_assets: usize,
    errors: []const []const u8,

    pub fn deinit(self: *ReleaseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.html_url);
        for (self.errors) |err| allocator.free(err);
        allocator.free(self.errors);
    }
};

/// Client configuration options.
pub const ClientOptions = struct {
    /// Timeout for HTTP requests in milliseconds (default: 30 seconds)
    timeout_ms: u64 = 30_000,
    /// Maximum response size in bytes (default: 100 MB)
    max_response_size: usize = 100 * 1024 * 1024,
    /// Base URL for GitHub API (default: https://api.github.com)
    base_url: []const u8 = "https://api.github.com",
};

/// Client for interacting with the GitHub REST API.
pub const GitHubClient = struct {
    const api_version = "2022-11-28";
    const redirect_buffer_size = 64 * 1024; // 64KB for headers

    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    token: []const u8,
    base_url: []const u8,
    timeout_ms: u64,
    max_response_size: usize,

    /// Initialize a new GitHub client with default options.
    /// Caller owns the returned memory and must call deinit.
    pub fn init(allocator: std.mem.Allocator, token: []const u8) GitHubError!GitHubClient {
        return initWithOptions(allocator, token, .{});
    }

    /// Initialize a new GitHub client with custom options.
    /// Caller owns the returned memory and must call deinit.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        token: []const u8,
        options: ClientOptions,
    ) GitHubError!GitHubClient {
        const token_copy = try allocator.dupe(u8, token);
        errdefer allocator.free(token_copy);

        const http_client = std.http.Client{ .allocator = allocator, .io = std.Options.debug_io };

        const base_url_copy = try allocator.dupe(u8, options.base_url);
        errdefer allocator.free(base_url_copy);

        return .{
            .allocator = allocator,
            .http_client = http_client,
            .token = token_copy,
            .base_url = base_url_copy,
            .timeout_ms = options.timeout_ms,
            .max_response_size = options.max_response_size,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *GitHubClient) void {
        self.http_client.deinit();
        self.allocator.free(self.token);
        self.allocator.free(self.base_url);
    }

    /// Build extra headers for GitHub API requests.
    fn buildHeaders(self: *GitHubClient, include_content_type: bool) GitHubError![]const std.http.Header {
        var headers = try self.allocator.alloc(std.http.Header, if (include_content_type) 5 else 4);
        errdefer self.allocator.free(headers);

        headers[0] = .{ .name = "Accept", .value = "application/vnd.github+json" };
        headers[1] = .{
            .name = "Authorization",
            .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token}),
        };
        headers[2] = .{ .name = "X-GitHub-Api-Version", .value = api_version };
        headers[3] = .{ .name = "Accept-Encoding", .value = "identity" };

        if (include_content_type) {
            headers[4] = .{ .name = "Content-Type", .value = "application/json" };
        }

        return headers;
    }

    /// Free headers allocated by buildHeaders.
    fn freeHeaders(self: *GitHubClient, headers: []const std.http.Header) void {
        for (headers) |header| {
            if (std.mem.eql(u8, header.name, "Authorization")) {
                self.allocator.free(header.value);
            }
        }
        self.allocator.free(headers);
    }

    /// Parse Link header for pagination.
    fn parseLinkHeader(self: *GitHubClient, link_header: []const u8) ?[]const u8 {
        // Link: <url>; rel="next", <url>; rel="last"
        var it = std.mem.split(u8, link_header, ",");
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " ");
            if (std.mem.endsWith(u8, trimmed, "; rel=\"next\"")) {
                // Extract URL from <url>
                const start = std.mem.indexOf(u8, trimmed, "<") orelse continue;
                const end = std.mem.indexOf(u8, trimmed, ">") orelse continue;
                if (end > start + 1) {
                    return self.allocator.dupe(u8, trimmed[start + 1 .. end]) catch null;
                }
            }
        }
        return null;
    }

    /// Make a request to the GitHub API.
    fn makeRequest(
        self: *GitHubClient,
        method: std.http.Method,
        path: []const u8,
        body: ?[]const u8,
    ) GitHubError![]const u8 {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.base_url, path },
        );
        defer self.allocator.free(url);

        return try self.makeRequestRaw(method, url, body);
    }

    /// Make a request to a raw URL.
    fn makeRequestRaw(
        self: *GitHubClient,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
    ) GitHubError![]const u8 {
        const headers = try self.buildHeaders(body != null);
        defer self.freeHeaders(headers);

        const uri = std.Uri.parse(url) catch |err| {
            log.err("failed to parse URL: {}", .{err});
            return error.ParseError;
        };

        var req = self.http_client.request(method, uri, .{
            .extra_headers = headers,
        }) catch |err| {
            log.err("failed to create request: {}", .{err});
            return error.NetworkError;
        };
        defer req.deinit();

        // Send body if present
        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
                log.err("failed to start body: {}", .{err});
                return error.NetworkError;
            };
            body_writer.writer.writeAll(payload) catch |err| {
                log.err("failed to write body: {}", .{err});
                return error.NetworkError;
            };
            body_writer.end() catch |err| {
                log.err("failed to end body: {}", .{err});
                return error.NetworkError;
            };
            req.connection.?.flush() catch |err| {
                log.err("failed to flush: {}", .{err});
                return error.NetworkError;
            };
        } else {
            req.sendBodiless() catch |err| {
                log.err("failed to send request: {}", .{err});
                return error.NetworkError;
            };
        }

        var redirect_buffer: [redirect_buffer_size]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            log.err("failed to receive response: {}", .{err});
            return error.NetworkError;
        };

        const status = response.head.status;

        // Read response body with size limit
        var response_body: std.ArrayListUnmanaged(u8) = .empty;
        defer response_body.deinit(self.allocator);

        var reader = response.reader(&.{});
        const response_bytes = reader.allocRemaining(self.allocator, .limited(self.max_response_size)) catch |err| {
            log.err("failed to read response body: {}", .{err});
            return error.NetworkError;
        };
        defer self.allocator.free(response_bytes);

        // Detect gzip by magic bytes (1F 8B) — Zig's http client negotiates gzip automatically
        if (response_bytes.len >= 2 and response_bytes[0] == 0x1f and response_bytes[1] == 0x8b) {
            var input_reader: std.Io.Reader = .fixed(response_bytes);
            var decompress_buffer: [65536]u8 = undefined;
            var decompress: std.compress.flate.Decompress = .init(&input_reader, .gzip, &decompress_buffer);
            // Read all decompressed data
            while (true) {
                var chunk: [4096]u8 = undefined;
                const n = decompress.reader.readSliceShort(&chunk) catch break;
                if (n == 0) break;
                response_body.appendSlice(self.allocator, chunk[0..n]) catch |err| {
                    log.err("failed to append decompressed chunk: {}", .{err});
                    return error.NetworkError;
                };
            }
        } else {
            response_body.appendSlice(self.allocator, response_bytes) catch |err| {
                log.err("failed to append to response buffer: {}", .{err});
                return error.NetworkError;
            };
        }

        const response_data = try self.allocator.dupe(u8, response_body.items);
        errdefer self.allocator.free(response_data);

        switch (status) {
            .ok, .created => return response_data,
            .no_content => {
                self.allocator.free(response_data);
                return try self.allocator.dupe(u8, "");
            },
            .unauthorized => {
                self.allocator.free(response_data);
                return error.AuthenticationFailed;
            },
            .forbidden => {
                self.allocator.free(response_data);
                return error.RateLimited;
            },
            .not_found => {
                self.allocator.free(response_data);
                return error.NotFound;
            },
            .unprocessable_entity => {
                self.allocator.free(response_data);
                return error.AlreadyExists;
            },
            else => {
                if (@intFromEnum(status) >= 500) {
                    self.allocator.free(response_data);
                    return error.ServerError;
                }
                log.err("unexpected status: {d}", .{@intFromEnum(status)});
                log.err("response: {s}", .{response_data});
                self.allocator.free(response_data);
                return error.ServerError;
            },
        }
    }

    /// Create a new release.
    pub fn createRelease(self: *GitHubClient, opts: ReleaseOptions) GitHubError!ReleaseInfo {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/repos/{s}/{s}/releases",
            .{ opts.owner, opts.repo },
        );
        defer self.allocator.free(path);

        const json_body = try buildReleaseJson(self.allocator, opts);
        defer self.allocator.free(json_body);

        const response = try self.makeRequest(.POST, path, json_body);
        errdefer self.allocator.free(response);

        return try parseReleaseResponse(self.allocator, response);
    }

    /// Get a release by tag.
    /// Returns null if not found.
    pub fn getReleaseByTag(
        self: *GitHubClient,
        owner: []const u8,
        repo: []const u8,
        tag: []const u8,
    ) GitHubError!?ReleaseInfo {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/repos/{s}/{s}/releases/tags/{s}",
            .{ owner, repo, tag },
        );
        defer self.allocator.free(path);

        const response = self.makeRequest(.GET, path, null) catch |err| {
            if (err == error.NotFound) return null;
            return err;
        };
        errdefer self.allocator.free(response);

        return try parseReleaseResponse(self.allocator, response);
    }

    /// Update an existing release.
    pub fn updateRelease(
        self: *GitHubClient,
        release_id: u64,
        opts: ReleaseOptions,
    ) GitHubError!ReleaseInfo {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/repos/{s}/{s}/releases/{d}",
            .{ opts.owner, opts.repo, release_id },
        );
        defer self.allocator.free(path);

        const json_body = try buildReleaseJson(self.allocator, opts);
        defer self.allocator.free(json_body);

        const response = try self.makeRequest(.PATCH, path, json_body);
        errdefer self.allocator.free(response);

        return try parseReleaseResponse(self.allocator, response);
    }

    /// Delete an asset by ID.
    pub fn deleteAsset(
        self: *GitHubClient,
        owner: []const u8,
        repo: []const u8,
        asset_id: u64,
    ) GitHubError!void {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/repos/{s}/{s}/releases/assets/{d}",
            .{ owner, repo, asset_id },
        );
        defer self.allocator.free(path);

        const response = try self.makeRequest(.DELETE, path, null);
        self.allocator.free(response);
    }

    /// List all assets for a release with pagination support.
    pub fn listReleaseAssets(
        self: *GitHubClient,
        owner: []const u8,
        repo: []const u8,
        release_id: u64,
    ) GitHubError![]AssetInfo {
        var all_assets = std.ArrayListUnmanaged(AssetInfo).empty;
        errdefer {
            for (all_assets.items) |*asset| asset.deinit(self.allocator);
            all_assets.deinit(self.allocator);
        }

        var page: usize = 1;
        const per_page = 100;

        while (true) {
            const path = try std.fmt.allocPrint(
                self.allocator,
                "/repos/{s}/{s}/releases/{d}/assets?per_page={d}&page={d}",
                .{ owner, repo, release_id, per_page, page },
            );
            defer self.allocator.free(path);

            const response = try self.makeRequest(.GET, path, null);
            defer self.allocator.free(response);

            // Parse assets array from JSON response
            const assets = try parseAssetsArray(self.allocator, response);
            defer {
                for (assets) |*asset| asset.deinit(self.allocator);
                self.allocator.free(assets);
            }

            if (assets.len == 0) break;

            // Append assets to our list
            for (assets) |asset| {
                const asset_copy = try copyAssetInfo(self.allocator, asset);
                try all_assets.append(self.allocator, asset_copy);
            }

            // Check if we got less than per_page, meaning we're done
            if (assets.len < per_page) break;

            page += 1;
        }

        return all_assets.toOwnedSlice(self.allocator);
    }

    /// Delete all assets for a release.
    pub fn deleteAllAssets(
        self: *GitHubClient,
        owner: []const u8,
        repo: []const u8,
        release_id: u64,
    ) GitHubError!usize {
        const assets = try self.listReleaseAssets(owner, repo, release_id);
        defer {
            for (assets) |*asset| asset.deinit(self.allocator);
            self.allocator.free(assets);
        }

        var deleted: usize = 0;
        for (assets) |asset| {
            self.deleteAsset(owner, repo, asset.id) catch |err| {
                log.warn("failed to delete asset {s} (id={d}): {}", .{ asset.name, asset.id, err });
                continue;
            };
            deleted += 1;
            log.info("deleted asset: {s}", .{asset.name});
        }

        return deleted;
    }

    /// Upload an asset to a release.
    /// The upload_url is the template returned by the create/update API.
    pub fn uploadAsset(
        self: *GitHubClient,
        upload_url_template: []const u8,
        file_path: []const u8,
    ) GitHubError!AssetInfo {
        // Extract the base upload URL (remove {?name,label} template)
        const upload_base = blk: {
            const template_start = std.mem.indexOf(u8, upload_url_template, "{") orelse
                upload_url_template.len;
            break :blk upload_url_template[0..template_start];
        };

        const file_name = std.fs.path.basename(file_path);

        // Build upload URL with query parameter
        const upload_url = try std.fmt.allocPrint(
            self.allocator,
            "{s}?name={s}",
            .{ upload_base, file_name },
        );
        defer self.allocator.free(upload_url);

        // Determine content type
        const content_type = guessContentType(file_name);

        // Read file content
        const io = std.Options.debug_io;
        const file_content = std.Io.Dir.cwd().readFileAlloc(io, file_path, self.allocator, .limited(100 * 1024 * 1024)) catch |err| {
            log.err("failed to read file {s}: {}", .{ file_path, err });
            return error.FileError;
        };
        defer self.allocator.free(file_content);

        // Build headers for upload
        var headers = try self.allocator.alloc(std.http.Header, 5);
        errdefer self.allocator.free(headers);

        headers[0] = .{ .name = "Accept", .value = "application/vnd.github+json" };
        headers[1] = .{
            .name = "Authorization",
            .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.token}),
        };
        headers[2] = .{ .name = "X-GitHub-Api-Version", .value = api_version };
        headers[3] = .{ .name = "Content-Type", .value = content_type };
        headers[4] = .{
            .name = "Content-Length",
            .value = try std.fmt.allocPrint(self.allocator, "{d}", .{file_content.len}),
        };
        defer {
            for (headers) |header| {
                if (std.mem.eql(u8, header.name, "Authorization") or
                    std.mem.eql(u8, header.name, "Content-Length"))
                {
                    self.allocator.free(header.value);
                }
            }
            self.allocator.free(headers);
        }

        // Upload
        const response = self.uploadRaw(upload_url, file_content, headers) catch |err| {
            log.err("failed to upload {s}: {}", .{ file_name, err });
            return error.UploadFailed;
        };
        errdefer self.allocator.free(response);

        return try parseAssetResponse(self.allocator, response);
    }

    /// Raw upload to a URL.
    fn uploadRaw(
        self: *GitHubClient,
        url: []const u8,
        data: []const u8,
        headers: []const std.http.Header,
    ) GitHubError![]const u8 {
        const uri = std.Uri.parse(url) catch |err| {
            log.err("failed to parse URL: {}", .{err});
            return error.ParseError;
        };

        var req = self.http_client.request(.POST, uri, .{
            .extra_headers = headers,
        }) catch |err| {
            log.err("failed to create request: {}", .{err});
            return error.NetworkError;
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = data.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
            log.err("failed to start body: {}", .{err});
            return error.NetworkError;
        };
        body_writer.writer.writeAll(data) catch |err| {
            log.err("failed to write body: {}", .{err});
            return error.NetworkError;
        };
        body_writer.end() catch |err| {
            log.err("failed to end body: {}", .{err});
            return error.NetworkError;
        };
        req.connection.?.flush() catch |err| {
            log.err("failed to flush: {}", .{err});
            return error.NetworkError;
        };

        var redirect_buffer: [redirect_buffer_size]u8 = undefined;
        var response = req.receiveHead(&redirect_buffer) catch |err| {
            log.err("failed to receive response: {}", .{err});
            return error.NetworkError;
        };

        const status = response.head.status;

        var response_body: std.ArrayListUnmanaged(u8) = .empty;
        defer response_body.deinit(self.allocator);

        var reader = response.reader(&.{});
        const response_bytes = reader.allocRemaining(self.allocator, .limited(self.max_response_size)) catch |err| {
            log.err("failed to read response body: {}", .{err});
            return error.NetworkError;
        };
        defer self.allocator.free(response_bytes);
        response_body.appendSlice(self.allocator, response_bytes) catch {
            return error.NetworkError;
        };

        const response_data = try self.allocator.dupe(u8, response_body.items);
        errdefer self.allocator.free(response_data);

        switch (status) {
            .ok, .created => return response_data,
            else => {
                self.allocator.free(response_data);
                return error.UploadFailed;
            },
        }
    }
};

/// Build JSON payload for release create/update.
fn buildReleaseJson(allocator: std.mem.Allocator, opts: ReleaseOptions) GitHubError![]const u8 {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{");
    try json.appendSlice(allocator, "\"tag_name\":\"");
    try json.appendSlice(allocator, opts.tag);
    try json.appendSlice(allocator, "\"");

    if (opts.target_commitish) |commit| {
        try json.appendSlice(allocator, ",\"target_commitish\":\"");
        try json.appendSlice(allocator, commit);
        try json.appendSlice(allocator, "\"");
    }

    if (opts.name) |name| {
        try json.appendSlice(allocator, ",\"name\":\"");
        try json.appendSlice(allocator, name);
        try json.appendSlice(allocator, "\"");
    }

    try json.appendSlice(allocator, ",\"body\":\"");
    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        escapeJsonString(&aw.writer, opts.body) catch {
            return error.ParseError;
        };
        const escaped = try aw.toOwnedSlice();
        defer allocator.free(escaped);
        try json.appendSlice(allocator, escaped);
    }
    try json.appendSlice(allocator, "\"");

    const draft_txt = if (opts.draft) "true" else "false";
    const prerelease_txt = if (opts.prerelease) "true" else "false";
    try json.appendSlice(allocator, ",\"draft\":");
    try json.appendSlice(allocator, draft_txt);
    try json.appendSlice(allocator, ",\"prerelease\":");
    try json.appendSlice(allocator, prerelease_txt);
    try json.appendSlice(allocator, "}");

    return json.toOwnedSlice(allocator);
}

/// Escape a string for JSON.
fn escapeJsonString(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"), // backspace
            0x0C => try writer.writeAll("\\f"), // form feed
            else => {
                // Escape control characters
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}

/// Unescape a JSON string (handle escape sequences).
fn unescapeJsonString(allocator: std.mem.Allocator, input: []const u8) GitHubError![]const u8 {
    // Check if we need unescaping
    if (std.mem.indexOfScalar(u8, input, '\\') == null) {
        return try allocator.dupe(u8, input);
    }

    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            switch (next) {
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                '/' => try result.append(allocator, '/'),
                'b' => try result.append(allocator, '\x08'),
                'f' => try result.append(allocator, '\x0c'),
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                'u' => {
                    // Unicode escape: \uXXXX
                    if (i + 5 < input.len) {
                        const hex = input[i + 2 .. i + 6];
                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch 0xFFFD;
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch 0;
                        try result.appendSlice(allocator, buf[0..len]);
                        i += 4;
                    }
                },
                else => try result.append(allocator, next),
            }
            i += 1;
        } else {
            try result.append(allocator, input[i]);
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse a release JSON response.
fn parseReleaseResponse(allocator: std.mem.Allocator, json_data: []const u8) GitHubError!ReleaseInfo {
    // Simple JSON parsing - extract key fields
    const id = extractJsonU64(json_data, "\"id\":") orelse {
        log.err("failed to parse release ID from response", .{});
        return error.ParseError;
    };

    const tag_name = extractJsonString(allocator, json_data, "\"tag_name\":\"") orelse {
        log.err("failed to parse tag_name from response", .{});
        return error.ParseError;
    };
    errdefer allocator.free(tag_name);

    const name = extractJsonString(allocator, json_data, "\"name\":\"") orelse tag_name;
    errdefer if (name.ptr != tag_name.ptr) allocator.free(name);

    const body = extractJsonString(allocator, json_data, "\"body\":\"") orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(body);

    const html_url = extractJsonString(allocator, json_data, "\"html_url\":\"") orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(html_url);

    const upload_url = extractJsonString(allocator, json_data, "\"upload_url\":\"") orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(upload_url);

    // For simplicity, we're not parsing assets in detail here
    // A full implementation would parse the assets array
    const assets = try allocator.alloc(AssetInfo, 0);

    return .{
        .id = id,
        .tag_name = tag_name,
        .name = name,
        .body = body,
        .draft = std.mem.indexOf(u8, json_data, "\"draft\":true") != null,
        .prerelease = std.mem.indexOf(u8, json_data, "\"prerelease\":true") != null,
        .html_url = html_url,
        .upload_url = upload_url,
        .assets = assets,
    };
}

/// Parse an asset JSON response.
fn parseAssetResponse(allocator: std.mem.Allocator, json_data: []const u8) GitHubError!AssetInfo {
    const id = extractJsonU64(json_data, "\"id\":") orelse 0;

    const name = extractJsonString(allocator, json_data, "\"name\":\"") orelse
        try allocator.dupe(u8, "unknown");
    errdefer allocator.free(name);

    const content_type = extractJsonString(allocator, json_data, "\"content_type\":\"") orelse
        try allocator.dupe(u8, "application/octet-stream");
    errdefer allocator.free(content_type);

    const browser_download_url = extractJsonString(allocator, json_data, "\"browser_download_url\":\"") orelse
        try allocator.dupe(u8, "");
    errdefer allocator.free(browser_download_url);

    const size = extractJsonU64(json_data, "\"size\":") orelse 0;

    return .{
        .id = id,
        .name = name,
        .content_type = content_type,
        .size = @intCast(size),
        .browser_download_url = browser_download_url,
    };
}

/// Parse an array of assets from JSON response.
fn parseAssetsArray(allocator: std.mem.Allocator, json_data: []const u8) GitHubError![]AssetInfo {
    // Expecting JSON array: [{...}, {...}]
    var assets = std.ArrayListUnmanaged(AssetInfo).empty;
    errdefer {
        for (assets.items) |*asset| asset.deinit(allocator);
        assets.deinit(allocator);
    }

    // Simple parsing: find each object in the array
    var pos: usize = 0;
    while (pos < json_data.len) {
        // Find start of object
        const obj_start = std.mem.indexOfScalarPos(u8, json_data, pos, '{') orelse break;

        // Find matching end of object (simple approach)
        var depth: usize = 1;
        var obj_end = obj_start + 1;
        while (obj_end < json_data.len and depth > 0) : (obj_end += 1) {
            switch (json_data[obj_end]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                '"' => {
                    // Skip string
                    var i = obj_end + 1;
                    while (i < json_data.len) : (i += 1) {
                        if (json_data[i] == '"' and json_data[i - 1] != '\\') break;
                    }
                    obj_end = i;
                },
                else => {},
            }
        }

        if (depth != 0) break;

        const obj_json = json_data[obj_start..obj_end];
        const asset = try parseAssetResponse(allocator, obj_json);
        try assets.append(allocator, asset);

        pos = obj_end;
    }

    return assets.toOwnedSlice(allocator);
}

/// Copy an AssetInfo struct.
fn copyAssetInfo(allocator: std.mem.Allocator, asset: AssetInfo) GitHubError!AssetInfo {
    return .{
        .id = asset.id,
        .name = try allocator.dupe(u8, asset.name),
        .content_type = try allocator.dupe(u8, asset.content_type),
        .size = asset.size,
        .browser_download_url = try allocator.dupe(u8, asset.browser_download_url),
    };
}

/// Extract a string value from JSON with proper escape handling.
fn extractJsonString(
    allocator: std.mem.Allocator,
    json: []const u8,
    key: []const u8,
) ?[]const u8 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const start = key_pos + key.len;
    if (start >= json.len) return null;

    // Check for null value
    const after_key = std.mem.trimStart(u8, json[start..], " \t\n\r");
    if (std.mem.startsWith(u8, after_key, "null")) {
        return allocator.dupe(u8, "") catch null;
    }

    // Find end of string (handling escaped quotes)
    var end = start;
    var escaped = false;
    while (end < json.len) : (end += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (json[end] == '\\') {
            escaped = true;
            continue;
        }
        if (json[end] == '"') break;
    }

    if (end >= json.len) return null;

    // Extract and unescape
    const raw = json[start..end];
    return unescapeJsonString(allocator, raw) catch null;
}

/// Extract a u64 value from JSON.
fn extractJsonU64(json: []const u8, key: []const u8) ?u64 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    const start = key_pos + key.len;
    if (start >= json.len) return null;

    // Skip whitespace
    var pos = start;
    while (pos < json.len and (json[pos] == ' ' or json[pos] == '\n' or json[pos] == '\r' or json[pos] == '\t')) : (pos += 1) {}

    if (pos >= json.len) return null;

    // Read number
    var end = pos;
    while (end < json.len and std.ascii.isDigit(json[end])) : (end += 1) {}

    if (end == pos) return null;

    return std.fmt.parseInt(u64, json[pos..end], 10) catch null;
}

/// Guess content type from file extension.
fn guessContentType(filename: []const u8) []const u8 {
    if (std.mem.endsWith(u8, filename, ".tar.gz") or
        std.mem.endsWith(u8, filename, ".tgz"))
    {
        return "application/gzip";
    }
    if (std.mem.endsWith(u8, filename, ".zip")) {
        return "application/zip";
    }
    if (std.mem.endsWith(u8, filename, ".txt")) {
        return "text/plain";
    }
    if (std.mem.endsWith(u8, filename, ".md")) {
        return "text/markdown";
    }
    return "application/octet-stream";
}

/// Publish a release with all artifacts.
/// This is idempotent - if release exists, it will be updated.
pub fn publishRelease(
    allocator: std.mem.Allocator,
    opts: ReleaseOptions,
    artifact_dir: []const u8,
    assets_to_upload: []const []const u8,
    clean_assets: bool,
) GitHubError!ReleaseResult {
    const environ = std.Options.debug_threaded_io.?.environ.process_environ;
    const token = std.process.Environ.getAlloc(environ, allocator, "GITHUB_TOKEN") catch |err| {
        log.err("GITHUB_TOKEN environment variable is required: {}", .{err});
        return error.MissingToken;
    };
    defer allocator.free(token);

    var client = try GitHubClient.init(allocator, token);
    defer client.deinit();

    log.info("checking for existing release {s}", .{opts.tag});

    // Check if release already exists
    const existing_release = try client.getReleaseByTag(opts.owner, opts.repo, opts.tag);

    var release: ReleaseInfo = undefined;
    var is_update = false;
    var deleted_count: usize = 0;

    if (existing_release) |*er| {
        log.info("updating existing release id={d}", .{er.id});

        // Clean existing assets if requested
        if (clean_assets) {
            log.info("cleaning existing assets...", .{});
            deleted_count = try client.deleteAllAssets(opts.owner, opts.repo, er.id);
            log.info("deleted {d} existing assets", .{deleted_count});
        }

        release = try client.updateRelease(er.id, opts);
        @constCast(er).deinit(allocator);
        is_update = true;
    } else {
        log.info("creating new release for tag {s}", .{opts.tag});
        release = try client.createRelease(opts);
    }
    errdefer release.deinit(allocator);

    log.info("release URL: {s}", .{release.html_url});

    // Upload assets
    var errors = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (errors.items) |err| allocator.free(err);
        errors.deinit(allocator);
    }

    var uploaded_count: usize = 0;

    for (assets_to_upload) |asset_path| {
        const full_path = if (std.fs.path.isAbsolute(asset_path))
            try allocator.dupe(u8, asset_path)
        else
            try std.fs.path.join(allocator, &.{ artifact_dir, asset_path });
        defer allocator.free(full_path);

        // Check if file exists
        std.Io.Dir.cwd().access(std.Options.debug_io, full_path, .{}) catch {
            const err_msg = try std.fmt.allocPrint(
                allocator,
                "File not found: {s}",
                .{asset_path},
            );
            try errors.append(allocator, err_msg);
            continue;
        };

        log.info("uploading {s}...", .{std.fs.path.basename(full_path)});

        _ = client.uploadAsset(release.upload_url, full_path) catch |err| {
            const err_msg = try std.fmt.allocPrint(
                allocator,
                "Failed to upload {s}: {s}",
                .{ asset_path, @errorName(err) },
            );
            try errors.append(allocator, err_msg);
            continue;
        };

        uploaded_count += 1;
        log.info("uploaded {s}", .{std.fs.path.basename(full_path)});
    }

    const result = ReleaseResult{
        .success = errors.items.len == 0,
        .release_id = release.id,
        .html_url = try allocator.dupe(u8, release.html_url),
        .uploaded_assets = uploaded_count,
        .deleted_assets = deleted_count,
        .errors = try errors.toOwnedSlice(allocator),
    };

    release.deinit(allocator);

    return result;
}

test "guessContentType works" {
    try std.testing.expectEqualStrings("application/gzip", guessContentType("file.tar.gz"));
    try std.testing.expectEqualStrings("application/gzip", guessContentType("file.tgz"));
    try std.testing.expectEqualStrings("application/zip", guessContentType("file.zip"));
    try std.testing.expectEqualStrings("text/plain", guessContentType("file.txt"));
    try std.testing.expectEqualStrings("text/markdown", guessContentType("file.md"));
    try std.testing.expectEqualStrings("application/octet-stream", guessContentType("file.unknown"));
}

test "buildReleaseJson builds valid JSON" {
    const allocator = std.testing.allocator;

    const opts = ReleaseOptions{
        .owner = "test",
        .repo = "test",
        .tag = "v1.0.0",
        .name = "Release 1.0.0",
        .body = "Test release\nWith newline",
        .draft = true,
        .prerelease = false,
    };

    const json = try buildReleaseJson(allocator, opts);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"tag_name\":\"v1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Release 1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"body\":\"Test release\\nWith newline\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"draft\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"prerelease\":false") != null);
}

test "escapeJsonString escapes correctly" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try escapeJsonString(fbs.writer(), "Hello \"World\"\n");
    try std.testing.expectEqualStrings("Hello \\\"World\\\"\\n", fbs.getWritten());
}

test "unescapeJsonString handles escapes" {
    const allocator = std.testing.allocator;

    const unescaped = try unescapeJsonString(allocator, "Hello\\nWorld\\t!");
    defer allocator.free(unescaped);

    try std.testing.expectEqualStrings("Hello\nWorld\t!", unescaped);
}

test "unescapeJsonString handles unicode" {
    const allocator = std.testing.allocator;

    const unescaped = try unescapeJsonString(allocator, "\\u0048\\u0065\\u006c\\u006c\\u006f");
    defer allocator.free(unescaped);

    try std.testing.expectEqualStrings("Hello", unescaped);
}

test "parseReleaseResponse handles missing optional fields" {
    const allocator = std.testing.allocator;

    const json_data =
        \\{"id":123,"tag_name":"v1.2.3"}
    ;

    var release = try parseReleaseResponse(allocator, json_data);
    defer release.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 123), release.id);
    try std.testing.expectEqualStrings("v1.2.3", release.tag_name);
    try std.testing.expectEqualStrings("v1.2.3", release.name);
    try std.testing.expectEqualStrings("", release.body);
    try std.testing.expectEqualStrings("", release.html_url);
    try std.testing.expectEqualStrings("", release.upload_url);
}

test "parseAssetResponse handles missing optional fields" {
    const allocator = std.testing.allocator;

    const json_data =
        \\{"id":999}
    ;

    var asset = try parseAssetResponse(allocator, json_data);
    defer asset.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 999), asset.id);
    try std.testing.expectEqualStrings("unknown", asset.name);
    try std.testing.expectEqualStrings("application/octet-stream", asset.content_type);
    try std.testing.expectEqualStrings("", asset.browser_download_url);
}
