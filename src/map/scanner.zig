const std = @import("std");
const entry_mod = @import("entry.zig");
const metadata_mod = @import("metadata.zig");
const utils = @import("utils.zig");

const Entry = entry_mod.Entry;
const Metadata = metadata_mod.Metadata;

/// Recursively walks a directory under `base/rel`, building `Entry` structs
/// for every file and subdirectory.  Returns an ArrayList of sibling entries.
pub fn scanDir(alloc: std.mem.Allocator, io: std.Io, base: []const u8, rel: []const u8) !std.ArrayList(Entry) {
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

            const meta = try metadata_mod.fileMetadata(alloc, io, fpath, entry.name);
            errdefer {
                alloc.free(meta.name);
                alloc.free(meta.description);
            }
            try files.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .meta = meta });
        } else if (entry.kind == .directory) {
            const child_rel = if (rel.len == 0) entry.name else try std.fs.path.join(alloc, &.{ rel, entry.name });
            defer if (rel.len > 0) alloc.free(child_rel);
            const entries = try scanDir(alloc, io, base, child_rel);
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

        try result.append(alloc, .{
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

        const title = try utils.titleFromDirname(alloc, d.name);
        errdefer alloc.free(title);

        try result.append(alloc, .{
            .description = title,
            .path = path,
            .children = d.entries,
        });
    }

    return result;
}
