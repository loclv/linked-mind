//! Markdown parser for knowledge graph nodes.
//!
//! Parses Obsidian-style markdown files into Node structs with:
//! - YAML frontmatter metadata
//! - Wikilinks: [[target]] and [[nature::target]]
//! - Tags: #tag (distinguishing from markdown headers)
//!
//! Design: Single-pass parsing for efficiency. All strings are owned by Node
//! and must be freed via deinit().

const std = @import("std");

/// Represents a link from one note to another.
/// Wikilinks can have optional "nature" describing the relationship type.
/// Example: [[supports::Feature A]] -> nature="supports", target="Feature A"
pub const Link = struct {
    /// The target note name/path (required)
    target: []const u8,
    /// Optional relationship type (e.g., "supports", "contradicts", "derived-from")
    /// Uses :: syntax: [[nature::target]]
    nature: ?[]const u8,
};

/// A parsed markdown note in the knowledge graph.
///
/// Ownership: All string fields are owned by this struct.
/// Must call deinit() to free all allocated memory.
///
/// Design: Uses ArrayLists for variable-length collections (links, tags, backlinks)
/// and StringHashMap for O(1) metadata lookups. Backlinks are populated externally
/// by the graph module after parsing all nodes.
pub const Node = struct {
    /// File path relative to knowledge base root
    path: []const u8,
    /// Display title (currently basename of path, could be enhanced to use first H1)
    title: []const u8,
    /// UUID v4 for unique identification (36 chars: 8-4-4-4-12 format)
    id: []const u8,
    /// Raw markdown content (includes frontmatter)
    content: []const u8,
    /// Outgoing wikilinks found in content
    links: std.ArrayList(Link),
    /// Incoming links from other notes (populated by graph module, not parser)
    backlinks: std.ArrayList([]const u8),
    /// Tags extracted from #tag syntax
    tags: std.ArrayList([]const u8),
    /// YAML frontmatter key-value pairs
    metadata: std.StringHashMap([]const u8),

    /// Creates a deep copy of the node with all strings duplicated.
    /// Used when nodes need independent lifetimes (e.g., cache invalidation).
    ///
    /// Why deep clone: ArrayList.clone() only copies slices (pointers), not the
    /// underlying string data. We dupe each string to ensure the clone survives
    /// after the original is deinitialized.
    pub fn clone(self: Node, allocator: std.mem.Allocator) !Node {
        var new_node: Node = .{
            .path = try allocator.dupe(u8, self.path),
            .title = try allocator.dupe(u8, self.title),
            .id = try allocator.dupe(u8, self.id),
            .content = try allocator.dupe(u8, self.content),
            .links = try self.links.clone(allocator),
            .backlinks = try self.backlinks.clone(allocator),
            .tags = try self.tags.clone(allocator),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
        errdefer new_node.deinit(allocator);

        // Deep clone links
        for (new_node.links.items) |*link| {
            link.target = try allocator.dupe(u8, link.target);
            if (link.nature) |nat| link.nature = try allocator.dupe(u8, nat);
        }

        // Deep clone backlinks
        for (new_node.backlinks.items) |*blink| {
            blink.* = try allocator.dupe(u8, blink.*);
        }

        // Deep clone tags
        for (new_node.tags.items) |*tag| {
            tag.* = try allocator.dupe(u8, tag.*);
        }

        // Deep clone metadata
        var meta_it = self.metadata.iterator();
        while (meta_it.next()) |entry| {
            try new_node.metadata.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
        }

        return new_node;
    }

    /// Frees all owned memory. Must be called when node is no longer needed.
    ///
    /// Order matters: Free child allocations before containers.
    /// 1. Free strings in ArrayLists
    /// 2. Free ArrayLists themselves
    /// 3. Free metadata keys/values, then HashMap
    ///
    /// Sets self.* = undefined to catch use-after-free bugs (accessing undefined
    /// memory will crash rather than silently corrupt data).
    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        allocator.free(self.id);
        allocator.free(self.content);
        // Free link strings before ArrayList
        for (self.links.items) |link| {
            allocator.free(link.target);
            if (link.nature) |nat| allocator.free(nat);
        }
        for (self.backlinks.items) |blink| allocator.free(blink);
        for (self.tags.items) |tag| allocator.free(tag);
        // Free ArrayList buffers
        self.links.deinit(allocator);
        self.backlinks.deinit(allocator);
        self.tags.deinit(allocator);

        // Free metadata key/value strings before HashMap
        var meta_iter = self.metadata.iterator();
        while (meta_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
        self.* = undefined;
    }
};

/// Markdown parser that extracts structured data from notes.
///
/// Usage:
///   var parser = Parser.init(allocator);
///   var node = try parser.parseFile("note.md");
///   defer node.deinit(allocator);
///
/// Thread safety: Parser is NOT thread-safe. Use one parser per thread or
/// synchronize access.
pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    /// Generate a UUID v4 string (36 chars: 8-4-4-4-12 format)
    /// Uses crypto-secure random bytes for uniqueness
    fn generateUuid(self: *Parser) ![]const u8 {
        var uuid_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&uuid_bytes);

        // Set version (4) and variant bits per RFC 4122
        uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40; // version 4
        uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80; // variant 1

        // Format: 8-4-4-4-12 (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        const hex_chars = "0123456789abcdef";
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            try buf.append(self.allocator, hex_chars[uuid_bytes[i] >> 4]);
            try buf.append(self.allocator, hex_chars[uuid_bytes[i] & 0x0f]);
            if (i == 3 or i == 5 or i == 7 or i == 9) {
                try buf.append(self.allocator, '-');
            }
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Parses a markdown file from disk.
    ///
    /// 1MB limit prevents memory exhaustion from accidentally parsing binary files
    /// or extremely large documents. Most knowledge base notes are <100KB.
    pub fn parseFile(self: *Parser, path: []const u8) !Node {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // max 1MB
        defer self.allocator.free(content);

        return self.parseContent(path, content);
    }

    /// Parses markdown content string into a Node.
    ///
    /// Processing order:
    /// 1. Create Node with path/title/content (all dupe'd for ownership)
    /// 2. Parse YAML frontmatter if present (between --- markers)
    /// 3. Extract wikilinks: [[target]] and [[nature::target]]
    /// 4. Extract tags: #tag (skip markdown headers ##, ###, etc.)
    ///
    /// Why single-pass: Avoids multiple content scans. Frontmatter and links/tags
    /// can be extracted in one traversal after frontmatter boundary is found.
    pub fn parseContent(self: *Parser, path: []const u8, content: []const u8) !Node {
        // Initialize node with empty collections
        // ArrayLists start empty (.{} = zero-length unmanaged ArrayList)
        var node: Node = .{
            .path = try self.allocator.dupe(u8, path),
            .title = try self.allocator.dupe(u8, std.fs.path.basename(path)),
            .id = try self.generateUuid(),
            .content = try self.allocator.dupe(u8, content),
            .links = .{},
            .backlinks = .{},
            .tags = .{},
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
        errdefer node.deinit(self.allocator);

        var content_start: usize = 0;

        // YAML frontmatter: ---\nkey: value\n---\n
        // Why check content[3..]: Skip first ---, find closing ---
        // This handles files that start with --- but aren't frontmatter (rare edge case)
        if (std.mem.startsWith(u8, content, "---")) {
            const second_sep = std.mem.indexOf(u8, content[3..], "---");
            if (second_sep) |sep_idx| {
                const frontmatter = content[3 .. sep_idx + 3];
                content_start = sep_idx + 6; // Move past --- and potential newline

                // Simple YAML parsing: split on first ":" per line
                // Limitation: Values with colons (URLs) get truncated
                // Example: "url: https://example.com" -> key="url", value="https"
                // Future: Could use proper YAML parser for complex values
                var lines = std.mem.tokenizeAny(u8, frontmatter, "\r\n");
                while (lines.next()) |line| {
                    var parts = std.mem.splitSequence(u8, line, ":");
                    const key_raw = parts.next() orelse continue;
                    const value_raw = parts.next() orelse "";

                    const key = std.mem.trim(u8, key_raw, " ");
                    const value = std.mem.trim(u8, value_raw, " ");

                    if (key.len > 0) {
                        try node.metadata.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
                    }
                }
            }
        }

        // Single-pass extraction of wikilinks and tags
        // Why single loop: Both features scan content character-by-character,
        // combining them avoids redundant iteration.
        var i: usize = content_start;
        while (i < content.len) : (i += 1) {
            // Wikilink detection: [[target]] or [[nature::target]]
            // Obsidian/Logseq-style syntax for note links
            if (i + 2 <= content.len and std.mem.eql(u8, content[i .. i + 2], "[[")) {
                const start = i + 2;
                var end = start;
                // Find closing ]]: scan until "]]" found
                // Limitation: Doesn't handle nested [[...]] inside wikilink
                while (end < content.len and !(end + 2 <= content.len and std.mem.eql(u8, content[end .. end + 2], "]]"))) : (end += 1) {}
                if (end + 2 <= content.len and std.mem.eql(u8, content[end .. end + 2], "]]")) {
                    const raw_link = content[start..end];
                    var link_obj: Link = .{ .target = undefined, .nature = null };

                    // Split on :: to separate nature from target
                    // First :: is separator, subsequent :: stay in target
                    // Example: [[a::b::c]] -> nature="a", target="b::c"
                    if (std.mem.indexOf(u8, raw_link, "::")) |sep_idx| {
                        link_obj.nature = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link[0..sep_idx], " "));
                        link_obj.target = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link[sep_idx + 2 ..], " "));
                    } else {
                        link_obj.target = try self.allocator.dupe(u8, std.mem.trim(u8, raw_link, " "));
                    }

                    try node.links.append(self.allocator, link_obj);
                    i = end + 1; // Skip past ]] to continue scanning
                }
            } else if (content[i] == '#') {
                // Tag extraction: #tag
                // Must distinguish from markdown headers: # Heading, ## Heading, etc.
                //
                // Heuristic: If # is followed by # or space, it's a header:
                //   "# Heading" -> # followed by space = header
                //   "## Heading" -> # followed by # = header
                //   "#tag" -> # followed by 't' = tag
                //
                // Limitation: "# heading" (H1 with space) correctly skipped,
                // but "#heading" (tag-like) would be extracted as tag.
                // This matches Obsidian behavior.
                if (i + 1 < content.len and (content[i + 1] == '#' or content[i + 1] == ' ')) {
                    // Markdown header, not a tag
                    continue;
                }

                const start = i + 1;
                var end = start;
                // Tag ends at whitespace or sentence punctuation
                // Allows: underscores, hyphens, numbers, letters in tags
                // Example: #tag_name, #tag-name, #tag123 all valid
                while (end < content.len and !std.ascii.isWhitespace(content[end]) and content[end] != '.' and content[end] != ',') : (end += 1) {}
                if (end > start) {
                    const tag = try self.allocator.dupe(u8, content[start..end]);
                    try node.tags.append(self.allocator, tag);
                    i = end; // Continue from tag end
                }
            }
        }

        return node;
    }
};

