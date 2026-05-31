const std = @import("std");
const utils = @import("utils.zig");

/// Holds the name and description extracted from a single file.
pub const Metadata = struct {
    name: []const u8,
    description: []const u8,

    pub fn deinit(self: Metadata, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
    }
};

/// Reads an entire file into an allocator-owned buffer.
pub fn readFileAlloc(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

/// Parses YAML frontmatter (`--- ... ---`) for `name:` and `description:`.
/// Returns null if the file has no frontmatter or the keys are missing.
pub fn extractFrontmatter(alloc: std.mem.Allocator, content: []const u8) !?Metadata {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;
    const end = std.mem.indexOf(u8, content[4..], "\n---") orelse return null;
    const fm = content[4 .. 4 + end];

    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            name = std.mem.trim(u8, trimmed[5..], " \r\t\"'");
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            desc = std.mem.trim(u8, trimmed[12..], " \r\t\"'");
        }
    }

    if (name == null or desc == null) return null;
    return Metadata{
        .name = try alloc.dupe(u8, name.?),
        .description = try alloc.dupe(u8, desc.?),
    };
}

/// Looks for the first `//` comment in a Zig file to use as its description.
pub fn extractZigDesc(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//")) {
            return std.mem.trim(u8, t[2..], " \r\t");
        }
        if (t.len > 0) break;
    }
    return "";
}

/// For Markdown without frontmatter, extracts the first heading/paragraph text.
pub fn extractMdDesc(content: []const u8) []const u8 {
    const body_start = if (std.mem.indexOf(u8, content, "\n---")) |i|
        if (std.mem.indexOf(u8, content[i + 4 ..], "\n")) |j| i + 4 + j + 1 else content.len
    else
        0;
    const body = content[body_start..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t#");
        if (t.len > 0) return t;
    }
    return "";
}

/// Reads a file and builds Metadata based on its extension and contents.
pub fn fileMetadata(io: std.Io, alloc: std.mem.Allocator, full_path: []const u8, basename: []const u8) !Metadata {
    const content = try readFileAlloc(io, alloc, full_path);
    defer alloc.free(content);

    if (std.mem.endsWith(u8, basename, ".md")) {
        if (try extractFrontmatter(alloc, content)) |fm| return fm;
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc = try alloc.dupe(u8, extractMdDesc(content));
        return Metadata{ .name = name, .description = desc };
    }

    if (std.mem.endsWith(u8, basename, ".zig")) {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractZigDesc(content);
        if (desc_raw.len > 0) {
            const desc = try alloc.dupe(u8, desc_raw);
            return Metadata{ .name = name, .description = desc };
        }
        const desc = try std.fmt.allocPrint(alloc, "Zig code sample: {s}.", .{name});
        return Metadata{ .name = name, .description = desc };
    }

    const name = try utils.kebabFromFilename(alloc, basename);
    errdefer alloc.free(name);
    return Metadata{ .name = name, .description = "" };
}

test "extractFrontmatter: valid frontmatter" {
    const alloc = std.testing.allocator;
    const content =
        \\---
        \\name: "My custom name"
        \\description: "This is a great description"
        \\---
        \\Some other body text here.
    ;

    const meta = try extractFrontmatter(alloc, content);
    try std.testing.expect(meta != null);
    defer meta.?.deinit(alloc);

    try std.testing.expectEqualStrings("My custom name", meta.?.name);
    try std.testing.expectEqualStrings("This is a great description", meta.?.description);
}

test "extractFrontmatter: missing keys" {
    const alloc = std.testing.allocator;
    const content =
        \\---
        \\name: "Only Name"
        \\---
    ;

    const meta = try extractFrontmatter(alloc, content);
    try std.testing.expect(meta == null);
}

test "extractZigDesc: extracts first comment line" {
    const content =
        \\// This is the description comment
        \\const std = @import("std");
    ;
    const desc = extractZigDesc(content);
    try std.testing.expectEqualStrings("This is the description comment", desc);
}

test "extractMdDesc: extracts first text paragraph" {
    const content =
        \\# My Title
        \\
        \\This is the first paragraph.
        \\And another one.
    ;
    const desc = extractMdDesc(content);
    try std.testing.expectEqualStrings("My Title", desc);
}
