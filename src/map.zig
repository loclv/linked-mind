//! Scans the `docs/` directory, extracts metadata from each file
//! (frontmatter for Markdown, comments/filename for Zig), then rebuilds
//! the map index file (`map.toon` by default, or `map.json` if --json is passed).

const std = @import("std");

pub const utils = @import("map/utils.zig");
pub const metadata = @import("map/metadata.zig");
pub const entry = @import("map/entry.zig");
pub const scanner = @import("map/scanner.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var format_json = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json") or std.mem.eql(u8, args[i], "-j")) {
            format_json = true;
        } else if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "json")) {
                format_json = true;
            }
            i += 1;
        }
    }

    var entries = try scanner.scanDir(alloc, io, "docs", "");
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }

    std.mem.sort(entry.Entry, entries.items, {}, entry.entryLessThan);

    if (format_json) {
        var json_writer = std.Io.Writer.Allocating.init(alloc);
        defer json_writer.deinit();

        var stringify: std.json.Stringify = .{ .writer = &json_writer.writer, .options = .{ .whitespace = .indent_2 } };
        try stringify.write(entries.items);
        try json_writer.writer.writeByte('\n');

        const out = try json_writer.toOwnedSlice();
        defer alloc.free(out);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "map.json", .data = out });
        std.debug.print("Updated map.json with {d} entries.\n", .{entries.items.len});
    } else {
        var toon_writer = std.Io.Writer.Allocating.init(alloc);
        defer toon_writer.deinit();

        try toon_writer.writer.print("[{d}]:\n", .{entries.items.len});
        for (entries.items) |e| {
            try e.writeToon(&toon_writer.writer, 4, true);
        }

        const out = try toon_writer.toOwnedSlice();
        defer alloc.free(out);

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "map.toon", .data = out });
        std.debug.print("Updated map.toon with {d} entries.\n", .{entries.items.len});
    }
}

test {
    std.testing.refAllDecls(@This());
}
