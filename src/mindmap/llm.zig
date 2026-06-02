const std = @import("std");

pub const LLMConfig = struct { // ziglint-ignore: Z032
    model: []const u8 = "gpt-4o",
    endpoint: []const u8 = "https://api.openai.com/v1/chat/completions",
    api_key: []const u8 = "",
    max_retries: u3 = 3,

    pub fn init() LLMConfig {
        return .{};
    }
};

pub const LLMMessage = struct { // ziglint-ignore: Z032
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

pub const LLMRequest = struct { // ziglint-ignore: Z032
    model: []const u8,
    messages: []LLMMessage,
    temperature: f64 = 0.7,
    allocator: std.mem.Allocator,

    pub fn init(messages: []LLMMessage, model: []const u8, temperature: f64) LLMRequest {
        return .{ .model = model, .messages = messages, .temperature = temperature, .allocator = undefined };
    }

    pub fn deinit(self: *LLMRequest, _: std.mem.Allocator) void {
        self.* = undefined;
    }

    pub fn toJson(self: *const LLMRequest, alloc: std.mem.Allocator) ![]const u8 {
        var out = std.Io.Writer.Allocating.init(alloc);
        defer out.deinit();
        var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(self.model);
        try jw.objectField("messages");
        try jw.write(self.messages);
        try jw.objectField("temperature");
        try jw.write(self.temperature);
        try jw.endObject();
        return alloc.dupe(u8, out.written());
    }
};

pub const LLMResponse = struct { // ziglint-ignore: Z032
    content: []const u8,
    finish_reason: []const u8 = "",
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LLMResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.content);
        alloc.free(self.finish_reason);
        self.* = undefined;
    }

    pub fn fromJson(alloc: std.mem.Allocator, json: []const u8) !LLMResponse {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        const root = parsed.value;
        const root_obj = if (root == .object) root.object else return error.InvalidJson;
        const choices_val = root_obj.get("choices") orelse return emptyResponse(alloc);
        const choices_arr = if (choices_val == .array) choices_val.array else return error.InvalidJson;
        if (choices_arr.items.len == 0) return emptyResponse(alloc);
        const first_choice = choices_arr.items[0];
        const choice_obj = if (first_choice == .object) first_choice.object else return error.InvalidJson;
        const msg_val = choice_obj.get("message") orelse return emptyResponse(alloc);
        const msg_obj = if (msg_val == .object) msg_val.object else return error.InvalidJson;
        const content_val = msg_obj.get("content") orelse return emptyResponse(alloc);
        const content_str = if (content_val == .string) content_val.string else return error.InvalidJson;
        return .{
            .content = try alloc.dupe(u8, content_str),
            .finish_reason = try alloc.dupe(u8, ""),
            .allocator = alloc,
        };
    }

    fn emptyResponse(alloc: std.mem.Allocator) !LLMResponse {
        return .{
            .content = try alloc.dupe(u8, ""),
            .finish_reason = try alloc.dupe(u8, ""),
            .allocator = alloc,
        };
    }
};

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
    const json =
        \\{"id":"1","choices":[]}
    ;
    const alloc = std.testing.allocator;
    var resp = try LLMResponse.fromJson(alloc, json);
    defer resp.deinit(alloc);
    try std.testing.expectEqualStrings("", resp.content);
}
