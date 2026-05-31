//! Scans the `docs/` directory, extracts metadata from each file
//! (frontmatter for Markdown, comments/filename for Zig), then rebuilds
//! `map.json` with updated name, description, and path fields.

const std = @import("std");

pub const utils = @import("map/utils.zig");
pub const metadata = @import("map/metadata.zig");
pub const entry = @import("map/entry.zig");
pub const scanner = @import("map/scanner.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    var entries = try scanner.scanDir(alloc, io, "docs", "");
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }

    std.mem.sort(entry.Entry, entries.items, {}, entry.entryLessThan);

    var json_writer = std.Io.Writer.Allocating.init(alloc);
    defer json_writer.deinit();

    var stringify: std.json.Stringify = .{ .writer = &json_writer.writer, .options = .{ .whitespace = .indent_2 } };
    try stringify.write(entries.items);
    try json_writer.writer.writeByte('\n');

    const out = try json_writer.toOwnedSlice();
    defer alloc.free(out);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "map.json", .data = out });
    std.debug.print("Updated map.json with {d} entries.\n", .{entries.items.len});
}

test {
    std.testing.refAllDecls(@This());
}
