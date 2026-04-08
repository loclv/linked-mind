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
                try context.writer(self.allocator).print("#{s}{s}", .{ tag, if (i == node.tags.items.len - 1) "" else ", " });
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
                        try context.writer(self.allocator).print("- OUT ({s}): [[{s}]] (Found: {s})\n", .{ nat, link.target, other.path });
                    } else {
                        try context.writer(self.allocator).print("- OUT: [[{s}]] (Found: {s})\n", .{ link.target, other.path });
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (link.nature) |nat| {
                    try context.writer(self.allocator).print("- OUT ({s}): [[{s}]] (Unresolved)\n", .{ nat, link.target });
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
        var title_map = std.StringHashMap(*parser.Node).init(self.allocator);
        defer title_map.deinit();

        // 1. Build title map for O(1) resolution
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try title_map.put(entry.value_ptr.title, entry.value_ptr);
            // Also store title without extension if it ends in .md
            if (std.mem.endsWith(u8, entry.value_ptr.title, ".md")) {
                const no_ext = entry.value_ptr.title[0 .. entry.value_ptr.title.len - 3];
                try title_map.put(no_ext, entry.value_ptr);
            }
        }

        // 2. Resolve using map
        it = self.nodes.iterator();
        while (it.next()) |entry| {
            const source_node = entry.value_ptr;

            for (source_node.links.items) |link| {
                if (title_map.get(link.target)) |target_node| {
                    const source_desc = try self.allocator.dupe(u8, source_node.title);
                    try target_node.backlinks.append(self.allocator, source_desc);
                } else {
                    // Fallback to fuzzy match (indexOf) for nodes not found by exact/no-ext title
                    var fuzzy_it = self.nodes.iterator();
                    while (fuzzy_it.next()) |target_entry| {
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
    }

    /// Computes PageRank for all nodes in the graph
    pub fn computePageRank(self: *Graph, iterations: usize) !std.StringHashMap(f32) {
        var pr_scores = std.StringHashMap(f32).init(self.allocator);
        const damping = 0.85;
        const total_nodes = @as(f32, @floatFromInt(self.nodes.count()));

        // Initial scores
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try pr_scores.put(entry.value_ptr.title, 1.0 / total_nodes);
        }

        for (0..iterations) |_| {
            var new_scores = std.StringHashMap(f32).init(self.allocator);
            errdefer new_scores.deinit();

            const base_pr = (1.0 - damping) / total_nodes;

            it = self.nodes.iterator();
            while (it.next()) |entry| {
                const node = entry.value_ptr;
                var rank_sum: f32 = 0.0;

                // Sum up contributions from nodes that link to this one
                for (node.backlinks.items) |source_title| {
                    if (self.findNodeByTitle(source_title)) |source_node| {
                        const source_pr = pr_scores.get(source_node.title) orelse 0.0;
                        const outbound_count = @as(f32, @floatFromInt(source_node.links.items.len));
                        if (outbound_count > 0) {
                            rank_sum += source_pr / outbound_count;
                        }
                    }
                }

                try new_scores.put(node.title, base_pr + damping * rank_sum);
            }

            pr_scores.deinit();
            pr_scores = new_scores;
        }

        return pr_scores;
    }

    pub const Cluster = struct {
        nodes: std.ArrayListUnmanaged(*parser.Node),

        pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
            self.nodes.deinit(allocator);
        }
    };

    pub const ScoreResult = struct { node: *parser.Node, score: f32 };

    /// Pre-computed word set for a node. Avoids re-tokenizing content
    /// on every pairwise Jaccard comparison.
    pub const WordSet = struct {
        words: std.StringHashMap(void),

        pub fn deinit(self: *WordSet) void {
            var it = self.words.keyIterator();
            while (it.next()) |key| self.words.allocator.free(key.*);
            self.words.deinit();
        }
    };

    /// Tokenize content into a set of lowercased words (len > 3).
    /// Caller owns the returned WordSet and must call deinit.
    fn buildWordSet(self: *Graph, content: []const u8) !WordSet {
        var set = std.StringHashMap(void).init(self.allocator);
        errdefer {
            var it = set.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            set.deinit();
        }

        var words = std.mem.tokenizeAny(u8, content, " \n\r\t.,!?;:()[]{}\"'#*-_/\\@<>");
        while (words.next()) |word| {
            if (word.len > 3) {
                const lower = try self.allocator.alloc(u8, word.len);
                for (word, 0..) |c, i| lower[i] = std.ascii.toLower(c);
                if (set.contains(lower)) {
                    self.allocator.free(lower);
                } else {
                    try set.put(lower, {});
                }
            }
        }

        return .{ .words = set };
    }

    /// Compute Jaccard similarity between two pre-computed word sets.
    /// Avoids allocating anything -- pure read-only comparison.
    fn jaccardFromSets(set_a: *const std.StringHashMap(void), set_b: *const std.StringHashMap(void)) f32 {
        const count_a = set_a.count();
        const count_b = set_b.count();
        if (count_a == 0 or count_b == 0) return 0.0;

        var intersection: usize = 0;
        var it = set_a.keyIterator();
        while (it.next()) |key| {
            if (set_b.contains(key.*)) intersection += 1;
        }

        const union_size = count_a + count_b - intersection;
        return @as(f32, @floatFromInt(intersection)) / @as(f32, @floatFromInt(union_size));
    }

    /// Weakly Connected Components -- used as a baseline for Louvain init
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

                for (current.links.items) |link| {
                    if (self.findNodeByTitle(link.target)) |neighbor| {
                        if (!visited.contains(neighbor)) {
                            try visited.put(neighbor, {});
                            try queue.append(self.allocator, neighbor);
                            try cluster.nodes.append(self.allocator, neighbor);
                        }
                    }
                }

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

    /// Louvain-style modularity-based community detection.
    /// Assigns each node to the community that maximizes local modularity gain.
    /// Returns a map from node title -> community ID.
    pub fn detectLouvainCommunities(self: *Graph, max_iterations: usize) !std.StringHashMap(usize) {
        var community = std.StringHashMap(usize).init(self.allocator);
        errdefer community.deinit();

        // Total edges in graph (treat as undirected: count each link once)
        var total_edges: usize = 0;

        // Initialize: each node starts in its own community
        var idx: usize = 0;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            try community.put(entry.value_ptr.title, idx);
            total_edges += entry.value_ptr.links.items.len;
            idx += 1;
        }

        if (total_edges == 0) return community;
        const m = @as(f64, @floatFromInt(total_edges));

        // Build degree map (outgoing + incoming)
        var degree = std.StringHashMap(usize).init(self.allocator);
        defer degree.deinit();

        it = self.nodes.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr;
            const deg = node.links.items.len + node.backlinks.items.len;
            try degree.put(node.title, deg);
        }

        // Iteratively reassign nodes to maximize modularity
        for (0..max_iterations) |_| {
            var changed = false;

            it = self.nodes.iterator();
            while (it.next()) |entry| {
                const node = entry.value_ptr;
                const current_comm = community.get(node.title) orelse continue;
                const ki = @as(f64, @floatFromInt(degree.get(node.title) orelse 0));

                var best_comm = current_comm;
                var best_gain: f64 = 0.0;

                // Collect neighbor communities and count links to each
                var comm_links = std.AutoHashMap(usize, usize).init(self.allocator);
                defer comm_links.deinit();

                for (node.links.items) |link| {
                    if (self.findNodeByTitle(link.target)) |neighbor| {
                        const nc = community.get(neighbor.title) orelse continue;
                        const prev = comm_links.get(nc) orelse 0;
                        try comm_links.put(nc, prev + 1);
                    }
                }

                for (node.backlinks.items) |btitle| {
                    if (self.findNodeByTitle(btitle)) |neighbor| {
                        const nc = community.get(neighbor.title) orelse continue;
                        const prev = comm_links.get(nc) orelse 0;
                        try comm_links.put(nc, prev + 1);
                    }
                }

                // Evaluate modularity gain for each neighbor community
                var cl_it = comm_links.iterator();
                while (cl_it.next()) |cl_entry| {
                    const target_comm = cl_entry.key_ptr.*;
                    if (target_comm == current_comm) continue;

                    const ki_in = @as(f64, @floatFromInt(cl_entry.value_ptr.*));

                    // Sum of degrees in target community
                    var sigma_tot: f64 = 0.0;
                    var node_it2 = self.nodes.iterator();
                    while (node_it2.next()) |e2| {
                        if ((community.get(e2.value_ptr.title) orelse 0) == target_comm) {
                            sigma_tot += @as(f64, @floatFromInt(degree.get(e2.value_ptr.title) orelse 0));
                        }
                    }

                    // Simplified modularity gain: delta_Q = ki_in/m - sigma_tot*ki/(2*m^2)
                    const gain = ki_in / m - (sigma_tot * ki) / (2.0 * m * m);
                    if (gain > best_gain) {
                        best_gain = gain;
                        best_comm = target_comm;
                    }
                }

                if (best_comm != current_comm) {
                    try community.put(node.title, best_comm);
                    changed = true;
                }
            }

            if (!changed) break;
        }

        return community;
    }

    pub fn generateMOC(self: *Graph) ![]const u8 {
        // Use Louvain for better community structure
        var communities = try self.detectLouvainCommunities(10);
        defer communities.deinit();

        // Group nodes by community ID
        var groups = std.AutoHashMap(usize, std.ArrayListUnmanaged([]const u8)).init(self.allocator);
        defer {
            var g_it = groups.valueIterator();
            while (g_it.next()) |v| v.deinit(self.allocator);
            groups.deinit();
        }

        var c_it = communities.iterator();
        while (c_it.next()) |entry| {
            const gop = try groups.getOrPut(entry.value_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(self.allocator, entry.key_ptr.*);
        }

        var moc = std.ArrayListUnmanaged(u8){};
        defer moc.deinit(self.allocator);

        try moc.writer(self.allocator).print("# Map of Content (MOC)\n", .{});
        try moc.writer(self.allocator).print("Detected via Louvain community detection\n\n", .{});

        var group_it = groups.iterator();
        var cluster_num: usize = 1;
        while (group_it.next()) |entry| {
            try moc.writer(self.allocator).print("## Community {d} ({d} nodes)\n", .{ cluster_num, entry.value_ptr.items.len });
            for (entry.value_ptr.items) |title| {
                // Find the node to get its path
                if (self.findNodeByTitle(title)) |node| {
                    try moc.writer(self.allocator).print("- [[{s}]] ({s})\n", .{ title, node.path });
                } else {
                    try moc.writer(self.allocator).print("- [[{s}]]\n", .{title});
                }
            }
            try moc.writer(self.allocator).print("\n", .{});
            cluster_num += 1;
        }

        return try moc.toOwnedSlice(self.allocator);
    }

    pub fn findSimilarNodes(self: *Graph, target_title: []const u8, limit: usize) ![]ScoreResult {
        const target_node = self.findNodeByTitle(target_title) orelse return error.NodeNotFound;

        // Pre-compute word sets for all nodes (avoids redundant tokenization)
        var word_sets = std.AutoHashMap(*parser.Node, WordSet).init(self.allocator);
        defer {
            var ws_it = word_sets.valueIterator();
            while (ws_it.next()) |ws| ws.deinit();
            word_sets.deinit();
        }

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            try word_sets.put(entry.value_ptr, try self.buildWordSet(entry.value_ptr.content));
        }

        const target_ws = word_sets.getPtr(target_node) orelse return error.NodeNotFound;

        var scores = std.ArrayListUnmanaged(ScoreResult){};
        defer scores.deinit(self.allocator);

        node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const other_node = entry.value_ptr;
            if (other_node == target_node) continue;

            const other_ws = word_sets.getPtr(other_node) orelse continue;
            const score = jaccardFromSets(&target_ws.words, &other_ws.words);
            if (score > 0) {
                try scores.append(self.allocator, .{ .node = other_node, .score = score });
            }
        }

        const Sorter = struct {
            pub fn lessThan(_: void, lhs: ScoreResult, rhs: ScoreResult) bool {
                return lhs.score > rhs.score;
            }
        };
        std.mem.sort(ScoreResult, scores.items, {}, Sorter.lessThan);

        const real_limit = if (scores.items.len < limit) scores.items.len else limit;
        return try self.allocator.dupe(ScoreResult, scores.items[0..real_limit]);
    }

    /// Suggested link between two nodes that are content-similar but not explicitly linked
    pub const LinkSuggestion = struct {
        source: *parser.Node,
        target: *parser.Node,
        score: f32,
    };

    /// Analyze all node pairs and suggest links where content similarity
    /// is high (above threshold) but no explicit link exists.
    pub fn suggestLinks(self: *Graph, threshold: f32, limit: usize) ![]LinkSuggestion {
        // Pre-compute word sets once for all nodes
        var word_sets = std.AutoHashMap(*parser.Node, WordSet).init(self.allocator);
        defer {
            var ws_it = word_sets.valueIterator();
            while (ws_it.next()) |ws| ws.deinit();
            word_sets.deinit();
        }

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            try word_sets.put(entry.value_ptr, try self.buildWordSet(entry.value_ptr.content));
        }

        var suggestions = std.ArrayListUnmanaged(LinkSuggestion){};
        defer suggestions.deinit(self.allocator);

        // Check all pairs (avoiding duplicates by comparing pointer addresses)
        var it_a = self.nodes.iterator();
        while (it_a.next()) |entry_a| {
            const node_a = entry_a.value_ptr;
            const ws_a = word_sets.getPtr(node_a) orelse continue;

            var it_b = self.nodes.iterator();
            while (it_b.next()) |entry_b| {
                const node_b = entry_b.value_ptr;
                // Skip self and avoid duplicate pairs (only compare when A < B by pointer)
                if (node_a == node_b) continue;
                if (@intFromPtr(node_a) >= @intFromPtr(node_b)) continue;

                // Skip if already explicitly linked
                var already_linked = false;
                for (node_a.links.items) |link| {
                    if (std.mem.indexOf(u8, node_b.title, link.target) != null) {
                        already_linked = true;
                        break;
                    }
                }
                if (!already_linked) {
                    for (node_b.links.items) |link| {
                        if (std.mem.indexOf(u8, node_a.title, link.target) != null) {
                            already_linked = true;
                            break;
                        }
                    }
                }
                if (already_linked) continue;

                const ws_b = word_sets.getPtr(node_b) orelse continue;
                const score = jaccardFromSets(&ws_a.words, &ws_b.words);
                if (score >= threshold) {
                    try suggestions.append(self.allocator, .{
                        .source = node_a,
                        .target = node_b,
                        .score = score,
                    });
                }
            }
        }

        // Sort by score DESC
        const Sorter = struct {
            pub fn lessThan(_: void, lhs: LinkSuggestion, rhs: LinkSuggestion) bool {
                return lhs.score > rhs.score;
            }
        };
        std.mem.sort(LinkSuggestion, suggestions.items, {}, Sorter.lessThan);

        const real_limit = if (suggestions.items.len < limit) suggestions.items.len else limit;
        return try self.allocator.dupe(LinkSuggestion, suggestions.items[0..real_limit]);
    }

    pub fn exportGraphJSON(self: *Graph) ![]const u8 {
        const NodeObj = struct {
            id: []const u8,
            title: []const u8,
            group: usize,
            rank: f32,
        };

        const LinkObj = struct {
            source: []const u8,
            target: []const u8,
            type: []const u8,
        };

        const GraphObj = struct {
            nodes: []NodeObj,
            links: []LinkObj,
        };

        var nodes_arr: std.ArrayList(NodeObj) = .empty;
        defer nodes_arr.deinit(self.allocator);

        var links_arr: std.ArrayList(LinkObj) = .empty;
        defer links_arr.deinit(self.allocator);

        const clusters = try self.detectClusters();
        defer {
            for (clusters) |*c| c.deinit(self.allocator);
            self.allocator.free(clusters);
        }

        var node_to_group = std.AutoHashMap(*parser.Node, usize).init(self.allocator);
        defer node_to_group.deinit();

        for (clusters, 0..) |cluster, i| {
            for (cluster.nodes.items) |node| {
                try node_to_group.put(node, i + 1);
            }
        }

        var pr_scores = try self.computePageRank(10);
        defer pr_scores.deinit();

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const node = entry.value_ptr;
            const group = node_to_group.get(node) orelse 0;
            const rank = pr_scores.get(node.title) orelse 0.0;

            try nodes_arr.append(self.allocator, .{
                .id = node.title,
                .title = node.title,
                .group = group,
                .rank = rank,
            });

            for (node.links.items) |link| {
                try links_arr.append(self.allocator, .{
                    .source = node.title,
                    .target = link.target,
                    .type = link.nature orelse "link",
                });
            }
        }

        const graph_obj = GraphObj{
            .nodes = nodes_arr.items,
            .links = links_arr.items,
        };

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();

        var jw: std.json.Stringify = .{
            .writer = &writer.writer,
        };

        try jw.write(graph_obj);

        return try writer.toOwnedSlice();
    }

    pub const GCReport = struct {
        orphans: std.ArrayListUnmanaged(*parser.Node),
        islands: std.ArrayListUnmanaged(Cluster),

        pub fn deinit(self: *GCReport, allocator: std.mem.Allocator) void {
            self.orphans.deinit(allocator);
            for (self.islands.items) |*c| c.deinit(allocator);
            self.islands.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn getGCReport(self: *Graph, island_threshold: usize) !GCReport {
        const clusters = try self.detectClusters();
        defer self.allocator.free(clusters);

        var report: GCReport = .{
            .orphans = .{},
            .islands = .{},
        };

        for (clusters) |cluster| {
            if (cluster.nodes.items.len == 1) {
                try report.orphans.append(self.allocator, cluster.nodes.items[0]);
                // Free the cluster's list since we only took the node
                var mutable_cluster = cluster;
                mutable_cluster.deinit(self.allocator);
            } else if (cluster.nodes.items.len <= island_threshold) {
                try report.islands.append(self.allocator, cluster);
            } else {
                var mutable_cluster = cluster;
                mutable_cluster.deinit(self.allocator);
            }
        }

        return report;
    }
};
