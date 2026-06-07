const std = @import("std");
const mindmap_mod = @import("mindmap.zig");
const llm_mod = @import("llm.zig");
const ConceptNode = mindmap_mod.ConceptNode;
const MindMap = mindmap_mod.MindMap;
const LLMService = llm_mod.LLMService; // ziglint-ignore: Z032
const LLMMessage = llm_mod.LLMMessage; // ziglint-ignore: Z032
const LLMRequest = llm_mod.LLMRequest; // ziglint-ignore: Z032

pub const QueryResult = struct {
    answer: []const u8,
    context: []const u8,
    node_ids: []const []const u8,

    pub fn deinit(self: *QueryResult, alloc: std.mem.Allocator) void {
        alloc.free(self.answer);
        alloc.free(self.context);
        for (self.node_ids) |id| alloc.free(id);
        alloc.free(self.node_ids);
        self.* = undefined;
    }
};

const TarjanContext = struct {
    allocator: std.mem.Allocator,
    flat_map: *const std.StringHashMap(*const ConceptNode),
    index: usize,
    indices: std.StringHashMap(usize),
    lowlink: std.StringHashMap(usize),
    on_stack: std.StringHashMap(bool),
    stack: std.ArrayList([]const u8),
    sccs: std.ArrayList(std.ArrayList([]const u8)),

    fn init(allocator: std.mem.Allocator, flat_map: *const std.StringHashMap(*const ConceptNode)) TarjanContext {
        return .{
            .allocator = allocator,
            .flat_map = flat_map,
            .index = 0,
            .indices = std.StringHashMap(usize).init(allocator),
            .lowlink = std.StringHashMap(usize).init(allocator),
            .on_stack = std.StringHashMap(bool).init(allocator),
            .stack = .empty,
            .sccs = .empty,
        };
    }

    fn deinit(self: *TarjanContext) void {
        self.indices.deinit();
        self.lowlink.deinit();
        self.on_stack.deinit();
        self.stack.deinit(self.allocator);
        self.sccs.deinit(self.allocator);
        self.* = undefined;
    }

    fn run(self: *TarjanContext) !void {
        var it = self.flat_map.keyIterator();
        while (it.next()) |node_id_ptr| {
            const node_id = node_id_ptr.*;
            if (!self.indices.contains(node_id)) {
                try self.strongConnect(node_id);
            }
        }
    }

    fn strongConnect(self: *TarjanContext, v: []const u8) !void {
        try self.indices.put(v, self.index);
        try self.lowlink.put(v, self.index);
        self.index += 1;
        try self.stack.append(self.allocator, v);
        try self.on_stack.put(v, true);

        if (self.flat_map.get(v)) |node| {
            if (node.children) |*ch| {
                for (ch.items) |*child| {
                    const w = child.id;
                    if (!self.indices.contains(w)) {
                        try self.strongConnect(w);
                        const v_low = self.lowlink.get(v).?;
                        const w_low = self.lowlink.get(w).?;
                        try self.lowlink.put(v, @min(v_low, w_low));
                    } else if (self.on_stack.get(w) orelse false) {
                        const v_low = self.lowlink.get(v).?;
                        const w_index = self.indices.get(w).?;
                        try self.lowlink.put(v, @min(v_low, w_index));
                    }
                }
            }
            if (node.causal_links) |*cl| {
                for (cl.items) |*link| {
                    const w = link.target;
                    if (self.flat_map.contains(w)) {
                        if (!self.indices.contains(w)) {
                            try self.strongConnect(w);
                            const v_low = self.lowlink.get(v).?;
                            const w_low = self.lowlink.get(w).?;
                            try self.lowlink.put(v, @min(v_low, w_low));
                        } else if (self.on_stack.get(w) orelse false) {
                            const v_low = self.lowlink.get(v).?;
                            const w_index = self.indices.get(w).?;
                            try self.lowlink.put(v, @min(v_low, w_index));
                        }
                    }
                }
            }
        }

        if ((self.lowlink.get(v).?) == (self.indices.get(v).?)) {
            var scc: std.ArrayList([]const u8) = .empty;
            errdefer scc.deinit(self.allocator);
            while (true) {
                const w = self.stack.pop().?;
                try self.on_stack.put(w, false);
                try scc.append(self.allocator, w);
                if (std.mem.eql(u8, w, v)) break;
            }
            var is_cycle = scc.items.len > 1;
            if (scc.items.len == 1) {
                const node_id = scc.items[0];
                if (self.flat_map.get(node_id)) |node| {
                    if (node.causal_links) |*cl| {
                        for (cl.items) |*link| {
                            if (std.mem.eql(u8, link.target, node_id)) {
                                is_cycle = true;
                                break;
                            }
                        }
                    }
                }
            }

            if (is_cycle) {
                try self.sccs.append(self.allocator, scc);
            } else {
                scc.deinit(self.allocator);
            }
        }
    }
};

