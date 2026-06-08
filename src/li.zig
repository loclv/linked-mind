//! Workspace-aware CLI for the Linked-Mind knowledge graph tool.
//!
//! `li` is the main executable entry point.  It discovers the nearest `.li/`
//! workspace directory by walking up from the current working directory,
//! then dispatches to subcommands:
//!
//!   init      Create a new `.li/` workspace
//!   scan      Parse all files and persist the cache
//!   export    Emit `llm_knowledge.md` for LLM consumption
//!   path      BFS shortest path between two nodes
//!   clusters  Community detection map
//!   gc        Orphan / island node hygiene report
//!   similar   Find content-similar nodes
//!   suggest   Suggest missing wikilinks
//!   visualize Export `graph.json` for web visualisation
//!   watch     Stream file-change events as JSON
const std = @import("std");

const cache = @import("cache.zig");
const graph = @import("graph.zig");
const parser = @import("parser.zig");
const map_scanner = @import("map/scanner.zig");
const map_entry = @import("map/entry.zig");
const mindmap = @import("mindmap/mindmap.zig");
const builder = @import("mindmap/builder.zig");
const serialize = @import("mindmap/serialize.zig");
const llm_mod = @import("mindmap/llm.zig");
const query_mod = @import("mindmap/query.zig");

const log = std.log.scoped(.li);

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
    \\  mind build <file>  Build mind-map from a Markdown file (mind-map.json)
    \\  mind query <q>     Query the mind-map using LLM (set OPENAI_API_KEY)
    \\  serve [--port]    Start API and Visualizer server (default port: 8080)
    \\
    \\Global Options:
    \\  --tag <tag>       Filter results by tag
    \\  --status <status> Filter results by status metadata
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "init")) {
        const target_path = if (args.len > 2) args[2] else ".";
        try initWorkspace(allocator, init.io, target_path);
        return;
    }

    const ws_root = findWorkspaceRoot(allocator, init.io) catch |err| {
        if (err == error.NoWorkspaceFound) {
            std.debug.print("Fatal: Not in a Linked-Mind workspace. Run 'li init' to create one.\n", .{});
            std.process.exit(1);
        }
        return err;
    };
    defer allocator.free(ws_root);

    try runCommand(allocator, init.io, cmd, ws_root, args[2..]);
}

fn initWorkspace(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    _ = allocator;
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);

    dir.createDir(io, ".li", .default_dir) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.debug.print("Reinitialized existing Linked-Mind workspace in {s}/.li/\n", .{path});
            return;
        }
        return err;
    };

    std.debug.print("Initialized empty Linked-Mind workspace in {s}/.li/\n", .{path});
}

fn findWorkspaceRoot(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    var current_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    errdefer allocator.free(current_path);

    while (true) {
        var dir = std.Io.Dir.openDirAbsolute(io, current_path, .{}) catch break;
        defer dir.close(io);

        dir.access(io, ".li", .{}) catch {
            const parent = std.fs.path.dirname(current_path);
            if (parent == null or std.mem.eql(u8, parent.?, current_path)) break;
            const next_path = try allocator.dupeZ(u8, parent.?);
            allocator.free(current_path);
            current_path = next_path;
            continue;
        };

        return current_path;
    }

    return error.NoWorkspaceFound;
}

fn ensureNodeMtime(allocator: std.mem.Allocator, node: *parser.Node, mtime: i128) !void {
    const mtime_ms = @divTrunc(mtime, 1000000);
    const mtime_str = try std.fmt.allocPrint(allocator, "{d}", .{mtime_ms});
    errdefer allocator.free(mtime_str);

    const key = try allocator.dupe(u8, "mtime");
    errdefer allocator.free(key);

    if (node.metadata.getPtr("mtime")) |val_ptr| {
        allocator.free(val_ptr.*);
        val_ptr.* = mtime_str;
        allocator.free(key);
    } else {
        try node.metadata.put(key, mtime_str);
    }
}

