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
        self.* = undefined;
    }

    pub fn addNode(self: *Graph, node: parser.Node) !void {
        const key = try self.allocator.dupe(u8, node.path);
        try self.nodes.put(key, node);
    }

    pub fn getContext(self: *Graph, path: []const u8) ![]const u8 {
        const node = self.nodes.get(path) orelse return error.NodeNotFound;
        var context: std.ArrayList(u8) = .{};
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

        return context.toOwnedSlice(self.allocator);
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

        var queue: std.ArrayList(*parser.Node) = .{};
        defer queue.deinit(self.allocator);

        var parent_map = std.AutoHashMap(*parser.Node, *parser.Node).init(self.allocator);
        defer parent_map.deinit();

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
                        try parent_map.put(neighbor, current);
                        try queue.append(self.allocator, neighbor);
                    }
                }
            }
        }

        if (!found) return null;

        var path: std.ArrayList([]const u8) = .{};
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
        nodes: std.ArrayList(*parser.Node),

        pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
            self.nodes.deinit(allocator);
            self.* = undefined;
        }
    };

    pub const ScoreResult = struct {
        node: *parser.Node,
        score: f32,
    };

    /// Pre-computed word set for a node. Avoids re-tokenizing content
    /// on every pairwise Jaccard comparison.
    pub const WordSet = struct {
        words: std.StringHashMap(void),

        pub fn deinit(self: *WordSet) void {
            var it = self.words.keyIterator();
            while (it.next()) |key| self.words.allocator.free(key.*);
            self.words.deinit();
            self.* = undefined;
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

        var clusters: std.ArrayList(Cluster) = .{};
        defer clusters.deinit(self.allocator);

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const start_node = entry.value_ptr;
            if (visited.contains(start_node)) continue;

            var cluster: Cluster = .{ .nodes = .{} };
            var queue: std.ArrayList(*parser.Node) = .{};
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

        return clusters.toOwnedSlice(self.allocator);
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

    pub fn generateMoc(self: *Graph) ![]const u8 {
        // Use Louvain for better community structure
        var communities = try self.detectLouvainCommunities(10);
        defer communities.deinit();

        // Group nodes by community ID
        var groups = std.AutoHashMap(usize, std.ArrayList([]const u8)).init(self.allocator);
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

        var moc: std.ArrayList(u8) = .{};
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

        return moc.toOwnedSlice(self.allocator);
    }

    /// Generate CSV map of the knowledge graph.
    /// Format: id,name,tags,summary,problem,solution,action,causeIds,effectIds,nextPartOfIds,previousPartOfIds
    /// - causeIds: documents that caused this one (backlinks)
    /// - effectIds: documents this one caused (outgoing links)
    /// - nextPartOfIds: next part/continuation documents (from metadata)
    /// - previousPartOfIds: previous part documents (from metadata)
    pub fn generateMapCsv(self: *Graph) ![]const u8 {
        var csv: std.ArrayList(u8) = .{};
        defer csv.deinit(self.allocator);

        // Write header
        try csv.writer(self.allocator).print("id,name,tags,summary,problem,solution,action,causeIds,effectIds,nextPartOfIds,previousPartOfIds\n", .{});

        var node_it = self.nodes.iterator();
        while (node_it.next()) |entry| {
            const node = entry.value_ptr;

            // id
            try csv.writer(self.allocator).print("{s},", .{node.id});

            // name (escape commas if present)
            try self.writeCsvField(&csv, node.title);
            try csv.append(self.allocator, ',');

            // tags (comma-separated, wrapped in quotes if multiple)
            try self.writeCsvTags(&csv, node);
            try csv.append(self.allocator, ',');

            // summary (from metadata or first line of content)
            const summary = node.metadata.get("summary") orelse "";
            try self.writeCsvField(&csv, summary);
            try csv.append(self.allocator, ',');

            // problem (optional)
            const problem = node.metadata.get("problem") orelse "";
            try self.writeCsvField(&csv, problem);
            try csv.append(self.allocator, ',');

            // solution (optional)
            const solution = node.metadata.get("solution") orelse "";
            try self.writeCsvField(&csv, solution);
            try csv.append(self.allocator, ',');

            // action (optional)
            const action = node.metadata.get("action") orelse "";
            try self.writeCsvField(&csv, action);
            try csv.append(self.allocator, ',');

            // causeIds (backlinks - documents that link TO this node)
            try self.writeCsvIdList(&csv, node.backlinks.items);
            try csv.append(self.allocator, ',');

            // effectIds (outgoing links - documents this node links TO)
            try self.writeCsvLinkIdList(&csv, node.links.items);
            try csv.append(self.allocator, ',');

            // nextPartOfIds (from metadata - single title or comma-separated)
            const next_part = node.metadata.get("nextPartOf") orelse "";
            try self.writeCsvTitleToId(&csv, next_part);
            try csv.append(self.allocator, ',');

            // previousPartOfIds (from metadata - single title or comma-separated)
            const prev_part = node.metadata.get("previousPartOf") orelse "";
            try self.writeCsvTitleToId(&csv, prev_part);
            try csv.append(self.allocator, '\n');
        }

        return csv.toOwnedSlice(self.allocator);
    }

    /// Write a title string to ID lookup (handles single or comma-separated titles)
    fn writeCsvTitleToId(self: *Graph, csv: *std.ArrayList(u8), titles_str: []const u8) !void {
        if (titles_str.len == 0) return;

        // Check if comma-separated (wrapped in quotes or not)
        const has_comma = std.mem.indexOf(u8, titles_str, ",") != null;

        if (!has_comma) {
            // Single title
            if (self.findNodeByTitle(titles_str)) |node| {
                try csv.appendSlice(self.allocator, node.id);
            }
        } else {
            // Multiple titles - parse and look up each
            try csv.append(self.allocator, '"');
            var first = true;
            var it = std.mem.tokenizeAny(u8, titles_str, ",");
            while (it.next()) |title| {
                const trimmed = std.mem.trim(u8, title, " \"");
                if (self.findNodeByTitle(trimmed)) |node| {
                    if (!first) try csv.append(self.allocator, ',');
                    first = false;
                    try csv.appendSlice(self.allocator, node.id);
                }
            }
            try csv.append(self.allocator, '"');
        }
    }

    /// Write a CSV field, escaping quotes and wrapping in quotes if contains comma/newline
    fn writeCsvField(self: *Graph, csv: *std.ArrayList(u8), field: []const u8) !void {
        const needs_quote = std.mem.indexOf(u8, field, ",") != null or
            std.mem.indexOf(u8, field, "\"") != null or
            std.mem.indexOf(u8, field, "\n") != null;

        if (needs_quote) {
            try csv.append(self.allocator, '"');
            // Escape internal quotes by doubling them
            var i: usize = 0;
            while (i < field.len) : (i += 1) {
                if (field[i] == '"') {
                    try csv.append(self.allocator, '"');
                    try csv.append(self.allocator, '"');
                } else {
                    try csv.append(self.allocator, field[i]);
                }
            }
            try csv.append(self.allocator, '"');
        } else {
            try csv.appendSlice(self.allocator, field);
        }
    }

    /// Write tags as comma-separated list, wrapped in quotes if multiple
    fn writeCsvTags(self: *Graph, csv: *std.ArrayList(u8), node: *const parser.Node) !void {
        if (node.tags.items.len == 0) {
            return;
        } else if (node.tags.items.len == 1) {
            try csv.appendSlice(self.allocator, node.tags.items[0]);
        } else {
            try csv.append(self.allocator, '"');
            for (node.tags.items, 0..) |tag, i| {
                if (i > 0) try csv.append(self.allocator, ',');
                try csv.appendSlice(self.allocator, tag);
            }
            try csv.append(self.allocator, '"');
        }
    }

    /// Write list of titles as UUID list (look up IDs from titles)
    fn writeCsvIdList(self: *Graph, csv: *std.ArrayList(u8), titles: []const []const u8) !void {
        if (titles.len == 0) return;

        if (titles.len == 1) {
            if (self.findNodeByTitle(titles[0])) |node| {
                try csv.appendSlice(self.allocator, node.id);
            }
        } else {
            try csv.append(self.allocator, '"');
            var first = true;
            for (titles) |title| {
                if (self.findNodeByTitle(title)) |node| {
                    if (!first) try csv.append(self.allocator, ',');
                    first = false;
                    try csv.appendSlice(self.allocator, node.id);
                }
            }
            try csv.append(self.allocator, '"');
        }
    }

    /// Write list of Link targets as UUID list
    fn writeCsvLinkIdList(self: *Graph, csv: *std.ArrayList(u8), links: []const parser.Link) !void {
        if (links.len == 0) return;

        if (links.len == 1) {
            if (self.findNodeByTitle(links[0].target)) |node| {
                try csv.appendSlice(self.allocator, node.id);
            }
        } else {
            try csv.append(self.allocator, '"');
            var first = true;
            for (links) |link| {
                if (self.findNodeByTitle(link.target)) |node| {
                    if (!first) try csv.append(self.allocator, ',');
                    first = false;
                    try csv.appendSlice(self.allocator, node.id);
                }
            }
            try csv.append(self.allocator, '"');
        }
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

        var scores: std.ArrayList(ScoreResult) = .{};
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
        return self.allocator.dupe(ScoreResult, scores.items[0..real_limit]);
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

        var suggestions: std.ArrayList(LinkSuggestion) = .{};
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
        return self.allocator.dupe(LinkSuggestion, suggestions.items[0..real_limit]);
    }

    pub fn exportGraphJson(self: *Graph) ![]const u8 {
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

        const graph_obj: GraphObj = .{
            .nodes = nodes_arr.items,
            .links = links_arr.items,
        };

        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();

        var jw: std.json.Stringify = .{
            .writer = &writer.writer,
        };

        try jw.write(graph_obj);

        return writer.toOwnedSlice();
    }

    pub const GcReport = struct {
        orphans: std.ArrayList(*parser.Node),
        islands: std.ArrayList(Cluster),

        pub fn deinit(self: *GcReport, allocator: std.mem.Allocator) void {
            self.orphans.deinit(allocator);
            for (self.islands.items) |*c| c.deinit(allocator);
            self.islands.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn getGcReport(self: *Graph, island_threshold: usize) !GcReport {
        const clusters = try self.detectClusters();
        defer self.allocator.free(clusters);

        var report: GcReport = .{
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

test "Graph: basic operations and backlink resolution" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    var node1: parser.Node = .{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, "Links to [[B]]"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node1.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });

    const node2: parser.Node = .{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, "No links"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };

    try graph.addNode(node1);
    try graph.addNode(node2);

    try graph.resolveBacklinks();

    const b = graph.findNodeByTitle("B").?;
    try std.testing.expectEqual(@as(usize, 1), b.backlinks.items.len);
    try std.testing.expectEqualStrings("A", b.backlinks.items[0]);
}

test "Graph: findShortestPath" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // A -> B -> C
    // A -> D -> C
    // E (isolated)

    const titles = [_][]const u8{ "A", "B", "C", "D", "E" };
    for (titles) |title| {
        const path = try std.fmt.allocPrint(allocator, "{s}.md", .{title});
        const id = try std.fmt.allocPrint(allocator, "uuid-{s}", .{title});
        try graph.addNode(.{
            .path = try allocator.dupe(u8, path),
            .title = try allocator.dupe(u8, title),
            .id = id,
            .content = try allocator.dupe(u8, ""),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
        });
        allocator.free(path);
    }

    try graph.findNodeByTitle("A").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });
    try graph.findNodeByTitle("B").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "C"), .nature = null });
    try graph.findNodeByTitle("A").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "D"), .nature = null });
    try graph.findNodeByTitle("D").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "C"), .nature = null });

    const path = (try graph.findShortestPath("A", "C")).?;
    defer {
        for (path) |p| allocator.free(p);
        allocator.free(path);
    }

    try std.testing.expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqualStrings("A", path[0]);
    try std.testing.expectEqualStrings("C", path[2]);
    // Could be B or D
    try std.testing.expect(std.mem.eql(u8, path[1], "B") or std.mem.eql(u8, path[1], "D"));

    try std.testing.expect((try graph.findShortestPath("A", "E")) == null);
}

