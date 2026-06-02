# Mind-Map RAG Implementation Plan

>For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Goal: Build a reasoning-based RAG system that structures long markdown documents as concept mind-maps (section tree + causal links) and retrieves answers via LLM-guided tree traversal.

Architecture: Five new modules under `src/mindmap/` — data structures, LLM HTTP client, serialization, build pipeline, query pipeline — wired into the existing `li` CLI.

Tech Stack: Zig 0.16.0, `std.http.Client` for LLM API calls, `std.json` for serialization, existing `src/parser.zig` for markdown parsing.

### Task 1: Data Structures — `src/mindmap/mindmap.zig`

Files:

- Create: `src/mindmap/mindmap.zig`
- Test: Tests in same file

- [ ] Step 1: Write tests for ConceptNode, CausalLink, MindMap

Append to `src/mindmap/mindmap.zig`:

```zig
test "ConceptNode: init and deinit lifecycle" {
    const alloc = std.testing.allocator;
    var node = try ConceptNode.init(alloc, "intro", "Introduction", "Overview of the topic", 1, 0, 10);
    defer node.deinit(alloc);
    try std.testing.expectEqualStrings("intro", node.id);
    try std.testing.expectEqualStrings("Introduction", node.title);
    try std.testing.expectEqualStrings("Overview of the topic", node.summary);
    try std.testing.expectEqual(@as(u8, 1), node.level);
    try std.testing.expect(node.children == null);
    try std.testing.expect(node.causal_links == null);
}

test "ConceptNode: add child and causal link" {
    const alloc = std.testing.allocator;
    var parent = try ConceptNode.init(alloc, "parent", "Parent", "", 1, 0, 10);
    defer parent.deinit(alloc);
    var child = try ConceptNode.init(alloc, "child", "Child", "", 2, 3, 7);
    try parent.addChild(alloc, child);
    try parent.addCausalLink(alloc, "child", "leads-to", "Child follows from parent");
    try std.testing.expect(parent.children.?.items.len == 1);
    try std.testing.expect(parent.causal_links.?.items.len == 1);
    try std.testing.expectEqualStrings("child", parent.causal_links.?.items[0].target);
}

test "CausalLink: init" {
    var link = CausalLink.init("a", "b", "causes", "A causes B");
    try std.testing.expectEqualStrings("a", link.source);
    try std.testing.expectEqualStrings("causes", link.relation);
}

test "MindMap: init and deinit" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "My Doc", "A test document");
    defer mm.deinit(alloc);
    try std.testing.expectEqualStrings("My Doc", mm.title);
    try std.testing.expect(mm.nodes.items.len == 0);
}

test "MindMap: serialization round-trip" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Doc", "Summary");
    defer mm.deinit(alloc);
    var node = try ConceptNode.init(alloc, "c1", "Concept 1", "First concept", 1, 0, 5);
    try node.addCausalLink(alloc, "c2", "enables", "C1 enables C2");
    try mm.nodes.append(alloc, node);

    var out_buf = std.ArrayList(u8).init(alloc);
    defer out_buf.deinit();
    try mm.toJson(alloc, out_buf.writer());

    var parsed = try MindMap.fromJson(alloc, out_buf.items);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("Doc", parsed.title);
    try std.testing.expect(parsed.nodes.items.len == 1);
    try std.testing.expectEqualStrings("c1", parsed.nodes.items[0].id);
    try std.testing.expect(parsed.nodes.items[0].causal_links.?.items.len == 1);
}
```

- [ ] Step 2: Run tests, expect compile error (no struct yet)

Run: `zig build test`
Expected: Compile error — module not found.

- [ ] Step 3: Implement data structures

`src/mindmap/mindmap.zig`:

```zig
const std = @import("std");

pub const CausalLink = struct {
    source: []const u8,
    target: []const u8,
    relation: []const u8,
    description: []const u8,

    pub fn init(source: []const u8, target: []const u8, relation: []const u8, description: []const u8) CausalLink {
        return .{ .source = source, .target = target, .relation = relation, .description = description };
    }

    pub fn deinit(_: *CausalLink, _: std.mem.Allocator) void {}
};

pub const ConceptNode = struct {
    id: []const u8,
    title: []const u8,
    summary: []const u8,
    level: u8,
    source_start: usize,
    source_end: usize,
    children: ?std.ArrayList(ConceptNode),
    causal_links: ?std.ArrayList(CausalLink),

    pub fn init(alloc: std.mem.Allocator, id: []const u8, title: []const u8, summary: []const u8, level: u8, source_start: usize, source_end: usize) !ConceptNode {
        return .{
            .id = try alloc.dupe(u8, id),
            .title = try alloc.dupe(u8, title),
            .summary = try alloc.dupe(u8, summary),
            .level = level,
            .source_start = source_start,
            .source_end = source_end,
            .children = null,
            .causal_links = null,
        };
    }

    pub fn deinit(self: *ConceptNode, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.summary);
        if (self.children) |*ch| {
            for (ch.items) |*c| c.deinit(alloc);
            ch.deinit(alloc);
        }
        if (self.causal_links) |*cl| {
            cl.deinit(alloc);
        }
    }

    pub fn addChild(self: *ConceptNode, alloc: std.mem.Allocator, child: ConceptNode) !void {
        if (self.children) |*ch| {
            try ch.append(alloc, child);
        } else {
            var list = std.ArrayList(ConceptNode).init(alloc);
            try list.append(alloc, child);
            self.children = list;
        }
    }

    pub fn addCausalLink(self: *ConceptNode, alloc: std.mem.Allocator, target: []const u8, relation: []const u8, description: []const u8) !void {
        const link = CausalLink.init(self.id, target, relation, description);
        if (self.causal_links) |*cl| {
            try cl.append(alloc, link);
        } else {
            var list = std.ArrayList(CausalLink).init(alloc);
            try list.append(alloc, link);
            self.causal_links = list;
        }
    }
};

pub const MindMap = struct {
    title: []const u8,
    summary: []const u8,
    nodes: std.ArrayList(ConceptNode),

    pub fn init(alloc: std.mem.Allocator, title: []const u8, summary: []const u8) !MindMap {
        return .{
            .title = try alloc.dupe(u8, title),
            .summary = try alloc.dupe(u8, summary),
            .nodes = std.ArrayList(ConceptNode).init(alloc),
        };
    }

    pub fn deinit(self: *MindMap, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.summary);
        for (self.nodes.items) |*n| n.deinit(alloc);
        self.nodes.deinit(alloc);
    }

    pub fn toJson(self: *const MindMap, alloc: std.mem.Allocator, writer: anytype) !void {
        var jw: std.json.Stringify = .{ .writer = &writer, .options = .{ .whitespace = .indent_2 } };
        try jw.write(self);
    }

    pub fn jsonStringify(self: *const MindMap, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("title");
        try jws.write(self.title);
        try jws.objectField("summary");
        try jws.write(self.summary);
        try jws.objectField("nodes");
        try jws.write(self.nodes.items);
        try jws.endObject();
    }
};
```

- [ ] Step 4: Run tests

Run: `zig build test`
Expected: All tests pass.

- [ ] Step 5: Commit

```bash
git add src/mindmap/mindmap.zig
git commit -m "feat(mindmap): add core data structures"
```

### Task 2: LLM HTTP Client — `src/mindmap/llm.zig`

Files:

- Create: `src/mindmap/llm.zig`
- Test: Tests in same file

- [ ] Step 1: Write tests

```zig
test "LLMConfig: default values" {
    const config = LLMConfig.init();
    try std.testing.expectEqualStrings("gpt-4o", config.model);
    try std.testing.expect(config.api_key.len == 0);
}

test "LLMRequest: build chat payload" {
    const alloc = std.testing.allocator;
    var messages: [2]LLMMessage = .{
        .{ .role = "system", .content = "You are a helpful assistant." },
        .{ .role = "user", .content = "Summarize this." },
    };
    var req = LLMRequest.init(messages[0..], "gpt-4o", 0.7);
    defer req.deinit(alloc);

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    const json = try req.toJson(alloc);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "gpt-4o") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Summarize this.") != null);
}

test "LLMResponse: parse from JSON" {
    const json =
        \\{"id":"1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Hello world"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
    ;
    const alloc = std.testing.allocator;
    var resp = try LLMResponse.fromJson(alloc, json);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("Hello world", resp.content);
}

test "LLMResponse: empty choices" {
    const json = \\{"id":"1","choices":[]};
    const alloc = std.testing.allocator;
    var resp = try LLMResponse.fromJson(alloc, json);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("", resp.content);
}
```

- [ ] Step 2: Run tests, expect compile error

