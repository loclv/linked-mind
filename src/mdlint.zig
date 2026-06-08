//! Markdown metadata linter CLI.
//! Scans specified target file or recursively scans a folder for Markdown files,
//! validating that each contains `name`, `description`, and `tags` metadata inside
//! its YAML frontmatter. Reports failures as a structured JSON array.

const std = @import("std");
const gitignore_mod = @import("map/handle_gitignore.zig");
const Gitignore = gitignore_mod.Gitignore;

pub const LintError = struct {
    file: []const u8,
    errors: std.ArrayList([]const u8),

    pub fn deinit(self: *LintError, allocator: std.mem.Allocator) void {
        allocator.free(self.file);
        for (self.errors.items) |err| {
            allocator.free(err);
        }
        self.errors.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: LintError, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(self.file);
        try jw.objectField("errors");
        try jw.beginArray();
        for (self.errors.items) |err| {
            try jw.write(err);
        }
        try jw.endArray();
        try jw.endObject();
    }
};

/// Reads file and returns a `LintError` if any metadata keys are missing.
pub fn checkMarkdownFile(allocator: std.mem.Allocator, io: std.Io, full_path: []const u8, report_path: []const u8) !?LintError {
    const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch |err| {
        std.log.err("Failed to read file '{s}': {any}", .{ full_path, err });
        return err;
    };
    defer allocator.free(content);

    var errors = std.ArrayList([]const u8).empty;
    errdefer {
        for (errors.items) |err| {
            allocator.free(err);
        }
        errors.deinit(allocator);
    }

    var has_frontmatter = false;
    var fm_content: []const u8 = "";

    if (std.mem.startsWith(u8, content, "---\n") or std.mem.startsWith(u8, content, "---\r\n")) {
        const start_offset = if (std.mem.startsWith(u8, content, "---\r\n")) @as(usize, 5) else @as(usize, 4);
        var search_idx: usize = start_offset;
        while (search_idx < content.len) {
            if (std.mem.startsWith(u8, content[search_idx..], "\n---")) {
                const after_idx = search_idx + 4;
                if (after_idx == content.len or content[after_idx] == '\n' or content[after_idx] == '\r') {
                    fm_content = content[start_offset..search_idx];
                    has_frontmatter = true;
                    break;
                }
            } else if (std.mem.startsWith(u8, content[search_idx..], "\r\n---")) {
                const after_idx = search_idx + 5;
                if (after_idx == content.len or content[after_idx] == '\n' or content[after_idx] == '\r') {
                    fm_content = content[start_offset..search_idx];
                    has_frontmatter = true;
                    break;
                }
            }
            search_idx += 1;
        }
    }

    if (!has_frontmatter) {
        try errors.append(allocator, try allocator.dupe(u8, "missing 'name' metadata"));
        try errors.append(allocator, try allocator.dupe(u8, "missing 'description' metadata"));
        try errors.append(allocator, try allocator.dupe(u8, "missing 'tags' metadata"));
    } else {
        var name_val: ?[]const u8 = null;
        var desc_val: ?[]const u8 = null;
        var tags_val: ?[]const u8 = null;
        var tags_list_has_items = false;

        var lines = std.mem.splitScalar(u8, fm_content, '\n');
        var inside_tags_list = false;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

            if (std.mem.startsWith(u8, trimmed, "name:")) {
                inside_tags_list = false;
                const val = std.mem.trim(u8, trimmed[5..], " \r\t\"'");
                if (val.len > 0) {
                    name_val = val;
                }
            } else if (std.mem.startsWith(u8, trimmed, "description:")) {
                inside_tags_list = false;
                const val = std.mem.trim(u8, trimmed[12..], " \r\t\"'");
                if (val.len > 0) {
                    desc_val = val;
                }
            } else if (std.mem.startsWith(u8, trimmed, "tags:")) {
                const val = std.mem.trim(u8, trimmed[5..], " \r\t\"'[]");
                if (val.len > 0) {
                    tags_val = val;
                } else {
                    inside_tags_list = true;
                }
            } else if (inside_tags_list and std.mem.startsWith(u8, trimmed, "-")) {
                const val = std.mem.trim(u8, trimmed[1..], " \r\t\"'");
                if (val.len > 0) {
                    tags_list_has_items = true;
                }
            } else {
                if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
                    inside_tags_list = false;
                }
            }
        }

        if (name_val == null) {
            try errors.append(allocator, try allocator.dupe(u8, "missing 'name' metadata"));
        }
        if (desc_val == null) {
            try errors.append(allocator, try allocator.dupe(u8, "missing 'description' metadata"));
        }
        const has_tags = (tags_val != null) or tags_list_has_items;
        if (!has_tags) {
            try errors.append(allocator, try allocator.dupe(u8, "missing 'tags' metadata"));
        }
    }

    if (errors.items.len > 0) {
        return .{
            .file = try allocator.dupe(u8, report_path),
            .errors = errors,
        };
    } else {
        errors.deinit(allocator);
        return null;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var target_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_text =
                \\🐸 mdlint - Markdown Metadata Linter CLI
                \\
                \\USAGE:
                \\  mdlint [target_file_or_folder]
                \\
                \\OPTIONS:
                \\  -h, --help            Show this help message
                \\
            ;
            try std.Io.File.stdout().writeStreamingAll(io, help_text);
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target_path == null) {
                target_path = arg;
            } else {
                std.debug.print("Error: Unknown or extra argument '{s}'\nRun 'mdlint --help' for usage.\n", .{arg});
                std.process.exit(1);
            }
        } else {
            std.debug.print("Error: Unknown option '{s}'\nRun 'mdlint --help' for usage.\n", .{arg});
            std.process.exit(1);
        }
    }

    const target = target_path orelse ".";

    var lint_errors = std.ArrayList(LintError).empty;
    defer {
        for (lint_errors.items) |*le| {
            le.deinit(allocator);
        }
        lint_errors.deinit(allocator);
    }

    // Determine if target is a file or directory
    var is_dir = false;
    var open_res = std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
    if (open_res) |*d| {
        d.close(io);
        is_dir = true;
    } else |err| {
        if (err != error.NotDir) {
            std.debug.print("Error: Failed to open path '{s}': {any}\n", .{ target, err });
            std.process.exit(1);
        }
    }

    if (is_dir) {
        // Walk directory recursively
        var dir = try std.Io.Dir.cwd().openDir(io, target, .{ .iterate = true });
        defer dir.close(io);

        var gitignore = try Gitignore.init(allocator, io, target);
        defer gitignore.deinit(allocator);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.basename, ".")) continue;
            
            const rel_dir = std.fs.path.dirname(entry.path) orelse "";
            if (try gitignore.isIgnored(allocator, target, rel_dir, entry.basename, entry.kind == .directory)) continue;

            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
                const full_path = try std.fs.path.join(allocator, &.{ target, entry.path });
                defer allocator.free(full_path);

                if (try checkMarkdownFile(allocator, io, full_path, entry.path)) |le| {
                    try lint_errors.append(allocator, le);
                }
            }
        }
    } else {
        // Single file check
        if (std.mem.endsWith(u8, target, ".md")) {
            if (try checkMarkdownFile(allocator, io, target, target)) |le| {
                try lint_errors.append(allocator, le);
            }
        } else {
            std.debug.print("Error: Target path '{s}' is not a Markdown file.\n", .{target});
            std.process.exit(1);
        }
    }

    // Output results as JSON
    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();

    var stringify: std.json.Stringify = .{
        .writer = &json_writer.writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.write(lint_errors.items);
    try json_writer.writer.writeByte('\n');

    const out = try json_writer.toOwnedSlice();
    defer allocator.free(out);

    try std.Io.File.stdout().writeStreamingAll(io, out);

    if (lint_errors.items.len > 0) {
        std.process.exit(1);
    }
}