test "Graph: computePageRank" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Star graph: B, C, D all link to A
    const titles = [_][]const u8{ "A", "B", "C", "D" };
    for (titles) |title| {
        try graph.addNode(.{
            .path = try allocator.dupe(u8, title),
            .title = try allocator.dupe(u8, title),
            .id = try std.fmt.allocPrint(allocator, "uuid-{s}", .{title}),
            .content = try allocator.dupe(u8, ""),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
        });
    }

    try graph.findNodeByTitle("B").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "A"), .nature = null });
    try graph.findNodeByTitle("C").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "A"), .nature = null });
    try graph.findNodeByTitle("D").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "A"), .nature = null });

    try graph.resolveBacklinks();

    var pr = try graph.computePageRank(10);
    defer pr.deinit();

    const score_a = pr.get("A").?;
    const score_b = pr.get("B").?;

    // A should have higher rank than B because everyone links to A
    try std.testing.expect(score_a > score_b);
}

test "Graph: detectClusters" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Two isolated pairs: (A-B) and (C-D)
    const titles = [_][]const u8{ "A", "B", "C", "D" };
    for (titles) |title| {
        try graph.addNode(.{
            .path = try allocator.dupe(u8, title),
            .title = try allocator.dupe(u8, title),
            .id = try std.fmt.allocPrint(allocator, "uuid-{s}", .{title}),
            .content = try allocator.dupe(u8, ""),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
        });
    }

    try graph.findNodeByTitle("A").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });
    try graph.findNodeByTitle("C").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "D"), .nature = null });

    try graph.resolveBacklinks();

    const clusters = try graph.detectClusters();
    defer {
        for (clusters) |*c| c.deinit(allocator);
        allocator.free(clusters);
    }

    try std.testing.expectEqual(@as(usize, 2), clusters.len);
}

