//! Scans the `docs/` directory, extracts metadata from each file
//! (frontmatter for Markdown, comments/filename for Zig), then rebuilds
//! `map.json` with updated name, description, and path fields.

const std = @import("std");

/// Holds the name and description extracted from a single file.
const Metadata = struct {
    name: []const u8,
    description: []const u8,
};

/// Reads an entire file into an allocator-owned buffer (max 1 MiB).
fn readFileAlloc(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

/// Parses YAML frontmatter (`--- ... ---`) for `name:` and `description:`.
/// Returns null if the file has no frontmatter or the keys are missing.
fn extractFrontmatter(alloc: std.mem.Allocator, content: []const u8) !?Metadata {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;
    const end = std.mem.indexOf(u8, content[4..], "\n---") orelse return null;
    const fm = content[4 .. 4 + end];

    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            name = std.mem.trim(u8, trimmed[5..], " \r\t\"'");
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            desc = std.mem.trim(u8, trimmed[12..], " \r\t\"'");
        }
    }

    if (name == null or desc == null) return null;
    return Metadata{
        .name = try alloc.dupe(u8, name.?),
        .description = try alloc.dupe(u8, desc.?),
    };
}

/// Converts a filename stem into kebab-case (e.g. `hello_world.zig` → `hello-world`).
fn kebabFromFilename(alloc: std.mem.Allocator, filename: []const u8) ![]const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, filename, '.')) |i| filename[0..i] else filename;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (stem) |c| {
        if (c == '_' or c == ' ') {
            try buf.append(alloc, '-');
        } else if (std.ascii.isAlphanumeric(c) or c == '-') {
            try buf.append(alloc, std.ascii.toLower(c));
        } else {
            try buf.append(alloc, '-');
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Converts a directory name into a title (e.g. `memory_management` → `Memory Management`).
fn titleFromDirname(alloc: std.mem.Allocator, dirname: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var first = true;
    for (dirname) |c| {
        if (c == '_' or c == '-') {
            try buf.append(alloc, ' ');
            first = true;
        } else if (std.ascii.isAlphanumeric(c)) {
            if (first) {
                try buf.append(alloc, std.ascii.toUpper(c));
                first = false;
            } else {
                try buf.append(alloc, c);
            }
        }
    }
    return buf.toOwnedSlice(alloc);
}

/// Looks for the first `//` comment in a Zig file to use as its description.
fn extractZigDesc(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//")) {
            return std.mem.trim(u8, t[2..], " \r\t");
        }
        if (t.len > 0) break;
    }
    return "";
}

/// For Markdown without frontmatter, extracts the first heading/paragraph text.
fn extractMdDesc(content: []const u8) []const u8 {
    const body_start = if (std.mem.indexOf(u8, content, "\n---")) |i|
        if (std.mem.indexOf(u8, content[i + 4 ..], "\n")) |j| i + 4 + j + 1 else content.len
    else
        0;
    const body = content[body_start..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t#");
        if (t.len > 0) return t;
    }
    return "";
}

/// Reads a file and builds Metadata based on its extension and contents.
fn fileMetadata(io: std.Io, alloc: std.mem.Allocator, full_path: []const u8, basename: []const u8) !Metadata {
    const content = try readFileAlloc(io, alloc, full_path);
    defer alloc.free(content);

    if (std.mem.endsWith(u8, basename, ".md")) {
        if (try extractFrontmatter(alloc, content)) |fm| return fm;
        const name = try kebabFromFilename(alloc, basename);
        const desc = try alloc.dupe(u8, extractMdDesc(content));
        return Metadata{ .name = name, .description = desc };
    }

    if (std.mem.endsWith(u8, basename, ".zig")) {
        const name = try kebabFromFilename(alloc, basename);
        const desc_raw = extractZigDesc(content);
        if (desc_raw.len > 0) {
            const desc = try alloc.dupe(u8, desc_raw);
            return Metadata{ .name = name, .description = desc };
        }
        const desc = try std.fmt.allocPrint(alloc, "Zig code sample: {s}.", .{name});
        return Metadata{ .name = name, .description = desc };
    }

    const name = try kebabFromFilename(alloc, basename);
    return Metadata{ .name = name, .description = "" };
}