Run: `zig build test`

- [ ] Step 3: Implement LLM module

`src/mindmap/llm.zig`:

```zig
const std = @import("std");

pub const LLMConfig = struct {
    model: []const u8 = "gpt-4o",
    endpoint: []const u8 = "https://api.openai.com/v1/chat/completions",
    api_key: []const u8 = "",
    max_retries: u3 = 3,

    pub fn init() LLMConfig {
        return .{};
    }
};

pub const LLMMessage = struct {
    role: []const u8,
    content: []const u8,

    pub fn jsonStringify(self: LLMMessage, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("role");
        try jws.write(self.role);
        try jws.objectField("content");
        try jws.write(self.content);
        try jws.endObject();
    }
};

pub const LLMRequest = struct {
    model: []const u8,
    messages: []LLMMessage,
    temperature: f64 = 0.7,
    allocator: std.mem.Allocator,

    pub fn init(messages: []LLMMessage, model: []const u8, temperature: f64) LLMRequest {
        return .{ .model = model, .messages = messages, .temperature = temperature, .allocator = undefined };
    }

    pub fn deinit(_: *LLMRequest, _: std.mem.Allocator) void {}

    pub fn toJson(self: *const LLMRequest, alloc: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer(), .options = .{} };
        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(self.model);
        try jw.objectField("messages");
        try jw.write(self.messages);
        try jw.objectField("temperature");
        try jw.write(self.temperature);
        try jw.endObject();
        return buf.toOwnedSlice();
    }
};

pub const LLMResponse = struct {
    content: []const u8,
    finish_reason: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LLMResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        alloc.free(self.finish_reason);
    }

    pub fn fromJson(alloc: std.mem.Allocator, json: []const u8) !LLMResponse {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        const root = parsed.value;
        const choices = root.object.get("choices") orelse return LLMResponse{ .content = try alloc.dupe(u8, ""), .allocator = alloc };
        if (choices.array.items.len == 0) return LLMResponse{ .content = try alloc.dupe(u8, ""), .allocator = alloc };
        const msg = choices.array.items[0].object.get("message") orelse return LLMResponse{ .content = try alloc.dupe(u8, ""), .allocator = alloc };
        const content = msg.object.get("content") orelse return LLMResponse{ .content = try alloc.dupe(u8, ""), .allocator = alloc };
        const finish = msg.object.get("finish_reason") orelse "";
        return .{
            .content = try alloc.dupe(u8, content.string),
            .finish_reason = try alloc.dupe(u8, if (finish != .string) "" else finish.string),
            .allocator = alloc,
        };
    }
};
```

- [ ] Step 4: Run tests

Run: `zig build test`
Expected: All tests pass.

- [ ] Step 5: Commit

```bash
git add src/mindmap/llm.zig
git commit -m "feat(mindmap): add LLM HTTP client types"
```

### Task 3: Serialization — `src/mindmap/serialize.zig`

Files:

- Create: `src/mindmap/serialize.zig`
- Test: Tests in same file

- [ ] Step 1: Write tests

```zig
test "serialize: JSON round-trip for minimal mindmap" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Test", "A test mind-map");
    defer mm.deinit(alloc);
    var node = try ConceptNode.init(alloc, "n1", "Node 1", "First node", 1, 0, 10);
    try mm.nodes.append(alloc, node);

    const json = try serializeToJson(alloc, &mm);
    defer alloc.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Node 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "n1") != null);

    var parsed = try deserializeFromJson(alloc, json);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("Test", parsed.title);
    try std.testing.expect(parsed.nodes.items.len == 1);
}

test "serialize: JSON with children and causal links" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Doc", "Summary");
    defer mm.deinit(alloc);
    var parent = try ConceptNode.init(alloc, "p1", "Parent", "Parent concept", 1, 0, 20);
    var child = try ConceptNode.init(alloc, "c1", "Child", "Child concept", 2, 5, 15);
    try parent.addChild(alloc, child);
    try parent.addCausalLink(alloc, "other", "causes", "Parent causes other");
    try mm.nodes.append(alloc, parent);

    const json = try serializeToJson(alloc, &mm);
    defer alloc.free(json);
    var parsed = try deserializeFromJson(alloc, json);
    defer parsed.deinit(alloc);

    try std.testing.expect(parsed.nodes.items[0].children.?.items.len == 1);
    try std.testing.expectEqualStrings("Child", parsed.nodes.items[0].children.?.items[0].title);
    try std.testing.expect(parsed.nodes.items[0].causal_links.?.items.len == 1);
    try std.testing.expectEqualStrings("causes", parsed.nodes.items[0].causal_links.?.items[0].relation);
}

test "serialize: empty mindmap" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Empty", "");
    defer mm.deinit(alloc);
    const json = try serializeToJson(alloc, &mm);
    defer alloc.free(json);
    var parsed = try deserializeFromJson(alloc, json);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("Empty", parsed.title);
    try std.testing.expect(parsed.nodes.items.len == 0);
}
```