fn runCommand(allocator: std.mem.Allocator, io: std.Io, cmd: []const u8, ws_root: []const u8, args: []const [:0]const u8) !void {
    var kb_graph = graph.Graph.init(allocator);
    defer kb_graph.deinit();

    var kb_parser = parser.Parser.init(allocator, io);

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

    var kb_dir = try std.Io.Dir.openDirAbsolute(io, ws_root, .{ .iterate = true });
    defer kb_dir.close(io);

    const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, ".li", "cache.json" });
    defer allocator.free(cache_path);

    var kb_cache = cache.Cache.init(allocator);
    defer kb_cache.deinit();
    kb_cache.load(io, cache_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Note: Could not load cache: {any}. Starting fresh.\n", .{err});
        }
    };

    var new_cache = cache.Cache.init(allocator);
    defer new_cache.deinit();

    var walker = try kb_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip .li and other hidden dirs
        if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

        const is_supported = std.mem.endsWith(u8, entry.basename, ".md") or
            std.mem.endsWith(u8, entry.basename, ".org") or
            std.mem.endsWith(u8, entry.basename, ".txt") or
            std.mem.endsWith(u8, entry.basename, ".pdf");
        if (entry.kind == .file and is_supported) {
            const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, entry.path });
            defer allocator.free(absolute_path);

            const stat = try kb_dir.statFile(io, entry.path, .{});
            const mtime = @as(i128, stat.mtime.toNanoseconds());

            var cached_entry: ?*cache.CacheEntry = null;
            if (kb_cache.entries.getPtr(absolute_path)) |cached| {
                if (cached.mtime == mtime) {
                    cached_entry = cached;
                } else {
                    const hash = try calculateHash(io, absolute_path);
                    if (std.mem.eql(u8, &hash, &cached.hash)) {
                        cached_entry = cached;
                        cached_entry.?.*.mtime = mtime;
                    }
                }
            }

            if (cached_entry) |ce| {
                try ensureNodeMtime(allocator, &ce.node, mtime);
                try kb_graph.addNode(try ce.node.clone(allocator));
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = ce.mtime,
                    .hash = ce.hash,
                    .node = try ce.node.clone(allocator),
                });
            } else {
                var node = try kb_parser.parseFile(absolute_path);
                const hash = try calculateHash(io, absolute_path);
                try ensureNodeMtime(allocator, &node, mtime);
                try kb_graph.addNode(try node.clone(allocator));
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = mtime,
                    .hash = hash,
                    .node = node,
                });
            }
        }
    }

    try new_cache.save(io, cache_path);

    try kb_graph.resolveBacklinks();
    var pr_scores = try kb_graph.computePageRank(10);
    defer pr_scores.deinit();

    if (std.mem.eql(u8, cmd, "scan")) {
        std.debug.print("Workspace scanned. {d} nodes processed.\n", .{kb_graph.nodes.count()});
    } else if (std.mem.eql(u8, cmd, "export")) {
        const export_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, "llm_knowledge.md" });
        defer allocator.free(export_path);

        var bundle = std.Io.Writer.Allocating.init(allocator);
        defer bundle.deinit();

        try bundle.writer.print("# LLM Knowledge Bundle\nGenerated on: 2026-04-10\n", .{});
        if (filter_tag) |t| try bundle.writer.print("Filter Tag: {s}\n", .{t});
        if (filter_status) |s| try bundle.writer.print("Filter Status: {s}\n", .{s});
        try bundle.writer.print("\n", .{});

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
            try bundle.writer.print("**PageRank:** {d:.4}\n", .{rank});
            try bundle.writer.print("---\n{s}\n", .{ctx});
        }
        const bundle_data = try bundle.toOwnedSlice();
        defer allocator.free(bundle_data);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = export_path, .data = bundle_data });
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
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = csv_path, .data = csv });
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
        const json = try kb_graph.exportGraphJson(ws_root);
        defer allocator.free(json);
        const json_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, "graph.json" });
        defer allocator.free(json_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = json });
        std.debug.print("Visualizer data written to {s}\n", .{json_path});
    } else if (std.mem.eql(u8, cmd, "watch")) {
        const watch_path_raw = if (args.len > 0) args[0] else ws_root;
        const watch_path = try std.Io.Dir.cwd().realPathFileAlloc(io, watch_path_raw, allocator);
        defer allocator.free(watch_path);
        try watchWorkspace(allocator, io, watch_path);
    } else if (std.mem.eql(u8, cmd, "mind")) {
        if (args.len < 1) {
            std.debug.print("Usage: li mind <build|query> [args]\n", .{});
            return;
        }
        const subcmd = args[0];
        if (std.mem.eql(u8, subcmd, "build")) {
            if (args.len < 2) {
                std.debug.print("Usage: li mind build <file.md>\n", .{});
                return;
            }
            const file_path = args[1];
            const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited);
            defer allocator.free(content);

            var tree = try builder.buildHeadingTree(allocator, content);
            defer tree.deinit(allocator);

            var mind_map = try mindmap.MindMap.init(allocator, file_path, "");
            defer mind_map.deinit(allocator);

            // Steal tree's children into the mind-map to avoid double-free
            if (tree.children) |*ch| {
                mind_map.nodes = ch.*;
                tree.children = null;
            }

            const out_path = try std.fs.path.join(allocator, &.{ ws_root, "mind-map.json" });
            defer allocator.free(out_path);
            const json_data = try serialize.serializeToJson(allocator, &mind_map);
            defer allocator.free(json_data);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json_data });
            std.debug.print("Mind-map written to {s}\n", .{out_path});
        } else if (std.mem.eql(u8, subcmd, "query")) {
            if (args.len < 2) {
                std.debug.print("Usage: li mind query \"<question>\"\n", .{});
                return;
            }
            const question = args[1];
            const map_path = try std.fs.path.join(allocator, &.{ ws_root, "mind-map.json" });
            defer allocator.free(map_path);
            const json_str = std.Io.Dir.cwd().readFileAlloc(io, map_path, allocator, .unlimited) catch |err| {
                std.debug.print("No mind-map found at {s}. Run 'li mind build' first. ({any})\n", .{ map_path, err });
                return;
            };
            defer allocator.free(json_str);
            var mind_map = try serialize.deserializeFromJson(allocator, json_str);
            defer mind_map.deinit(allocator);

            // Read the source document to assemble context
            const doc = std.Io.Dir.cwd().readFileAlloc(io, mind_map.title, allocator, .unlimited) catch |err| {
                std.debug.print("Warning: could not read source document '{s}' ({any}). Using mind-map tree only.\n", .{ mind_map.title, err });
                return;
            };
            defer allocator.free(doc);

            const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, ".li", "config.json" });
            defer allocator.free(config_path);

            var config = try llm_mod.LLMConfig.load(allocator, io, config_path);
            defer config.deinit();
            var llm_svc = llm_mod.LLMService.init(allocator, io, config);
            var engine = query_mod.QueryEngine.init(allocator);
            defer engine.deinit(allocator);

            var result = engine.query(&mind_map, doc, question, &llm_svc) catch |err| {
                if (err == error.ApiKeyMissing) {
                    std.debug.print("Error: OPENAI_API_KEY not set. Export it and try again.\n", .{});
                } else {
                    std.debug.print("Query failed: {any}\n", .{err});
                }
                return;
            };
            defer result.deinit(allocator);

            std.debug.print("{s}\n", .{result.answer});
        } else {
            std.debug.print("Unknown mind subcommand: {s}. Use 'build' or 'query'.\n", .{subcmd});
        }
    } else if (std.mem.eql(u8, cmd, "serve")) {
        var port: u16 = 8080;
        var j: usize = 0;
        while (j < args.len) : (j += 1) {
            if (std.mem.eql(u8, args[j], "--port") and j + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[j + 1], 10) catch |err| {
                    std.debug.print("Invalid port number: {s} ({any})\n", .{ args[j + 1], err });
                    return;
                };
                j += 1;
            }
        }
        try startServer(allocator, io, ws_root, port);
    } else {
        std.debug.print("Unknown command: {s}\n{s}", .{ cmd, usage });
    }
}

fn serveFile(writer: anytype, content_type: []const u8, content: []const u8) !void {
    try writer.print(
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: {s}; charset=utf-8\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ content_type, content.len });
    try writer.writeAll(content);
}

fn serve404(writer: anytype) !void {
    const body = "404 Not Found";
    try writer.print(
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ body.len });
    try writer.writeAll(body);
}

