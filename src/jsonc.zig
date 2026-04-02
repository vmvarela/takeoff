const std = @import("std");

const log = std.log.scoped(.jsonc);

pub const Error = error{
    UnterminatedString,
    UnterminatedBlockComment,
    OutOfMemory,
};

pub fn stripComments(allocator: std.mem.Allocator, content: []const u8) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (i + 1 < content.len) {
            const two_char = content[i..][0..2];
            if (std.mem.eql(u8, two_char, "//")) {
                i = skipLineComment(content, i);
                continue;
            }
            if (std.mem.eql(u8, two_char, "/*")) {
                i = try skipBlockComment(content, i);
                continue;
            }
        }

        if (content[i] == '"') {
            try copyString(allocator, content, &i, &result);
            continue;
        }

        try result.append(allocator, content[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn skipLineComment(content: []const u8, start: usize) usize {
    var i = start + 2;
    while (i < content.len and content[i] != '\n') {
        i += 1;
    }
    return i;
}

fn skipBlockComment(content: []const u8, start: usize) Error!usize {
    var i = start + 2;
    while (i + 1 < content.len) {
        if (content[i] == '*' and content[i + 1] == '/') {
            return i + 2;
        }
        i += 1;
    }
    return error.UnterminatedBlockComment;
}

fn copyString(allocator: std.mem.Allocator, content: []const u8, index: *usize, result: *std.ArrayList(u8)) Error!void {
    try result.append(allocator, '"');
    index.* += 1;

    while (index.* < content.len) {
        const char = content[index.*];
        try result.append(allocator, char);
        index.* += 1;

        if (char == '"') {
            return;
        }

        if (char == '\\' and index.* < content.len) {
            try result.append(allocator, content[index.*]);
            index.* += 1;
        }
    }

    return error.UnterminatedString;
}

test "stripComments removes line comments" {
    const allocator = std.testing.allocator;
    const input = "{\"name\": \"test\" // this is a comment\n}";
    const expected = "{\"name\": \"test\" \n}";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments removes block comments" {
    const allocator = std.testing.allocator;
    const input = "{\"name\": /* comment */ \"test\"}";
    const expected = "{\"name\":  \"test\"}";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments preserves strings with comment-like content" {
    const allocator = std.testing.allocator;
    const input = "{\"url\": \"https://example.com\"}";
    const expected = "{\"url\": \"https://example.com\"}";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments handles escaped quotes in strings" {
    const allocator = std.testing.allocator;
    const input = "{\"msg\": \"he said \\\"hello\\\" // not a comment\"}";
    const expected = "{\"msg\": \"he said \\\"hello\\\" // not a comment\"}";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments handles multiline block comments" {
    const allocator = std.testing.allocator;
    const input = "{/* multi\nline\ncomment */\"x\": 1}";
    const expected = "{\"x\": 1}";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments preserves strings with slashes" {
    const allocator = std.testing.allocator;
    const input = "{\"path\": \"/usr/local/bin\"}";
    const expected = "{\"path\": \"/usr/local/bin\"}";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments handles empty input" {
    const allocator = std.testing.allocator;
    const input = "";
    const expected = "";

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments handles complex JSONC" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "project": {
        \\    "name": "takeoff", // project name
        \\    /* description
        \\       multiline */
        \\    "version": "1.0"
        \\  }
        \\}
    ;
    const expected =
        \\{
        \\  "project": {
        \\    "name": "takeoff", 
        \\    
        \\    "version": "1.0"
        \\  }
        \\}
    ;

    const result = try stripComments(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

test "stripComments returns error for unterminated string" {
    const allocator = std.testing.allocator;
    const input = "{\"name\": \"test}";

    try std.testing.expectError(error.UnterminatedString, stripComments(allocator, input));
}

test "stripComments returns error for unterminated block comment" {
    const allocator = std.testing.allocator;
    const input = "{\"name\": /* unclosed";

    try std.testing.expectError(error.UnterminatedBlockComment, stripComments(allocator, input));
}
