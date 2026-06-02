const std = @import("std");

const c = std.c;

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

pub const LLMError = error{ // ziglint-ignore: Z032
    ApiKeyMissing,
    HttpStatusError,
    ResponseTooLarge,
};

pub const LLMService = struct { // ziglint-ignore: Z032
    allocator: std.mem.Allocator,
    config: LLMConfig,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: LLMConfig) LLMService {
        return .{ .allocator = allocator, .config = config, .io = io };
    }

    fn getApiKey(self: *const LLMService) ![]const u8 {
        if (self.config.api_key.len > 0) return self.config.api_key;
        const from_env = c.getenv("OPENAI_API_KEY") orelse return error.ApiKeyMissing;
        return std.mem.span(from_env);
    }

    pub fn chat(self: *LLMService, llm_req: *const LLMRequest) !LLMResponse {
        const api_key = try self.getApiKey();
        const json_body = try llm_req.toJson(self.allocator);
        defer self.allocator.free(json_body);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const uri = try std.Uri.parse(self.config.endpoint);

        var auth_hdr_buf: [4096]u8 = undefined;
        const auth_value = try std.fmt.bufPrint(&auth_hdr_buf, "Bearer {s}", .{api_key});

        var extra_headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_value },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        var req = try client.request(.POST, uri, .{ .extra_headers = &extra_headers });
        defer req.deinit();

        var transfer_buf: [4096]u8 = undefined;
        var bw = try req.sendBody(&transfer_buf);
        try bw.writer.writeAll(json_body);
        try bw.end();

        var redirect_buf: [4096]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);

        if (resp.head.status.class() != .success) {
            var err_reader = resp.reader(&transfer_buf);
            var err_list: std.ArrayList(u8) = .empty;
            defer err_list.deinit(self.allocator);
            var chunk: [512]u8 = undefined;
            while (true) {
                const n = try err_reader.readSliceShort(&chunk);
                if (n == 0) break;
                try err_list.appendSlice(self.allocator, chunk[0..n]);
            }
            std.log.err("LLM API returned {}: {s}", .{ resp.head.status, err_list.items });
            return error.HttpStatusError;
        }

        var resp_reader = resp.reader(&transfer_buf);
        var resp_list: std.ArrayList(u8) = .empty;
        defer resp_list.deinit(self.allocator);
        while (true) {
            const n = try resp_reader.readSliceShort(&transfer_buf);
            if (n == 0) break;
            try resp_list.appendSlice(self.allocator, transfer_buf[0..n]);
        }

        return LLMResponse.fromJson(self.allocator, resp_list.items);
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
