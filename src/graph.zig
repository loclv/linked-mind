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

    pub const Cluster = struct {
        nodes: std.ArrayListUnmanaged(*parser.Node),

        pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
            self.nodes.deinit(allocator);
        }
    };

    pub const ScoreResult = struct { node: *parser.Node, score: f32 };

    pub fn detectClusters(self: *Graph) ![]Cluster {
        var visited = std.AutoHashMap(*parser.Node, void).init(self.allocator);
        defer visited.deinit();

        var clusters = std.ArrayListUnmanaged(Cluster){};
        defer clusters.deinit(self.allocator);

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const start_node = entry.value_ptr;
            if (visited.contains(start_node)) continue;

            var cluster = Cluster{ .nodes = .{} };
            var queue = std.ArrayListUnmanaged(*parser.Node){};
            defer queue.deinit(self.allocator);

            try queue.append(self.allocator, start_node);
            try visited.put(start_node, {});
            try cluster.nodes.append(self.allocator, start_node);

            var head: usize = 0;
            while (head < queue.items.len) {
                const current = queue.items[head];
                head += 1;

                // Outgoing links
                for (current.links.items) |link| {
                    if (self.findNodeByTitle(link.target)) |neighbor| {
                        if (!visited.contains(neighbor)) {
                            try visited.put(neighbor, {});
                            try queue.append(self.allocator, neighbor);
                            try cluster.nodes.append(self.allocator, neighbor);
                        }
                    }
                }

                // Incoming links (backlinks)
                for (current.backlinks.items) |btitle| {
                    if (self.findNodeByTitle(btitle)) |neighbor| {
                        if (!visited.contains(neighbor)) {
                            try visited.put(neighbor, {});
                            try queue.append(self.allocator, neighbor);
                            try cluster.nodes.append(self.allocator, neighbor);
                        }
                    }
                }
            }
            try clusters.append(self.allocator, cluster);
        }

        return try clusters.toOwnedSlice(self.allocator);
    }

    pub fn generateMOC(self: *Graph) ![]const u8 {
        const clusters = try self.detectClusters();
        defer {
            for (clusters) |*c| c.deinit(self.allocator);
            self.allocator.free(clusters);
        }

        var moc = std.ArrayListUnmanaged(u8){};
        defer moc.deinit(self.allocator);

        try moc.writer(self.allocator).print("# Map of Content (MOC)\n", .{});
        try moc.writer(self.allocator).print("Generated on: 2026-04-07\n\n", .{});

        for (clusters, 0..) |cluster, i| {
            try moc.writer(self.allocator).print("## Cluster {d}\n", .{i + 1});
            for (cluster.nodes.items) |node| {
                try moc.writer(self.allocator).print("- [[{s}]] ({s})\n", .{ node.title, node.path });
            }
            try moc.writer(self.allocator).print("\n", .{});
        }

        return try moc.toOwnedSlice(self.allocator);
    }

    pub fn findSimilarNodes(self: *Graph, target_title: []const u8, limit: usize) ![]ScoreResult {
        const target_node = self.findNodeByTitle(target_title) orelse return error.NodeNotFound;

        var scores = std.ArrayListUnmanaged(ScoreResult){};
        defer scores.deinit(self.allocator);

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const other_node = entry.value_ptr;
            if (other_node == target_node) continue;

            const score = try self.computeJaccard(target_node.content, other_node.content);
            if (score > 0) {
                try scores.append(self.allocator, .{ .node = other_node, .score = score });
            }
        }

        // Sort by score DESC
        const Sorter = struct {
            pub fn lessThan(_: void, lhs: ScoreResult, rhs: ScoreResult) bool {
                return lhs.score > rhs.score;
            }
        };
        std.mem.sort(ScoreResult, scores.items, {}, Sorter.lessThan);

        const real_limit = if (scores.items.len < limit) scores.items.len else limit;
        return try self.allocator.dupe(ScoreResult, scores.items[0..real_limit]);
    }

    fn computeJaccard(self: *Graph, content1: []const u8, content2: []const u8) !f32 {
        var set1 = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = set1.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            set1.deinit();
        }
        var set2 = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = set2.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            set2.deinit();
        }

        var words1 = std.mem.tokenizeAny(u8, content1, " \n\r\t.,!?;:()[]{}");
        while (words1.next()) |word| {
            if (word.len > 3) {
                const lower = try self.allocator.alloc(u8, word.len);
                for (word, 0..) |c, i| lower[i] = std.ascii.toLower(c);
                if (set1.contains(lower)) {
                    self.allocator.free(lower);
                } else {
                    try set1.put(lower, {});
                }
            }
        }

        var words2 = std.mem.tokenizeAny(u8, content2, " \n\r\t.,!?;:()[]{}");
        while (words2.next()) |word| {
            if (word.len > 3) {
                const lower = try self.allocator.alloc(u8, word.len);
                for (word, 0..) |c, i| lower[i] = std.ascii.toLower(c);
                if (set2.contains(lower)) {
                    self.allocator.free(lower);
                } else {
                    try set2.put(lower, {});
                }
            }
        }

        if (set1.count() == 0 or set2.count() == 0) return 0.0;

        var intersection: usize = 0;
        var it1 = set1.keyIterator();
        while (it1.next()) |key| {
            if (set2.contains(key.*)) {
                intersection += 1;
            }
        }

        const union_size = set1.count() + set2.count() - intersection;
        return @as(f32, @floatFromInt(intersection)) / @as(f32, @floatFromInt(union_size));
    }
};
