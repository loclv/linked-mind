//! Scans the `docs/` directory, extracts metadata from each file
//! (frontmatter for Markdown, comments/filename for Zig), then rebuilds
//! the map index file (`map.toon` by default, or `map.json` if --json is passed).

const std = @import("std");

pub const utils = @import("map/utils.zig");
pub const metadata = @import("map/metadata.zig");
pub const entry = @import("map/entry.zig");
pub const scanner = @import("map/scanner.zig");
pub const toon = @import("utils/toon.zig");
pub const gitignore = @import("map/handle_gitignore.zig");


const version = "0.2.0";

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const Format = enum {
        csv,
        json,
        toon,
    };

    var format = Format.csv;
    var target_dir: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            const version_text = "map-builder v" ++ version ++ "\n";
            try std.Io.File.stdout().writeStreamingAll(io, version_text);
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_text =
                \\🥦 map-builder - Documentation Index Map Generator
                \\
                \\USAGE:
                \\  map-builder [target_folder] [options]
                \\
                \\OPTIONS:
                \\  -d, --dir <dir>       Specify the target folder to scan (default: ".")
                \\  -o, --output <file>   Specify the output file path (default: "map.csv", "map.json", or "map.toon")
                \\  -j, --json            Output in JSON format (map.json)
                \\  -t, --toon            Output in TOON format (map.toon)
                \\  --format <format>     Output format: "csv", "json", or "toon" (default: "csv")
                \\  -v, --version         Print version and exit
                \\  -h, --help            Show this help message
                \\
            ;
            try std.Io.File.stdout().writeStreamingAll(io, help_text);
            return;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            format = .json;
        } else if (std.mem.eql(u8, arg, "--toon") or std.mem.eql(u8, arg, "-t")) {
            format = .toon;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 < args.len) {
                const fmt_str = args[i + 1];
                if (std.mem.eql(u8, fmt_str, "json")) {
                    format = .json;
                } else if (std.mem.eql(u8, fmt_str, "toon")) {
                    format = .toon;
                } else if (std.mem.eql(u8, fmt_str, "csv")) {
                    format = .csv;
                } else {
                    std.debug.print("Error: Invalid format '{s}'. Must be 'csv', 'json' or 'toon'.\n", .{fmt_str});
                    std.process.exit(1);
                }
                i += 1;
            } else {
                std.debug.print("Error: Option '{s}' requires an argument.\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "-d")) {
            if (i + 1 < args.len) {
                target_dir = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: Option '{s}' requires an argument.\n", .{arg});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 < args.len) {
                output_file = args[i + 1];
                i += 1;
            } else {
                std.debug.print("Error: Option '{s}' requires an argument.\n", .{arg});
                std.process.exit(1);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target_dir == null) {
                target_dir = arg;
            } else {
                std.debug.print("Error: Unknown or extra argument '{s}'\nRun 'map-builder --help' for usage.\n", .{arg});
                std.process.exit(1);
            }
        } else {
            std.debug.print("Error: Unknown option '{s}'\nRun 'map-builder --help' for usage.\n", .{arg});
            std.process.exit(1);
        }
    }

    // Default to the current directory "." instead of "docs" per project requirement
    const dir_to_scan = target_dir orelse ".";
    const default_out = switch (format) {
        .csv => "map.csv",
        .json => "map.json",
        .toon => "map.toon",
    };
    
    // Resolve out_path: if target_dir is explicitly specified, default to writing inside it.
    const out_path = if (output_file) |o|
        try alloc.dupe(u8, o)
    else if (target_dir) |td|
        try std.fs.path.join(alloc, &.{ td, default_out })
    else
        try alloc.dupe(u8, default_out);
    defer alloc.free(out_path);

    var entries = try scanner.scanDir(alloc, io, dir_to_scan, "");
    defer {
        for (entries.items) |*e| e.deinit(alloc);
        entries.deinit(alloc);
    }

    std.mem.sort(entry.Entry, entries.items, {}, entry.entryLessThan);

    switch (format) {
        .csv => {
            var flat_list = std.ArrayList(entry.FlatEntry).empty;
            defer flat_list.deinit(alloc);

            // Collect all entries recursively into flat list and sort alphabetically by path
            try entry.collectFlat(alloc, entries.items, &flat_list);
            std.mem.sort(entry.FlatEntry, flat_list.items, {}, entry.flatEntryLessThan);

            var csv_writer = std.Io.Writer.Allocating.init(alloc);
            defer csv_writer.deinit();

            try csv_writer.writer.writeAll("name,description,path\n");
            for (flat_list.items) |fe| {
                try entry.writeCsvField(&csv_writer.writer, fe.name);
                try csv_writer.writer.writeByte(',');
                try entry.writeCsvField(&csv_writer.writer, fe.description);
                try csv_writer.writer.writeByte(',');
                try entry.writeCsvField(&csv_writer.writer, fe.path);
                try csv_writer.writer.writeByte('\n');
            }

            const out = try csv_writer.toOwnedSlice();
            defer alloc.free(out);

            // Check if the file already exists and has the exact same content
            // to avoid unnecessary disk writes and suppress the update output.
            var up_to_date = false;
            if (std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .unlimited)) |existing_data| {
                defer alloc.free(existing_data);
                if (std.mem.eql(u8, existing_data, out)) {
                    up_to_date = true;
                }
            } else |_| {}

            if (!up_to_date) {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out });
                std.debug.print("Updated {s} with {d} entries.\n", .{out_path, flat_list.items.len});
            } else {
                std.debug.print("nothing changed, didn't update {s}\n", .{out_path});
            }
        },
        .json => {
            var json_writer = std.Io.Writer.Allocating.init(alloc);
            defer json_writer.deinit();

            var stringify: std.json.Stringify = .{ .writer = &json_writer.writer, .options = .{ .whitespace = .indent_2 } };
            try stringify.write(entries.items);
            try json_writer.writer.writeByte('\n');

            const out = try json_writer.toOwnedSlice();
            defer alloc.free(out);

            // Check if the file already exists and has the exact same content
            // to avoid unnecessary disk writes and suppress the update output.
            var up_to_date = false;
            if (std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .unlimited)) |existing_data| {
                defer alloc.free(existing_data);
                if (std.mem.eql(u8, existing_data, out)) {
                    up_to_date = true;
                }
            } else |_| {}

            if (!up_to_date) {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out });
                std.debug.print("Updated {s} with {d} entries.\n", .{out_path, entries.items.len});
            } else {
                std.debug.print("nothing changed, didn't update {s}\n", .{out_path});
            }
        },
        .toon => {
            var toon_writer = std.Io.Writer.Allocating.init(alloc);
            defer toon_writer.deinit();

            try toon_writer.writer.print("[{d}]:\n", .{entries.items.len});
            for (entries.items) |e| {
                try e.writeToon(&toon_writer.writer, 4, true);
            }

            const out = try toon_writer.toOwnedSlice();
            defer alloc.free(out);

            // Check if the file already exists and has the exact same content
            // to avoid unnecessary disk writes and suppress the update output.
            var up_to_date = false;
            if (std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .unlimited)) |existing_data| {
                defer alloc.free(existing_data);
                if (std.mem.eql(u8, existing_data, out)) {
                    up_to_date = true;
                }
            } else |_| {}

            if (!up_to_date) {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out });
                std.debug.print("Updated {s} with {d} entries.\n", .{out_path, entries.items.len});
            } else {
                std.debug.print("nothing changed, didn't update {s}\n", .{out_path});
            }
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "map-builder: scanning a custom target folder" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const temp_base = "test_map_builder_temp";
    var cwd_dir = std.Io.Dir.cwd();
    
    cwd_dir.deleteTree(io, temp_base) catch |err| {
        std.log.debug("cleanup temp base failed: {any}", .{err});
    };

    var temp_dir = try cwd_dir.createDirPathOpen(io, temp_base, .{});
    defer {
        temp_dir.close(io);
        cwd_dir.deleteTree(io, temp_base) catch {};
    }

    try temp_dir.writeFile(io, .{ .sub_path = "test.md", .data = "---\nname: \"test-node\"\ndescription: \"Test Description\"\n---\nHello" });

    var entries = try scanner.scanDir(allocator, io, temp_base, "");
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("test-node", entries.items[0].name.?);
    try testing.expectEqualStrings("Test Description", entries.items[0].description.?);
    try testing.expectEqualStrings("test.md", entries.items[0].path);
}
