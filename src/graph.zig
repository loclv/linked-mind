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
        var context = std.ArrayList(u8).init(self.allocator);
        defer context.deinit();

        try context.writer().print("Knowledge Node: {s}\n", .{node.title});
        try context.writer().print("Tags: ", .{});
        for (node.tags.items, 0..) |tag, i| {
            try context.writer().print("{s}{s}", .{tag, if (i == node.tags.items.len - 1) "" else ", "});
        }
        try context.writer().print("\nRelated Connections:\n", .{});
        
        for (node.links.items) |link| {
            try context.writer().print("- {s}\n", .{link});
        }

        return try context.toOwnedSlice();
    }
};