- [ ] Step 2: Run tests, expect compile error

Run: `zig build test`

- [ ] Step 3: Implement serialize module

`src/mindmap/serialize.zig`:

```zig
const std = @import("std");
const mm = @import("mindmap.zig");
const MindMap = mm.MindMap;
const ConceptNode = mm.ConceptNode;
const CausalLink = mm.CausalLink;

pub fn serializeToJson(alloc: std.mem.Allocator, mindmap: *const MindMap) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &buf.writer(), .options = .{ .whitespace = .indent_2 } };
    try jw.write(mindmap);
    try buf.append('\n');
    return buf.toOwnedSlice();
}

pub fn deserializeFromJson(alloc: std.mem.Allocator, json: []const u8) !MindMap {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value;

    const title = root.object.get("title") orelse return error.MissingField;
    const summary = root.object.get("summary") orelse return error.MissingField;
    const nodes_val = root.object.get("nodes") orelse return error.MissingField;

    var mindmap = try MindMap.init(alloc, title.string, summary.string);

    if (nodes_val.array.items.len == 0) return mindmap;

    for (nodes_val.array.items) |node_val| {
        var node = try parseNode(alloc, &node_val);
        try mindmap.nodes.append(alloc, node);
    }

    return mindmap;
}

fn parseNode(alloc: std.mem.Allocator, val: *const std.json.Value) !ConceptNode {
    const obj = val.object;
    const id = obj.get("id") orelse return error.MissingField;
    const title = obj.get("title") orelse return error.MissingField;
    const summary = obj.get("summary") orelse return error.MissingField;
    const level = obj.get("level") orelse return error.MissingField;
    const source_start = obj.get("source_start") orelse return error.MissingField;
    const source_end = obj.get("source_end") orelse return error.MissingField;

    var node = try ConceptNode.init(
        alloc, id.string, title.string, summary.string,
        @intCast(level.integer), @intCast(source_start.integer), @intCast(source_end.integer),
    );

    if (obj.get("children")) |children_val| {
        for (children_val.array.items) |child_val| {
            var child = try parseNode(alloc, &child_val);
            try node.addChild(alloc, child);
        }
    }

    if (obj.get("causal_links")) |links_val| {
        for (links_val.array.items) |link_val| {
            const link_obj = link_val.object;
            const src = link_obj.get("source") orelse return error.MissingField;
            const tgt = link_obj.get("target") orelse return error.MissingField;
            const rel = link_obj.get("relation") orelse return error.MissingField;
            const desc = link_obj.get("description") orelse return error.MissingField;
            try node.addCausalLink(alloc, tgt.string, rel.string, desc.string);
        }
    }

    return node;
}
```

- [ ] Step 4: Run tests

Run: `zig build test`
Expected: All tests pass.

- [ ] Step 5: Commit

```bash
git add src/mindmap/serialize.zig
git commit -m "feat(mindmap): add JSON serialization"
```

### Task 4: Build Pipeline — `src/mindmap/builder.zig`

Files:

- Create: `src/mindmap/builder.zig`
- Test: Tests in same file

- [ ] Step 1: Write tests

