const std = @import("std");

pub const Link = struct {
    target: []const u8,
    nature: ?[]const u8,
};

pub const Node = struct {
    path: []const u8,
    title: []const u8,
    content: []const u8,
    links: std.ArrayList(Link),
    backlinks: std.ArrayList([]const u8),
    tags: std.ArrayList([]const u8),
    metadata: std.StringHashMap([]const u8),

    pub fn clone(self: Node, allocator: std.mem.Allocator) !Node {
        var new_node: Node = .{
            .path = try allocator.dupe(u8, self.path),
            .title = try allocator.dupe(u8, self.title),
            .content = try allocator.dupe(u8, self.content),
            .links = try self.links.clone(allocator),
            .backlinks = try self.backlinks.clone(allocator),
            .tags = try self.tags.clone(allocator),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
        errdefer new_node.deinit(allocator);

        // Deep clone links
        for (new_node.links.items) |*link| {
            link.target = try allocator.dupe(u8, link.target);
            if (link.nature) |nat| link.nature = try allocator.dupe(u8, nat);
        }

        // Deep clone backlinks
        for (new_node.backlinks.items) |*blink| {
            blink.* = try allocator.dupe(u8, blink.*);
        }

        // Deep clone tags
        for (new_node.tags.items) |*tag| {
            tag.* = try allocator.dupe(u8, tag.*);
        }

        // Deep clone metadata
        var meta_it = self.metadata.iterator();
        while (meta_it.next()) |entry| {
            try new_node.metadata.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }

        return new_node;
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        allocator.free(self.content);
        for (self.links.items) |link| {
            allocator.free(link.target);
            if (link.nature) |nat| allocator.free(nat);
        }
        for (self.backlinks.items) |blink| allocator.free(blink);
        for (self.tags.items) |tag| allocator.free(tag);
        self.links.deinit(allocator);
        self.backlinks.deinit(allocator);
        self.tags.deinit(allocator);

        var meta_iter = self.metadata.iterator();
        while (meta_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
        self.* = undefined;
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn parseFile(self: *Parser, path: []const u8) !Node {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // max 1MB
        defer self.allocator.free(content);

        return self.parseContent(path, content);
    }

    pub fn parseContent(self: *Parser, path: []const u8, content: []const u8) !Node {
        var node: Node = .{
            .path = try self.allocator.dupe(u8, path),
            .title = try self.allocator.dupe(u8, std.fs.path.basename(path)),
            .content = try self.allocator.dupe(u8, content),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
        errdefer node.deinit(self.allocator);

        var content_start: usize = 0;

        // Frontmatter parsing
        if (std.mem.startsWith(u8, content, "---")) {
            const second_sep = std.mem.indexOf(u8, content[3..], "---");
            if (second_sep) |sep_idx| {
                const frontmatter = content[3 .. sep_idx + 3];
                content_start = sep_idx + 6; // Move past --- and potential newline

                var lines = std.mem.tokenizeAny(u8, frontmatter, "\r\n");
                while (lines.next()) |line| {
                    var parts = std.mem.splitSequence(u8, line, ":");
                    const key_raw = parts.next() orelse continue;
                    const value_raw = parts.next() orelse "";

                    const key = std.mem.trim(u8, key_raw, " ");
                    const value = std.mem.trim(u8, value_raw, " ");

                    if (key.len > 0) {
                        try node.metadata.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
                    }
                }
            }
        }

        // Simple Wikilink extraction: [[link]]
        var i: usize = content_start;
        while (i < content.len) : (i += 1) {
            if (i + 2 <= content.len and std.mem.eql(u8, content[i .. i + 2], "[[")) {
                const start = i + 2;
                var end = start;
                while (end < content.len and !(end + 2 <= content.len and std.mem.eql(u8, content[end .. end + 2], "]]"))) : (end += 1) {}
                if (end + 2 <= content.len and std.mem.eql(u8, content[end .. end + 2], "]]")) {
                    const raw_link = content[start..end];
                    var link_obj: Link = .{ .target = undefined, .nature = null };

                    if (std.mem.indexOf(u8, raw_link, "::")) |sep_idx| {
                        link_obj.nature = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link[0..sep_idx], " "));
                        link_obj.target = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link[sep_idx + 2 ..], " "));
                    } else {
                        link_obj.target = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link, " "));
                    }

                    try node.links.append(self.allocator, link_obj);
                    i = end + 1;
                }
            } else if (content[i] == '#') {
                // Tag extraction: #tag (must NOT be markdown header ##, ###, etc.)
                // Check if next char is # or space (header pattern like "# " or "##")
                if (i + 1 < content.len and (content[i + 1] == '#' or content[i + 1] == ' ')) {
                    // This is a markdown header, skip
                    continue;
                }

                const start = i + 1;
                var end = start;
                while (end < content.len and !std.ascii.isWhitespace(content[end]) and content[end] != '.' and content[end] != ',') : (end += 1) {}
                if (end > start) {
                    const tag = try self.allocator.dupe(u8, content[start..end]);
                    try node.tags.append(self.allocator, tag);
                    i = end;
                }
            }
        }

        return node;
    }
};

