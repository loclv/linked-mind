const std = @import("std");
const parser = @import("parser.zig");
const graph = @import("graph.zig");
const embeddings = @import("embeddings.zig");
const Graph = graph.Graph;
const EmbeddingEngine = embeddings.EmbeddingEngine;
const Doc = embeddings.Doc;

pub const HybridResult = struct {
    node: *parser.Node,
    vector_score: f32,
    graph_score: f32,
    combined_score: f32,
    hop_distance: usize,
};

const SortableResult = struct {
    score: f32,
    result: HybridResult,
};

/// Hybrid search combining TF-IDF vector similarity with graph proximity.
/// For a given query, finds nodes whose content is similar AND within
/// N hops of a seed node in the graph.
pub fn search(
    allocator: std.mem.Allocator,
    g: *Graph,
    engine: *EmbeddingEngine,
    query_text: []const u8,
    seed_title: []const u8,
    hop_radius: usize,
    top_k: usize,
) ![]HybridResult {
    const raw_results = try engine.query(query_text, @max(top_k * 3, 20));
    defer allocator.free(raw_results);

    var seed_node: ?*parser.Node = null;
    if (seed_title.len > 0) {
        seed_node = g.findNodeByTitle(seed_title);
    }

    var hop_cache: ?std.StringHashMap(usize) = null;
    if (seed_node) |sn| {
        hop_cache = try computeHops(allocator, g, sn, hop_radius);
    }

    var scored: std.ArrayList(HybridResult) = .empty;
    defer scored.deinit(allocator);

    for (raw_results) |rr| {
        const node = g.nodes.getPtr(rr.path) orelse continue;

        var hop_dist: usize = hop_radius + 1;
        var graph_score: f32 = 0.0;

        if (hop_cache) |*hc| {
            if (hc.get(rr.path)) |hd| {
                hop_dist = hd;
                graph_score = @as(f32, @floatFromInt(hop_radius + 1 - hop_dist)) / @as(f32, @floatFromInt(hop_radius + 1));
            } else {
                continue;
            }
        }

        const vector_score = rr.score;
        const alpha: f32 = 0.6;
        const combined = alpha * vector_score + (1.0 - alpha) * graph_score;

        try scored.append(allocator, .{
            .node = node,
            .vector_score = vector_score,
            .graph_score = graph_score,
            .combined_score = combined,
            .hop_distance = hop_dist,
        });
    }

    std.mem.sort(HybridResult, scored.items, {}, struct {
        fn lessThan(_: void, a: HybridResult, b: HybridResult) bool {
            return a.combined_score > b.combined_score;
        }
    }.lessThan);

    const limit = @min(top_k, scored.items.len);
    return allocator.dupe(HybridResult, scored.items[0..limit]);
}

fn computeHops(allocator: std.mem.Allocator, g: *Graph, start: *parser.Node, max_dist: usize) !std.StringHashMap(usize) {
    var distances = std.StringHashMap(usize).init(allocator);
    try distances.put(start.path, 0);

    var queue: std.ArrayList(*parser.Node) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, start);

    var head: usize = 0;
    while (head < queue.items.len) {
        const current = queue.items[head];
        head += 1;

        const current_dist = distances.get(current.path) orelse continue;
        if (current_dist >= max_dist) continue;

        for (current.links.items) |link| {
            if (g.findNodeByTitle(link.target)) |neighbor| {
                if (!distances.contains(neighbor.path)) {
                    try distances.put(neighbor.path, current_dist + 1);
                    try queue.append(allocator, neighbor);
                }
            }
        }

        for (current.backlinks.items) |btitle| {
            if (g.findNodeByTitle(btitle)) |neighbor| {
                if (!distances.contains(neighbor.path)) {
                    try distances.put(neighbor.path, current_dist + 1);
                    try queue.append(allocator, neighbor);
                }
            }
        }
    }

    return distances;
}

test "HybridSearch: computeHops within radius" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    const node_defs = [_]struct { path: []const u8, title: []const u8, content: []const u8 }{
        .{ .path = "/a.md", .title = "Alpha", .content = "alpha concept" },
        .{ .path = "/b.md", .title = "Beta", .content = "beta concept" },
        .{ .path = "/c.md", .title = "Gamma", .content = "gamma concept" },
        .{ .path = "/d.md", .title = "Delta", .content = "delta concept" },
    };

    for (node_defs) |nd| {
        try g.addNode(.{
            .path = try alloc.dupe(u8, nd.path),
            .title = try alloc.dupe(u8, nd.title),
            .id = try alloc.dupe(u8, nd.title),
            .content = try alloc.dupe(u8, nd.content),
            .links = .empty,
            .backlinks = .empty,
            .tags = .empty,
            .metadata = std.StringHashMap([]const u8).init(alloc),
        });
    }

    const node_a = g.findNodeByTitle("Alpha").?;
    const node_b = g.findNodeByTitle("Beta").?;
    const node_c = g.findNodeByTitle("Gamma").?;

    try node_a.links.append(alloc, .{ .target = try alloc.dupe(u8, "Beta"), .nature = null });
    try node_b.links.append(alloc, .{ .target = try alloc.dupe(u8, "Gamma"), .nature = null });
    try node_c.links.append(alloc, .{ .target = try alloc.dupe(u8, "Delta"), .nature = null });

    var hops = try computeHops(alloc, &g, node_a, 2);
    defer hops.deinit();

    try std.testing.expectEqual(@as(usize, 0), hops.get("/a.md").?);
    try std.testing.expectEqual(@as(usize, 1), hops.get("/b.md").?);
    try std.testing.expectEqual(@as(usize, 2), hops.get("/c.md").?);
    try std.testing.expect(hops.get("/d.md") == null);
}

test "HybridSearch: search with and without seed" {
    const alloc = std.testing.allocator;
    var g = Graph.init(alloc);
    defer g.deinit();

    const node_defs = [_]struct { path: []const u8, title: []const u8, content: []const u8 }{
        .{ .path = "/ml.md", .title = "Machine Learning", .content = "machine learning algorithms neural networks deep learning" },
        .{ .path = "/cv.md", .title = "Computer Vision", .content = "computer vision image recognition neural networks" },
        .{ .path = "/web.md", .title = "Web Dev", .content = "html css javascript web development frontend" },
    };

    for (node_defs) |nd| {
        try g.addNode(.{
            .path = try alloc.dupe(u8, nd.path),
            .title = try alloc.dupe(u8, nd.title),
            .id = try alloc.dupe(u8, nd.title),
            .content = try alloc.dupe(u8, nd.content),
            .links = .empty,
            .backlinks = .empty,
            .tags = .empty,
            .metadata = std.StringHashMap([]const u8).init(alloc),
        });
    }

    const ml = g.findNodeByTitle("Machine Learning").?;
    try ml.links.append(alloc, .{ .target = try alloc.dupe(u8, "Computer Vision"), .nature = null });

    var engine = EmbeddingEngine.init(alloc);
    defer engine.deinit();

    const docs = [_]Doc{
        .{ .path = "/ml.md", .content = "machine learning algorithms neural networks deep learning" },
        .{ .path = "/cv.md", .content = "computer vision image recognition neural networks" },
        .{ .path = "/web.md", .content = "html css javascript web development frontend" },
    };

    try engine.buildCorpus(&docs);
    try engine.buildAllVectors(&docs);

    const results = try search(alloc, &g, &engine, "neural networks", "", 2, 5);
    defer alloc.free(results);

    try std.testing.expect(results.len >= 2);
    try std.testing.expect(results[0].combined_score > 0);
}