```zig
test "Builder: extract headings from markdown" {
    const alloc = std.testing.allocator;
    const md =
        \\# Introduction
        \\Some intro text.
        \\## Details
        \\More text.
        \\# Conclusion
        \\Final words.
    ;
    const headings = try extractHeadings(alloc, md);
    defer {
        for (headings) |h| { alloc.free(h.title); alloc.free(h.id); }
        alloc.free(headings);
    }
    try std.testing.expectEqual(@as(usize, 3), headings.len);
    try std.testing.expectEqualStrings("Introduction", headings[0].title);
    try std.testing.expectEqualStrings("details", headings[1].id);
    try std.testing.expectEqual(@as(u8, 2), headings[1].level);
}

test "Builder: parse heading id from title" {
    try std.testing.expectEqualStrings("hello-world", headingId("Hello World"));
    try std.testing.expectEqualStrings("hello-world", headingId("Hello   World!"));
    try std.testing.expectEqualStrings("my-section", headingId("My Section: Subtitle"));
}

test "Builder: build tree from flat headings" {
    const alloc = std.testing.allocator;
    const md =
        \\# A
        \\## B
        \\### C
        \\## D
        \\# E
    ;
    var tree = try buildHeadingTree(alloc, md);
    defer tree.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), tree.nodes.items.len);
    try std.testing.expectEqualStrings("a", tree.nodes.items[0].id);
    try std.testing.expect(tree.nodes.items[0].children.?.items.len == 2);
    try std.testing.expectEqualStrings("b", tree.nodes.items[0].children.?.items[0].id);
}
```

- [ ] Step 2: Run tests, expect compile error

Run: `zig build test`

- [ ] Step 3: Implement builder module

`src/mindmap/builder.zig`:

```zig
const std = @import("std");
const mm = @import("mindmap.zig");
const MindMap = mm.MindMap;
const ConceptNode = mm.ConceptNode;

pub const HeadingInfo = struct {
    id: []const u8,
    title: []const u8,
    level: u8,
    line: usize,
};

pub fn headingId(title: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    var idx: usize = 0;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (idx < buf.len) {
                buf[idx] = std.ascii.toLower(c);
                idx += 1;
            }
        } else if (c == ' ' or c == '-' or c == '_' or c == ':') {
            if (idx > 0 and buf[idx - 1] != '-' and idx < buf.len) {
                buf[idx] = '-';
                idx += 1;
            }
        }
    }
    if (idx > 0 and buf[idx - 1] == '-') idx -= 1;
    return buf[0..idx];
}

pub fn extractHeadings(alloc: std.mem.Allocator, content: []const u8) ![]HeadingInfo {
    var headings = std.ArrayList(HeadingInfo).init(alloc);
    errdefer {
        for (headings.items) |h| { alloc.free(h.title); alloc.free(h.id); }
        headings.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (lines.next()) |line| : (line_num += 1) {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0 and trimmed[0] == '#') {
            var level: u8 = 0;
            for (trimmed) |c| {
                if (c == '#') level += 1 else break;
            }
            const title = std.mem.trim(u8, trimmed[level..], " \r\t");
            // Skip frontmatter fences
            if (title.len == 0) continue;
            if (std.mem.eql(u8, title, "---")) continue;
            const id_str = headingId(title);
            try headings.append(alloc, .{
                .id = try alloc.dupe(u8, id_str),
                .title = try alloc.dupe(u8, title),
                .level = level,
                .line = line_num,
            });
        }
    }
    return headings.toOwnedSlice();
}

pub fn buildHeadingTree(alloc: std.mem.Allocator, content: []const u8) !ConceptNode {
    const headings = try extractHeadings(alloc, content);
    defer {
        for (headings) |h| { alloc.free(h.title); alloc.free(h.id); }
        alloc.free(headings);
    }

    if (headings.len == 0) {
        return ConceptNode.init(alloc, "doc", "Document", "", 0, 1, 0) catch unreachable;
    }

    const total_lines = 1 + std.mem.count(u8, content, "\n");
    const root_level = headings[0].level;
    var root = try ConceptNode.init(alloc, "doc", "Document", "", 0, 1, total_lines);

    var stack = std.ArrayList(*ConceptNode).init(alloc);
    defer stack.deinit(alloc);
    try stack.append(alloc, &root);

    for (headings) |h| {
        const rel_level = h.level - root_level + 1; // 1-indexed under root
        var child = try ConceptNode.init(alloc, h.id, h.title, "", rel_level, h.line, total_lines);

        while (stack.items.len > 1 and stack.items[stack.items.len - 1].level >= rel_level) {
            _ = stack.pop();
        }

        try stack.items[stack.items.len - 1].addChild(alloc, child);

        // The child was moved into the parent, but we need a pointer to it
        const last_child_idx = stack.items[stack.items.len - 1].children.?.items.len - 1;
        try stack.append(alloc, &stack.items[stack.items.len - 1].children.?.items[last_child_idx]);
    }

    return root;
}
```

