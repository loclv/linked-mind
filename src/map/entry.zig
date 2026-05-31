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
