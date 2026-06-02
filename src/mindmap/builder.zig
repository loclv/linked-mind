const std = @import("std");
const mm = @import("mindmap.zig");
const ConceptNode = mm.ConceptNode;

pub const HeadingInfo = struct {
    id: []const u8,
    title: []const u8,
    level: u8,
    line: usize,
};

pub fn headingId(alloc: std.mem.Allocator, title: []const u8) ![]const u8 {
    var buf: [256]u8 = undefined;
    var idx: usize = 0;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (idx < buf.len) {
                buf[idx] = std.ascii.toLower(c);
                idx += 1;
            }
        } else if (c == ' ' or c == '-' or c == '_' or c == ':') {
            if (idx > 0 and buf[idx - 1] != '-' and idx < buf.len) {
                buf[idx] = '-';
                idx += 1;
            }
        }
    }
    if (idx > 0 and buf[idx - 1] == '-') idx -= 1;
    return alloc.dupe(u8, buf[0..idx]);
}

pub fn extractHeadings(alloc: std.mem.Allocator, content: []const u8) ![]HeadingInfo {
    var headings: std.ArrayList(HeadingInfo) = .empty;
    errdefer {
        for (headings.items) |h| {
            alloc.free(h.title);
            alloc.free(h.id);
        }
        headings.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (lines.next()) |line| : (line_num += 1) {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0 and trimmed[0] == '#') {
            var level: u8 = 0;
            for (trimmed) |c| {
                if (c == '#') level += 1 else break;
            }
            const title = std.mem.trim(u8, trimmed[level..], " \r\t");
            if (title.len == 0) continue;
            if (std.mem.eql(u8, title, "---")) continue;
            const id_str = try headingId(alloc, title);
            try headings.append(alloc, .{
                .id = id_str,
                .title = try alloc.dupe(u8, title),
                .level = level,
                .line = line_num,
            });
        }
    }
    return headings.toOwnedSlice(alloc);
}

/// Build a heading tree from markdown content.
/// Uses an indexed approach: computes parent-child relationships via index
/// tracking, then steals child nodes from a flat array into parent children
/// lists — all without pointer invalidation or stale copies.
/// Returns a root ConceptNode whose children are the top-level headings.
pub fn buildHeadingTree(alloc: std.mem.Allocator, content: []const u8) !ConceptNode {
    const headings = try extractHeadings(alloc, content);
    defer {
        for (headings) |h| {
            alloc.free(h.title);
            alloc.free(h.id);
        }
        alloc.free(headings);
    }

    if (headings.len == 0) {
        return ConceptNode.init(alloc, "doc", "Document", "", 0, 1, 0) catch unreachable;
    }

    const total_lines = 1 + std.mem.count(u8, content, "\n");
    const root_level = headings[0].level;

    // Flat list: index 0 = root, 1..n = heading nodes
    var all_nodes: std.ArrayList(ConceptNode) = .empty;
    defer all_nodes.deinit(alloc);

    try all_nodes.append(alloc, try ConceptNode.init(alloc, "doc", "Document", "", 0, 1, total_lines));

    for (headings) |h| {
        const rel_level = h.level -| root_level + 1;
        try all_nodes.append(alloc, try ConceptNode.init(alloc, h.id, h.title, "", rel_level, h.line, total_lines));
    }

    // Build parent index table: parent_idx[i] = parent index for all_nodes[i]
    var parent_idx: std.ArrayList(usize) = .empty;
    defer parent_idx.deinit(alloc);
    try parent_idx.append(alloc, 0);

    var i: usize = 1;
    while (i < all_nodes.items.len) : (i += 1) {
        const node_level = all_nodes.items[i].level;
        var j = i - 1;
        while (j > 0 and all_nodes.items[j].level >= node_level) {
            j = parent_idx.items[j];
        }
        try parent_idx.append(alloc, j);
    }

    // Build children-of tracking: for each node, list of child indices
    var children_of: std.ArrayList(std.ArrayList(usize)) = .empty;
    defer {
        for (children_of.items) |*cl| cl.deinit(alloc);
        children_of.deinit(alloc);
    }
    for (0..all_nodes.items.len) |_| {
        try children_of.append(alloc, .empty);
    }

    for (1..all_nodes.items.len) |child_idx| {
        try children_of.items[parent_idx.items[child_idx]].append(alloc, child_idx);
    }

    // Wire up children in reverse order so children have their sub-children
    // already set when their parent collects them.
    var rev = all_nodes.items.len;
    while (rev > 0) {
        rev -= 1;
        const child_indices = &children_of.items[rev];
        if (child_indices.items.len == 0) continue;

        var child_list: std.ArrayList(ConceptNode) = .empty;
        for (child_indices.items) |child_idx| {
            try child_list.append(alloc, all_nodes.items[child_idx]);
            all_nodes.items[child_idx] = undefined;
        }
        all_nodes.items[rev].children = child_list;
    }

    const result = all_nodes.items[0];
    all_nodes.items.len = 0;
    return result;
}

test "extract headings from markdown" {
    const alloc = std.testing.allocator;
    const md =
        \\# Introduction
        \\Some intro text.
        \\## Details
        \\More text.
        \\# Conclusion
        \\Final words.
    ;
    const headings = try extractHeadings(alloc, md);
    defer {
        for (headings) |h| {
            alloc.free(h.title);
            alloc.free(h.id);
        }
        alloc.free(headings);
    }
    try std.testing.expectEqual(@as(usize, 3), headings.len);
    try std.testing.expectEqualStrings("Introduction", headings[0].title);
    try std.testing.expectEqualStrings("details", headings[1].id);
    try std.testing.expectEqual(@as(u8, 2), headings[1].level);
}

test "parse heading id from title" {
    const alloc = std.testing.allocator;
    const id1 = try headingId(alloc, "Hello World");
    defer alloc.free(id1);
    try std.testing.expectEqualStrings("hello-world", id1);

    const id2 = try headingId(alloc, "Hello   World!");
    defer alloc.free(id2);
    try std.testing.expectEqualStrings("hello-world", id2);

    const id3 = try headingId(alloc, "My Section: Subtitle");
    defer alloc.free(id3);
    try std.testing.expectEqualStrings("my-section-subtitle", id3);
}

test "build tree from flat headings" {
    const alloc = std.testing.allocator;
    const md =
        \\# A
        \\## B
        \\### C
        \\## D
        \\# E
    ;
    var tree = try buildHeadingTree(alloc, md);
    defer tree.deinit(alloc);
    try std.testing.expect(tree.children != null);
    try std.testing.expectEqual(@as(usize, 2), tree.children.?.items.len);
    try std.testing.expectEqualStrings("a", tree.children.?.items[0].id);
    try std.testing.expect(tree.children.?.items[0].children.?.items.len == 2);
    try std.testing.expectEqualStrings("b", tree.children.?.items[0].children.?.items[0].id);
}