test "Graph: getContext with metadata and tags" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    var node: parser.Node = .{
        .path = try allocator.dupe(u8, "test.md"),
        .title = try allocator.dupe(u8, "Test Note"),
        .id = try allocator.dupe(u8, "uuid-test"),
        .content = try allocator.dupe(u8, "Content here"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node.metadata.put(try allocator.dupe(u8, "author"), try allocator.dupe(u8, "Alice"));
    try node.tags.append(allocator, try allocator.dupe(u8, "important"));
    try node.links.append(allocator, .{ .target = try allocator.dupe(u8, "Other"), .nature = null });

    try graph.addNode(node);

    const context = try graph.getContext("test.md");
    defer allocator.free(context);

    try std.testing.expect(std.mem.indexOf(u8, context, "Test Note") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "author") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "#important") != null);
    try std.testing.expect(std.mem.indexOf(u8, context, "Unresolved") != null);
}

test "Graph: getContext NodeNotFound error" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    const result = graph.getContext("nonexistent.md");
    try std.testing.expectError(error.NodeNotFound, result);
}

test "Graph: findSimilarNodes with similar content" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, "programming software development code"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, "programming software engineering code"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "c.md"),
        .title = try allocator.dupe(u8, "C"),
        .id = try allocator.dupe(u8, "uuid-c"),
        .content = try allocator.dupe(u8, "cooking recipes food kitchen"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    const similar = try graph.findSimilarNodes("A", 5);
    defer allocator.free(similar);

    // B should be similar to A (shared words), C should not
    try std.testing.expect(similar.len >= 1);
    try std.testing.expectEqualStrings("B", similar[0].node.title);
    try std.testing.expect(similar[0].score > 0);
}

