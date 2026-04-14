const std = @import("std");

const cache = @import("cache.zig");
const graph = @import("graph.zig");
const parser = @import("parser.zig");

const usage =
    \\Usage: li <command> [options]
    \\
    \\Commands:
    \\  init [path]       Initialize a Linked-Mind workspace (creates .li/)
    \\  scan              Scan the workspace and update cache
    \\  export            Export workspace to llm_knowledge.md
    \\  path <A> <B>      Find shortest path between nodes A and B
    \\  clusters          Generate community detection map (map.csv)
    \\  gc [--threshold]  Identify orphan and island nodes
    \\  similar <title>   Find nodes similar to the given title
    \\  suggest           Suggest missing links based on similarity
    \\  visualize         Export graph.json for web visualization
    \\  watch [path]      Watch folder for changes and emit events (JSON)
    \\
    \\Global Options:
    \\  --tag <tag>       Filter results by tag
    \\  --status <status> Filter results by status metadata
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "init")) {
        const target_path = if (args.len > 2) args[2] else ".";
        try initWorkspace(allocator, target_path);
        return;
    }

    const ws_root = findWorkspaceRoot(allocator) catch |err| {
        if (err == error.NoWorkspaceFound) {
            std.debug.print("Fatal: Not in a Linked-Mind workspace. Run 'li init' to create one.\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer allocator.free(ws_root);

    try runCommand(allocator, cmd, ws_root, args[2..]);
}

fn initWorkspace(_: std.mem.Allocator, path: []const u8) !void {
    var dir = try std.fs.cwd().makeOpenPath(path, .{});
    defer dir.close();

    dir.makeDir(".li") catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("Reinitialized existing Linked-Mind workspace in {s}/.li/\n", .{path});
            return;
        }
        return err;
    };

    std.debug.print("Initialized empty Linked-Mind workspace in {s}/.li/\n", .{path});
}

fn findWorkspaceRoot(allocator: std.mem.Allocator) ![]const u8 {
    var current_path = try std.fs.cwd().realpathAlloc(allocator, ".");

    while (true) {
        var dir = std.fs.openDirAbsolute(current_path, .{}) catch break;
        defer dir.close();

        dir.access(".li", .{}) catch {
            const parent = std.fs.path.dirname(current_path);
            if (parent == null or std.mem.eql(u8, parent.?, current_path)) break;
            const next_path = try allocator.dupe(u8, parent.?);
            allocator.free(current_path);
            current_path = next_path;
            continue;
        };

        return current_path;
    }

    return error.NoWorkspaceFound;
}

