const std = @import("std");
const parser = @import("parser.zig");
const graph = @import("graph.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var kb_graph = graph.Graph.init(allocator);
    defer kb_graph.deinit();

    var kb_parser = parser.Parser.init(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage:\n", .{});
        std.debug.print("  {s} scan <kb_dir>\n", .{args[0]});
        std.debug.print("  {s} export <kb_dir> [--tag <tag>] [--status <status>]\n", .{args[0]});
        std.debug.print("  {s} path <kb_dir> <start_node> <end_node>\n", .{args[0]});
        return;
    }

    const mode = args[1];
    const kb_dir_path = args[2];
    
    // Simple command line parsing for flags
    var filter_tag: ?[]const u8 = null;
    var filter_status: ?[]const u8 = null;
    
    if (std.mem.eql(u8, mode, "export")) {
        var arg_i: usize = 3;
        while (arg_i < args.len) : (arg_i += 1) {
            if (std.mem.eql(u8, args[arg_i], "--tag") and arg_i + 1 < args.len) {
                filter_tag = args[arg_i + 1];
                arg_i += 1;
            } else if (std.mem.eql(u8, args[arg_i], "--status") and arg_i + 1 < args.len) {
                filter_status = args[arg_i + 1];
                arg_i += 1;
            }
        }
    }

    var kb_dir = try std.fs.cwd().openDir(kb_dir_path, .{ .iterate = true });
    defer kb_dir.close();

    var walker = try kb_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
            const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ kb_dir_path, entry.path });
            defer allocator.free(absolute_path);

            const node = try kb_parser.parseFile(absolute_path);
            try kb_graph.addNode(node);
        }
    }

    try kb_graph.resolveBacklinks();

    if (std.mem.eql(u8, mode, "export")) {
        var bundle = std.ArrayListUnmanaged(u8){};
        defer bundle.deinit(allocator);
        
        try bundle.writer(allocator).print("# LLM Knowledge Bundle\nGenerated on: {s}\n", .{"2026-04-07"});
        if (filter_tag) |t| try bundle.writer(allocator).print("Filter Tag: {s}\n", .{t});
        if (filter_status) |s| try bundle.writer(allocator).print("Filter Status: {s}\n", .{s});
        try bundle.writer(allocator).print("\n", .{});
        
        var iter = kb_graph.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr;
            
            // Check filters
            if (filter_tag) |t| {
                var found_tag = false;
                for (node.tags.items) |tag| {
                    if (std.mem.eql(u8, tag, t)) {
                        found_tag = true;
                        break;
                    }
                }
                if (!found_tag) continue;
            }
            
            if (filter_status) |s| {
                const status = node.metadata.get("status") orelse "";
                if (!std.mem.eql(u8, status, s)) continue;
            }

            const ctx = try kb_graph.getContext(entry.key_ptr.*);
            defer allocator.free(ctx);
            try bundle.writer(allocator).print("---\n{s}\n", .{ctx});
        }
        
        try std.fs.cwd().writeFile(.{ .sub_path = "llm_knowledge.md", .data = bundle.items });
        std.debug.print("Knowledge bundle written to llm_knowledge.md\n", .{});
    } else if (std.mem.eql(u8, mode, "path")) {
        if (args.len < 5) {
            std.debug.print("Usage: {s} path <kb_dir> <start_node> <end_node>\n", .{args[0]});
            return;
        }
        const start = args[3];
        const end = args[4];
        
        if (try kb_graph.findShortestPath(start, end)) |path| {
            defer allocator.free(path);
            std.debug.print("Shortest path from '{s}' to '{s}':\n", .{start, end});
            for (path, 0..) |step, i| {
                std.debug.print("{s}{s}", .{step, if (i == path.len - 1) "" else " -> "});
                allocator.free(step);
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("No path found between '{s}' and '{s}'.\n", .{start, end});
        }
    } else {
        var iter = kb_graph.nodes.iterator();
        while (iter.next()) |entry| {
            const ctx = try kb_graph.getContext(entry.key_ptr.*);
            defer allocator.free(ctx);
            std.debug.print("\n--- Knowledge Item ---\n{s}\n", .{ctx});
        }
    }
}