test "Graph: findSimilarNodes NodeNotFound error" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    const result = graph.findSimilarNodes("nonexistent", 5);
    try std.testing.expectError(error.NodeNotFound, result);
}

test "Graph: suggestLinks finds unlinked similar nodes" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Two similar nodes with no explicit link
    try graph.addNode(.{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, "machine learning artificial intelligence algorithms"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, "machine learning artificial intelligence neural networks"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    const suggestions = try graph.suggestLinks(0.3, 10);
    defer allocator.free(suggestions);

    // Should suggest link between A and B (similar but not linked)
    try std.testing.expect(suggestions.len >= 1);
}

test "Graph: suggestLinks excludes already linked nodes" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    var node_a: parser.Node = .{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, "machine learning artificial intelligence"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node_a.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });
    try graph.addNode(node_a);

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, "machine learning artificial intelligence"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    const suggestions = try graph.suggestLinks(0.3, 10);
    defer allocator.free(suggestions);

    // Should not suggest A-B since they're already linked
    for (suggestions) |s| {
        try std.testing.expect(!(std.mem.eql(u8, s.source.title, "A") and std.mem.eql(u8, s.target.title, "B")));
        try std.testing.expect(!(std.mem.eql(u8, s.source.title, "B") and std.mem.eql(u8, s.target.title, "A")));
    }
}

