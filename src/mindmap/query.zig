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
    /// Query the mind-map using the LLM: collect leaf context, build prompts, call the LLM.
    pub fn query(self: *QueryEngine, mindmap: *const MindMap, doc: []const u8, question: []const u8, llm: *LLMService) !QueryResult {
        const all_leaves = try self.collectLeafNodes(mindmap);
        defer self.allocator.free(all_leaves);

        const sorted = try self.allocator.dupe(*const ConceptNode, all_leaves);
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