pub const QueryEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QueryEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *QueryEngine, _: std.mem.Allocator) void {
        self.* = undefined;
    }

    /// Collect all leaf nodes (nodes without children) from the mind-map.
    pub fn collectLeafNodes(self: *QueryEngine, mindmap: *const MindMap) ![]*const ConceptNode {
        var leaves: std.ArrayList(*const ConceptNode) = .empty;
        errdefer leaves.deinit(self.allocator);
        for (mindmap.nodes.items) |*node| {
            try self.collectLeavesRecursive(node, &leaves);
        }
        return leaves.toOwnedSlice(self.allocator);
    }

    fn collectLeavesRecursive(self: *QueryEngine, node: *const ConceptNode, leaves: *std.ArrayList(*const ConceptNode)) !void {
        if (node.children) |*ch| {
            for (ch.items) |*child| {
                try self.collectLeavesRecursive(child, leaves);
            }
        } else {
            try leaves.append(self.allocator, node);
        }
    }

    /// Select nodes whose IDs are in the given set.
    pub fn selectNodes(self: *QueryEngine, candidates: []const *const ConceptNode, selected_ids: []const []const u8) ![]*const ConceptNode {
        var result: std.ArrayList(*const ConceptNode) = .empty;
        errdefer result.deinit(self.allocator);
        for (candidates) |node| {
            for (selected_ids) |id| {
                if (std.mem.eql(u8, node.id, id)) {
                    try result.append(self.allocator, node);
                    break;
                }
            }
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// Assemble context text from the original document for selected nodes.
    pub fn assembleContext(_: *QueryEngine, alloc: std.mem.Allocator, doc: []const u8, nodes: []*const ConceptNode) ![]const u8 {
        var line_buf: std.ArrayList(u8) = .empty;

        // Sort nodes by source_start
        std.mem.sort(*const ConceptNode, nodes, {}, struct {
            fn lessThan(_: void, a: *const ConceptNode, b: *const ConceptNode) bool {
                return a.source_start < b.source_start;
            }
        }.lessThan);

        var line_num: usize = 1;
        var lines = std.mem.splitScalar(u8, doc, '\n');
        while (lines.next()) |line| : (line_num += 1) {
            for (nodes) |node| {
                if (line_num >= node.source_start and line_num <= node.source_end) {
                    try line_buf.appendSlice(alloc, line);
                    try line_buf.append(alloc, '\n');
                    break;
                }
            }
        }

        return line_buf.toOwnedSlice(alloc);
    }

    fn buildFlatNodeMap(self: *QueryEngine, mindmap: *const MindMap, map: *std.StringHashMap(*const ConceptNode)) !void {
        for (mindmap.nodes.items) |*node| {
            try self.collectNodesRecursive(node, map);
        }
    }

    fn collectNodesRecursive(self: *QueryEngine, node: *const ConceptNode, map: *std.StringHashMap(*const ConceptNode)) !void {
        try map.put(node.id, node);
        if (node.children) |*ch| {
            for (ch.items) |*child| {
                try self.collectNodesRecursive(child, map);
            }
        }
    }

    pub fn findStartNodes(
        self: *QueryEngine,
        flat_map: *const std.StringHashMap(*const ConceptNode),
        question: []const u8,
    ) ![]const []const u8 {
        var starts: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (starts.items) |id| self.allocator.free(id);
            starts.deinit(self.allocator);
        }

        const question_lower = try self.allocator.alloc(u8, question.len);
        defer self.allocator.free(question_lower);
        for (question, 0..) |c, idx| question_lower[idx] = std.ascii.toLower(c);

        var it = flat_map.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;

            const title_lower = try self.allocator.alloc(u8, node.title.len);
            defer self.allocator.free(title_lower);
            for (node.title, 0..) |c, idx| title_lower[idx] = std.ascii.toLower(c);

            if (std.mem.indexOf(u8, question_lower, title_lower) != null or
                std.mem.indexOf(u8, question_lower, node.id) != null) {
                try starts.append(self.allocator, try self.allocator.dupe(u8, node.id));
            }
        }

        return starts.toOwnedSlice(self.allocator);
    }

    pub fn traverseGraph(
        self: *QueryEngine,
        mindmap: *const MindMap,
        flat_map: *const std.StringHashMap(*const ConceptNode),
        start_nodes: []const []const u8,
        max_depth: usize,
    ) ![]*const ConceptNode {
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var result: std.ArrayList(*const ConceptNode) = .empty;
        errdefer result.deinit(self.allocator);

        var tarjan = TarjanContext.init(self.allocator, flat_map);
        defer {
            for (tarjan.sccs.items) |*scc| {
                scc.deinit(self.allocator);
            }
            tarjan.deinit();
        }
        try tarjan.run();

        var node_to_cycle = std.StringHashMap(usize).init(self.allocator);
        defer node_to_cycle.deinit();

        for (tarjan.sccs.items, 0..) |scc, scc_idx| {
            for (scc.items) |node_id| {
                try node_to_cycle.put(node_id, scc_idx);
            }
        }

        var starts: std.ArrayList([]const u8) = .empty;
        defer {
            for (starts.items) |id| self.allocator.free(id);
            starts.deinit(self.allocator);
        }

        if (start_nodes.len > 0) {
            for (start_nodes) |id| {
                try starts.append(self.allocator, try self.allocator.dupe(u8, id));
            }
        } else {
            for (mindmap.nodes.items) |*node| {
                try starts.append(self.allocator, try self.allocator.dupe(u8, node.id));
            }
        }

        for (starts.items) |start_id| {
            try self.traverseDfs(flat_map, &node_to_cycle, tarjan.sccs.items, start_id, 0, max_depth, &visited, &result);
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn traverseDfs(
        self: *QueryEngine,
        flat_map: *const std.StringHashMap(*const ConceptNode),
        node_to_cycle: *const std.StringHashMap(usize),
        sccs: []const std.ArrayList([]const u8),
        node_id: []const u8,
        depth: usize,
        max_depth: usize,
        visited: *std.StringHashMap(void),
        result: *std.ArrayList(*const ConceptNode),
    ) !void {
        if (depth > max_depth) return;
        if (visited.contains(node_id)) return;

        const node = flat_map.get(node_id) orelse return;

        if (node_to_cycle.get(node_id)) |scc_idx| {
            const scc = sccs[scc_idx];

            for (scc.items) |cycle_id| {
                try visited.put(cycle_id, {});
            }

            for (scc.items) |cycle_id| {
                if (flat_map.get(cycle_id)) |cycle_node| {
                    try result.append(self.allocator, cycle_node);
                }
            }

            for (scc.items) |cycle_id| {
                if (flat_map.get(cycle_id)) |cycle_node| {
                    if (cycle_node.children) |*ch| {
                        for (ch.items) |*child| {
                            try self.traverseDfs(flat_map, node_to_cycle, sccs, child.id, depth + 1, max_depth, visited, result);
                        }
                    }
                    if (cycle_node.causal_links) |*cl| {
                        for (cl.items) |*link| {
                            try self.traverseDfs(flat_map, node_to_cycle, sccs, link.target, depth + 1, max_depth, visited, result);
                        }
                    }
                }
            }
        } else {
            try visited.put(node_id, {});
            try result.append(self.allocator, node);

            if (node.children) |*ch| {
                for (ch.items) |*child| {
                    try self.traverseDfs(flat_map, node_to_cycle, sccs, child.id, depth + 1, max_depth, visited, result);
                }
            }
            if (node.causal_links) |*cl| {
                for (cl.items) |*link| {
                    try self.traverseDfs(flat_map, node_to_cycle, sccs, link.target, depth + 1, max_depth, visited, result);
                }
            }
        }
    }

    /// Query the mind-map using the LLM: collect leaf context, build prompts, call the LLM.
    pub fn query(self: *QueryEngine, mindmap: *const MindMap, doc: []const u8, question: []const u8, llm: *LLMService) !QueryResult {
        var flat_map = std.StringHashMap(*const ConceptNode).init(self.allocator);
        defer flat_map.deinit();
        try self.buildFlatNodeMap(mindmap, &flat_map);

        const start_node_ids = try self.findStartNodes(&flat_map, question);
        defer {
            for (start_node_ids) |id| self.allocator.free(id);
            self.allocator.free(start_node_ids);
        }

        const traversed = try self.traverseGraph(mindmap, &flat_map, start_node_ids, 5);
        defer self.allocator.free(traversed);

        const nodes_to_assemble = if (traversed.len > 0) traversed else try self.collectLeafNodes(mindmap);
        defer if (traversed.len == 0) self.allocator.free(nodes_to_assemble);

        const sorted = try self.allocator.dupe(*const ConceptNode, nodes_to_assemble);
        defer self.allocator.free(sorted);
        std.mem.sort(*const ConceptNode, sorted, {}, struct {
            fn lessThan(_: void, a: *const ConceptNode, b: *const ConceptNode) bool {
                return a.source_start < b.source_start;
            }
        }.lessThan);

        const context = try self.assembleContext(self.allocator, doc, sorted);
        defer self.allocator.free(context);

        const tree_str = try self.buildTreeString(mindmap);
        defer self.allocator.free(tree_str);

        const system_msg = try std.fmt.allocPrint(self.allocator,
            \\You are a knowledge assistant analyzing a structured document mind-map.
            \\Answer concisely based only on the document content provided.
            \\
            \\Document tree structure:
            \\{s}
            \\
            \\Relevant content from document sections:
            \\{s}
        , .{ tree_str, context });
        defer self.allocator.free(system_msg);

        const user_msg = try std.fmt.allocPrint(self.allocator, "Question: {s}", .{question});
        defer self.allocator.free(user_msg);

        var messages = [_]LLMMessage{
            .{ .role = "system", .content = system_msg },
            .{ .role = "user", .content = user_msg },
        };

        var llm_req = LLMRequest.init(messages[0..], "gpt-4o", 0.3);
        var llm_resp = try llm.chat(&llm_req);
        defer llm_resp.deinit(self.allocator);

        var node_ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (node_ids.items) |id| self.allocator.free(id);
            node_ids.deinit(self.allocator);
        }
        for (sorted) |node| {
            try node_ids.append(self.allocator, try self.allocator.dupe(u8, node.id));
        }

        return .{
            .answer = try self.allocator.dupe(u8, llm_resp.content),
            .context = try self.allocator.dupe(u8, context),
            .node_ids = try node_ids.toOwnedSlice(self.allocator),
        };
    }

    /// Build an indented tree representation for the system prompt.
    fn buildTreeString(self: *QueryEngine, mindmap: *const MindMap) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        for (mindmap.nodes.items) |*node| {
            try self.renderNode(&out.writer, node, 0);
        }
        return out.toOwnedSlice();
    }

    fn renderNode(self: *QueryEngine, w: *std.Io.Writer, node: *const ConceptNode, depth: usize) !void {
        for (0..depth) |_| try w.writeAll("  ");
        try w.print("- {s} (lines {d}-{d})\n", .{ node.title, node.source_start, node.source_end });
        if (node.children) |*ch| {
            for (ch.items) |*child| try self.renderNode(w, child, depth + 1);
        }
    }
};