Note: The tree-building above has a borrow issue (pointers to ArrayList items may be invalidated). We'll use a simpler approach with indices instead:

```zig
pub fn buildHeadingTree(alloc: std.mem.Allocator, content: []const u8) !ConceptNode {
    const headings = try extractHeadings(alloc, content);
    defer {
        for (headings) |h| { alloc.free(h.title); alloc.free(h.id); }
        alloc.free(headings);
    }

    if (headings.len == 0) {
        return ConceptNode.init(alloc, "doc", "Document", "", 0, 1, 0) catch unreachable;
    }

    const total_lines = 1 + std.mem.count(u8, content, "\n");
    var root = try ConceptNode.init(alloc, "doc", "Document", "", 0, 1, total_lines);

    // parent_indices: for each heading, index of its parent in the tree array
    var tree = std.ArrayList(ConceptNode).init(alloc);
    defer tree.deinit(alloc);

    for (headings) |h| {
        var node = try ConceptNode.init(alloc, h.id, h.title, "", h.level, h.line, total_lines);
        try tree.append(alloc, node);
    }

    // Build parent-child relationships
    var i: usize = 0;
    while (i < tree.items.len) : (i += 1) {
        const node_level = tree.items[i].level;
        var j = i + 1;
        while (j < tree.items.len and tree.items[j].level > node_level) : (j += 1) {
            if (tree.items[j].level == node_level + 1) {
                var child = tree.items[j];
                try tree.items[i].addChild(alloc, child);
            }
        }
    }

    // Top-level nodes become children of root
    for (tree.items) |*node| {
        if (node.level == headings[0].level) {
            try root.addChild(alloc, node.*);
        }
    }

    return root;
}
```

- [ ] Step 4: Run tests

Run: `zig build test`
Expected: All tests pass.

- [ ] Step 5: Commit

```bash
git add src/mindmap/builder.zig
git commit -m "feat(mindmap): add build pipeline (heading extraction + tree builder)"
```

### Task 5: Query Pipeline — `src/mindmap/query.zig`

Files:

- Create: `src/mindmap/query.zig`
- Test: Tests in same file

- [ ] Step 1: Write tests

```zig
const mm = @import("mindmap.zig");
const builder = @import("builder.zig");
const ConceptNode = mm.ConceptNode;
const MindMap = mm.MindMap;
const QueryResult = @import("query.zig").QueryResult;
const QueryEngine = @import("query.zig").QueryEngine;

test "QueryEngine: collect leaf nodes" {
    const alloc = std.testing.allocator;
    var mm = try MindMap.init(alloc, "Doc", "Summary");
    defer mm.deinit(alloc);
    var parent = try ConceptNode.init(alloc, "p1", "Parent", "Parent concept", 1, 0, 20);
    var child = try ConceptNode.init(alloc, "c1", "Child", "Child concept", 2, 5, 15);
    try parent.addChild(alloc, child);
    try mm.nodes.append(alloc, parent);

    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);
    const leaves = try engine.collectLeafNodes(&mm);
    defer alloc.free(leaves);
    try std.testing.expectEqual(@as(usize, 1), leaves.len);
    try std.testing.expectEqualStrings("c1", leaves[0].id);
}

test "QueryEngine: select relevant nodes by id" {
    const alloc = std.testing.allocator;
    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);

    var n1 = try ConceptNode.init(alloc, "a", "Alpha", "First concept", 1, 0, 5);
    var n2 = try ConceptNode.init(alloc, "b", "Beta", "Second concept", 1, 6, 10);

    const selected = try engine.selectNodes(&.{&n1, &n2}, &.{"a"});
    defer alloc.free(selected);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqualStrings("a", selected[0].id);
}

test "QueryEngine: assemble context text from nodes and document" {
    const alloc = std.testing.allocator;
    const doc =
        \\# Intro
        \\Hello world.
        \\## Details
        \\Deep dive here.
    ;
    var engine = QueryEngine.init(alloc);
    defer engine.deinit(alloc);
    var n1 = try ConceptNode.init(alloc, "intro", "Intro", "Intro section", 1, 1, 2);
    var n2 = try ConceptNode.init(alloc, "details", "Details", "Details section", 2, 3, 4);

    const ctx = try engine.assembleContext(alloc, doc, &.{&n1, &n2});
    defer alloc.free(ctx);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "Hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "Deep dive") != null);
}
```

