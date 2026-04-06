const std = @import("std");

pub const Node = struct {
    path: []const u8,
    title: []const u8,
    links: std.ArrayList([]const u8),
    tags: std.ArrayList([]const u8),

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        for (self.links.items) |link| allocator.free(link);
        for (self.tags.items) |tag| allocator.free(tag);
        self.links.deinit(allocator);
        self.tags.deinit(allocator);
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn parseFile(self: *Parser, path: []const u8) !Node {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // max 1MB
        defer self.allocator.free(content);

        var node = Node{
            .path = try self.allocator.dupe(u8, path),
            .title = try self.allocator.dupe(u8, std.fs.path.basename(path)),
            .links = std.ArrayList([]const u8).init(self.allocator),
            .tags = std.ArrayList([]const u8).init(self.allocator),
        };

        // Simple Wikilink extraction: [[link]]
        var i: usize = 0;
        while (i < content.len - 4) : (i += 1) {
            if (std.mem.eql(u8, content[i..i+2], "[[")) {
                const start = i + 2;
                var end = start;
                while (end < content.len - 2 and !std.mem.eql(u8, content[end..end+2], "]]")) : (end += 1) {}
                if (end < content.len - 1 and std.mem.eql(u8, content[end..end+2], "]]")) {
                    const link = try self.allocator.dupe(u8, content[start..end]);
                    try node.links.append(link);
                    i = end + 1;
                }
            } else if (content[i] == '#') {
                // Simple Tag extraction: #tag (must be followed by space or newline)
                const start = i + 1;
                var end = start;
                while (end < content.len and !std.ascii.isWhitespace(content[end]) and content[end] != '.' and content[end] != ',') : (end += 1) {}
                if (end > start) {
                    const tag = try self.allocator.dupe(u8, content[start..end]);
                    try node.tags.append(tag);
                    i = end;
                }
            }
        }

        return node;
    }
};
