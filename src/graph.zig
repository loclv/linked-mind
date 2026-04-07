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
        
        if (node.metadata.count() > 0) {
            try context.writer(self.allocator).print("**Metadata:**\n", .{});
            var meta_it = node.metadata.iterator();
            while (meta_it.next()) |entry| {
                try context.writer(self.allocator).print("- {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        if (node.tags.items.len > 0) {
            try context.writer(self.allocator).print("**Tags:** ", .{});
            for (node.tags.items, 0..) |tag, i| {
                try context.writer(self.allocator).print("#{s}{s}", .{tag, if (i == node.tags.items.len - 1) "" else ", "});
            }
            try context.writer(self.allocator).print("\n", .{});
        }

        try context.writer(self.allocator).print("\n### Connections\n", .{});
        for (node.links.items) |link| {
            var found = false;
            var it = self.nodes.iterator();
            while (it.next()) |entry| {
                const other = entry.value_ptr;
                if (std.mem.indexOf(u8, other.title, link.target) != null) {
                    if (link.nature) |nat| {
                        try context.writer(self.allocator).print("- OUT ({s}): [[{s}]] (Found: {s})\n", .{nat, link.target, other.path});
                    } else {
                        try context.writer(self.allocator).print("- OUT: [[{s}]] (Found: {s})\n", .{link.target, other.path});
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (link.nature) |nat| {
                    try context.writer(self.allocator).print("- OUT ({s}): [[{s}]] (Unresolved)\n", .{nat, link.target});
                } else {
                    try context.writer(self.allocator).print("- OUT: [[{s}]] (Unresolved)\n", .{link.target});
                }
            }
        }

        if (node.backlinks.items.len > 0) {
            try context.writer(self.allocator).print("\n### Backlinks (Linked by)\n", .{});
            for (node.backlinks.items) |blink| {
                try context.writer(self.allocator).print("- IN: {s}\n", .{blink});
            }
        }

        return try context.toOwnedSlice(self.allocator);
    }

    pub fn findNodeByTitle(self: *Graph, title: []const u8) ?*parser.Node {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (std.mem.indexOf(u8, entry.value_ptr.title, title) != null) {
                return entry.value_ptr;
            }
        }
        return null;
    }

    pub fn findShortestPath(self: *Graph, start_title: []const u8, end_title: []const u8) !?[]const []const u8 {
        const start_node = self.findNodeByTitle(start_title) orelse return null;
        const end_node = self.findNodeByTitle(end_title) orelse return null;

        if (start_node == end_node) {
            const result = try self.allocator.alloc([]const u8, 1);
            result[0] = try self.allocator.dupe(u8, start_node.title);
            return result;
        }

        var queue = std.ArrayListUnmanaged(*parser.Node){};
        defer queue.deinit(self.allocator);

        var parent_map = std.AutoHashMapUnmanaged(*parser.Node, *parser.Node){};
        defer parent_map.deinit(self.allocator);

        try queue.append(self.allocator, start_node);

        var head: usize = 0;
        var found = false;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;

            if (current == end_node) {
                found = true;
                break;
            }

            for (current.links.items) |link| {
                if (self.findNodeByTitle(link.target)) |neighbor| {
                    if (!parent_map.contains(neighbor) and neighbor != start_node) {
                        try parent_map.put(self.allocator, neighbor, current);
                        try queue.append(self.allocator, neighbor);
                    }
                }
            }
        }

        if (!found) return null;

        var path = std.ArrayListUnmanaged([]const u8){};
        var curr = end_node;
        while (curr != start_node) {
            try path.append(self.allocator, try self.allocator.dupe(u8, curr.title));
            curr = parent_map.get(curr).?;
        }
        try path.append(self.allocator, try self.allocator.dupe(u8, start_node.title));

        std.mem.reverse([]const u8, path.items);
        return try path.toOwnedSlice(self.allocator);

    }

    pub fn resolveBacklinks(self: *Graph) !void {

        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            const source_node = entry.value_ptr;

            for (source_node.links.items) |link| {
                var target_it = self.nodes.iterator();
                while (target_it.next()) |target_entry| {
                    const target_node = target_entry.value_ptr;
                    if (std.mem.indexOf(u8, target_node.title, link.target) != null) {
                        const source_desc = try self.allocator.dupe(u8, source_node.title);
                        try target_node.backlinks.append(self.allocator, source_desc);
                        break;
                    }
                }
            }
        }
    }
};
