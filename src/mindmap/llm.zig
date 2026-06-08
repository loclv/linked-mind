const std = @import("std");

const c = std.c;

pub const LLMConfig = struct { // ziglint-ignore: Z032
    model: []const u8 = "gpt-4o",
    fallback_model: ?[]const u8 = "gpt-4o-mini",
    endpoint: []const u8 = "https://api.openai.com/v1/chat/completions",
    api_key: []const u8 = "",
    max_retries: u3 = 3,

    // Track dynamic allocations to avoid memory leaks during custom config loading
    _allocated_model: bool = false,
    _allocated_fallback: bool = false,
    _allocated_endpoint: bool = false,
    _allocated_api_key: bool = false,
    _allocator: ?std.mem.Allocator = null,

    pub fn init() LLMConfig {
        return .{};
    }

    pub fn deinit(self: *LLMConfig) void {
        if (self._allocator) |alloc| {
            if (self._allocated_model) alloc.free(self.model);
            if (self._allocated_fallback) {
                if (self.fallback_model) |fb| alloc.free(fb);
            }
            if (self._allocated_endpoint) alloc.free(self.endpoint);
            if (self._allocated_api_key) alloc.free(self.api_key);
        }
        self.* = undefined;
    }

    // Load configuration values from a JSON configuration file if it exists, otherwise use defaults
    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !LLMConfig {
        const file_content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1048576)) catch |err| {
            if (err == error.FileNotFound) {
                return init();
            }
            return err;
        };
        defer allocator.free(file_content);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, file_content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        const obj = if (root == .object) root.object else return error.InvalidJson;

        var config = init();
        config._allocator = allocator;

        if (obj.get("model")) |val| {
            if (val == .string) {
                config.model = try allocator.dupe(u8, val.string);
                config._allocated_model = true;
            }
        }
        if (obj.get("fallback_model")) |val| {
            if (val == .string) {
                config.fallback_model = try allocator.dupe(u8, val.string);
                config._allocated_fallback = true;
            } else if (val == .null) {
                config.fallback_model = null;
            }
        }
        if (obj.get("endpoint")) |val| {
            if (val == .string) {
                config.endpoint = try allocator.dupe(u8, val.string);
                config._allocated_endpoint = true;
            }
        }
        if (obj.get("api_key")) |val| {
            if (val == .string) {
                config.api_key = try allocator.dupe(u8, val.string);
                config._allocated_api_key = true;
            }
        }
        if (obj.get("max_retries")) |val| {
            if (val == .integer) {
                config.max_retries = @intCast(val.integer);
            }
        }

        return config;
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
        return out.toOwnedSlice();
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
        var current_model = llm_req.model;
        var attempt: u3 = 0;
        const max_attempts = self.config.max_retries;
        var backoff_seconds: u32 = 1;

        while (true) {
            var req_with_model = LLMRequest.init(llm_req.messages, current_model, llm_req.temperature);
            const json_body = req_with_model.toJson(self.allocator) catch |err| {
                std.log.err("Failed to serialize LLMRequest: {any}", .{err});
                return err;
            };
            defer self.allocator.free(json_body);

            var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
            defer client.deinit();

            const uri = std.Uri.parse(self.config.endpoint) catch |err| {
                std.log.err("Failed to parse LLM endpoint URI: {any}", .{err});
                return err;
            };

            var auth_hdr_buf: [4096]u8 = undefined;
            const auth_value = std.fmt.bufPrint(&auth_hdr_buf, "Bearer {s}", .{api_key}) catch |err| {
                std.log.err("Failed to format authorization header: {any}", .{err});
                return err;
            };

            var extra_headers = [_]std.http.Header{
                .{ .name = "Authorization", .value = auth_value },
                .{ .name = "Content-Type", .value = "application/json" },
            };

            var req = client.request(.POST, uri, .{ .extra_headers = &extra_headers }) catch |err| {
                std.log.err("LLM HTTP request failed (attempt {d}/{d}): {any}", .{ attempt + 1, max_attempts, err });
                if (attempt + 1 < max_attempts) {
                    attempt += 1;
                    try std.Io.sleep(self.io, std.Io.Duration.fromSeconds(backoff_seconds), .awake);
                    backoff_seconds *= 2;
                    continue;
                }
                if (self.config.fallback_model) |fallback| {
                    if (!std.mem.eql(u8, current_model, fallback)) {
                        std.log.warn("All attempts failed for {s}. Falling back to: {s}", .{ current_model, fallback });
                        current_model = fallback;
                        attempt = 0;
                        backoff_seconds = 1;
                        continue;
                    }
                }
                return err;
            };
            defer req.deinit();

            var transfer_buf: [4096]u8 = undefined;
            var bw = req.sendBody(&transfer_buf) catch |err| {
                std.log.err("Failed to send HTTP request body: {any}", .{err});
                if (attempt + 1 < max_attempts) {
                    attempt += 1;
                    try std.Io.sleep(self.io, std.Io.Duration.fromSeconds(backoff_seconds), .awake);
                    backoff_seconds *= 2;
                    continue;
                }
                if (self.config.fallback_model) |fallback| {
                    if (!std.mem.eql(u8, current_model, fallback)) {
                        std.log.warn("Failed sending body. Falling back to: {s}", .{fallback});
                        current_model = fallback;
                        attempt = 0;
                        backoff_seconds = 1;
                        continue;
                    }
                }
                return err;
            };
            bw.writer.writeAll(json_body) catch |err| {
                std.log.err("Failed to write JSON body: {any}", .{err});
                return err;
            };
            bw.end() catch |err| {
                std.log.err("Failed to end request body: {any}", .{err});
                return err;
            };

            var redirect_buf: [4096]u8 = undefined;
            var resp = req.receiveHead(&redirect_buf) catch |err| {
                std.log.err("Failed to receive HTTP response head: {any}", .{err});
                if (attempt + 1 < max_attempts) {
                    attempt += 1;
                    try std.Io.sleep(self.io, std.Io.Duration.fromSeconds(backoff_seconds), .awake);
                    backoff_seconds *= 2;
                    continue;
                }
                if (self.config.fallback_model) |fallback| {
                    if (!std.mem.eql(u8, current_model, fallback)) {
                        std.log.warn("Failed receiving head. Falling back to: {s}", .{fallback});
                        current_model = fallback;
                        attempt = 0;
                        backoff_seconds = 1;
                        continue;
                    }
                }
                return err;
            };

            if (resp.head.status.class() != .success) {
                var err_reader = resp.reader(&transfer_buf);
                var err_list: std.ArrayList(u8) = .empty;
                defer err_list.deinit(self.allocator);
                var chunk: [512]u8 = undefined;
                while (true) {
                    const n = err_reader.readSliceShort(&chunk) catch 0;
                    if (n == 0) break;
                    err_list.appendSlice(self.allocator, chunk[0..n]) catch |err| {
                        std.log.err("Failed to append to error list: {any}", .{err});
                    };
                }
                std.log.err("LLM API returned status {}: {s}", .{ resp.head.status, err_list.items });

                // Retriable HTTP status codes
                const is_retriable_status = resp.head.status == .too_many_requests or @intFromEnum(resp.head.status) >= 500;
                if (is_retriable_status and attempt + 1 < max_attempts) {
                    attempt += 1;
                    try std.Io.sleep(self.io, std.Io.Duration.fromSeconds(backoff_seconds), .awake);
                    backoff_seconds *= 2;
                    continue;
                }
                if (self.config.fallback_model) |fallback| {
                    if (!std.mem.eql(u8, current_model, fallback)) {
                        std.log.warn("HTTP status error. Falling back to: {s}", .{fallback});
                        current_model = fallback;
                        attempt = 0;
                        backoff_seconds = 1;
                        continue;
                    }
                }
                return error.HttpStatusError;
            }

            var resp_reader = resp.reader(&transfer_buf);
            var resp_list: std.ArrayList(u8) = .empty;
            defer resp_list.deinit(self.allocator);
            while (true) {
                const n = resp_reader.readSliceShort(&transfer_buf) catch |err| {
                    std.log.err("Failed to read response body: {any}", .{err});
                    return err;
                };
                if (n == 0) break;
                try resp_list.appendSlice(self.allocator, transfer_buf[0..n]);
            }

            return LLMResponse.fromJson(self.allocator, resp_list.items);
        }
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

        // Parse finish_reason if available
        var finish_reason_str: []const u8 = "";
        if (choice_obj.get("finish_reason")) |fr_val| {
            if (fr_val == .string) {
                finish_reason_str = fr_val.string;
            }
        }

        return .{
            .content = try alloc.dupe(u8, content_str),
            .finish_reason = try alloc.dupe(u8, finish_reason_str),
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
    try std.testing.expect(config.fallback_model != null);
    try std.testing.expectEqualStrings("gpt-4o-mini", config.fallback_model.?);
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
    try std.testing.expectEqualStrings("stop", resp.finish_reason);
}