/// Represents one node in the `map.json` tree.
/// Leaf nodes have `name`, `description`, and `path`.
/// Group nodes (directories) have `description`, `path`, and `children`.
const Entry = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    path: []const u8,
    children: ?std.ArrayList(Entry) = null,

    /// Recursively frees all owned strings and child arrays.
    fn deinit(self: *Entry, alloc: std.mem.Allocator) void {
        if (self.name) |s| alloc.free(s);
        if (self.description) |s| alloc.free(s);
        alloc.free(self.path);
        if (self.children) |*ch| {
            for (ch.items) |*c| c.deinit(alloc);
            ch.deinit(alloc);
        }
    }

    /// Serializes this entry into a `std.json.Value` object.
    /// Emits `children` for groups and `name`/`description`/`path` for leaves.
    fn toJson(self: Entry, alloc: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.empty;

        if (self.children) |ch| {
            const desc = self.description orelse "";
            try obj.put(alloc, "description", std.json.Value{ .string = try alloc.dupe(u8, desc) });
            try obj.put(alloc, "path", std.json.Value{ .string = try alloc.dupe(u8, self.path) });
            var arr = std.json.Array.init(alloc);
            for (ch.items) |c| {
                try arr.append(try c.toJson(alloc));
            }
            try obj.put(alloc, "children", std.json.Value{ .array = arr });
        } else {
            const name = self.name orelse "";
            const desc = self.description orelse "";
            // name, description, and path are all required for files, validated during construction
            try obj.put(alloc, "name", std.json.Value{ .string = try alloc.dupe(u8, name) });
            try obj.put(alloc, "description", std.json.Value{ .string = try alloc.dupe(u8, desc) });
            try obj.put(alloc, "path", std.json.Value{ .string = try alloc.dupe(u8, self.path) });
        }

        return std.json.Value{ .object = obj };
    }
};

/// Recursively walks a directory under `base/rel`, building `Entry` structs
/// for every file and subdirectory.  Returns an ArrayList of sibling entries.
fn scanDir(io: std.Io, alloc: std.mem.Allocator, base: []const u8, rel: []const u8) !std.ArrayList(Entry) {
    const full_path = if (rel.len == 0) base else try std.fs.path.join(alloc, &.{ base, rel });
    defer if (rel.len > 0) alloc.free(full_path);

    var dir = try std.Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList(struct { name: []const u8, meta: Metadata }) = .empty;
    defer {
        for (files.items) |*f| {
            alloc.free(f.name);
        }
        files.deinit(alloc);
    }
    errdefer {
        for (files.items) |*f| {
            alloc.free(f.meta.name);
            alloc.free(f.meta.description);
        }
    }

    var subdirs: std.ArrayList(struct { name: []const u8, entries: std.ArrayList(Entry) }) = .empty;
    defer {
        for (subdirs.items) |*d| {
            alloc.free(d.name);
        }
        subdirs.deinit(alloc);
    }
    errdefer {
        for (subdirs.items) |*d| {
            for (d.entries.items) |*e| {
                e.deinit(alloc);
            }
            d.entries.deinit(alloc);
        }
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) {
            const fpath = if (rel.len == 0)
                try std.fs.path.join(alloc, &.{ base, entry.name })
            else
                try std.fs.path.join(alloc, &.{ base, rel, entry.name });
            defer alloc.free(fpath);

            const meta = try fileMetadata(io, alloc, fpath, entry.name);
            errdefer {
                alloc.free(meta.name);
                alloc.free(meta.description);
            }
            try files.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .meta = meta });
        } else if (entry.kind == .directory) {
            const child_rel = if (rel.len == 0) entry.name else try std.fs.path.join(alloc, &.{ rel, entry.name });
            defer if (rel.len > 0) alloc.free(child_rel);
            const entries = try scanDir(io, alloc, base, child_rel);
            try subdirs.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .entries = entries });
        }
    }

    var result: std.ArrayList(Entry) = .empty;
    errdefer {
        for (result.items) |*e| {
            e.deinit(alloc);
        }
        result.deinit(alloc);
    }

    for (files.items) |f| {
        const path = if (rel.len == 0)
            try alloc.dupe(u8, f.name)
        else
            try std.fs.path.join(alloc, &.{ rel, f.name });
        errdefer alloc.free(path);

        try result.append(alloc, Entry{
            .name = f.meta.name,
            .description = f.meta.description,
            .path = path,
        });
    }

    for (subdirs.items) |d| {
        const rel_path = if (rel.len == 0) d.name else try std.fs.path.join(alloc, &.{ rel, d.name });
        defer if (rel.len > 0) alloc.free(rel_path);
        const path = try std.fmt.allocPrint(alloc, "{s}/", .{rel_path});
        errdefer alloc.free(path);

        const title = try titleFromDirname(alloc, d.name);
        errdefer alloc.free(title);

        try result.append(alloc, Entry{
            .description = title,
            .path = path,
            .children = d.entries,
        });
    }

    return result;
}

/// Sort comparator so entries are ordered alphabetically by path.
fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Entry point: scan `docs/`, sort entries, and write the resulting
/// JSON tree to `map.json`.
pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    var entries = try scanDir(io, alloc, "docs", "");
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }

    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    var json_arr = std.json.Array.init(alloc);
    defer json_arr.deinit();

    for (entries.items) |e| {
        try json_arr.append(try e.toJson(alloc));
    }

    var json_writer = std.Io.Writer.Allocating.init(alloc);
    defer json_writer.deinit();

    var stringify = std.json.Stringify{ .writer = &json_writer.writer, .options = .{ .whitespace = .indent_2 } };
    try stringify.write(std.json.Value{ .array = json_arr });
    try json_writer.writer.writeByte('\n');

    const out = try json_writer.toOwnedSlice();
    defer alloc.free(out);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "map.json", .data = out });
    std.debug.print("Updated map.json with {d} entries.\n", .{entries.items.len});
}