fn serve405(writer: anytype) !void {
    const body = "405 Method Not Allowed";
    try writer.print(
        "HTTP/1.1 405 Method Not Allowed\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ body.len });
    try writer.writeAll(body);
}

fn serve500(writer: anytype) !void {
    const body = "500 Internal Server Error";
    try writer.print(
        "HTTP/1.1 500 Internal Server Error\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{ body.len });
    try writer.writeAll(body);
}

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result_list = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result_list.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex_val = input[i + 1 .. i + 3];
            const byte = std.fmt.parseInt(u8, hex_val, 16) catch |err| {
                log.warn("urlDecode parsing hex {s} failed: {any}", .{hex_val, err});
                try result_list.append(allocator, '%');
                i += 1;
                continue;
            };
            try result_list.append(allocator, byte);
            i += 3;
        } else if (input[i] == '+') {
            try result_list.append(allocator, ' ');
            i += 1;
        } else {
            try result_list.append(allocator, input[i]);
            i += 1;
        }
    }
    return result_list.toOwnedSlice(allocator);
}

fn serveJsonError(writer: anytype, message: []const u8) !void {
    try writer.print(
        "HTTP/1.1 400 Bad Request\r\n" ++
        "Content-Type: application/json; charset=utf-8\r\n" ++
        "Connection: close\r\n" ++
        "\r\n", .{});
    try writer.print("{{\"error\": \"{s}\"}}\n", .{message});
}