test "LLMConfig: load from JSON file" {
    const alloc = std.testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const json_content =
        \\{
        \\  "model": "claude-3-opus",
        \\  "fallback_model": "claude-3-sonnet",
        \\  "endpoint": "https://api.anthropic.com/v1/messages",
        \\  "api_key": "sk-anthropic-test",
        \\  "max_retries": 5
        \\}
    ;

    var base = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer base.close(io);

    var rand_bytes: [8]u8 = undefined;
    try io.randomSecure(&rand_bytes);
    const hex_name = std.fmt.bytesToHex(rand_bytes, .lower);
    var name_buf: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(&name_buf, "li-llm-config-{s}.json", .{&hex_name});

    const full_path = try std.fs.path.join(alloc, &.{ "/tmp", filename });
    defer alloc.free(full_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = json_content });
    defer {
        if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |*b| {
            var mut_b = b.*;
            defer mut_b.close(io);
            mut_b.deleteFile(io, filename) catch {};
        } else |_| {}
    }

    var config = try LLMConfig.load(alloc, io, full_path);
    defer config.deinit();

    try std.testing.expectEqualStrings("claude-3-opus", config.model);
    try std.testing.expect(config.fallback_model != null);
    try std.testing.expectEqualStrings("claude-3-sonnet", config.fallback_model.?);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", config.endpoint);
    try std.testing.expectEqualStrings("sk-anthropic-test", config.api_key);
    try std.testing.expectEqual(@as(u3, 5), config.max_retries);
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
