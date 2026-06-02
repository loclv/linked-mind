const std = @import("std");
const mindmap_mod = @import("mindmap.zig");
const MindMap = mindmap_mod.MindMap;

pub fn serializeToJson(alloc: std.mem.Allocator, mindmap: *const MindMap) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try mindmap.toJson(&out.writer);
    try out.writer.writeAll("\n");
    return alloc.dupe(u8, out.written());
}

pub fn deserializeFromJson(alloc: std.mem.Allocator, json: []const u8) !MindMap {
    return mindmap_mod.fromJson(alloc, json);
}

test "serialize: JSON round-trip for minimal mindmap" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Test", "A test mind-map");
    defer mm.deinit(alloc);
    const node = try mindmap_mod.ConceptNode.init(alloc, "n1", "Node 1", "First node", 1, 0, 10);
    try mm.nodes.append(alloc, node);

    const json = try serializeToJson(alloc, &mm);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Node 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "n1") != null);

    var parsed = try deserializeFromJson(alloc, json);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("Test", parsed.title);
    try std.testing.expect(parsed.nodes.items.len == 1);
}

test "serialize: JSON with children and causal links" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Doc", "Summary");
    defer mm.deinit(alloc);
    var parent = try mindmap_mod.ConceptNode.init(alloc, "p1", "Parent", "Parent concept", 1, 0, 20);
    const child = try mindmap_mod.ConceptNode.init(alloc, "c1", "Child", "Child concept", 2, 5, 15);
    try parent.addChild(alloc, child);
    try parent.addCausalLink(alloc, "other", "causes", "Parent causes other");
    try mm.nodes.append(alloc, parent);

    const json = try serializeToJson(alloc, &mm);
    defer alloc.free(json);
    var parsed = try deserializeFromJson(alloc, json);
    defer parsed.deinit(alloc);

    try std.testing.expect(parsed.nodes.items[0].children.?.items.len == 1);
    try std.testing.expectEqualStrings("Child", parsed.nodes.items[0].children.?.items[0].title);
    try std.testing.expect(parsed.nodes.items[0].causal_links.?.items.len == 1);
    try std.testing.expectEqualStrings("causes", parsed.nodes.items[0].causal_links.?.items[0].relation);
}

test "serialize: empty mindmap" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Empty", "");
    defer mm.deinit(alloc);
    const json = try serializeToJson(alloc, &mm);
    defer alloc.free(json);
    var parsed = try deserializeFromJson(alloc, json);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("Empty", parsed.title);
    try std.testing.expect(parsed.nodes.items.len == 0);
}
