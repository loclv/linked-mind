const std = @import("std");

const cache = @import("cache.zig");
const graph = @import("graph.zig");
const parser = @import("parser.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var kb_graph = graph.Graph.init(allocator);
    defer kb_graph.deinit();

    var kb_parser = parser.Parser.init(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print(
            \\Usage:
            \\  {s} scan <kb_dir> [--tag <tag>] [--status <status>]
            \\  {s} export <kb_dir> [--tag <tag>] [--status <status>]
            \\  {s} path <kb_dir> <start_node> <end_node>
            \\  {s} clusters <kb_dir>
            \\  {s} gc <kb_dir> [--threshold <n>]
            \\  {s} similar <kb_dir> <node_title>
            \\  {s} suggest <kb_dir> [--threshold <0.1>]
            \\  {s} visualize <kb_dir>
            \\
        , .{ args[0], args[0], args[0], args[0], args[0], args[0], args[0], args[0] });
        return;
    }

    const mode = args[1];
    const kb_dir_path = args[2];

    // Flag parsing (Global)
    var filter_tag: ?[]const u8 = null;
    var filter_status: ?[]const u8 = null;

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

    var kb_dir = try std.fs.cwd().openDir(kb_dir_path, .{ .iterate = true });
    defer kb_dir.close();

    var kb_cache = cache.Cache.init(allocator);
    defer kb_cache.deinit();
    kb_cache.load("cache.json") catch |err| {
        std.debug.print("Note: Could not load cache.json: {any}. Starting fresh.\n", .{err});
    };

    var new_cache = cache.Cache.init(allocator);
    defer new_cache.deinit();

    var walker = try kb_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
            const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ kb_dir_path, entry.path });
            defer allocator.free(absolute_path);

            const stat = try kb_dir.statFile(entry.path);
            const mtime = stat.mtime;

            var cached_entry: ?*cache.CacheEntry = null;
            if (kb_cache.entries.getPtr(absolute_path)) |cached| {
                if (cached.mtime == mtime) {
                    cached_entry = cached;
                } else {
                    const hash = try calculateHash(absolute_path);
                    if (std.mem.eql(u8, &hash, &cached.hash)) {
                        cached_entry = cached;
                        // Still update mtime so we skip hashing next time
                        cached_entry.?.*.mtime = mtime;
                    }
                }
            }

            if (cached_entry) |ce| {
                try kb_graph.addNode(try ce.node.clone(allocator));
                // Add to new cache
                const new_node_copy = try ce.node.clone(allocator);
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = ce.mtime,
                    .hash = ce.hash,
                    .node = new_node_copy,
                });
            } else {
                const node = try kb_parser.parseFile(absolute_path);
                const hash = try calculateHash(absolute_path);

                // Add a clone to the graph because new_cache will own the 'node' struct
                try kb_graph.addNode(try node.clone(allocator));

                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = mtime,
                    .hash = hash,
                    .node = node, // ownership transferred to new_cache
                });
            }
        }
    }

    try new_cache.save("cache.json");

    try kb_graph.resolveBacklinks();
    var pr_scores = try kb_graph.computePageRank(10);
    defer pr_scores.deinit();

    if (std.mem.eql(u8, mode, "export")) {
        var bundle: std.ArrayList(u8) = .{};
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

            const rank = pr_scores.get(node.title) orelse 0.0;
            try bundle.writer(allocator).print("**PageRank:** {d:.4}\n", .{rank});
            try bundle.writer(allocator).print("---\n{s}\n", .{ctx});
        }

        try std.fs.cwd().writeFile(.{ .sub_path = "llm_knowledge.md", .data = bundle.items });
        std.debug.print("Knowledge bundle written to llm_knowledge.md\n", .{});
    } else if (std.mem.eql(u8, mode, "path")) {
        if (args.len < 5) {
            std.debug.print(
                \\Usage: {s} path <kb_dir> <start_node> <end_node>
                \\
            , .{args[0]});
            return;
        }
        const start = args[3];
        const end = args[4];

        if (try kb_graph.findShortestPath(start, end)) |path| {
            defer allocator.free(path);
            std.debug.print("Shortest path from '{s}' to '{s}':\n", .{ start, end });
            for (path, 0..) |step, i| {
                std.debug.print("{s}{s}", .{ step, if (i == path.len - 1) "" else " -> " });
                allocator.free(step);
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("No path found between '{s}' and '{s}'.\n", .{ start, end });
        }
    } else if (std.mem.eql(u8, mode, "clusters")) {
        const moc = try kb_graph.generateMoc();
        defer allocator.free(moc);

        try std.fs.cwd().writeFile(.{ .sub_path = "MOC.md", .data = moc });
        std.debug.print("Map of Content written to MOC.md\nClusters detected and grouped.\n", .{});
    } else if (std.mem.eql(u8, mode, "gc")) {
        var threshold: usize = 3;
        var arg_j: usize = 3;
        while (arg_j < args.len) : (arg_j += 1) {
            if (std.mem.eql(u8, args[arg_j], "--threshold") and arg_j + 1 < args.len) {
                threshold = try std.fmt.parseInt(usize, args[arg_j + 1], 10);
                arg_j += 1;
            }
        }

        var report = try kb_graph.getGcReport(threshold);
        defer report.deinit(allocator);

        std.debug.print("# Knowledge Garbage Collection Report\n\n", .{});

        std.debug.print("## Orphan Notes ({d})\n", .{report.orphans.items.len});
        if (report.orphans.items.len == 0) {
            std.debug.print("No orphan notes found.\n", .{});
        } else {
            for (report.orphans.items) |node| {
                std.debug.print("- [[{s}]] ({s})\n", .{ node.title, node.path });
            }
        }

        std.debug.print("\n## Island Nodes (Small Detached Cliques, size <= {d})\n", .{threshold});
        if (report.islands.items.len == 0) {
            std.debug.print("No island nodes found.\n", .{});
        } else {
            for (report.islands.items, 0..) |cluster, i| {
                std.debug.print("Island {d} (Size: {d}):\n", .{ i + 1, cluster.nodes.items.len });
                for (cluster.nodes.items) |node| {
                    std.debug.print("  - [[{s}]] ({s})\n", .{ node.title, node.path });
                }
            }
        }
    } else if (std.mem.eql(u8, mode, "similar")) {
        if (args.len < 4) {
            std.debug.print(
                \\Usage: {s} similar <kb_dir> <node_title>
                \\
            , .{args[0]});
            return;
        }
        const target = args[3];
        const similarities = try kb_graph.findSimilarNodes(target, 5);
        defer allocator.free(similarities);

        if (similarities.len == 0) {
            std.debug.print("No similar nodes found for '{s}'.\n", .{target});
        } else {
            std.debug.print("Nodes similar to '{s}':\n", .{target});
            for (similarities) |sim| {
                std.debug.print("- {s} (Score: {d:.4})\n", .{ sim.node.title, sim.score });
            }
        }
    } else if (std.mem.eql(u8, mode, "suggest")) {
        // Link suggestion: find content-similar but unlinked node pairs
        var suggest_threshold: f32 = 0.1;
        var arg_j: usize = 3;
        while (arg_j < args.len) : (arg_j += 1) {
            if (std.mem.eql(u8, args[arg_j], "--threshold") and arg_j + 1 < args.len) {
                suggest_threshold = try std.fmt.parseFloat(f32, args[arg_j + 1]);
                arg_j += 1;
            }
        }

        const suggestions = try kb_graph.suggestLinks(suggest_threshold, 10);
        defer allocator.free(suggestions);

        if (suggestions.len == 0) {
            std.debug.print("No link suggestions found (threshold: {d:.2}).\n", .{suggest_threshold});
        } else {
            std.debug.print("# Suggested Links (threshold >= {d:.2})\n\n", .{suggest_threshold});
            for (suggestions) |s| {
                std.debug.print("- [[{s}]] <-> [[{s}]] (Similarity: {d:.4})\n", .{ s.source.title, s.target.title, s.score });
            }
        }
    } else if (std.mem.eql(u8, mode, "visualize")) {
        const json_data = try kb_graph.exportGraphJson();
        defer allocator.free(json_data);

        try std.fs.cwd().writeFile(.{ .sub_path = "graph.json", .data = json_data });
        std.debug.print("Graph data written to graph.json. Use a web server to view the dashboard.\n", .{});
    } else {
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
            const rank = pr_scores.get(node.title) orelse 0.0;
            std.debug.print("\n--- Knowledge Item (Rank: {d:.4}) ---\n{s}\n", .{ rank, ctx });
        }
    }
}

fn calculateHash(path: []const u8) ![32]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;
        hash.update(buffer[0..bytes_read]);
    }
    return hash.finalResult();
}