fn startServer(allocator: std.mem.Allocator, io: std.Io, ws_root: []const u8, port: u16) !void {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var server = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("Linked-Mind API Server running at http://127.0.0.1:{d}/\n", .{port});
    std.debug.print("Press Ctrl+C to stop.\n", .{});

    while (true) {
        var conn = server.accept(io) catch |err| {
            log.err("Accept error: {any}", .{err});
            continue;
        };
        defer conn.close(io);

        var read_buf: [4096]u8 = undefined;
        var conn_reader = conn.reader(io, &read_buf);
        const req_len = conn_reader.interface.readSliceShort(&read_buf) catch |err| {
            log.err("Read error: {any}", .{err});
            continue;
        };
        if (req_len == 0) continue;

        const req = read_buf[0..req_len];
        var lines = std.mem.splitSequence(u8, req, "\r\n");
        const first_line = lines.next() orelse continue;
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse continue;
        const path = parts.next() orelse continue;

        var write_buf: [1024]u8 = undefined;
        var conn_writer = conn.writer(io, &write_buf);

        if (!std.mem.eql(u8, method, "GET")) {
            serve405(&conn_writer.interface) catch |err| {
                log.err("Failed to serve 405 response: {any}", .{err});
            };
            conn_writer.interface.flush() catch |err| {
                log.err("Failed to flush connection writer: {any}", .{err});
            };
            continue;
        }

        const clean_path = std.mem.trim(u8, path, " ");
        var path_parts = std.mem.splitScalar(u8, clean_path, '?');
        const req_path = path_parts.next() orelse clean_path;

        if (std.mem.startsWith(u8, req_path, "/api/add-link")) {
            var source_opt: ?[]const u8 = null;
            var target_opt: ?[]const u8 = null;
            var type_opt: ?[]const u8 = null;

            const query_string = if (std.mem.findScalar(u8, clean_path, '?')) |q_idx| clean_path[q_idx + 1 ..] else "";
            var params = std.mem.splitScalar(u8, query_string, '&');
            while (params.next()) |param| {
                var kv = std.mem.splitScalar(u8, param, '=');
                const key = kv.next() orelse continue;
                const val = kv.next() orelse "";
                if (std.mem.eql(u8, key, "source")) {
                    source_opt = val;
                } else if (std.mem.eql(u8, key, "target")) {
                    target_opt = val;
                } else if (std.mem.eql(u8, key, "type")) {
                    type_opt = val;
                }
            }

            if (source_opt == null or target_opt == null) {
                serveJsonError(&conn_writer.interface, "Missing required parameters: 'source' and 'target'") catch |err| {
                    log.err("Failed to serve JSON error: {any}", .{err});
                };
                conn_writer.interface.flush() catch |err| {
                    log.err("Failed to flush connection: {any}", .{err});
                };
                continue;
            }

            const source_decoded = urlDecode(allocator, source_opt.?) catch |err| {
                log.err("Failed to decode source: {any}", .{err});
                serveJsonError(&conn_writer.interface, "Failed to decode source parameter") catch |se_err| {
                    log.err("Failed to serve JSON error: {any}", .{se_err});
                };
                conn_writer.interface.flush() catch |flush_err| {
                    log.err("Failed to flush connection: {any}", .{flush_err});
                };
                continue;
            };
            defer allocator.free(source_decoded);

            const target_decoded = urlDecode(allocator, target_opt.?) catch |err| {
                log.err("Failed to decode target: {any}", .{err});
                serveJsonError(&conn_writer.interface, "Failed to decode target parameter") catch |se_err| {
                    log.err("Failed to serve JSON error: {any}", .{se_err});
                };
                conn_writer.interface.flush() catch |flush_err| {
                    log.err("Failed to flush connection: {any}", .{flush_err});
                };
                continue;
            };
            defer allocator.free(target_decoded);

            const type_decoded = if (type_opt) |t_opt| urlDecode(allocator, t_opt) catch |err| {
                log.err("Failed to decode type: {any}", .{err});
                serveJsonError(&conn_writer.interface, "Failed to decode type parameter") catch |se_err| {
                    log.err("Failed to serve JSON error: {any}", .{se_err});
                };
                conn_writer.interface.flush() catch |flush_err| {
                    log.err("Failed to flush connection: {any}", .{flush_err});
                };
                continue;
            } else try allocator.dupe(u8, "");
            defer allocator.free(type_decoded);

            // Locate node path from cache
            const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, ".li", "cache.json" });
            defer allocator.free(cache_path);

            var kb_cache = cache.Cache.init(allocator);
            defer kb_cache.deinit();

            var source_path: ?[]const u8 = null;
            if (kb_cache.load(io, cache_path)) |_| {
                var iter = kb_cache.entries.iterator();
                while (iter.next()) |entry| {
                    if (std.mem.eql(u8, entry.value_ptr.node.title, source_decoded) or std.mem.eql(u8, entry.value_ptr.node.id, source_decoded)) {
                        source_path = try allocator.dupe(u8, entry.key_ptr.*);
                        break;
                    }
                }
            } else |err| {
                log.err("Failed to load cache: {any}", .{err});
            }

            if (source_path) |spath| {
                defer allocator.free(spath);

                // Modify file - open with read_write to append
                var file = std.Io.Dir.openFileAbsolute(io, spath, .{ .mode = .read_write }) catch |err| {
                    log.err("Failed to open source file {s}: {any}", .{ spath, err });
                    serveJsonError(&conn_writer.interface, "Failed to open source file for writing") catch |se_err| {
                        log.err("Failed to serve JSON error: {any}", .{se_err});
                    };
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush connection: {any}", .{flush_err});
                    };
                    continue;
                };
                defer file.close(io);

                const file_stat = file.stat(io) catch |err| {
                    log.err("Failed to stat source file: {any}", .{err});
                    serveJsonError(&conn_writer.interface, "Failed to read file status") catch |se_err| {
                        log.err("Failed to serve JSON error: {any}", .{se_err});
                    };
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush connection: {any}", .{flush_err});
                    };
                    continue;
                };
                const size = file_stat.size;

                const append_str = if (type_decoded.len > 0)
                    std.fmt.allocPrint(allocator, "\n\n[[{s}::{s}]]", .{ type_decoded, target_decoded }) catch |err| {
                        log.err("Alloc print failed: {any}", .{err});
                        serveJsonError(&conn_writer.interface, "Out of memory") catch |se_err| {
                            log.err("Failed to serve JSON error: {any}", .{se_err});
                        };
                        conn_writer.interface.flush() catch |flush_err| {
                            log.err("Failed to flush connection: {any}", .{flush_err});
                        };
                        continue;
                    }
                else
                    std.fmt.allocPrint(allocator, "\n\n[[{s}]]", .{ target_decoded }) catch |err| {
                        log.err("Alloc print failed: {any}", .{err});
                        serveJsonError(&conn_writer.interface, "Out of memory") catch |se_err| {
                            log.err("Failed to serve JSON error: {any}", .{se_err});
                        };
                        conn_writer.interface.flush() catch |flush_err| {
                            log.err("Failed to flush connection: {any}", .{flush_err});
                        };
                        continue;
                    };
                defer allocator.free(append_str);

                file.writePositionalAll(io, append_str, size) catch |err| {
                    log.err("Failed to write to file: {any}", .{err});
                    serveJsonError(&conn_writer.interface, "Failed to write new relationship to disk") catch |se_err| {
                        log.err("Failed to serve JSON error: {any}", .{se_err});
                    };
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush connection: {any}", .{flush_err});
                    };
                    continue;
                };

                // Re-export graph immediately
                updateGraphAndExport(allocator, io, ws_root) catch |err| {
                    log.err("Failed to update graph: {any}", .{err});
                };

                serveFile(&conn_writer.interface, "application/json", "{\"status\":\"ok\"}") catch |err| {
                    log.err("Failed to serve response: {any}", .{err});
                };
            } else {
                serveJsonError(&conn_writer.interface, "Source node not found in workspace") catch |se_err| {
                    log.err("Failed to serve JSON error: {any}", .{se_err});
                };
            }

            conn_writer.interface.flush() catch |err| {
                log.err("Failed to flush connection writer: {any}", .{err});
            };
            continue;
        }

        if (std.mem.startsWith(u8, req_path, "/api/query")) {
            var question_opt: ?[]const u8 = null;
            if (std.mem.find(u8, clean_path, "?q=")) |idx| {
                question_opt = clean_path[idx + 3 ..];
            } else if (std.mem.find(u8, clean_path, "&q=")) |idx| {
                question_opt = clean_path[idx + 3 ..];
            }

            if (question_opt) |q_raw| {
                var q_str = q_raw;
                if (std.mem.findScalar(u8, q_str, '&')) |amp_idx| {
                    q_str = q_str[0..amp_idx];
                }

                const q_decoded = urlDecode(allocator, q_str) catch |err| {
                    log.err("URL decode failed: {any}", .{err});
                    try serveJsonError(&conn_writer.interface, "URL decode failed.");
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush error response: {any}", .{flush_err});
                    };
                    continue;
                };
                defer allocator.free(q_decoded);

                const map_path = try std.fs.path.join(allocator, &.{ ws_root, "mind-map.json" });
                defer allocator.free(map_path);

                const json_str = std.Io.Dir.cwd().readFileAlloc(io, map_path, allocator, .unlimited) catch |err| {
                    log.err("No mind-map found at {s}: {any}", .{ map_path, err });
                    try serveJsonError(&conn_writer.interface, "No mind-map found. Run 'li mind build <file>' first.");
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush error response: {any}", .{flush_err});
                    };
                    continue;
                };
                defer allocator.free(json_str);

                var mind_map = serialize.deserializeFromJson(allocator, json_str) catch |err| {
                    log.err("Failed to deserialize mind-map: {any}", .{err});
                    try serveJsonError(&conn_writer.interface, "Failed to parse mind-map JSON.");
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush error response: {any}", .{flush_err});
                    };
                    continue;
                };
                defer mind_map.deinit(allocator);

                const doc = std.Io.Dir.cwd().readFileAlloc(io, mind_map.title, allocator, .unlimited) catch |err| {
                    log.err("Could not read source document '{s}': {any}", .{ mind_map.title, err });
                    try serveJsonError(&conn_writer.interface, "Could not read source document.");
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush error response: {any}", .{flush_err});
                    };
                    continue;
                };
                defer allocator.free(doc);

                const config_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, ".li", "config.json" });
                defer allocator.free(config_path);

                var config = try llm_mod.LLMConfig.load(allocator, io, config_path);
                defer config.deinit();
                var llm_svc = llm_mod.LLMService.init(allocator, io, config);
                var engine = query_mod.QueryEngine.init(allocator);
                defer engine.deinit(allocator);

                var result = engine.query(&mind_map, doc, q_decoded, &llm_svc) catch |err| {
                    log.err("Query failed: {any}", .{err});
                    if (err == error.ApiKeyMissing) {
                        try serveJsonError(&conn_writer.interface, "OPENAI_API_KEY environment variable is not set.");
                    } else {
                        try serveJsonError(&conn_writer.interface, "AI Query failed. Check API key and network.");
                    }
                    conn_writer.interface.flush() catch |flush_err| {
                        log.err("Failed to flush error response: {any}", .{flush_err});
                    };
                    continue;
                };
                defer result.deinit(allocator);

                const ResponseObj = struct {
                    answer: []const u8,
                    node_ids: []const []const u8,
                };
                const resp_obj: ResponseObj = .{
                    .answer = result.answer,
                    .node_ids = result.node_ids,
                };

                var out = std.Io.Writer.Allocating.init(allocator);
                defer out.deinit();
                var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
                try stringify.write(resp_obj);

                const response_json = out.written();
                try serveFile(&conn_writer.interface, "application/json", response_json);
            } else {
                try serveJsonError(&conn_writer.interface, "Missing query parameter 'q'.");
            }
            conn_writer.interface.flush() catch |err| {
                log.err("Failed to flush connection writer: {any}", .{err});
            };
            continue;
        }

        const filename: ?[]const u8 = if (std.mem.eql(u8, req_path, "/") or std.mem.eql(u8, req_path, "/index.html"))
            "index.html"
        else if (std.mem.eql(u8, req_path, "/graph.json"))
            "graph.json"
        else if (std.mem.eql(u8, req_path, "/llm_knowledge.md"))
            "llm_knowledge.md"
        else if (std.mem.eql(u8, req_path, "/map.json"))
            "map.json"
        else if (std.mem.eql(u8, req_path, "/map.toon"))
            "map.toon"
        else if (std.mem.eql(u8, req_path, "/map.csv"))
            "map.csv"
        else
            null;

        if (filename) |fname| {
            const content_type = if (std.mem.endsWith(u8, fname, ".html"))
                "text/html"
            else if (std.mem.endsWith(u8, fname, ".json"))
                "application/json"
            else if (std.mem.endsWith(u8, fname, ".md"))
                "text/markdown"
            else if (std.mem.endsWith(u8, fname, ".toon"))
                "text/plain"
            else if (std.mem.endsWith(u8, fname, ".csv"))
                "text/csv"
            else
                "application/octet-stream";

            const full_path = try std.fs.path.join(allocator, &.{ ws_root, fname });
            defer allocator.free(full_path);

            if (std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited)) |content| {
                defer allocator.free(content);
                serveFile(&conn_writer.interface, content_type, content) catch |err| {
                    log.err("Serve error: {any}", .{err});
                };
            } else |err| {
                if (err == error.FileNotFound) {
                    serve404(&conn_writer.interface) catch |serve_err| {
                        log.err("Failed to serve 404 response: {any}", .{serve_err});
                    };
                } else {
                    log.err("Read file error: {any}", .{err});
                    serve500(&conn_writer.interface) catch |serve_err| {
                        log.err("Failed to serve 500 response: {any}", .{serve_err});
                    };
                }
            }
        } else {
            var rel_path = req_path;
            if (rel_path.len > 0 and rel_path[0] == '/') {
                rel_path = rel_path[1..];
            }

            const is_safe = std.mem.indexOf(u8, rel_path, "..") == null;
            const is_supported = std.mem.endsWith(u8, rel_path, ".md") or
                std.mem.endsWith(u8, rel_path, ".org") or
                std.mem.endsWith(u8, rel_path, ".txt") or
                std.mem.endsWith(u8, rel_path, ".pdf");

            if (is_safe and is_supported) {
                const content_type = if (std.mem.endsWith(u8, rel_path, ".md"))
                    "text/markdown"
                else if (std.mem.endsWith(u8, rel_path, ".org") or std.mem.endsWith(u8, rel_path, ".txt"))
                    "text/plain"
                else if (std.mem.endsWith(u8, rel_path, ".pdf"))
                    "application/pdf"
                else
                    "application/octet-stream";

                const full_path = try std.fs.path.join(allocator, &.{ ws_root, rel_path });
                defer allocator.free(full_path);

                if (std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited)) |content| {
                    defer allocator.free(content);
                    serveFile(&conn_writer.interface, content_type, content) catch |err| {
                        log.err("Serve error for {s}: {any}", .{ rel_path, err });
                    };
                } else |err| {
                    if (err == error.FileNotFound) {
                        serve404(&conn_writer.interface) catch |serve_err| {
                            log.err("Failed to serve 404 response: {any}", .{serve_err});
                        };
                    } else {
                        log.err("Read file error for {s}: {any}", .{ rel_path, err });
                        serve500(&conn_writer.interface) catch |serve_err| {
                            log.err("Failed to serve 500 response: {any}", .{serve_err});
                        };
                    }
                }
            } else {
                serve404(&conn_writer.interface) catch |serve_err| {
                    log.err("Failed to serve 404 response: {any}", .{serve_err});
                };
            }
        }

        conn_writer.interface.flush() catch |err| {
            log.err("Failed to flush connection writer: {any}", .{err});
        };
    }
}

