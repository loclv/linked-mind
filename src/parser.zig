const std = @import("std");

pub const Link = struct {
    target: []const u8,
    nature: ?[]const u8,
};

pub const Node = struct {
    path: []const u8,
    title: []const u8,
    content: []const u8,
    links: std.ArrayListUnmanaged(Link),
    backlinks: std.ArrayListUnmanaged([]const u8),
    tags: std.ArrayListUnmanaged([]const u8),
    metadata: std.StringHashMapUnmanaged([]const u8),

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
        self.metadata.deinit(allocator);
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

        var node = Node{
            .path = try self.allocator.dupe(u8, path),
            .title = try self.allocator.dupe(u8, std.fs.path.basename(path)),
            .content = try self.allocator.dupe(u8, content),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = .{},
        };

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
                        try node.metadata.put(self.allocator, try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
                    }
                }
            }
        }

        // Simple Wikilink extraction: [[link]]
        var i: usize = content_start;
        while (i < content.len) : (i += 1) {
            if (i + 2 < content.len and std.mem.eql(u8, content[i..i+2], "[[")) {
                const start = i + 2;
                var end = start;
                while (end < content.len and !(end + 2 <= content.len and std.mem.eql(u8, content[end..end+2], "]]"))) : (end += 1) {}
                if (end + 2 <= content.len and std.mem.eql(u8, content[end..end+2], "]]")) {
                    const raw_link = content[start..end];
                    var link_obj = Link{ .target = undefined, .nature = null };
                    
                    if (std.mem.indexOf(u8, raw_link, "::")) |sep_idx| {
                        link_obj.nature = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link[0..sep_idx], " "));
                        link_obj.target = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link[sep_idx + 2..], " "));
                    } else {
                        link_obj.target = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link, " "));
                    }

                    try node.links.append(self.allocator, link_obj);
                    i = end + 1;
                }
            } else if (content[i] == '#') {

                // Simple Tag extraction: #tag (must be followed by space or newline)
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
