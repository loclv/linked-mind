const std = @import("std");

const parser = @import("parser.zig");

pub const CacheEntry = struct {
    mtime: i128,
    hash: [32]u8,
    node: parser.Node,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(CacheEntry),

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var cache_entry = entry.value_ptr;
            cache_entry.node.deinit(self.allocator);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn load(self: *Cache, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB cache limit
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        const files = root.object.get("files") orelse return;
        if (files != .object) return;

        var file_iter = files.object.iterator();
        while (file_iter.next()) |entry| {
            const file_path = entry.key_ptr.*;
            const file_data = entry.value_ptr.*;

            if (file_data != .object) continue;

            const mtime: i128 = if (file_data.object.get("mtime")) |m| @as(i128, m.integer) else 0;
            const hash_hex = if (file_data.object.get("hash")) |h| h.string else "";

            var hash: [32]u8 = undefined;
            if (hash_hex.len == 64) {
                _ = try std.fmt.hexToBytes(&hash, hash_hex);
            } else {
                @memset(&hash, 0);
            }

            const node_val = file_data.object.get("node") orelse continue;
            if (node_val != .object) continue;

            const node = try self.parseNode(node_val.object, file_path);

            try self.entries.put(try self.allocator.dupe(u8, file_path), .{
                .mtime = mtime,
                .hash = hash,
                .node = node,
            });
        }
    }

    fn parseNode(self: *Cache, obj: std.json.ObjectMap, path: []const u8) !parser.Node {
        var node: parser.Node = .{
            .path = try self.allocator.dupe(u8, path),
            .title = try self.allocator.dupe(u8, if (obj.get("title")) |t| t.string else ""),
            .content = try self.allocator.dupe(u8, if (obj.get("content")) |c| c.string else ""),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };

        if (obj.get("tags")) |tags_val| {
            if (tags_val == .array) {
                for (tags_val.array.items) |tag| {
                    if (tag == .string) {
                        try node.tags.append(self.allocator, try self.allocator.dupe(u8, tag.string));
                    }
                }
            }
        }

        if (obj.get("links")) |links_val| {
            if (links_val == .array) {
                for (links_val.array.items) |link| {
                    if (link == .object) {
                        const target = if (link.object.get("target")) |t| t.string else "";
                        const nature = if (link.object.get("nature")) |n| (if (n == .string) n.string else null) else null;

                        try node.links.append(self.allocator, .{
                            .target = try self.allocator.dupe(u8, target),
                            .nature = if (nature) |nat| try self.allocator.dupe(u8, nat) else null,
                        });
                    }
                }
            }
        }

        if (obj.get("metadata")) |meta_val| {
            if (meta_val == .object) {
                var it = meta_val.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try node.metadata.put(try self.allocator.dupe(u8, entry.key_ptr.*), try self.allocator.dupe(u8, entry.value_ptr.*.string));
                    }
                }
            }
        }

        return node;
    }

    pub fn save(self: *Cache, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var out_list: std.ArrayList(u8) = .{};
        defer out_list.deinit(self.allocator);

        var writer = out_list.writer(self.allocator);
        try writer.writeAll("{\"version\": 1, \"files\": {");

        var first = true;
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            try writer.print("\"{s}\": ", .{entry.key_ptr.*});
            try self.serializeEntry(writer, entry.value_ptr.*);
        }

        try writer.writeAll("}}");
        try file.writeAll(out_list.items);
    }

    fn serializeEntry(self: *Cache, writer: anytype, entry: CacheEntry) !void {
        _ = self;
        try writer.print("{{\"mtime\": {d}, \"hash\": \"", .{entry.mtime});
        for (entry.hash) |b| try writer.print("{x:0>2}", .{b});
        try writer.writeAll("\", \"node\": {");

        const node = entry.node;
        try writer.writeAll("\"title\": ");
        try writer.print("{f}, ", .{std.json.fmt(node.title, .{})});
        try writer.writeAll("\"content\": ");
        try writer.print("{f}, ", .{std.json.fmt(node.content, .{})});

        try writer.writeAll("\"tags\": [");
        for (node.tags.items, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{f}", .{std.json.fmt(tag, .{})});
        }
        try writer.writeAll("], \"links\": [");
        for (node.links.items, 0..) |link, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"target\": ");
            try writer.print("{f}", .{std.json.fmt(link.target, .{})});
            try writer.writeAll(", \"nature\": ");
            if (link.nature) |nat| {
                try writer.print("{f}", .{std.json.fmt(nat, .{})});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("], \"metadata\": {");
        var meta_it = node.metadata.iterator();
        var meta_first = true;
        while (meta_it.next()) |meta_entry| {
            if (!meta_first) try writer.writeAll(",");
            meta_first = false;
            try writer.print("{f}: {f}", .{
                std.json.fmt(meta_entry.key_ptr.*, .{}),
                std.json.fmt(meta_entry.value_ptr.*, .{}),
            });
        }
        try writer.writeAll("}}}");
    }
};