// updateGraphAndExport rebuilds the core knowledge graph structure and refreshes
// the graph.json file on disk. This is isolated as a reusable helper so that the
// same high-performance, cache-aware reconstruction logic is shared between the
// standard visualize commands and the live file watcher daemon.
fn updateGraphAndExport(allocator: std.mem.Allocator, io: std.Io, ws_root: []const u8) !void {
    var kb_graph = graph.Graph.init(allocator);
    defer kb_graph.deinit();

    var kb_parser = parser.Parser.init(allocator, io);

    var kb_dir = try std.Io.Dir.openDirAbsolute(io, ws_root, .{ .iterate = true });
    defer kb_dir.close(io);

    const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, ".li", "cache.json" });
    defer allocator.free(cache_path);

    // We load the existing cache.json so that we don't have to re-parse unchanged
    // Markdown files. This incremental system lowers graph updates to a few milliseconds.
    var kb_cache = cache.Cache.init(allocator);
    defer kb_cache.deinit();
    kb_cache.load(io, cache_path) catch |err| {
        if (err != error.FileNotFound) {
            std.debug.print("Note: Could not load cache: {any}. Starting fresh.\n", .{err});
        }
    };

    var new_cache = cache.Cache.init(allocator);
    defer new_cache.deinit();

    var walker = try kb_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // Skip metadata storage (.li) and git/hidden folders to avoid noise and cycles.
        if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

        const is_supported = std.mem.endsWith(u8, entry.basename, ".md") or
            std.mem.endsWith(u8, entry.basename, ".org") or
            std.mem.endsWith(u8, entry.basename, ".txt") or
            std.mem.endsWith(u8, entry.basename, ".pdf");
        if (entry.kind == .file and is_supported) {
            const absolute_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, entry.path });
            defer allocator.free(absolute_path);

            // We catch FileNotFound here to survive file renames or rapid deletes
            // happening concurrently while the walker is traversing.
            const stat = kb_dir.statFile(io, entry.path, .{}) catch |err| {
                if (err == error.FileNotFound) continue;
                return err;
            };
            const mtime = @as(i128, stat.mtime.toNanoseconds());

            var cached_entry: ?*cache.CacheEntry = null;
            if (kb_cache.entries.getPtr(absolute_path)) |cached| {
                if (cached.mtime == mtime) {
                    cached_entry = cached;
                } else {
                    // Double-check using content hash to prevent invalidating the cache
                    // on non-structural updates (like touch or external program edits).
                    const hash = calculateHash(io, absolute_path) catch |err| {
                        if (err == error.FileNotFound) continue;
                        return err;
                    };
                    if (std.mem.eql(u8, &hash, &cached.hash)) {
                        cached_entry = cached;
                        cached_entry.?.*.mtime = mtime;
                    }
                }
            }

            if (cached_entry) |ce| {
                try ensureNodeMtime(allocator, &ce.node, mtime);
                try kb_graph.addNode(try ce.node.clone(allocator));
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = ce.mtime,
                    .hash = ce.hash,
                    .node = try ce.node.clone(allocator),
                });
            } else {
                var node = kb_parser.parseFile(absolute_path) catch |err| {
                    if (err == error.FileNotFound) continue;
                    return err;
                };
                const hash = calculateHash(io, absolute_path) catch |err| {
                    node.deinit(allocator);
                    if (err == error.FileNotFound) continue;
                    return err;
                };
                try ensureNodeMtime(allocator, &node, mtime);
                try kb_graph.addNode(try node.clone(allocator));
                try new_cache.entries.put(try allocator.dupe(u8, absolute_path), .{
                    .mtime = mtime,
                    .hash = hash,
                    .node = node,
                });
            }
        }
    }

    try new_cache.save(io, cache_path);

    try kb_graph.resolveBacklinks();
    var pr_scores = try kb_graph.computePageRank(10);
    defer pr_scores.deinit();

    const json = try kb_graph.exportGraphJson(ws_root);
    defer allocator.free(json);
    const json_path = try std.fs.path.join(allocator, &[_][]const u8{ ws_root, "graph.json" });
    defer allocator.free(json_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = json });

    // Also rebuild map.csv and map.json for the docs directory under ws_root
    const docs_path = try std.fs.path.join(allocator, &.{ ws_root, "docs" });
    defer allocator.free(docs_path);

    var docs_dir = std.Io.Dir.openDirAbsolute(io, docs_path, .{});
    if (docs_dir) |*d| {
        d.close(io);

        var entries = try map_scanner.scanDir(allocator, io, docs_path, "");
        defer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        std.mem.sort(map_entry.Entry, entries.items, {}, map_entry.entryLessThan);

        // 1. Rebuild map.csv (default format)
        {
            var flat_list = std.ArrayList(map_entry.FlatEntry).empty;
            defer flat_list.deinit(allocator);

            // Collect all entries recursively into flat list and sort alphabetically by path
            try map_entry.collectFlat(allocator, entries.items, &flat_list);
            std.mem.sort(map_entry.FlatEntry, flat_list.items, {}, map_entry.flatEntryLessThan);

            var csv_writer = std.Io.Writer.Allocating.init(allocator);
            defer csv_writer.deinit();

            try csv_writer.writer.writeAll("name,description,path\n");
            for (flat_list.items) |fe| {
                try map_entry.writeCsvField(&csv_writer.writer, fe.name);
                try csv_writer.writer.writeByte(',');
                try map_entry.writeCsvField(&csv_writer.writer, fe.description);
                try csv_writer.writer.writeByte(',');
                try map_entry.writeCsvField(&csv_writer.writer, fe.path);
                try csv_writer.writer.writeByte('\n');
            }

            const out_csv = try csv_writer.toOwnedSlice();
            defer allocator.free(out_csv);

            const map_csv_path = try std.fs.path.join(allocator, &.{ ws_root, "map.csv" });
            defer allocator.free(map_csv_path);

            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = map_csv_path, .data = out_csv });
        }

        // 2. Rebuild map.json (JSON format)
        {
            var json_writer = std.Io.Writer.Allocating.init(allocator);
            defer json_writer.deinit();

            var stringify: std.json.Stringify = .{ .writer = &json_writer.writer, .options = .{ .whitespace = .indent_2 } };
            try stringify.write(entries.items);
            try json_writer.writer.writeByte('\n');

            const out_json = try json_writer.toOwnedSlice();
            defer allocator.free(out_json);

            const map_json_path = try std.fs.path.join(allocator, &.{ ws_root, "map.json" });
            defer allocator.free(map_json_path);

            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = map_json_path, .data = out_json });
        }
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }
}