fn runCommand(allocator: std.mem.Allocator, cmd: []const u8, ws_root: []const u8, args: [][:0]u8) !void {
    var kb_graph = graph.Graph.init(allocator);
    defer kb_graph.deinit();

    var kb_parser = parser.Parser.init(allocator);

    var filter_tag: ?[]const u8 = null;
    var filter_status: ?[]const u8 = null;
    var threshold: usize = 3;
    var suggest_threshold: f32 = 0.1;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--tag") and i + 1 < args.len) {
            filter_tag = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
            filter_status = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--threshold") and i + 1 < args.len) {
            if (std.mem.eql(u8, cmd, "gc")) {
                threshold = try std.fmt.parseInt(usize, args[i + 1], 10);
            } else if (std.mem.eql(u8, cmd, "suggest")) {
                suggest_threshold = try std.fmt.parseFloat(f32, args[i + 1]);
            }
            i += 1;
        }
    }

    var kb_dir = try std.fs.openDirAbsolute(ws_root, .{ .iterate = true });
    defer kb_dir.close();

    const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, ".li", "cache.json" });
    defer allocator.free(cache_path);

    var kb_cache = cache.Cache.init(allocator);
    defer kb_cache.deinit();
    kb_cache.load(cache_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Note: Could not load cache: {any}. Starting fresh.\n", .{err});
        }
    };

    var new_cache = cache.Cache.init(allocator);
    defer new_cache.deinit();

    var walker = try kb_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // Skip .li and other hidden dirs
        if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
            const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, entry.path });
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
                        cached_entry.?.*.mtime = mtime;
                    }
                }
            }

            if (cached_entry) |ce| {
                try kb_graph.addNode(try ce.node.clone(allocator));
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = ce.mtime,
                    .hash = ce.hash,
                    .node = try ce.node.clone(allocator),
                });
            } else {
                const node = try kb_parser.parseFile(absolute_path);
                const hash = try calculateHash(absolute_path);
                try kb_graph.addNode(try node.clone(allocator));
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = mtime,
                    .hash = hash,
                    .node = node,
                });
            }
        }
    }

    try new_cache.save(cache_path);

    try kb_graph.resolveBacklinks();
    var pr_scores = try kb_graph.computePageRank(10);
    defer pr_scores.deinit();

    if (std.mem.eql(u8, cmd, "scan")) {
        std.debug.print("Workspace scanned. {d} nodes processed.\n", .{kb_graph.nodes.count()});
    } else if (std.mem.eql(u8, cmd, "export")) {
        const export_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, "llm_knowledge.md" });
        defer allocator.free(export_path);

        var bundle: std.ArrayList(u8) = .{};
        defer bundle.deinit(allocator);

        try bundle.writer(allocator).print("# LLM Knowledge Bundle\nGenerated on: 2026-04-10\n", .{});
        if (filter_tag) |t| try bundle.writer(allocator).print("Filter Tag: {s}\n", .{t});
        if (filter_status) |s| try bundle.writer(allocator).print("Filter Status: {s}\n", .{s});
        try bundle.writer(allocator).print("\n", .{});

        var iter = kb_graph.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr;
            if (filter_tag) |t| {
                var found = false;
                for (node.tags.items) |tag| {
                    if (std.mem.eql(u8, tag, t)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
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
        try std.fs.cwd().writeFile(.{ .sub_path = export_path, .data = bundle.items });
        std.debug.print("Knowledge bundle written to {s}\n", .{export_path});
    } else if (std.mem.eql(u8, cmd, "path")) {
        if (args.len < 2) {
            std.debug.print("Usage: li path <start> <end>\n", .{});
            return;
        }
        const start = args[0];
        const end = args[1];
        if (try kb_graph.findShortestPath(start, end)) |path| {
            defer allocator.free(path);
            std.debug.print("Shortest path: ", .{});
            for (path, 0..) |step, j| {
                std.debug.print("{s}{s}", .{ step, if (j == path.len - 1) "" else " -> " });
                allocator.free(step);
            }
            std.debug.print("\n", .{});
        } else {
            std.debug.print("No path found.\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "clusters")) {
        const csv = try kb_graph.generateMapCsv();
        defer allocator.free(csv);
        const csv_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, "map.csv" });
        defer allocator.free(csv_path);
        try std.fs.cwd().writeFile(.{ .sub_path = csv_path, .data = csv });
        std.debug.print("Map written to {s}\n", .{csv_path});
    } else if (std.mem.eql(u8, cmd, "gc")) {
        var report = try kb_graph.getGcReport(threshold);
        defer report.deinit(allocator);
        std.debug.print("# Garbage Collection Report (Threshold: {d})\n\n", .{threshold});
        std.debug.print("## Orphans: {d}\n", .{report.orphans.items.len});
        for (report.orphans.items) |node| std.debug.print("- [[{s}]]\n", .{node.title});
        std.debug.print("\n## Islands: {d}\n", .{report.islands.items.len});
        for (report.islands.items, 0..) |c, j| {
            std.debug.print("Island {d}: ", .{j + 1});
            for (c.nodes.items) |node| std.debug.print("[[{s}]] ", .{node.title});
            std.debug.print("\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "similar")) {
        if (args.len < 1) {
            std.debug.print("Usage: li similar <title>\n", .{});
            return;
        }
        const target = args[0];
        const sims = try kb_graph.findSimilarNodes(target, 5);
        defer allocator.free(sims);
        for (sims) |sim| std.debug.print("- {s} ({d:.4})\n", .{ sim.node.title, sim.score });
    } else if (std.mem.eql(u8, cmd, "suggest")) {
        const suggs = try kb_graph.suggestLinks(suggest_threshold, 10);
        defer allocator.free(suggs);
        for (suggs) |s| std.debug.print("- [[{s}]] <-> [[{s}]] ({d:.4})\n", .{ s.source.title, s.target.title, s.score });
    } else if (std.mem.eql(u8, cmd, "visualize")) {
        const json = try kb_graph.exportGraphJson();
        defer allocator.free(json);
        const json_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, "graph.json" });
        defer allocator.free(json_path);
        try std.fs.cwd().writeFile(.{ .sub_path = json_path, .data = json });
        std.debug.print("Visualizer data written to {s}\n", .{json_path});
    } else if (std.mem.eql(u8, cmd, "watch")) {
        const watch_path_raw = if (args.len > 0) args[0] else ws_root;
        const watch_path = try std.fs.cwd().realpathAlloc(allocator, watch_path_raw);
        defer allocator.free(watch_path);
        try watchWorkspace(allocator, watch_path);
    } else {
        std.debug.print("Unknown command: {s}\n{s}", .{ cmd, usage });
    }
}

fn watchWorkspace(allocator: std.mem.Allocator, watch_path: []const u8) !void {
    var kb_parser = parser.Parser.init(allocator);
    var known_files = std.StringHashMap(i128).init(allocator);
    defer {
        var iter = known_files.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        known_files.deinit();
    }

    // Pre-scan to populate known_files
    {
        var watch_dir = try std.fs.openDirAbsolute(watch_path, .{ .iterate = true });
        defer watch_dir.close();
        var walker = try watch_dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
                const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ watch_path, entry.path });
                const stat = watch_dir.statFile(entry.path) catch |err| {
                    if (err == error.FileNotFound) {
                        allocator.free(abs_path);
                        continue;
                    }
                    return err;
                };
                try known_files.put(abs_path, stat.mtime);
            }
        }
    }

    std.debug.print("Watching {s} for changes... (Press Ctrl+C to stop)\n", .{watch_path});

    while (true) {
        var current_files = std.StringHashMap(i128).init(allocator);
        defer {
            var iter = current_files.iterator();
            while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
            current_files.deinit();
        }

        var watch_dir = std.fs.openDirAbsolute(watch_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Error opening watch directory: {any}\n", .{err});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        };
        defer watch_dir.close();

        var walker = try watch_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
                const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ watch_path, entry.path });
                const stat = watch_dir.statFile(entry.path) catch |err| {
                    if (err == error.FileNotFound) {
                        allocator.free(abs_path);
                        continue;
                    }
                    return err;
                };
                try current_files.put(abs_path, stat.mtime);
            }
        }

        // Check for deleted files
        var known_iter = known_files.iterator();
        while (known_iter.next()) |entry| {
            if (!current_files.contains(entry.key_ptr.*)) {
                std.debug.print("{{\"event\": \"deleted\", \"path\": \"{s}\"}}\n", .{entry.key_ptr.*});
            }
        }

        // Check for created or updated files
        var current_iter = current_files.iterator();
        while (current_iter.next()) |entry| {
            const path = entry.key_ptr.*;
            const mtime = entry.value_ptr.*;

            if (known_files.get(path)) |known_mtime| {
                if (mtime > known_mtime) {
                    // Updated
                    var node = try kb_parser.parseFile(path);
                    defer node.deinit(allocator);
                    std.debug.print("{{\"event\": \"updated\", \"path\": \"{s}\", \"node\": ", .{path});
                    serializeNodeToDebug(node);
                    std.debug.print("}}\n", .{});
                }
            } else {
                // Created
                var node = try kb_parser.parseFile(path);
                defer node.deinit(allocator);
                std.debug.print("{{\"event\": \"created\", \"path\": \"{s}\", \"node\": ", .{path});
                serializeNodeToDebug(node);
                std.debug.print("}}\n", .{});
            }
        }

        // Update known_files
        // Clear and refill to be safe with keys
        var old_iter = known_files.iterator();
        while (old_iter.next()) |entry| allocator.free(entry.key_ptr.*);
        known_files.clearRetainingCapacity();

        var new_iter = current_files.iterator();
        while (new_iter.next()) |entry| {
            try known_files.put(try allocator.dupe(u8, entry.key_ptr.*), entry.value_ptr.*);
        }

        std.Thread.sleep(1 * std.time.ns_per_s);
    }
}