test "Cache: save and load round-trip" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    var node: parser.Node = .{
        .path = try allocator.dupe(u8, "test.md"),
        .title = try allocator.dupe(u8, "Test Title"),
        .content = try allocator.dupe(u8, "Test content"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node.tags.append(allocator, try allocator.dupe(u8, "tag1"));
    try node.links.append(allocator, .{ .target = try allocator.dupe(u8, "target1"), .nature = try allocator.dupe(u8, "nature1") });
    try node.metadata.put(try allocator.dupe(u8, "key1"), try allocator.dupe(u8, "value1"));

    var hash: [32]u8 = undefined;
    @memset(&hash, 0xAB);

    try cache.entries.put(try allocator.dupe(u8, "test.md"), .{
        .mtime = 123456789,
        .hash = hash,
        .node = node,
    });

    const cache_path = "test_cache.json";
    try cache.save(cache_path);
    defer std.fs.cwd().deleteFile(cache_path) catch {};

    var new_cache = Cache.init(allocator);
    defer new_cache.deinit();

    try new_cache.load(cache_path);

    try std.testing.expectEqual(@as(u32, 1), new_cache.entries.count());
    const entry = new_cache.entries.get("test.md").?;
    try std.testing.expectEqual(@as(i128, 123456789), entry.mtime);
    try std.testing.expectEqualSlices(u8, &hash, &entry.hash);
    try std.testing.expectEqualStrings("Test Title", entry.node.title);
    try std.testing.expectEqualStrings("tag1", entry.node.tags.items[0]);
    try std.testing.expectEqualStrings("nature1", entry.node.links.items[0].nature.?);
    try std.testing.expectEqualStrings("value1", entry.node.metadata.get("key1").?);
}

test "Cache: empty cache save and load" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    const cache_path = "test_empty_cache.json";
    try cache.save(cache_path);
    defer std.fs.cwd().deleteFile(cache_path) catch {};

    var new_cache = Cache.init(allocator);
    defer new_cache.deinit();

    try new_cache.load(cache_path);
    try std.testing.expectEqual(@as(u32, 0), new_cache.entries.count());
}