test "Graph: generateMoc creates map of content" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Create connected graph
    try graph.addNode(.{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    var node_b: parser.Node = .{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node_b.links.append(allocator, .{ .target = try allocator.dupe(u8, "A"), .nature = null });
    try graph.addNode(node_b);

    try graph.resolveBacklinks();

    const moc = try graph.generateMoc();
    defer allocator.free(moc);

    try std.testing.expect(std.mem.indexOf(u8, moc, "Map of Content") != null);
    try std.testing.expect(std.mem.indexOf(u8, moc, "Community") != null);
}

test "Graph: generateMapCsv creates CSV with all fields" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Node A with metadata and tags
    var node_a: parser.Node = .{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, "Content A"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node_a.metadata.put(try allocator.dupe(u8, "summary"), try allocator.dupe(u8, "Summary A"));
    try node_a.metadata.put(try allocator.dupe(u8, "problem"), try allocator.dupe(u8, "Problem A"));
    try node_a.metadata.put(try allocator.dupe(u8, "solution"), try allocator.dupe(u8, "Solution A"));
    try node_a.metadata.put(try allocator.dupe(u8, "action"), try allocator.dupe(u8, "Action A"));
    try node_a.metadata.put(try allocator.dupe(u8, "nextPartOf"), try allocator.dupe(u8, "B"));
    try node_a.tags.append(allocator, try allocator.dupe(u8, "tag1"));
    try node_a.tags.append(allocator, try allocator.dupe(u8, "tag2"));
    try node_a.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });
    try graph.addNode(node_a);

    // Node B with previousPartOf
    var node_b: parser.Node = .{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, "Content B"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node_b.metadata.put(try allocator.dupe(u8, "summary"), try allocator.dupe(u8, "Summary B"));
    try node_b.metadata.put(try allocator.dupe(u8, "previousPartOf"), try allocator.dupe(u8, "A"));
    try node_b.tags.append(allocator, try allocator.dupe(u8, "tag3"));
    try graph.addNode(node_b);

    try graph.resolveBacklinks();

    const csv = try graph.generateMapCsv();
    defer allocator.free(csv);

    // Verify header
    try std.testing.expect(std.mem.indexOf(u8, csv, "id,name,tags,summary,problem,solution,action,causeIds,effectIds,nextPartOfIds,previousPartOfIds") != null);

    // Verify node A row
    try std.testing.expect(std.mem.indexOf(u8, csv, "uuid-a,A,\"tag1,tag2\",Summary A,Problem A,Solution A,Action A,,uuid-b,uuid-b,") != null);

    // Verify node B row with backlink and previousPartOfIds
    try std.testing.expect(std.mem.indexOf(u8, csv, "uuid-b,B,tag3,Summary B,,,,uuid-a,,,uuid-a") != null);
}

test "Graph: detectLouvainCommunities groups connected nodes" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Create two communities: (A-B-C) and (D-E)
    const titles = [_][]const u8{ "A", "B", "C", "D", "E" };
    for (titles) |title| {
        try graph.addNode(.{
            .path = try allocator.dupe(u8, title),
            .title = try allocator.dupe(u8, title),
            .id = try std.fmt.allocPrint(allocator, "uuid-{s}", .{title}),
            .content = try allocator.dupe(u8, ""),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
        });
    }

    // Community 1: A <-> B <-> C
    try graph.findNodeByTitle("A").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });
    try graph.findNodeByTitle("B").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "C"), .nature = null });

    // Community 2: D <-> E
    try graph.findNodeByTitle("D").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "E"), .nature = null });

    try graph.resolveBacklinks();

    var communities = try graph.detectLouvainCommunities(10);
    defer communities.deinit();

    // All nodes should have a community assignment
    try std.testing.expectEqual(@as(usize, 5), communities.count());
}

test "Graph: exportGraphJson produces valid JSON" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    var node_a: parser.Node = .{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node_a.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = try allocator.dupe(u8, "supports") });
    try graph.addNode(node_a);

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try graph.resolveBacklinks();

    const json = try graph.exportGraphJson();
    defer allocator.free(json);

    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"links\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"supports\"") != null);
}