fn serializeNodeToDebug(node: parser.Node) void {
    std.debug.print("{{\"title\": {f}, \"id\": {f}, \"tags\": [", .{
        std.json.fmt(node.title, .{}),
        std.json.fmt(node.id, .{}),
    });
    for (node.tags.items, 0..) |tag, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("{f}", .{std.json.fmt(tag, .{})});
    }
    std.debug.print("], \"links\": [", .{});
    for (node.links.items, 0..) |link, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("{{\"target\": {f}, \"nature\": ", .{std.json.fmt(link.target, .{})});
        if (link.nature) |nat| {
            std.debug.print("{f}", .{std.json.fmt(nat, .{})});
        } else {
            std.debug.print("null", .{});
        }
        std.debug.print("}}", .{});
    }
    std.debug.print("]}}", .{});
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

// Helper: create a temp dir, return its path, caller must clean up
fn createTempDir(allocator: std.mem.Allocator) !struct { dir: std.fs.Dir, path: []const u8 } {
    const base = try std.fs.cwd().makeOpenPath("/tmp", .{});
    defer base.close();
    var buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "li-test-{d}", .{std.time.milliTimestamp()});
    const dir = try base.makeOpenPath(name, .{});
    const path = try std.fs.path.join(allocator, &.{ "/tmp", name });
    return .{ .dir = dir, .path = path };
}

