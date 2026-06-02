const std = @import("std");
const mindmap_mod = @import("mindmap.zig");
const ConceptNode = mindmap_mod.ConceptNode;
const MindMap = mindmap_mod.MindMap;

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
