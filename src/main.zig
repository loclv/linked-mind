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
        std.debug.print("Usage: {s} <mode: scan|export> <knowledge_base_dir>\n", .{args[0]});
        return;
    }

    const mode = args[1];
    const kb_dir_path = args[2];
    var kb_dir = try std.fs.openDirAbsolute(kb_dir_path, .{ .iterate = true });
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

    if (std.mem.eql(u8, mode, "export")) {
        var bundle = std.ArrayListUnmanaged(u8){};
        defer bundle.deinit(allocator);
        
        try bundle.writer(allocator).print("# LLM Knowledge Bundle\nGenerated on: {s}\n\n", .{"2026-04-06"});
        
        var iter = kb_graph.nodes.iterator();
        while (iter.next()) |entry| {
            const ctx = try kb_graph.getContext(entry.key_ptr.*);
            defer allocator.free(ctx);
            try bundle.writer(allocator).print("---\n{s}\n", .{ctx});
        }
        
        try std.fs.cwd().writeFile(.{ .sub_path = "llm_knowledge.md", .data = bundle.items });
        std.debug.print("Knowledge bundle written to llm_knowledge.md\n", .{});
    } else {
        var iter = kb_graph.nodes.iterator();
        while (iter.next()) |entry| {
            const ctx = try kb_graph.getContext(entry.key_ptr.*);
            defer allocator.free(ctx);
            std.debug.print("\n--- Knowledge Item ---\n{s}\n", .{ctx});
        }
    }
}