// Tests: Each test covers a specific parsing scenario.
// Naming convention: "Parser: <feature> <variant>"
// Tests verify both happy path and edge cases/limitations.

test "Parser: basic parsing" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Hello world";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("test.md", node.path);
    try std.testing.expectEqualStrings("test.md", node.title);
    try std.testing.expectEqualStrings(content, node.content);
    try std.testing.expectEqual(@as(usize, 0), node.links.items.len);
    try std.testing.expectEqual(@as(usize, 0), node.tags.items.len);
    try std.testing.expectEqual(@as(u32, 0), node.metadata.count());
}

test "Parser: frontmatter" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\author: John Doe
        \\type: note
        \\---
        \\Content here
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("John Doe", node.metadata.get("author").?);
    try std.testing.expectEqualStrings("note", node.metadata.get("type").?);
    try std.testing.expectEqual(@as(u32, 2), node.metadata.count());
}

test "Parser: wikilinks" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Check [[Other File]] and [[supports::Feature]]";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.links.items.len);
    try std.testing.expectEqualStrings("Other File", node.links.items[0].target);
    try std.testing.expect(node.links.items[0].nature == null);

    try std.testing.expectEqualStrings("Feature", node.links.items[1].target);
    try std.testing.expectEqualStrings("supports", node.links.items[1].nature.?);
}