test "collect leaf nodes" {
    const alloc = std.testing.allocator;
    var mindmap = try MindMap.init(alloc, "Doc", "Summary");
    defer mindmap.deinit(alloc);
    var parent = try ConceptNode.init(alloc, "p1", "Parent", "Parent concept", 1, 0, 20);
    const child = try ConceptNode.init(alloc, "c1", "Child", "Child concept", 2, 5, 15);
    try parent.addChild(alloc, child);
    try mindmap.nodes.append(alloc, parent);

    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);
    const leaves = try engine.collectLeafNodes(&mindmap);
    defer alloc.free(leaves);
    try std.testing.expectEqual(@as(usize, 1), leaves.len);
    try std.testing.expectEqualStrings("c1", leaves[0].id);
}

test "select relevant nodes by id" {
    const alloc = std.testing.allocator;
    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);

    var n1 = try ConceptNode.init(alloc, "a", "Alpha", "First concept", 1, 0, 5);
    defer n1.deinit(alloc);
    var n2 = try ConceptNode.init(alloc, "b", "Beta", "Second concept", 1, 6, 10);
    defer n2.deinit(alloc);

    var candidates: [2]*const ConceptNode = .{ &n1, &n2 };
    const selected = try engine.selectNodes(&candidates, &.{"a"});
    defer alloc.free(selected);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("a", selected[0].id);
}

