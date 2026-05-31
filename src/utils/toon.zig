const std = @import("std");

/// Checks if a string is numeric-like, matching the TOON regex `/^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i`.
pub fn isNumericLike(str: []const u8) bool {
    if (str.len == 0) return false;
    var idx: usize = 0;
    if (str[idx] == '-') {
        idx += 1;
        if (idx == str.len) return false;
    }
    // Must have at least one digit
    if (!std.ascii.isDigit(str[idx])) return false;
    while (idx < str.len and std.ascii.isDigit(str[idx])) : (idx += 1) {}
    
    if (idx < str.len and str[idx] == '.') {
        idx += 1;
        if (idx == str.len or !std.ascii.isDigit(str[idx])) return false;
        while (idx < str.len and std.ascii.isDigit(str[idx])) : (idx += 1) {}
    }
    
    if (idx < str.len and (str[idx] == 'e' or str[idx] == 'E')) {
        idx += 1;
        if (idx < str.len and (str[idx] == '+' or str[idx] == '-')) {
            idx += 1;
        }
        if (idx == str.len or !std.ascii.isDigit(str[idx])) return false;
        while (idx < str.len and std.ascii.isDigit(str[idx])) : (idx += 1) {}
    }
    
    return idx == str.len;
}

/// Writes a string to the writer in TOON format, applying quoting and escaping only if necessary.
pub fn writeToonString(writer: anytype, str: []const u8, delim: u8) !void {
    var must_quote = false;
    if (str.len == 0) {
        must_quote = true;
    } else {
        // check leading/trailing whitespace
        if (std.ascii.isWhitespace(str[0]) or std.ascii.isWhitespace(str[str.len - 1])) {
            must_quote = true;
        }
        // check if equals true, false, null
        if (std.mem.eql(u8, str, "true") or std.mem.eql(u8, str, "false") or std.mem.eql(u8, str, "null")) {
            must_quote = true;
        }
        // check if numeric-like
        if (!must_quote and isNumericLike(str)) {
            must_quote = true;
        }
        // check if equals "-" or starts with "-"
        if (!must_quote and str[0] == '-') {
            must_quote = true;
        }
        // check special characters
        if (!must_quote) {
            for (str) |c| {
                if (c == ':' or c == '"' or c == '\\' or c == '[' or c == ']' or c == '{' or c == '}' or c == delim) {
                    must_quote = true;
                    break;
                }
                if (c >= 0 and c <= 0x1F) {
                    must_quote = true;
                    break;
                }
            }
        }
    }

    if (must_quote) {
        try writer.writeByte('"');
        for (str) |c| {
            if (c == '\\') {
                try writer.writeAll("\\\\");
            } else if (c == '"') {
                try writer.writeAll("\\\"");
            } else if (c == '\n') {
                try writer.writeAll("\\n");
            } else if (c == '\r') {
                try writer.writeAll("\\r");
            } else if (c == '\t') {
                try writer.writeAll("\\t");
            } else if (c >= 0 and c <= 0x1F) {
                // Formatting U+0000 - U+001F as lowercase \uXXXX hex sequences
                const hex_chars = "0123456789abcdef";
                var escape_buf: [6]u8 = undefined;
                escape_buf[0] = '\\';
                escape_buf[1] = 'u';
                escape_buf[2] = '0';
                escape_buf[3] = '0';
                escape_buf[4] = hex_chars[c >> 4];
                escape_buf[5] = hex_chars[c & 15];
                try writer.writeAll(&escape_buf);
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(str);
    }
}

test "isNumericLike: checks various numeric forms" {
    try std.testing.expect(isNumericLike("42"));
    try std.testing.expect(isNumericLike("-3.14"));
    try std.testing.expect(isNumericLike("05"));
    try std.testing.expect(isNumericLike("1e-6"));
    try std.testing.expect(isNumericLike("-0e+3"));
    try std.testing.expect(!isNumericLike("abc"));
    try std.testing.expect(!isNumericLike("42px"));
    try std.testing.expect(!isNumericLike(""));
    try std.testing.expect(!isNumericLike("-"));
}

test "writeToonString: tests quoting and escaping rules" {
    const alloc = std.testing.allocator;
    
    var out1 = std.Io.Writer.Allocating.init(alloc);
    defer out1.deinit();
    try writeToonString(&out1.writer, "hello", ',');
    const str1 = try out1.toOwnedSlice();
    defer alloc.free(str1);
    try std.testing.expectEqualStrings("hello", str1);

    var out2 = std.Io.Writer.Allocating.init(alloc);
    defer out2.deinit();
    try writeToonString(&out2.writer, "hello, world", ',');
    const str2 = try out2.toOwnedSlice();
    defer alloc.free(str2);
    try std.testing.expectEqualStrings("\"hello, world\"", str2);

    var out3 = std.Io.Writer.Allocating.init(alloc);
    defer out3.deinit();
    try writeToonString(&out3.writer, "true", ',');
    const str3 = try out3.toOwnedSlice();
    defer alloc.free(str3);
    try std.testing.expectEqualStrings("\"true\"", str3);

    var out4 = std.Io.Writer.Allocating.init(alloc);
    defer out4.deinit();
    try writeToonString(&out4.writer, "hello\nworld", ',');
    const str4 = try out4.toOwnedSlice();
    defer alloc.free(str4);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", str4);
}

test "writeToonString: additional edge cases and custom delimiters" {
    const alloc = std.testing.allocator;

    // 1. Strings starting with hyphen
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "-flag", ',');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("\"-flag\"", res);
    }

    // 2. Empty string
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "", ',');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("\"\"", res);
    }

    // 3. Leading and trailing whitespace
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "  spaces  ", ',');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("\"  spaces  \"", res);
    }

    // 4. Brackets and braces
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "foo[bar]", ',');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("\"foo[bar]\"", res);
    }

    // 5. Control characters (e.g. U+0007 Bell)
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "\x07", ',');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("\"\\u0007\"", res);
    }

    // 6. Active delimiter aware quoting
    // If pipe (|) is active: string with comma is NOT quoted, string with pipe IS quoted.
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "a,b", '|');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("a,b", res);
    }
    {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        try writeToonString(&out.writer, "a|b", '|');
        const res = try out.toOwnedSlice();
        defer alloc.free(res);
        try std.testing.expectEqualStrings("\"a|b\"", res);
    }
}