test "Parser: tags" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "This is #important and #urgent, but not #. or # alone";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
    try std.testing.expectEqualStrings("important", node.tags.items[0]);
    try std.testing.expectEqualStrings("urgent", node.tags.items[1]);
}

test "Parser: tags vs markdown headers" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\## Heading 1
        \\### Heading 2
        \\# Heading 3
        \\
        \\This has #real-tag but not # header-like.
        \\#### Another heading
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    // Only #real-tag should be extracted, headers should be skipped
    try std.testing.expectEqual(@as(usize, 1), node.tags.items.len);
    try std.testing.expectEqualStrings("real-tag", node.tags.items[0]);
}

test "Parser: complex combination" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\key: value
        \\---
        \\#start
        \\Link to [[Target]] with #tag inside.
        \\Another [[relation::AnotherTarget]].
        \\#end
    ;
    var node = try parser.parseContent("complex.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), node.metadata.count());
    try std.testing.expectEqual(@as(usize, 2), node.links.items.len);
    try std.testing.expectEqual(@as(usize, 3), node.tags.items.len);

    try std.testing.expectEqualStrings("value", node.metadata.get("key").?);
    try std.testing.expectEqualStrings("Target", node.links.items[0].target);
    try std.testing.expectEqualStrings("AnotherTarget", node.links.items[1].target);
    try std.testing.expectEqualStrings("relation", node.links.items[1].nature.?);
    try std.testing.expectEqualStrings("start", node.tags.items[0]);
    try std.testing.expectEqualStrings("tag", node.tags.items[1]);
    try std.testing.expectEqualStrings("end", node.tags.items[2]);
}