test "assemble context text from nodes and document" {
    const alloc = std.testing.allocator;
    const doc =
        \\# Intro
        \\Hello world.
        \\## Details
        \\Deep dive here.
    ;
    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);
    var n1 = try ConceptNode.init(alloc, "intro", "Intro", "Intro section", 1, 1, 2);
    defer n1.deinit(alloc);
    var n2 = try ConceptNode.init(alloc, "details", "Details", "Details section", 2, 3, 4);
    defer n2.deinit(alloc);

    var ctx_nodes: [2]*const ConceptNode = .{ &n1, &n2 };
    const ctx = try engine.assembleContext(alloc, doc, &ctx_nodes);
    defer alloc.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "Hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "Deep dive") != null);
}

test "QueryEngine: findStartNodes" {
    const alloc = std.testing.allocator;
    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);

    var flat_map = std.StringHashMap(*const ConceptNode).init(alloc);
    defer flat_map.deinit();

    var n1 = try ConceptNode.init(alloc, "intro", "Introduction", "Overview", 1, 1, 5);
    defer n1.deinit(alloc);
    try flat_map.put(n1.id, &n1);

    var n2 = try ConceptNode.init(alloc, "details", "Deep Dive", "Details", 2, 6, 10);
    defer n2.deinit(alloc);
    try flat_map.put(n2.id, &n2);

    const starts = try engine.findStartNodes(&flat_map, "Tell me about Introduction and Deep Dive.");
    defer {
        for (starts) |id| alloc.free(id);
        alloc.free(starts);
    }

    try std.testing.expect(starts.len == 2);
}