// watchWorkspace implements a cross-platform background watch daemon. It uses
// high-precision mtime polling rather than platform-specific watchers (inotify/FSEvents)
// to remain completely consistent and portable across macOS, Linux, and Windows.
fn watchWorkspace(allocator: std.mem.Allocator, io: std.Io, watch_path: []const u8) !void {
    var kb_parser = parser.Parser.init(allocator, io);
    var known_files = std.StringHashMap(i128).init(allocator);
    defer {
        var iter = known_files.iterator();
        while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
        known_files.deinit();
    }

    // Pre-scan the directory on startup to index the initial filesystem state.
    {
        var watch_dir = try std.Io.Dir.openDirAbsolute(io, watch_path, .{ .iterate = true });
        defer watch_dir.close(io);
        var walker = try watch_dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

            const is_supported = std.mem.endsWith(u8, entry.basename, ".md") or
                std.mem.endsWith(u8, entry.basename, ".org") or
                std.mem.endsWith(u8, entry.basename, ".txt") or
                std.mem.endsWith(u8, entry.basename, ".pdf");
            if (entry.kind == .file and is_supported) {
                const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ watch_path, entry.path });
                const stat = watch_dir.statFile(io, entry.path, .{}) catch |err| {
                    if (err == error.FileNotFound) {
                        allocator.free(abs_path);
                        continue;
                    }
                    return err;
                };
                try known_files.put(abs_path, @as(i128, stat.mtime.toNanoseconds()));
            }
        }
    }

    // Trigger an initial graph build at startup. This guarantees that graph.json perfectly
    // matches the filesystem state before the first polling update checks occur.
    std.debug.print("Initializing/Rebuilding graph...\n", .{});
    try updateGraphAndExport(allocator, io, watch_path);
    std.debug.print("Graph initialized. graph.json written to workspace root.\n", .{});

    std.debug.print("Watching {s} for changes... (Press Ctrl+C to stop)\n", .{watch_path});

    while (true) {
        var current_files = std.StringHashMap(i128).init(allocator);
        defer {
            var iter = current_files.iterator();
            while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
            current_files.deinit();
        }

        var watch_dir = std.Io.Dir.openDirAbsolute(io, watch_path, .{ .iterate = true }) catch |err| {
            std.debug.print("Error opening watch directory: {any}\n", .{err});
            try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
            continue;
        };
        defer watch_dir.close(io);

        var walker = try watch_dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.path, ".li") or std.mem.startsWith(u8, entry.path, ".")) continue;

            const is_supported = std.mem.endsWith(u8, entry.basename, ".md") or
                std.mem.endsWith(u8, entry.basename, ".org") or
                std.mem.endsWith(u8, entry.basename, ".txt") or
                std.mem.endsWith(u8, entry.basename, ".pdf");
            if (entry.kind == .file and is_supported) {
                const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ watch_path, entry.path });
                const stat = watch_dir.statFile(io, entry.path, .{}) catch |err| {
                    if (err == error.FileNotFound) {
                        allocator.free(abs_path);
                        continue;
                    }
                    return err;
                };
                try current_files.put(abs_path, @as(i128, stat.mtime.toNanoseconds()));
            }
        }

        var changed = false;

        // Check for deleted files
        var known_iter = known_files.iterator();
        while (known_iter.next()) |entry| {
            if (!current_files.contains(entry.key_ptr.*)) {
                std.debug.print("{{\"event\": \"deleted\", \"path\": \"{s}\"}}\n", .{entry.key_ptr.*});
                changed = true;
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
                    changed = true;
                }
            } else {
                // Created
                var node = try kb_parser.parseFile(path);
                defer node.deinit(allocator);
                std.debug.print("{{\"event\": \"created\", \"path\": \"{s}\", \"node\": ", .{path});
                serializeNodeToDebug(node);
                std.debug.print("}}\n", .{});
                changed = true;
            }
        }

        // We wrap updateGraphAndExport in a catch block here so that syntax errors
        // or half-written temporary files do not crash the watch daemon process.
        if (changed) {
            std.debug.print("Rebuilding graph...\n", .{});
            updateGraphAndExport(allocator, io, watch_path) catch |err| {
                std.debug.print("Error rebuilding graph: {any}\n", .{err});
            };
            std.debug.print("Graph rebuilt and graph.json updated.\n", .{});
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

        try std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake);
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

