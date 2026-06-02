const std = @import("std");

pub const CausalLink = struct {
    source: []const u8,
    target: []const u8,
    relation: []const u8,
    description: []const u8,

    pub fn init(source: []const u8, target: []const u8, relation: []const u8, description: []const u8) CausalLink {
        return .{ .source = source, .target = target, .relation = relation, .description = description };
    }

    pub fn jsonStringify(self: *const CausalLink, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("source");
        try jws.write(self.source);
        try jws.objectField("target");
        try jws.write(self.target);
        try jws.objectField("relation");
        try jws.write(self.relation);
        try jws.objectField("description");
        try jws.write(self.description);
        try jws.endObject();
    }
};

pub const ConceptNode = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    level: u8,
    source_start: usize,
    source_end: usize,
    children: ?std.ArrayList(ConceptNode),
    causal_links: ?std.ArrayList(CausalLink),

    pub fn init(alloc: std.mem.Allocator, id: []const u8, title: []const u8, summary: []const u8, level: u8, source_start: usize, source_end: usize) !ConceptNode {
        return .{
            .id = try alloc.dupe(u8, id),
            .title = try alloc.dupe(u8, title),
            .summary = try alloc.dupe(u8, summary),
            .level = level,
            .source_start = source_start,
            .source_end = source_end,
            .children = null,
            .causal_links = null,
        };
    }

    pub fn deinit(self: *ConceptNode, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.summary);
        if (self.children) |*ch| {
            for (ch.items) |*c| c.deinit(alloc);
            ch.deinit(alloc);
        }
        if (self.causal_links) |*cl| {
            for (cl.items) |*link| {
                alloc.free(link.target);
                alloc.free(link.relation);
                alloc.free(link.description);
            }
            cl.deinit(alloc);
        }
        self.* = undefined;
    }

    pub fn addChild(self: *ConceptNode, alloc: std.mem.Allocator, child: ConceptNode) !void {
        if (self.children) |*ch| {
            try ch.append(alloc, child);
        } else {
            var list: std.ArrayList(ConceptNode) = .empty;
            try list.append(alloc, child);
            self.children = list;
        }
    }

    pub fn addCausalLink(self: *ConceptNode, alloc: std.mem.Allocator, target: []const u8, relation: []const u8, description: []const u8) !void {
        const link: CausalLink = .{
            .source = self.id,
            .target = try alloc.dupe(u8, target),
            .relation = try alloc.dupe(u8, relation),
            .description = try alloc.dupe(u8, description),
        };
        if (self.causal_links) |*cl| {
            try cl.append(alloc, link);
        } else {
            var list: std.ArrayList(CausalLink) = .empty;
            try list.append(alloc, link);
            self.causal_links = list;
        }
    }

    pub fn jsonStringify(self: *const ConceptNode, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("title");
        try jws.write(self.title);
        try jws.objectField("summary");
        try jws.write(self.summary);
        try jws.objectField("level");
        try jws.write(self.level);
        try jws.objectField("source_start");
        try jws.write(self.source_start);
        try jws.objectField("source_end");
        try jws.write(self.source_end);
        try jws.objectField("children");
        if (self.children) |ch| {
            try jws.write(ch.items);
        } else {
            try jws.write(@as(?[]const u8, null));
        }
        try jws.objectField("causal_links");
        if (self.causal_links) |cl| {
            try jws.write(cl.items);
        } else {
            try jws.write(@as(?[]const u8, null));
        }
        try jws.endObject();
    }
};

pub const MindMap = struct {
    title: []const u8,
    summary: []const u8,
    nodes: std.ArrayList(ConceptNode),

    pub fn init(alloc: std.mem.Allocator, title: []const u8, summary: []const u8) !MindMap {
        return .{
            .title = try alloc.dupe(u8, title),
            .summary = try alloc.dupe(u8, summary),
            .nodes = std.ArrayList(ConceptNode).empty,
        };
    }

    pub fn deinit(self: *MindMap, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.summary);
        for (self.nodes.items) |*n| n.deinit(alloc);
        self.nodes.deinit(alloc);
        self.* = undefined;
    }

    pub fn toJson(self: *const MindMap, writer: *std.Io.Writer) !void {
        var jw: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };
        try jw.write(self);
    }

    pub fn jsonStringify(self: *const MindMap, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("title");
        try jws.write(self.title);
        try jws.objectField("summary");
        try jws.write(self.summary);
        try jws.objectField("nodes");
        try jws.write(self.nodes.items);
        try jws.endObject();
    }
};

/// Helper JSON types for deserialization.
const JsonCausalLink = struct {
    source: []const u8,
    target: []const u8,
    relation: []const u8,
    description: []const u8,
};