test "Parser: empty content" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    var node = try parser.parseContent("empty.md", "");
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("empty.md", node.path);
    try std.testing.expectEqual(@as(usize, 0), node.links.items.len);
    try std.testing.expectEqual(@as(usize, 0), node.tags.items.len);
    try std.testing.expectEqual(@as(u32, 0), node.metadata.count());
}

test "Parser: multiple wikilinks same line" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "See [[A]], [[B]], and [[C]] all here.";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), node.links.items.len);
    try std.testing.expectEqualStrings("A", node.links.items[0].target);
    try std.testing.expectEqualStrings("B", node.links.items[1].target);
    try std.testing.expectEqualStrings("C", node.links.items[2].target);
}

test "Parser: wikilink with spaces in target" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Link to [[My File Name]] and [[type::Some Target]]";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.links.items.len);
    try std.testing.expectEqualStrings("My File Name", node.links.items[0].target);
    try std.testing.expectEqualStrings("Some Target", node.links.items[1].target);
    try std.testing.expectEqualStrings("type", node.links.items[1].nature.?);
}

test "Parser: frontmatter with colons in value" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    // Note: Parser splits on first ":", so values with colons are truncated
    // This test documents current behavior (limitation)
    const content =
        \\---
        \\url: https://example.com
        \\simple: value
        \\---
        \\Content
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    // URL gets split at first colon - known limitation
    try std.testing.expectEqualStrings("https", node.metadata.get("url").?);
    try std.testing.expectEqualStrings("value", node.metadata.get("simple").?);
}

test "Parser: frontmatter with empty value" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\empty:
        \\filled: value
        \\---
        \\Content
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqualStrings("", node.metadata.get("empty").?);
    try std.testing.expectEqualStrings("value", node.metadata.get("filled").?);
}

test "Parser: tags with special characters" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Tags: #tag_name #tag-name #tag123 #TAG_UPPER";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), node.tags.items.len);
    try std.testing.expectEqualStrings("tag_name", node.tags.items[0]);
    try std.testing.expectEqualStrings("tag-name", node.tags.items[1]);
    try std.testing.expectEqualStrings("tag123", node.tags.items[2]);
    try std.testing.expectEqualStrings("TAG_UPPER", node.tags.items[3]);
}

