const std = @import("std");
const parser = @import("parser.zig");

pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.StringHashMap(parser.Node),

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = std.StringHashMap(parser.Node).init(allocator),
        };
    }

    pub fn deinit(self: *Graph) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var node = entry.value_ptr;
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    pub fn addNode(self: *Graph, node: parser.Node) !void {
        const key = try self.allocator.dupe(u8, node.path);
        try self.nodes.put(key, node);
    }

    pub fn getContext(self: *Graph, path: []const u8) ![]const u8 {
        const node = self.nodes.get(path) orelse return error.NodeNotFound;
        var context = std.ArrayListUnmanaged(u8){};
        defer context.deinit(self.allocator);

        try context.writer(self.allocator).print("### Node: {s}\n", .{node.title});
        try context.writer(self.allocator).print("**Path:** {s}\n", .{node.path});
        
        if (node.tags.items.len > 0) {
            try context.writer(self.allocator).print("**Tags:** ", .{});
            for (node.tags.items, 0..) |tag, i| {
                try context.writer(self.allocator).print("#{s}{s}", .{tag, if (i == node.tags.items.len - 1) "" else ", "});
            }
            try context.writer(self.allocator).print("\n", .{});
        }

        try context.writer(self.allocator).print("\n### Connections\n", .{});
        for (node.links.items) |link_title| {
            // Try to find if this link_title exists as a filename/title in our graph
            var found = false;
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                const other = entry.value_ptr;
                if (std.mem.indexOf(u8, other.title, link_title) != null) {
                    try context.writer(self.allocator).print("- [[{s}]] (Found: {s})\n", .{link_title, other.path});
                    found = true;
                    break;
                }
            }
            if (!found) {
                try context.writer(self.allocator).print("- [[{s}]] (Unresolved)\n", .{link_title});
            }
        }

        return try context.toOwnedSlice(self.allocator);
    }
};