test "Parser: basic parsing" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Hello world";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("test.md", node.path);
    try std.testing.expectEqualStrings("test.md", node.title);
    try std.testing.expectEqualStrings(content, node.content);
    try std.testing.expectEqual(@as(usize, 0), node.links.items.len);
    try std.testing.expectEqual(@as(usize, 0), node.tags.items.len);
    try std.testing.expectEqual(@as(u32, 0), node.metadata.count());
}

test "Parser: frontmatter" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\author: John Doe
        \\type: note
        \\---
        \\Content here
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("John Doe", node.metadata.get("author").?);
    try std.testing.expectEqualStrings("note", node.metadata.get("type").?);
    try std.testing.expectEqual(@as(u32, 2), node.metadata.count());
}

test "Parser: wikilinks" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Check [[Other File]] and [[supports::Feature]]";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.links.items.len);
    try std.testing.expectEqualStrings("Other File", node.links.items[0].target);
    try std.testing.expect(node.links.items[0].nature == null);

    try std.testing.expectEqualStrings("Feature", node.links.items[1].target);
    try std.testing.expectEqualStrings("supports", node.links.items[1].nature.?);
}

test "Parser: tags" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "This is #important and #urgent, but not #. or # alone";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
    try std.testing.expectEqualStrings("important", node.tags.items[0]);
    try std.testing.expectEqualStrings("urgent", node.tags.items[1]);
}

test "Parser: tags vs markdown headers" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\## Heading 1
        \\### Heading 2
        \\# Heading 3
        \\
        \\This has #real-tag but not # header-like.
        \\#### Another heading
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    // Only #real-tag should be extracted, headers should be skipped
    try std.testing.expectEqual(@as(usize, 1), node.tags.items.len);
    try std.testing.expectEqualStrings("real-tag", node.tags.items[0]);
}

test "Parser: complex combination" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\key: value
        \\---
        \\#start
        \\Link to [[Target]] with #tag inside.
        \\Another [[relation::AnotherTarget]].
        \\#end
    ;
    var node = try parser.parseContent("complex.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), node.metadata.count());
    try std.testing.expectEqual(@as(usize, 2), node.links.items.len);
    try std.testing.expectEqual(@as(usize, 3), node.tags.items.len);

    try std.testing.expectEqualStrings("value", node.metadata.get("key").?);
    try std.testing.expectEqualStrings("Target", node.links.items[0].target);
    try std.testing.expectEqualStrings("AnotherTarget", node.links.items[1].target);
    try std.testing.expectEqualStrings("relation", node.links.items[1].nature.?);
    try std.testing.expectEqualStrings("start", node.tags.items[0]);
    try std.testing.expectEqualStrings("tag", node.tags.items[1]);
    try std.testing.expectEqualStrings("end", node.tags.items[2]);
}