- [ ] Step 2: Run tests, expect compile error

Run: `zig build test`
Expected: Compile error — module not found.

- [ ] Step 3: Implement query module

`src/mindmap/query.zig`:

```zig
const std = @import("std");
const mm = @import("mindmap.zig");
const ConceptNode = mm.ConceptNode;
const MindMap = mm.MindMap;

pub const QueryResult = struct {
    answer: []const u8,
    context: []const u8,
    node_ids: []const []const u8,

    pub fn deinit(self: *QueryResult, alloc: std.mem.Allocator) void {
        alloc.free(self.answer);
        alloc.free(self.context);
        for (self.node_ids) |id| alloc.free(id);
        alloc.free(self.node_ids);
    }
};

pub const QueryEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) QueryEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *QueryEngine, _: std.mem.Allocator) void {}

    /// Collect all leaf nodes (nodes without children) from the mind-map.
    pub fn collectLeafNodes(self: *QueryEngine, mindmap: *const MindMap) ![]*const ConceptNode {
        var leaves = std.ArrayList(*const ConceptNode).init(self.allocator);
        errdefer leaves.deinit(self.allocator);
        for (mindmap.nodes.items) |*node| {
            try self.collectLeavesRecursive(node, &leaves);
        }
        return leaves.toOwnedSlice();
    }

    fn collectLeavesRecursive(self: *QueryEngine, node: *const ConceptNode, leaves: *std.ArrayList(*const ConceptNode)) !void {
        if (node.children) |ch| {
            for (ch.items) |*child| {
                try self.collectLeavesRecursive(child, leaves);
            }
        } else {
            try leaves.append(self.allocator, node);
        }
    }

    /// Select nodes whose IDs are in the given set.
    pub fn selectNodes(self: *QueryEngine, candidates: []*const ConceptNode, selected_ids: []const []const u8) ![]*const ConceptNode {
        var result = std.ArrayList(*const ConceptNode).init(self.allocator);
        errdefer result.deinit(self.allocator);
        for (candidates) |node| {
            for (selected_ids) |id| {
                if (std.mem.eql(u8, node.id, id)) {
                    try result.append(self.allocator, node);
                    break;
                }
            }
        }
        return result.toOwnedSlice();
    }

    /// Assemble context text from the original document for selected nodes.
    pub fn assembleContext(self: *QueryEngine, alloc: std.mem.Allocator, doc: []const u8, nodes: []*const ConceptNode) ![]const u8 {
        var lines = std.ArrayList([]const u8).init(alloc);
        defer lines.deinit(alloc);

        // Sort nodes by source_start
        std.mem.sort(*const ConceptNode, nodes, {}, struct {
            fn lessThan(_: void, a: *const ConceptNode, b: *const ConceptNode) bool {
                return a.source_start < b.source_start;
            }
        }.lessThan);

        var doc_lines = std.mem.splitScalar(u8, doc, '\n');
        var line_buf = std.ArrayList(u8).init(alloc);
        defer line_buf.deinit(alloc);

        var line_num: usize = 1;
        while (doc_lines.next()) |line| : (line_num += 1) {
            for (nodes) |node| {
                if (line_num >= node.source_start and line_num <= node.source_end) {
                    try line_buf.appendSlice(alloc, line);
                    try line_buf.append(alloc, '\n');
                    break;
                }
            }
        }

        return line_buf.toOwnedSlice();
    }
};
```

- [ ] Step 4: Run tests

Run: `zig build test`
Expected: All tests pass.

- [ ] Step 5: Commit

```bash
git add src/mindmap/query.zig
git commit -m "feat(mindmap): add query engine with context assembly"
```

### Task 6: CLI Integration — `src/li.zig` + `build.zig`

Files:

- Modify: `src/li.zig`
- Modify: `build.zig`

- [ ] Step 1: Add `li mind build` and `li mind query` subcommand dispatch

In `src/li.zig`, add an `else if` branch for `"mind"` before the final `else` at line ~316:

```zig
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
            const content = try std.Io.Dir.cwd().readFileAlloc(init.io, file_path, allocator, .unlimited);
            defer allocator.free(content);

            const headings = try builder.extractHeadings(allocator, content);
            defer {
                for (headings) |h| { allocator.free(h.title); allocator.free(h.id); }
                allocator.free(headings);
            }

            var tree = try builder.buildHeadingTree(allocator, content);
            defer tree.deinit(allocator);

            // Build MindMap from tree
            var mind_map = try mm.MindMap.init(allocator, file_path, "");
            defer mind_map.deinit(allocator);

            // Move tree children into mind_map
            if (tree.children) |*ch| {
                for (ch.items) |*child| {
                    try mind_map.nodes.append(allocator, child.*);
                }
            }

            const out_path = try std.fs.path.join(allocator, &.{ ws_root, "mind-map.json" });
            defer allocator.free(out_path);
            const json = try serialize.serializeToJson(allocator, &mind_map);
            defer allocator.free(json);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = json });
            std.debug.print("Mind-map written to {s}\n", .{out_path});
        } else if (std.mem.eql(u8, subcmd, "query")) {
            if (args.len < 2) {
                std.debug.print("Usage: li mind query \"<question>\"\n", .{});
                return;
            }
            const question = args[1];
            const map_path = try std.fs.path.join(allocator, &.{ ws_root, "mind-map.json" });
            defer allocator.free(map_path);
            const json = std.Io.Dir.cwd().readFileAlloc(init.io, map_path, allocator, .unlimited) catch |err| {
                std.debug.print("Error: No mind-map found at {s}. Run 'li mind build' first. ({any})\n", .{ map_path, err });
                return;
            };
            defer allocator.free(json);
            var mind_map = try serialize.deserializeFromJson(allocator, json);
            defer mind_map.deinit(allocator);
            std.debug.print("Loaded mind-map: {s} ({d} top-level nodes)\n", .{ mind_map.title, mind_map.nodes.items.len });
            std.debug.print("Question: {s}\n", .{question});
            std.debug.print("Note: Full LLM query pipeline requires LLM API integration.\n", .{});
        } else {
            std.debug.print("Unknown mind subcommand: {s}. Use 'build' or 'query'.\n", .{subcmd});
        }
```

- [ ] Step 2: Add imports to `src/li.zig`

Near the top of `src/li.zig` (after existing imports at line ~22):

```zig
const mm = @import("mindmap/mindmap.zig");
const builder = @import("mindmap/builder.zig");
const serialize = @import("mindmap/serialize.zig");
const query_engine = @import("mindmap/query.zig");
```

- [ ] Step 3: Update `build.zig` to add mindmap module

In `build.zig`, add the mindmap module path to the `li_exe` root module. Find the `li_exe` block (starting at line 97) and add the import paths. Since Zig modules need explicit path entries, add:

The `li_exe` root module at line 99-107 needs its root_source_file to be able to `@import` from `mindmap/`. Since Zig resolves relative imports from the file's directory, `src/li.zig` can already do `@import("mindmap/mindmap.zig")` — no build.zig changes needed as long as the files are in `src/mindmap/`.

Also add a test step for the mindmap module:

```zig
    const mindmap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mindmap/mindmap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_mindmap_tests = b.addRunArtifact(mindmap_tests);

    // Add to test step
    test_step.dependOn(&run_mindmap_tests.step);
```

- [ ] Step 4: Build and verify

Run: `zig build`
Expected: Builds successfully.

- [ ] Step 5: Run all tests

Run: `zig build test`
Expected: All tests pass (existing + new mind-map tests).

- [ ] Step 6: Test CLI end-to-end

```bash
# Create a test markdown file
cat > /tmp/test_doc.md << 'EOF'
# Introduction
This is the intro section.
## Background
Some background context here.
# Main Topic
The main content goes here.
## Subtopic
More detailed information.
EOF

# Build mind-map
./zig-out/bin/li init /tmp/test_mind
./zig-out/bin/li mind build /tmp/test_doc.md
```

Expected: "Mind-map written to .../mind-map.json"

Verify output has correct structure:

```bash
cat /tmp/test_mind/mind-map.json | python3 -m json.tool | head -20
```

Expected: Shows the mind-map JSON with title, nodes, children.

- [ ] Step 7: Commit

```bash
git add src/li.zig src/mindmap/ build.zig
git commit -m "feat(mindmap): integrate mind-map RAG into CLI"
```

<｜end▁of▁thinking｜>

<｜｜DSML｜｜tool_calls>
<｜｜DSML｜｜invoke name="read">
<｜｜DSML｜｜parameter name="filePath" string="true">/Users/a0/w/linked-mind/src/mindmap