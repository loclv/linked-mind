//! Entry type for the map index tree.
//!
//! An `Entry` represents a single node in the hierarchical map output
//! (`map.toon` or `map.json`).  Two kinds exist:
//!
//!   Leaf   - a file: has `name`, `description`, and `path` set; `children` is null.
//!   Group  - a directory: has `description` (title), `path` (trailing `/`),
//!            and `children`; `name` is null.
//!
//! Memory: all string fields and the `children` list are heap-owned.
//! Call `Entry.deinit(alloc)` to release them recursively.
const std = @import("std");
const toon = @import("../utils/toon.zig");

/// Represents one node in the `map.json` or `map.toon` tree.
/// Leaf nodes have `name`, `description`, and `path`.
/// Group nodes (directories) have `description`, `path`, and `children`.
pub const Entry = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    path: []const u8,
    children: ?std.ArrayList(Entry) = null,

    /// Recursively frees all owned strings and child arrays.
    pub fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        if (self.name) |s| alloc.free(s);
        if (self.description) |s| alloc.free(s);
        alloc.free(self.path);
        if (self.children) |*ch| {
            for (ch.items) |*c| c.deinit(alloc);
            ch.deinit(alloc);
        }
        self.* = undefined;
    }

    /// Custom JSON stringifier to serialize this entry directly without dynamic allocations.
    pub fn jsonStringify(self: Entry, jws: anytype) !void {
        try jws.beginObject();
        if (self.children) |ch| {
            try jws.objectField("description");
            try jws.write(self.description orelse "");
            try jws.objectField("path");
            try jws.write(self.path);
            try jws.objectField("children");
            try jws.write(ch.items);
        } else {
            try jws.objectField("name");
            try jws.write(self.name orelse "");
            try jws.objectField("description");
            try jws.write(self.description orelse "");
            try jws.objectField("path");
            try jws.write(self.path);
        }
        try jws.endObject();
    }

    /// Recursively writes this entry in TOON format to the writer.
    pub fn writeToon(self: Entry, writer: anytype, indent: usize, is_list_item: bool) !void {
        const writeSpaces = struct {
            fn run(w: anytype, num: usize) !void {
                var i: usize = 0;
                while (i < num) : (i += 1) {
                    try w.writeByte(' ');
                }
            }
        }.run;

        if (self.children) |ch| {
            // Group node (directory)
            if (is_list_item) {
                try writeSpaces(writer, indent - 2);
                try writer.writeAll("- description: ");
            } else {
                try writeSpaces(writer, indent);
                try writer.writeAll("description: ");
            }
            try toon.writeToonString(writer, self.description orelse "", ',');
            try writer.writeByte('\n');

            try writeSpaces(writer, indent);
            try writer.writeAll("path: ");
            try toon.writeToonString(writer, self.path, ',');
            try writer.writeByte('\n');

            try writeSpaces(writer, indent);
            if (ch.items.len == 0) {
                try writer.writeAll("children: []\n");
            } else {
                try writer.print("children[{d}]:\n", .{ch.items.len});
                for (ch.items) |child| {
                    try child.writeToon(writer, indent + 4, true);
                }
            }
        } else {
            // Leaf node (file)
            if (is_list_item) {
                try writeSpaces(writer, indent - 2);
                try writer.writeAll("- name: ");
            } else {
                try writeSpaces(writer, indent);
                try writer.writeAll("name: ");
            }
            try toon.writeToonString(writer, self.name orelse "", ',');
            try writer.writeByte('\n');

            try writeSpaces(writer, indent);
            try writer.writeAll("description: ");
            try toon.writeToonString(writer, self.description orelse "", ',');
            try writer.writeByte('\n');

            try writeSpaces(writer, indent);
            try writer.writeAll("path: ");
            try toon.writeToonString(writer, self.path, ',');
            try writer.writeByte('\n');
        }
    }
};

/// FlatEntry represents a flattened node structure for CSV serialization.
/// It uses borrowed string slices from the hierarchical tree for maximum performance
/// and 100% memory leak safety.
pub const FlatEntry = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,
};

/// Recursively collects nested Entry hierarchy into a flat list of FlatEntry nodes.
/// Using borrowed slices avoids dynamic allocation or string duplication.
pub fn collectFlat(alloc: std.mem.Allocator, entries: []const Entry, list: *std.ArrayList(FlatEntry)) !void {
    for (entries) |e| {
        try list.append(alloc, .{
            .name = e.name orelse "",
            .description = e.description orelse "",
            .path = e.path,
        });
        if (e.children) |ch| {
            try collectFlat(alloc, ch.items, list);
        }
    }
}