test "checkMarkdownFile: valid metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const temp_base = "test_mdlint_temp";
    var cwd_dir = std.Io.Dir.cwd();
    cwd_dir.deleteTree(io, temp_base) catch |err| {
        std.log.debug("cleanup failed: {any}", .{err});
    };
    var temp_dir = try cwd_dir.createDirPathOpen(io, temp_base, .{});
    defer {
        temp_dir.close(io);
        cwd_dir.deleteTree(io, temp_base) catch |err| {
            std.log.debug("cleanup failed: {any}", .{err});
        };
    }

    const valid_md =
        \\---
        \\name: Test Document
        \\description: A description of the test doc
        \\tags:
        \\  - test
        \\  - documentation
        \\---
        \\Hello, world!
    ;
    try temp_dir.writeFile(io, .{ .sub_path = "valid.md", .data = valid_md });

    const full_path = try std.fs.path.join(allocator, &.{ temp_base, "valid.md" });
    defer allocator.free(full_path);

    const le = try checkMarkdownFile(allocator, io, full_path, "valid.md");
    try testing.expect(le == null);
}

test "checkMarkdownFile: missing all metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const temp_base = "test_mdlint_temp";
    var cwd_dir = std.Io.Dir.cwd();
    cwd_dir.deleteTree(io, temp_base) catch |err| {
        std.log.debug("cleanup failed: {any}", .{err});
    };
    var temp_dir = try cwd_dir.createDirPathOpen(io, temp_base, .{});
    defer {
        temp_dir.close(io);
        cwd_dir.deleteTree(io, temp_base) catch |err| {
            std.log.debug("cleanup failed: {any}", .{err});
        };
    }

    const invalid_md =
        \\Hello, world without metadata!
    ;
    try temp_dir.writeFile(io, .{ .sub_path = "invalid.md", .data = invalid_md });

    const full_path = try std.fs.path.join(allocator, &.{ temp_base, "invalid.md" });
    defer allocator.free(full_path);

    var le = try checkMarkdownFile(allocator, io, full_path, "invalid.md");
    try testing.expect(le != null);
    defer le.?.deinit(allocator);

    try testing.expectEqualStrings("invalid.md", le.?.file);
    try testing.expectEqual(@as(usize, 3), le.?.errors.items.len);
    try testing.expectEqualStrings("missing 'name' metadata", le.?.errors.items[0]);
    try testing.expectEqualStrings("missing 'description' metadata", le.?.errors.items[1]);
    try testing.expectEqualStrings("missing 'tags' metadata", le.?.errors.items[2]);
}