const JsonConceptNode = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    level: u8,
    source_start: usize,
    source_end: usize,
    children: ?[]JsonConceptNode,
    causal_links: ?[]JsonCausalLink,
};

const JsonMindMap = struct {
    title: []const u8,
    summary: []const u8,
    nodes: []JsonConceptNode,
};

fn convertConceptNode(alloc: std.mem.Allocator, jn: JsonConceptNode) !ConceptNode {
    const node_id = try alloc.dupe(u8, jn.id);
    const node_title = try alloc.dupe(u8, jn.title);
    const node_summary = try alloc.dupe(u8, jn.summary);

    var children: ?std.ArrayList(ConceptNode) = null;
    if (jn.children) |ch| {
        var list: std.ArrayList(ConceptNode) = .empty;
        for (ch) |c| {
            try list.append(alloc, try convertConceptNode(alloc, c));
        }
        children = list;
    }

    var causal_links: ?std.ArrayList(CausalLink) = null;
    if (jn.causal_links) |cl| {
        var list: std.ArrayList(CausalLink) = .empty;
        for (cl) |link| {
            try list.append(alloc, .{
                .source = node_id,
                .target = try alloc.dupe(u8, link.target),
                .relation = try alloc.dupe(u8, link.relation),
                .description = try alloc.dupe(u8, link.description),
            });
        }
        causal_links = list;
    }

    return .{
        .id = node_id,
        .title = node_title,
        .summary = node_summary,
        .level = jn.level,
        .source_start = jn.source_start,
        .source_end = jn.source_end,
        .children = children,
        .causal_links = causal_links,
    };
}

pub fn fromJson(alloc: std.mem.Allocator, json_data: []const u8) !MindMap {
    const parsed = try std.json.parseFromSlice(JsonMindMap, alloc, json_data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const jm = parsed.value;
    const title = try alloc.dupe(u8, jm.title);
    const summary = try alloc.dupe(u8, jm.summary);

    var nodes = try std.ArrayList(ConceptNode).initCapacity(alloc, jm.nodes.len);
    for (jm.nodes) |jn| {
        try nodes.append(alloc, try convertConceptNode(alloc, jn));
    }

    return .{
        .title = title,
        .summary = summary,
        .nodes = nodes,
    };
}

test "ConceptNode: init and deinit lifecycle" {
    const alloc = std.testing.allocator;
    var node = try ConceptNode.init(alloc, "intro", "Introduction", "Overview of the topic", 1, 0, 10);
    defer node.deinit(alloc);
    try std.testing.expectEqualStrings("intro", node.id);
    try std.testing.expectEqualStrings("Introduction", node.title);
    try std.testing.expectEqualStrings("Overview of the topic", node.summary);
    try std.testing.expectEqual(@as(u8, 1), node.level);
    try std.testing.expect(node.children == null);
    try std.testing.expect(node.causal_links == null);
}

test "ConceptNode: add child and causal link" {
    const alloc = std.testing.allocator;
    var parent = try ConceptNode.init(alloc, "parent", "Parent", "", 1, 0, 10);
    defer parent.deinit(alloc);
    const child = try ConceptNode.init(alloc, "child", "Child", "", 2, 3, 7);
    try parent.addChild(alloc, child);
    try parent.addCausalLink(alloc, "child", "leads-to", "Child follows from parent");
    try std.testing.expect(parent.children.?.items.len == 1);
    try std.testing.expect(parent.causal_links.?.items.len == 1);
    try std.testing.expectEqualStrings("child", parent.causal_links.?.items[0].target);
}

test "CausalLink: init" {
    const link = CausalLink.init("a", "b", "causes", "A causes B");
    try std.testing.expectEqualStrings("a", link.source);
    try std.testing.expectEqualStrings("causes", link.relation);
}

test "MindMap: init and deinit" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "My Doc", "A test document");
    defer mm.deinit(alloc);
    try std.testing.expectEqualStrings("My Doc", mm.title);
    try std.testing.expect(mm.nodes.items.len == 0);
}

test "MindMap: serialization round-trip" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Doc", "Summary");
    defer mm.deinit(alloc);
    var node = try ConceptNode.init(alloc, "c1", "Concept 1", "First concept", 1, 0, 5);
    try node.addCausalLink(alloc, "c2", "enables", "C1 enables C2");
    try mm.nodes.append(alloc, node);

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try mm.toJson(&out.writer);

    var parsed = try fromJson(alloc, out.written());
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("Doc", parsed.title);
    try std.testing.expect(parsed.nodes.items.len == 1);
    try std.testing.expectEqualStrings("c1", parsed.nodes.items[0].id);
    try std.testing.expect(parsed.nodes.items[0].causal_links.?.items.len == 1);
}