test "li: initWorkspace creates .li directory" {
    const allocator = std.testing.allocator;
    const tmp = try createTempDir(allocator);
    defer allocator.free(tmp.path);
    defer {
        var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        var li_dir = tmp_dir.openDir(tmp.path[5..], .{ .iterate = true }) catch unreachable;
        li_dir.deleteTree(".li") catch {};
        li_dir.close();
        tmp_dir.deleteTree(tmp.path[5..]) catch {};
        tmp_dir.close();
    }

    try initWorkspace(allocator, tmp.path);

    // Verify .li exists
    var dir = try std.fs.openDirAbsolute(tmp.path, .{});
    defer dir.close();
    dir.access(".li", .{}) catch |err| {
        std.debug.print(".li dir not found after init: {any}\n", .{err});
        return err;
    };
}

test "li: initWorkspace reinit on existing .li returns ok" {
    const allocator = std.testing.allocator;
    const tmp = try createTempDir(allocator);
    defer allocator.free(tmp.path);
    defer {
        var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        var li_dir = tmp_dir.openDir(tmp.path[5..], .{ .iterate = true }) catch unreachable;
        li_dir.deleteTree(".li") catch {};
        li_dir.close();
        tmp_dir.deleteTree(tmp.path[5..]) catch {};
        tmp_dir.close();
    }

    // First init
    try initWorkspace(allocator, tmp.path);
    // Second init should succeed (reinit)
    try initWorkspace(allocator, tmp.path);
}