test "Cache: multiple entries" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    // First entry
    var node1: parser.Node = .{
        .path = try allocator.dupe(u8, "file1.md"),
        .title = try allocator.dupe(u8, "File One"),
        .content = try allocator.dupe(u8, "Content 1"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node1.tags.append(allocator, try allocator.dupe(u8, "alpha"));

    var hash1: [32]u8 = undefined;
    @memset(&hash1, 0x11);

    try cache.entries.put(try allocator.dupe(u8, "file1.md"), .{
        .mtime = 111,
        .hash = hash1,
        .node = node1,
    });

    // Second entry
    var node2: parser.Node = .{
        .path = try allocator.dupe(u8, "file2.md"),
        .title = try allocator.dupe(u8, "File Two"),
        .content = try allocator.dupe(u8, "Content 2"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    try node2.tags.append(allocator, try allocator.dupe(u8, "beta"));

    var hash2: [32]u8 = undefined;
    @memset(&hash2, 0x22);

    try cache.entries.put(try allocator.dupe(u8, "file2.md"), .{
        .mtime = 222,
        .hash = hash2,
        .node = node2,
    });

    const cache_path = "test_multi_cache.json";
    try cache.save(cache_path);
    defer std.fs.cwd().deleteFile(cache_path) catch {};

    var new_cache = Cache.init(allocator);
    defer new_cache.deinit();

    try new_cache.load(cache_path);
    try std.testing.expectEqual(@as(u32, 2), new_cache.entries.count());

    const entry1 = new_cache.entries.get("file1.md").?;
    try std.testing.expectEqual(@as(i128, 111), entry1.mtime);
    try std.testing.expectEqualStrings("File One", entry1.node.title);

    const entry2 = new_cache.entries.get("file2.md").?;
    try std.testing.expectEqual(@as(i128, 222), entry2.mtime);
    try std.testing.expectEqualStrings("File Two", entry2.node.title);
}

test "Cache: load missing file returns without error" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    try cache.load("nonexistent_cache_file_12345.json");
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}

test "Cache: load invalid JSON returns error" {
    const allocator = std.testing.allocator;

    const cache_path = "test_invalid_cache.json";
    const file = try std.fs.cwd().createFile(cache_path, .{});
    defer file.close();
    defer std.fs.cwd().deleteFile(cache_path) catch {};
    try file.writeAll("not valid json {{{");

    var cache = Cache.init(allocator);
    defer cache.deinit();

    try std.testing.expectError(error.SyntaxError, cache.load(cache_path));
}

test "Cache: link with null nature" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    var node: parser.Node = .{
        .path = try allocator.dupe(u8, "test.md"),
        .title = try allocator.dupe(u8, "Test"),
        .content = try allocator.dupe(u8, "Content"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };
    // Link with null nature
    try node.links.append(allocator, .{ .target = try allocator.dupe(u8, "target_no_nature"), .nature = null });

    var hash: [32]u8 = undefined;
    @memset(&hash, 0);

    try cache.entries.put(try allocator.dupe(u8, "test.md"), .{
        .mtime = 0,
        .hash = hash,
        .node = node,
    });

    const cache_path = "test_null_nature.json";
    try cache.save(cache_path);
    defer std.fs.cwd().deleteFile(cache_path) catch {};

    var new_cache = Cache.init(allocator);
    defer new_cache.deinit();

    try new_cache.load(cache_path);

    const entry = new_cache.entries.get("test.md").?;
    try std.testing.expectEqual(@as(usize, 1), entry.node.links.items.len);
    try std.testing.expectEqualStrings("target_no_nature", entry.node.links.items[0].target);
    try std.testing.expect(entry.node.links.items[0].nature == null);
}

test "Cache: entry with special characters in content" {
    const allocator = std.testing.allocator;
    var cache = Cache.init(allocator);
    defer cache.deinit();

    const node: parser.Node = .{
        .path = try allocator.dupe(u8, "special.md"),
        .title = try allocator.dupe(u8, "Title with \"quotes\" and \\backslash"),
        .content = try allocator.dupe(u8, "Content\nwith\nnewlines\tand\ttabs"),
        .links = .{},
        .backlinks = .{},
        .tags = .{},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    };

    var hash: [32]u8 = undefined;
    @memset(&hash, 0xCD);

    try cache.entries.put(try allocator.dupe(u8, "special.md"), .{
        .mtime = 999,
        .hash = hash,
        .node = node,
    });

    const cache_path = "test_special_chars.json";
    try cache.save(cache_path);
    defer std.fs.cwd().deleteFile(cache_path) catch {};

    var new_cache = Cache.init(allocator);
    defer new_cache.deinit();

    try new_cache.load(cache_path);

    const entry = new_cache.entries.get("special.md").?;
    try std.testing.expectEqualStrings("Title with \"quotes\" and \\backslash", entry.node.title);
    try std.testing.expectEqualStrings("Content\nwith\nnewlines\tand\ttabs", entry.node.content);
}