test "Parser: tag at line boundaries" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\#first
        \\text #middle text
        \\#last
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), node.tags.items.len);
    try std.testing.expectEqualStrings("first", node.tags.items[0]);
    try std.testing.expectEqualStrings("middle", node.tags.items[1]);
    try std.testing.expectEqualStrings("last", node.tags.items[2]);
}

test "Parser: unclosed wikilink ignored" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "This [[unclosed link should be ignored";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), node.links.items.len);
}

test "Parser: nested brackets in wikilink" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    // Note: Parser finds first "]]" - doesn't handle nested brackets
    // This test documents current behavior (limitation)
    const content = "Link [[File [with brackets]]] here";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    // Parser stops at first "]]", so target is "File [with brackets" (missing final ])
    try std.testing.expectEqual(@as(usize, 1), node.links.items.len);
    try std.testing.expectEqualStrings("File [with brackets", node.links.items[0].target);
}

test "Parser: Node.clone deep copies all fields" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Link [[Target]] with #tag";
    var original = try parser.parseContent("original.md", content);
    // Don't defer deinit yet - we need to test clone independence

    // Add backlink manually
    try original.backlinks.append(allocator, try allocator.dupe(u8, "backlink_source"));

    var cloned = try original.clone(allocator);

    // Deinit original BEFORE checking clone (tests deep copy independence)
    original.deinit(allocator);

    // Verify clone has same data
    try std.testing.expectEqualStrings("original.md", cloned.path);
    try std.testing.expectEqual(@as(usize, 1), cloned.links.items.len);
    try std.testing.expectEqual(@as(usize, 1), cloned.backlinks.items.len);
    try std.testing.expectEqual(@as(usize, 1), cloned.tags.items.len);

    cloned.deinit(allocator);
}

test "Parser: wikilink with multiple colons" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Link [[nature::type::Target]] here";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), node.links.items.len);
    // First :: separates nature from target
    try std.testing.expectEqualStrings("nature", node.links.items[0].nature.?);
    try std.testing.expectEqualStrings("type::Target", node.links.items[0].target);
}

test "Parser: only frontmatter no content" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\key: value
        \\---
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), node.metadata.count());
    try std.testing.expectEqualStrings("value", node.metadata.get("key").?);
    try std.testing.expectEqual(@as(usize, 0), node.links.items.len);
}

test "Parser: incomplete frontmatter ignored" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\key: value
        \\No closing separator
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    // No frontmatter should be parsed (missing closing ---)
    try std.testing.expectEqual(@as(u32, 0), node.metadata.count());
}

test "Parser: tag followed by punctuation" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "This is #important, and #urgent.";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
    try std.testing.expectEqualStrings("important", node.tags.items[0]);
    try std.testing.expectEqualStrings("urgent", node.tags.items[1]);
}

test "Parser: multiple frontmatter keys with spaces" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content =
        \\---
        \\  key1  :  value1
        \\key2:value2
        \\---
        \\Content
    ;
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), node.metadata.count());
    try std.testing.expectEqualStrings("value1", node.metadata.get("key1").?);
    try std.testing.expectEqualStrings("value2", node.metadata.get("key2").?);
}

test "Parser: consecutive tags" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "#a #b #c";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), node.tags.items.len);
    try std.testing.expectEqualStrings("a", node.tags.items[0]);
    try std.testing.expectEqualStrings("b", node.tags.items[1]);
    try std.testing.expectEqualStrings("c", node.tags.items[2]);
}

test "Parser: wikilink with trimmed whitespace" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);

    const content = "Link [[  spaced target  ]] and [[  nature  ::  target  ]]";
    var node = try parser.parseContent("test.md", content);
    defer node.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), node.links.items.len);
    try std.testing.expectEqualStrings("spaced target", node.links.items[0].target);
    try std.testing.expectEqualStrings("nature", node.links.items[1].nature.?);
    try std.testing.expectEqualStrings("target", node.links.items[1].target);
}