test "li: findWorkspaceRoot finds .li in current dir" {
    const allocator = std.testing.allocator;
    const tmp = try createTempDir(allocator);
    defer allocator.free(tmp.path);
    defer {
        var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        var li_dir = tmp_dir.openDir(tmp.path[5..], .{ .iterate = true }) catch unreachable;
        li_dir.deleteTree(".li") catch {};
        li_dir.close();
        tmp_dir.deleteTree(tmp.path[5..]) catch {};
        tmp_dir.close();
    }

    // Create .li in temp dir
    try initWorkspace(allocator, tmp.path);

    // cd into temp dir and find workspace root
    const original_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_dir);

    var tmp_dir = try std.fs.openDirAbsolute(tmp.path, .{});
    defer tmp_dir.close();
    // Change cwd to temp dir
    try tmp_dir.setAsCwd();
    defer {
        var orig = std.fs.openDirAbsolute(original_dir, .{}) catch unreachable;
        orig.setAsCwd() catch {};
        orig.close();
    }

    const root = try findWorkspaceRoot(allocator);
    defer allocator.free(root);

    // Root should match tmp.path (or be a parent containing it)
    try std.testing.expect(std.mem.indexOf(u8, tmp.path, root) != null or std.mem.eql(u8, root, tmp.path));
}

test "li: findWorkspaceRoot returns NoWorkspaceFound when no .li exists" {
    const allocator = std.testing.allocator;
    const tmp = try createTempDir(allocator);
    defer allocator.free(tmp.path);
    defer {
        var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        tmp_dir.deleteTree(tmp.path[5..]) catch {};
        tmp_dir.close();
    }

    const original_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_dir);

    var tmp_dir = try std.fs.openDirAbsolute(tmp.path, .{});
    defer tmp_dir.close();
    try tmp_dir.setAsCwd();
    defer {
        var orig = std.fs.openDirAbsolute(original_dir, .{}) catch unreachable;
        orig.setAsCwd() catch {};
        orig.close();
    }

    const result = findWorkspaceRoot(allocator);
    try std.testing.expectError(error.NoWorkspaceFound, result);
}

test "li: calculateHash returns consistent SHA256" {
    const allocator = std.testing.allocator;
    const tmp = try createTempDir(allocator);
    defer allocator.free(tmp.path);
    defer {
        var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        tmp_dir.deleteTree(tmp.path[5..]) catch {};
        tmp_dir.close();
    }

    // Write known content to a file
    const file_path = try std.fs.path.join(allocator, &.{ tmp.path, "test.txt" });
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "hello world" });

    const hash1 = try calculateHash(file_path);
    const hash2 = try calculateHash(file_path);

    // Same content must produce same hash
    try std.testing.expect(std.mem.eql(u8, &hash1, &hash2));

    // Write different content
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "different content" });
    const hash3 = try calculateHash(file_path);

    // Different content must produce different hash
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

test "li: findWorkspaceRoot finds .li in parent directory" {
    const allocator = std.testing.allocator;
    const tmp = try createTempDir(allocator);
    defer allocator.free(tmp.path);
    defer {
        var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch unreachable;
        var li_dir = tmp_dir.openDir(tmp.path[5..], .{ .iterate = true }) catch unreachable;
        li_dir.deleteTree(".li") catch {};
        li_dir.deleteTree("subdir") catch {};
        li_dir.close();
        tmp_dir.deleteTree(tmp.path[5..]) catch {};
        tmp_dir.close();
    }

    // Create .li in temp dir (parent)
    try initWorkspace(allocator, tmp.path);

    // Create subdir inside temp dir
    const subdir_path = try std.fs.path.join(allocator, &.{ tmp.path, "subdir" });
    defer allocator.free(subdir_path);
    var sub = try std.fs.openDirAbsolute(tmp.path, .{});
    defer sub.close();
    try sub.makePath("subdir");

    // cd into subdir and find workspace root (should find .li in parent)
    const original_dir = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(original_dir);

    var subdir = try std.fs.openDirAbsolute(subdir_path, .{});
    defer subdir.close();
    try subdir.setAsCwd();
    defer {
        var orig = std.fs.openDirAbsolute(original_dir, .{}) catch unreachable;
        orig.setAsCwd() catch {};
        orig.close();
    }

    const root = try findWorkspaceRoot(allocator);
    defer allocator.free(root);

    // Root should be the parent (tmp.path)
    try std.testing.expect(std.mem.eql(u8, root, tmp.path));
}