test "Graph: getGcReport identifies orphans and islands" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // Orphan: single node with no connections
    try graph.addNode(.{
        .path = try allocator.dupe(u8, "orphan.md"),
        .title = try allocator.dupe(u8, "Orphan"),
        .id = try allocator.dupe(u8, "uuid-orphan"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    // Small island: two connected nodes
    var island_a: parser.Node = .{
        .path = try allocator.dupe(u8, "island_a.md"),
        .title = try allocator.dupe(u8, "IslandA"),
        .id = try allocator.dupe(u8, "uuid-island-a"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try island_a.links.append(allocator, .{ .target = try allocator.dupe(u8, "IslandB"), .nature = null });
    try graph.addNode(island_a);

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "island_b.md"),
        .title = try allocator.dupe(u8, "IslandB"),
        .id = try allocator.dupe(u8, "uuid-island-b"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try graph.resolveBacklinks();

    var report = try graph.getGcReport(3);
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.orphans.items.len);
    try std.testing.expectEqual(@as(usize, 1), report.islands.items.len);
}

test "Graph: empty graph operations" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    try std.testing.expect((try graph.findShortestPath("A", "B")) == null);
    try std.testing.expect(graph.findNodeByTitle("NonExistent") == null);

    var pr = try graph.computePageRank(5);
    defer pr.deinit();
    try std.testing.expectEqual(@as(usize, 0), pr.count());

    const clusters = try graph.detectClusters();
    defer {
        for (clusters) |*c| c.deinit(allocator);
        allocator.free(clusters);
    }
    try std.testing.expectEqual(@as(usize, 0), clusters.len);
}

test "Graph: single node graph" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "solo.md"),
        .title = try allocator.dupe(u8, "Solo"),
        .id = try allocator.dupe(u8, "uuid-solo"),
        .content = try allocator.dupe(u8, "content"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    // Path to self
    const path = (try graph.findShortestPath("Solo", "Solo")).?;
    defer {
        for (path) |p| allocator.free(p);
        allocator.free(path);
    }
    try std.testing.expectEqual(@as(usize, 1), path.len);
    try std.testing.expectEqualStrings("Solo", path[0]);

    // Single cluster
    const clusters = try graph.detectClusters();
    defer {
        for (clusters) |*c| c.deinit(allocator);
        allocator.free(clusters);
    }
    try std.testing.expectEqual(@as(usize, 1), clusters.len);
    try std.testing.expectEqual(@as(usize, 1), clusters[0].nodes.items.len);
}

test "Graph: circular reference handling" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    // A -> B -> C -> A (circular)
    const titles = [_][]const u8{ "A", "B", "C" };
    for (titles) |title| {
        try graph.addNode(.{
            .path = try allocator.dupe(u8, title),
            .title = try allocator.dupe(u8, title),
            .id = try std.fmt.allocPrint(allocator, "uuid-{s}", .{title}),
            .content = try allocator.dupe(u8, ""),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
        });
    }

    try graph.findNodeByTitle("A").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = null });
    try graph.findNodeByTitle("B").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "C"), .nature = null });
    try graph.findNodeByTitle("C").?.links.append(allocator, .{ .target = try allocator.dupe(u8, "A"), .nature = null });

    try graph.resolveBacklinks();

    // Should find path even with cycle
    const path = (try graph.findShortestPath("A", "C")).?;
    defer {
        for (path) |p| allocator.free(p);
        allocator.free(path);
    }
    try std.testing.expect(path.len >= 2);

    // Should be one cluster (all connected)
    const clusters = try graph.detectClusters();
    defer {
        for (clusters) |*c| c.deinit(allocator);
        allocator.free(clusters);
    }
    try std.testing.expectEqual(@as(usize, 1), clusters.len);
}

test "Graph: findShortestPath with link nature" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    var node_a: parser.Node = .{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "A"),
        .id = try allocator.dupe(u8, "uuid-a"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node_a.links.append(allocator, .{ .target = try allocator.dupe(u8, "B"), .nature = try allocator.dupe(u8, "supports") });
    try graph.addNode(node_a);

    try graph.addNode(.{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    const path = (try graph.findShortestPath("A", "B")).?;
    defer {
        for (path) |p| allocator.free(p);
        allocator.free(path);
    }

    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectEqualStrings("A", path[0]);
    try std.testing.expectEqualStrings("B", path[1]);
}

test "Graph: resolveBacklinks with .md extension stripping" {
    const allocator = std.testing.allocator;
    var graph = Graph.init(allocator);
    defer graph.deinit();

    const node_a: parser.Node = .{
        .path = try allocator.dupe(u8, "a.md"),
        .title = try allocator.dupe(u8, "target.md"), // Title has .md
        .id = try allocator.dupe(u8, "uuid-target"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try graph.addNode(node_a);

    var node_b: parser.Node = .{
        .path = try allocator.dupe(u8, "b.md"),
        .title = try allocator.dupe(u8, "B"),
        .id = try allocator.dupe(u8, "uuid-b"),
        .content = try allocator.dupe(u8, ""),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    // Link to "target" (without .md) should still resolve to "target.md"
    try node_b.links.append(allocator, .{ .target = try allocator.dupe(u8, "target"), .nature = null });
    try graph.addNode(node_b);

    try graph.resolveBacklinks();

    const target = graph.findNodeByTitle("target.md").?;
    try std.testing.expectEqual(@as(usize, 1), target.backlinks.items.len);
    try std.testing.expectEqualStrings("B", target.backlinks.items[0]);
}