fn calculateHash(io: std.Io, path: []const u8) ![32]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try file_reader.interface.readSliceShort(&buffer);
        if (bytes_read == 0) break;
        hash.update(buffer[0..bytes_read]);
    }
    return hash.finalResult();
}

// Helper: create a temp dir, return its path, caller must clean up
fn createTempDir(allocator: std.mem.Allocator, io: std.Io) !struct { dir: std.Io.Dir, path: []const u8 } {
    var base = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer base.close(io);
    var rand_bytes: [8]u8 = undefined;
    try io.randomSecure(&rand_bytes);
    const hex_name = std.fmt.bytesToHex(rand_bytes, .lower);
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "li-test-{s}", .{&hex_name});
    const dir = try base.createDirPathOpen(io, name, .{});
    const path = try std.fs.path.join(allocator, &.{ "/tmp", name });
    return .{ .dir = dir, .path = path };
}

test "li: initWorkspace creates .li directory" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    try initWorkspace(allocator, io, tmp.path);

    // Verify .li exists
    var dir = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer dir.close(io);
    dir.access(io, ".li", .{}) catch |err| {
        std.debug.print(".li dir not found after init: {any}\n", .{err});
        return err;
    };
}

test "li: initWorkspace reinit on existing .li returns ok" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    // First init
    try initWorkspace(allocator, io, tmp.path);
    // Second init should succeed (reinit)
    try initWorkspace(allocator, io, tmp.path);
}

test "li: findWorkspaceRoot finds .li in current dir" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    // Create .li in temp dir
    try initWorkspace(allocator, io, tmp.path);

    const original_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(original_dir);

    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer tmp_dir.close(io);

    try std.process.setCurrentDir(io, tmp_dir);
    defer {
        var orig = std.Io.Dir.openDirAbsolute(io, original_dir, .{}) catch unreachable;
        std.process.setCurrentDir(io, orig) catch {};
        orig.close(io);
    }

    const root = try findWorkspaceRoot(allocator, io);
    defer allocator.free(root);

    const real_tmp_path = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp.path, allocator);
    defer allocator.free(real_tmp_path);

    try std.testing.expectEqualStrings(real_tmp_path, root);
}

test "li: findWorkspaceRoot returns NoWorkspaceFound when no .li exists" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    const original_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(original_dir);

    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer tmp_dir.close(io);

    try std.process.setCurrentDir(io, tmp_dir);
    defer {
        var orig = std.Io.Dir.openDirAbsolute(io, original_dir, .{}) catch unreachable;
        std.process.setCurrentDir(io, orig) catch {};
        orig.close(io);
    }

    const result = findWorkspaceRoot(allocator, io);
    try std.testing.expectError(error.NoWorkspaceFound, result);
}