test "checkMarkdownFile: missing description metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const temp_base = "test_mdlint_temp";
    var cwd_dir = std.Io.Dir.cwd();
    cwd_dir.deleteTree(io, temp_base) catch |err| {
        std.log.debug("cleanup failed: {any}", .{err});
    };
    var temp_dir = try cwd_dir.createDirPathOpen(io, temp_base, .{});
    defer {
        temp_dir.close(io);
        cwd_dir.deleteTree(io, temp_base) catch |err| {
            std.log.debug("cleanup failed: {any}", .{err});
        };
    }

    const invalid_md =
        \\---
        \\name: Test Document
        \\tags: test, documentation
        \\---
        \\Hello, world!
    ;
    try temp_dir.writeFile(io, .{ .sub_path = "invalid.md", .data = invalid_md });

    const full_path = try std.fs.path.join(allocator, &.{ temp_base, "invalid.md" });
    defer allocator.free(full_path);

    var le = try checkMarkdownFile(allocator, io, full_path, "invalid.md");
    try testing.expect(le != null);
    defer le.?.deinit(allocator);

    try testing.expectEqualStrings("invalid.md", le.?.file);
    try testing.expectEqual(@as(usize, 1), le.?.errors.items.len);
    try testing.expectEqualStrings("missing 'description' metadata", le.?.errors.items[0]);
}