/// Sort comparator so FlatEntry nodes are ordered alphabetically by path.
pub fn flatEntryLessThan(_: void, a: FlatEntry, b: FlatEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Helper function to write a CSV field, applying double-quotes and escaping as per RFC 4180.
pub fn writeCsvField(writer: anytype, field: []const u8) !void {
    var needs_quotes = false;
    for (field) |c| {
        if (c == ',' or c == '\n' or c == '\r' or c == '"') {
            needs_quotes = true;
            break;
        }
    }

    if (needs_quotes) {
        try writer.writeByte('"');
        for (field) |c| {
            if (c == '"') {
                try writer.writeAll("\"\"");
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(field);
    }
}

/// Sort comparator so entries are ordered alphabetically by path.
pub fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}


test "Entry: custom JSON serialization of leaf node" {
    const alloc = std.testing.allocator;

    var entry: Entry = .{
        .name = try alloc.dupe(u8, "my-leaf"),
        .description = try alloc.dupe(u8, "leaf description"),
        .path = try alloc.dupe(u8, "leaf.md"),
    };
    defer entry.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stringify.write(entry);

    const json_str = try out.toOwnedSlice();
    defer alloc.free(json_str);

    try std.testing.expectEqualStrings("{\"name\":\"my-leaf\",\"description\":\"leaf description\",\"path\":\"leaf.md\"}", json_str);
}

test "Entry: custom JSON serialization of group node" {
    const alloc = std.testing.allocator;

    var child: Entry = .{
        .name = try alloc.dupe(u8, "child"),
        .description = try alloc.dupe(u8, "child desc"),
        .path = try alloc.dupe(u8, "dir/child.md"),
    };
    errdefer child.deinit(alloc);

    var children_list = std.ArrayList(Entry).empty;
    try children_list.append(alloc, child);

    var entry: Entry = .{
        .description = try alloc.dupe(u8, "group desc"),
        .path = try alloc.dupe(u8, "dir/"),
        .children = children_list,
    };
    defer entry.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try stringify.write(entry);

    const json_str = try out.toOwnedSlice();
    defer alloc.free(json_str);

    try std.testing.expectEqualStrings("{\"description\":\"group desc\",\"path\":\"dir/\",\"children\":[{\"name\":\"child\",\"description\":\"child desc\",\"path\":\"dir/child.md\"}]}", json_str);
}

test "Entry: custom TOON serialization of leaf node" {
    const alloc = std.testing.allocator;

    var entry: Entry = .{
        .name = try alloc.dupe(u8, "my-leaf"),
        .description = try alloc.dupe(u8, "leaf description"),
        .path = try alloc.dupe(u8, "leaf.md"),
    };
    defer entry.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try entry.writeToon(&out.writer, 4, true);

    const toon_str = try out.toOwnedSlice();
    defer alloc.free(toon_str);

    try std.testing.expectEqualStrings("  - name: my-leaf\n    description: leaf description\n    path: leaf.md\n", toon_str);
}

test "Entry: custom TOON serialization of group node" {
    const alloc = std.testing.allocator;

    var child: Entry = .{
        .name = try alloc.dupe(u8, "child"),
        .description = try alloc.dupe(u8, "child desc"),
        .path = try alloc.dupe(u8, "dir/child.md"),
    };
    errdefer child.deinit(alloc);

    var children_list = std.ArrayList(Entry).empty;
    try children_list.append(alloc, child);

    var entry: Entry = .{
        .description = try alloc.dupe(u8, "group desc"),
        .path = try alloc.dupe(u8, "dir/"),
        .children = children_list,
    };
    defer entry.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try entry.writeToon(&out.writer, 4, true);

    const toon_str = try out.toOwnedSlice();
    defer alloc.free(toon_str);

    try std.testing.expectEqualStrings("  - description: group desc\n    path: dir/\n    children[1]:\n      - name: child\n        description: child desc\n        path: dir/child.md\n", toon_str);
}

test "FlatEntry: collectFlat, sorting, and CSV serialization" {
    const alloc = std.testing.allocator;

    const child1: Entry = .{
        .name = try alloc.dupe(u8, "apple"),
        .description = try alloc.dupe(u8, "an apple"),
        .path = try alloc.dupe(u8, "fruit/apple.md"),
    };

    const child2: Entry = .{
        .name = try alloc.dupe(u8, "banana"),
        .description = try alloc.dupe(u8, "a \"yellow\" banana, yummy"),
        .path = try alloc.dupe(u8, "fruit/banana.md"),
    };

    var children_list = std.ArrayList(Entry).empty;
    errdefer {
        // Clean up individual children if array append fails
        var c1 = child1;
        var c2 = child2;
        c1.deinit(alloc);
        c2.deinit(alloc);
        children_list.deinit(alloc);
    }
    try children_list.append(alloc, child1);
    try children_list.append(alloc, child2);

    var parent: Entry = .{
        .description = try alloc.dupe(u8, "fruit directory"),
        .path = try alloc.dupe(u8, "fruit/"),
        .children = children_list,
    };
    defer parent.deinit(alloc);

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, parent);

    var flat_list = std.ArrayList(FlatEntry).empty;
    defer flat_list.deinit(alloc);

    try collectFlat(alloc, entries.items, &flat_list);
    std.mem.sort(FlatEntry, flat_list.items, {}, flatEntryLessThan);

    try std.testing.expectEqual(@as(usize, 3), flat_list.items.len);
    try std.testing.expectEqualStrings("fruit/", flat_list.items[0].path);
    try std.testing.expectEqualStrings("fruit/apple.md", flat_list.items[1].path);
    try std.testing.expectEqualStrings("fruit/banana.md", flat_list.items[2].path);

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();

    try out.writer.writeAll("name,description,path\n");
    for (flat_list.items) |fe| {
        try writeCsvField(&out.writer, fe.name);
        try out.writer.writeByte(',');
        try writeCsvField(&out.writer, fe.description);
        try out.writer.writeByte(',');
        try writeCsvField(&out.writer, fe.path);
        try out.writer.writeByte('\n');
    }

    const csv_str = try out.toOwnedSlice();
    defer alloc.free(csv_str);

    const expected =
        \\name,description,path
        \\,fruit directory,fruit/
        \\apple,an apple,fruit/apple.md
        \\banana,"a ""yellow"" banana, yummy",fruit/banana.md
        \\
    ;
    try std.testing.expectEqualStrings(expected, csv_str);
}