test "li: calculateHash returns consistent SHA256" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    // Write known content to a file
    const file_path = try std.fs.path.join(allocator, &.{ tmp.path, "test.txt" });
    defer allocator.free(file_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "hello world" });

    const hash1 = try calculateHash(io, file_path);
    const hash2 = try calculateHash(io, file_path);

    // Same content must produce same hash
    try std.testing.expect(std.mem.eql(u8, &hash1, &hash2));

    // Write different content
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "different content" });
    const hash3 = try calculateHash(io, file_path);

    // Different content must produce different hash
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

test "li: findWorkspaceRoot finds .li in parent directory" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    // Create .li in temp dir (parent)
    try initWorkspace(allocator, io, tmp.path);

    // Create subdir inside temp dir
    const subdir_path = try std.fs.path.join(allocator, &.{ tmp.path, "subdir" });
    defer allocator.free(subdir_path);
    var sub = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer sub.close(io);
    try sub.createDir(io, "subdir", .default_dir);

    // cd into subdir and find workspace root (should find .li in parent)
    const original_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(original_dir);

    var subdir = try std.Io.Dir.cwd().openDir(io, subdir_path, .{});
    defer subdir.close(io);

    try std.process.setCurrentDir(io, subdir);
    defer {
        var orig = std.Io.Dir.openDirAbsolute(io, original_dir, .{}) catch unreachable;
        std.process.setCurrentDir(io, orig) catch {};
        orig.close(io);
    }

    const root = try findWorkspaceRoot(allocator, io);
    defer allocator.free(root);

    const real_tmp_path = try std.Io.Dir.cwd().realPathFileAlloc(io, tmp.path, allocator);
    defer allocator.free(real_tmp_path);

    try std.testing.expectEqualStrings(real_tmp_path, root);
}

test "li: serve responses" {
    const allocator = std.testing.allocator;

    // Test serveFile
    {
        var w: std.Io.Writer.Allocating = .init(allocator);
        defer w.deinit();
        try serveFile(&w.writer, "text/plain", "hello workspace");
        const out = try w.toOwnedSlice();
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 200 OK") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: text/plain; charset=utf-8") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 15") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "hello workspace") != null);
    }

    // Test serve404
    {
        var w: std.Io.Writer.Allocating = .init(allocator);
        defer w.deinit();
        try serve404(&w.writer);
        const out = try w.toOwnedSlice();
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 404 Not Found") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "404 Not Found") != null);
    }

    // Test serve405
    {
        var w: std.Io.Writer.Allocating = .init(allocator);
        defer w.deinit();
        try serve405(&w.writer);
        const out = try w.toOwnedSlice();
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 405 Method Not Allowed") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "405 Method Not Allowed") != null);
    }

    // Test serve500
    {
        var w: std.Io.Writer.Allocating = .init(allocator);
        defer w.deinit();
        try serve500(&w.writer);
        const out = try w.toOwnedSlice();
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "HTTP/1.1 500 Internal Server Error") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "500 Internal Server Error") != null);
    }
}

test "li: urlDecode tests" {
    const allocator = std.testing.allocator;
    
    const input1 = "hello+world";
    const out1 = try urlDecode(allocator, input1);
    defer allocator.free(out1);
    try std.testing.expectEqualStrings("hello world", out1);

    const input2 = "hello%20world";
    const out2 = try urlDecode(allocator, input2);
    defer allocator.free(out2);
    try std.testing.expectEqualStrings("hello world", out2);

    const input3 = "hello%2bworld";
    const out3 = try urlDecode(allocator, input3);
    defer allocator.free(out3);
    try std.testing.expectEqualStrings("hello+world", out3);
}

test "li: add-link endpoint logic" {
    const allocator = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const tmp = try createTempDir(allocator, io);
    defer allocator.free(tmp.path);
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |base| {
            var mut_base = base;
            defer mut_base.close(io);
            mut_base.deleteTree(io, tmp.path[5..]) catch {};
        } else |_| {}
    }

    try initWorkspace(allocator, io, tmp.path);

    // Create a node file
    const note_path = try std.fs.path.join(allocator, &.{ tmp.path, "Intro.md" });
    defer allocator.free(note_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = note_path, .data = "Hello World" });

    // Rebuild graph to populate cache
    try updateGraphAndExport(allocator, io, tmp.path);

    // Now manually test the add-link logic by simulating the route
    const source_decoded = try allocator.dupe(u8, "Intro.md");
    defer allocator.free(source_decoded);
    const target_decoded = try allocator.dupe(u8, "Deep Dive.md");
    defer allocator.free(target_decoded);
    const type_decoded = try allocator.dupe(u8, "depends_on");
    defer allocator.free(type_decoded);

    const cache_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp.path, ".li", "cache.json" });
    defer allocator.free(cache_path);

    var kb_cache = cache.Cache.init(allocator);
    defer kb_cache.deinit();

    var source_path: ?[]const u8 = null;
    if (kb_cache.load(io, cache_path)) |_| {
        var iter = kb_cache.entries.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.node.title, source_decoded) or std.mem.eql(u8, entry.value_ptr.node.id, source_decoded)) {
                source_path = try allocator.dupe(u8, entry.key_ptr.*);
                break;
            }
        }
    } else |_| {}

    try std.testing.expect(source_path != null);
    if (source_path) |spath| {
        defer allocator.free(spath);
        try std.testing.expectEqualStrings(note_path, spath);

        // Open and append link
        var file = try std.Io.Dir.openFileAbsolute(io, spath, .{ .mode = .read_write });
        defer file.close(io);

        const file_stat = try file.stat(io);
        const size = file_stat.size;

        const append_str = try std.fmt.allocPrint(allocator, "\n\n[[{s}::{s}]]", .{ type_decoded, target_decoded });
        defer allocator.free(append_str);

        try file.writePositionalAll(io, append_str, size);
    }

    // Re-read file to verify content
    const updated_content = try std.Io.Dir.cwd().readFileAlloc(io, note_path, allocator, .unlimited);
    defer allocator.free(updated_content);
    try std.testing.expect(std.mem.indexOf(u8, updated_content, "[[depends_on::Deep Dive.md]]") != null);
}