test "QueryEngine: traverseGraph with cycles and max depth" {
    const alloc = std.testing.allocator;
    var mindmap = try MindMap.init(alloc, "Doc", "Summary");
    defer mindmap.deinit(alloc);

    var node_a = try ConceptNode.init(alloc, "a", "Alpha", "A node", 1, 1, 5);
    var node_b = try ConceptNode.init(alloc, "b", "Beta", "B node", 1, 6, 10);
    var node_c = try ConceptNode.init(alloc, "c", "Gamma", "C node", 1, 11, 15);
    const node_d = try ConceptNode.init(alloc, "d", "Delta", "D node", 2, 16, 20);

    try node_a.addCausalLink(alloc, "b", "causes", "A causes B");
    try node_b.addCausalLink(alloc, "c", "causes", "B causes C");
    try node_c.addCausalLink(alloc, "a", "causes", "C causes A");
    try node_b.addCausalLink(alloc, "d", "causes", "B causes D");

    try mindmap.nodes.append(alloc, node_a);
    try mindmap.nodes.append(alloc, node_b);
    try mindmap.nodes.append(alloc, node_c);
    try mindmap.nodes.append(alloc, node_d);

    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);

    var flat_map = std.StringHashMap(*const ConceptNode).init(alloc);
    defer flat_map.deinit();
    try engine.buildFlatNodeMap(&mindmap, &flat_map);

    const traversed = try engine.traverseGraph(&mindmap, &flat_map, &.{"a"}, 2);
    defer alloc.free(traversed);

    try std.testing.expect(traversed.len == 4);
}
