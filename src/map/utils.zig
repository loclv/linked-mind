const std = @import("std");

/// Converts a filename stem into kebab-case (e.g. `hello_world.zig` → `hello-world`).
pub fn kebabFromFilename(alloc: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const stem = if (std.mem.findScalarLast(u8, filename, '.')) |i| filename[0..i] else filename;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (stem) |c| {
        if (c == '_' or c == ' ') {
            try buf.append(alloc, '-');
        } else if (std.ascii.isAlphanumeric(c) or c == '-') {
            try buf.append(alloc, std.ascii.toLower(c));
        } else {
            try buf.append(alloc, '-');
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Converts a directory name into a title (e.g. `memory_management` → `Memory Management`).
pub fn titleFromDirname(alloc: std.mem.Allocator, dirname: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var first = true;
    for (dirname) |c| {
        if (c == '_' or c == '-') {
            try buf.append(alloc, ' ');
            first = true;
        } else if (std.ascii.isAlphanumeric(c)) {
            if (first) {
                try buf.append(alloc, std.ascii.toUpper(c));
                first = false;
            } else {
                try buf.append(alloc, c);
            }
        }
    }
    return buf.toOwnedSlice(alloc);
}

test "kebabFromFilename: basic conversions" {
    const alloc = std.testing.allocator;

    const res1 = try kebabFromFilename(alloc, "hello_world.zig");
    defer alloc.free(res1);
    try std.testing.expectEqualStrings("hello-world", res1);

    const res2 = try kebabFromFilename(alloc, "MyAwesomeFile.md");
    defer alloc.free(res2);
    try std.testing.expectEqualStrings("myawesomefile", res2);

    const res3 = try kebabFromFilename(alloc, "some spaces here.txt");
    defer alloc.free(res3);
    try std.testing.expectEqualStrings("some-spaces-here", res3);

    const res4 = try kebabFromFilename(alloc, "already-kebab");
    defer alloc.free(res4);
    try std.testing.expectEqualStrings("already-kebab", res4);
}

test "titleFromDirname: basic conversions" {
    const alloc = std.testing.allocator;

    const res1 = try titleFromDirname(alloc, "memory_management");
    defer alloc.free(res1);
    try std.testing.expectEqualStrings("Memory Management", res1);

    const res2 = try titleFromDirname(alloc, "advanced-topics");
    defer alloc.free(res2);
    try std.testing.expectEqualStrings("Advanced Topics", res2);

    const res3 = try titleFromDirname(alloc, "simple");
    defer alloc.free(res3);
    try std.testing.expectEqualStrings("Simple", res3);
}
