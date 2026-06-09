const std = @import("std");

pub const SparseEntry = struct {
    index: usize,
    weight: f32,
};

pub const SparseVector = struct {
    entries: []SparseEntry,
    norm: f32,

    pub fn deinit(self: *SparseVector, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn cosineSimilarity(self: *const SparseVector, other: *const SparseVector) f32 {
        if (self.norm == 0.0 or other.norm == 0.0) return 0.0;
        var dot: f32 = 0.0;
        var i: usize = 0;
        var j: usize = 0;
        while (i < self.entries.len and j < other.entries.len) {
            if (self.entries[i].index < other.entries[j].index) {
                i += 1;
            } else if (self.entries[i].index > other.entries[j].index) {
                j += 1;
            } else {
                dot += self.entries[i].weight * other.entries[j].weight;
                i += 1;
                j += 1;
            }
        }
        return dot / (self.norm * other.norm);
    }
};

pub const Doc = struct {
    path: []const u8,
    content: []const u8,
};

pub const QueryResult = struct {
    path: []const u8,
    score: f32,
};

pub const EmbeddingEngine = struct {
    allocator: std.mem.Allocator,
    /// term -> term_index
    vocabulary: std.StringHashMap(usize),
    /// term_index -> document frequency count
    df: std.ArrayList(usize),
    /// total documents in corpus
    num_docs: usize,
    /// total terms in vocabulary
    vocab_size: usize,
    /// cached vectors: node_path -> SparseVector
    cache: std.StringHashMap(SparseVector),

    pub fn init(allocator: std.mem.Allocator) EmbeddingEngine {
        return .{
            .allocator = allocator,
            .vocabulary = std.StringHashMap(usize).init(allocator),
            .df = .empty,
            .num_docs = 0,
            .vocab_size = 0,
            .cache = std.StringHashMap(SparseVector).init(allocator),
        };
    }

    pub fn deinit(self: *EmbeddingEngine) void {
        var vocab_it = self.vocabulary.keyIterator();
        while (vocab_it.next()) |key| self.allocator.free(key.*);
        self.vocabulary.deinit();
        self.df.deinit(self.allocator);
        {
            var cache_it = self.cache.iterator();
            while (cache_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
        }
        self.cache.deinit();
        self.* = undefined;
    }

    fn tokenize(self: *EmbeddingEngine, content: []const u8, tokens: *std.ArrayList([]const u8)) !void {
        var words = std.mem.tokenizeAny(u8, content, " \n\r\t.,!?;:()[]{}\"'#*-_/\\@<>");
        while (words.next()) |word| {
            if (word.len > 2) {
                const lower = try self.allocator.alloc(u8, word.len);
                for (word, 0..) |c, i| lower[i] = std.ascii.toLower(c);
                try tokens.append(self.allocator, lower);
            }
        }
    }

    fn countTerms(allocator: std.mem.Allocator, tokens: []const []const u8) !std.StringHashMap(usize) {
        var counts = std.StringHashMap(usize).init(allocator);
        for (tokens) |token| {
            const gop = try counts.getOrPut(token);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }
        return counts;
    }

    /// Build vocabulary and document frequencies from a list of (path, content) pairs.
    pub fn buildCorpus(self: *EmbeddingEngine, docs: []const Doc) !void {
        self.num_docs = docs.len;
        self.vocab_size = 0;

        var all_terms = std.StringHashMap(usize).init(self.allocator);
        defer {
            var it = all_terms.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            all_terms.deinit();
        }

        for (docs) |doc| {
            var tokens: std.ArrayList([]const u8) = .empty;
            defer {
                for (tokens.items) |t| self.allocator.free(t);
                tokens.deinit(self.allocator);
            }
            try self.tokenize(doc.content, &tokens);

            var seen = std.StringHashMap(void).init(self.allocator);
            defer seen.deinit();
            for (tokens.items) |token| {
                if (seen.contains(token)) continue;
                try seen.put(token, {});
                const duped = try self.allocator.dupe(u8, token);
                const gop = try all_terms.getOrPut(duped);
                if (gop.found_existing) {
                    self.allocator.free(duped);
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            }
        }

        var sorted_terms: std.ArrayList([]const u8) = .empty;
        defer sorted_terms.deinit(self.allocator);
        {
            var it = all_terms.iterator();
            while (it.next()) |entry| {
                try sorted_terms.append(self.allocator, entry.key_ptr.*);
            }
        }
        std.mem.sort([]const u8, sorted_terms.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        self.vocabulary.clearRetainingCapacity();
        self.vocabulary.ensureTotalCapacity(@intCast(sorted_terms.items.len)) catch |err| {
            std.log.warn("vocabulary ensureCapacity failed: {}", .{err});
        };
        self.df.clearRetainingCapacity();

        for (sorted_terms.items, 0..) |term, i| {
            const duped = try self.allocator.dupe(u8, term);
            try self.vocabulary.put(duped, i);
            const df_val = all_terms.get(term).?;
            try self.df.append(self.allocator, df_val);
        }
        self.vocab_size = self.vocabulary.count();
    }

    /// Build TF-IDF vector for a single document.
    pub fn buildVector(self: *EmbeddingEngine, content: []const u8) !SparseVector {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer {
            for (tokens.items) |t| self.allocator.free(t);
            tokens.deinit(self.allocator);
        }
        try self.tokenize(content, &tokens);

        var term_counts = try countTerms(self.allocator, tokens.items);
        defer term_counts.deinit();

        const total_terms = tokens.items.len;
        const n_docs_f32 = @as(f32, @floatFromInt(self.num_docs));

        var entries: std.ArrayList(SparseEntry) = .empty;
        defer entries.deinit(self.allocator);

        var it = term_counts.iterator();
        while (it.next()) |entry| {
            const term = entry.key_ptr.*;
            const count = entry.value_ptr.*;
            const term_idx = self.vocabulary.get(term) orelse continue;
            const df_val = self.df.items[term_idx];
            const tf = @as(f32, @floatFromInt(count)) / @as(f32, @floatFromInt(total_terms));
            const idf = @log(1.0 + n_docs_f32 / @as(f32, @floatFromInt(df_val)));
            try entries.append(self.allocator, .{ .index = term_idx, .weight = tf * idf });
        }

        std.mem.sort(SparseEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: SparseEntry, b: SparseEntry) bool {
                return a.index < b.index;
            }
        }.lessThan);

        var norm: f32 = 0.0;
        for (entries.items) |e| norm += e.weight * e.weight;
        norm = @sqrt(norm);

        return .{
            .entries = try entries.toOwnedSlice(self.allocator),
            .norm = norm,
        };
    }

    /// Build and cache vectors for all documents in the corpus.
    pub fn buildAllVectors(self: *EmbeddingEngine, docs: []const Doc) !void {
        for (docs) |doc| {
            if (self.cache.contains(doc.path)) continue;
            const vec = try self.buildVector(doc.content);
            try self.cache.put(try self.allocator.dupe(u8, doc.path), vec);
        }
    }

    /// Get cached vector for a document path.
    pub fn getVector(self: *EmbeddingEngine, path: []const u8) ?*SparseVector {
        return self.cache.getPtr(path);
    }

    /// Find top-k most similar documents to a query string.
    pub fn query(self: *EmbeddingEngine, query_text: []const u8, top_k: usize) ![]QueryResult {
        var query_vec = try self.buildVector(query_text);
        defer query_vec.deinit(self.allocator);

        var results: std.ArrayList(QueryResult) = .empty;
        defer results.deinit(self.allocator);

        var it = self.cache.iterator();
        while (it.next()) |entry| {
            const score = query_vec.cosineSimilarity(entry.value_ptr);
            if (score > 0.0) {
                try results.append(self.allocator, .{ .path = entry.key_ptr.*, .score = score });
            }
        }

        std.mem.sort(QueryResult, results.items, {}, struct {
            fn lessThan(_: void, a: QueryResult, b: QueryResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        const limit = @min(top_k, results.items.len);
        return self.allocator.dupe(QueryResult, results.items[0..limit]);
    }
};

test "EmbeddingEngine: basic tokenization and vector building" {
    const alloc = std.testing.allocator;
    var engine = EmbeddingEngine.init(alloc);
    defer engine.deinit();

    const docs = [_]Doc{
        .{ .path = "a.md", .content = "machine learning algorithms for data science" },
        .{ .path = "b.md", .content = "deep neural networks for machine learning" },
        .{ .path = "c.md", .content = "data visualization with charts and graphs" },
    };

    try engine.buildCorpus(&docs);
    try engine.buildAllVectors(&docs);

    const query = "machine learning";
    const results = try engine.query(query, 2);
    defer alloc.free(results);

    try std.testing.expect(results.len == 2);
    try std.testing.expect(results[0].score > results[1].score);
}

test "EmbeddingEngine: query returns results for common terms" {
    const alloc = std.testing.allocator;
    var engine = EmbeddingEngine.init(alloc);
    defer engine.deinit();

    const docs = [_]Doc{
        .{ .path = "x.md", .content = "quantum computing entanglement superposition" },
        .{ .path = "y.md", .content = "quantum mechanics wave particle duality" },
    };

    try engine.buildCorpus(&docs);
    try engine.buildAllVectors(&docs);

    const results = try engine.query("quantum", 2);
    defer alloc.free(results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expect(results[0].score > 0);
}

test "EmbeddingEngine: empty corpus" {
    const alloc = std.testing.allocator;
    var engine = EmbeddingEngine.init(alloc);
    defer engine.deinit();
    try engine.buildCorpus(&.{});
    try engine.buildAllVectors(&.{});
    const results = try engine.query("hello", 5);
    defer alloc.free(results);
    try std.testing.expect(results.len == 0);
}

test "SparseVector: cosine similarity" {
    const alloc = std.testing.allocator;
    var a: SparseVector = .{
        .entries = try alloc.dupe(SparseEntry, &.{
            .{ .index = 0, .weight = 1.0 },
            .{ .index = 2, .weight = 2.0 },
        }),
        .norm = @sqrt(1.0 + 4.0),
    };
    defer a.deinit(alloc);

    var b: SparseVector = .{
        .entries = try alloc.dupe(SparseEntry, &.{
            .{ .index = 0, .weight = 1.0 },
            .{ .index = 1, .weight = 3.0 },
        }),
        .norm = @sqrt(1.0 + 9.0),
    };
    defer b.deinit(alloc);

    const sim = a.cosineSimilarity(&b);
    try std.testing.expect(sim > 0.0);
    try std.testing.expect(sim < 1.0);
}

test "SparseVector: orthogonal vectors" {
    const alloc = std.testing.allocator;
    var a: SparseVector = .{
        .entries = try alloc.dupe(SparseEntry, &.{.{
            .index = 0,
            .weight = 1.0,
        }}),
        .norm = 1.0,
    };
    defer a.deinit(alloc);

    var b: SparseVector = .{
        .entries = try alloc.dupe(SparseEntry, &.{.{
            .index = 1,
            .weight = 1.0,
        }}),
        .norm = 1.0,
    };
    defer b.deinit(alloc);

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), a.cosineSimilarity(&b), 0.0001);
}
