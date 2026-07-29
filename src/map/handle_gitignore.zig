//! .gitignore rule loader and matcher for the directory scanner.
//!
//! Reads the `.gitignore` file at `base/` (if present) and compiles each
//! non-comment, non-empty line into a `GitignorePattern`.  The `Gitignore`
//! struct is passed through the recursive scan so that every entry is tested
//! against the rules before being included in the map index.
//!
//! Matching rules supported:
//!   - Literal file / directory names
//!   - Glob wildcards `*` and `**`
//!   - Directory-only patterns ending in `/`
//!   - Anchored patterns starting with `/`
//!   - Negation patterns starting with `!` (planned; currently skipped)
const std = @import("std");
const log = std.log.scoped(.gitignore);

pub const GitignorePattern = struct {
    pattern: []const u8,
    is_dir_only: bool,
    is_anchored: bool,
};

pub const Gitignore = struct {
    patterns: std.ArrayList(GitignorePattern),
    is_base: bool,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, base: []const u8) !Gitignore {
        var patterns = std.ArrayList(GitignorePattern).empty;
        errdefer {
            for (patterns.items) |p| alloc.free(p.pattern);
            patterns.deinit(alloc);
        }

        var is_base = true;
        var file_content: ?[]const u8 = null;
        defer if (file_content) |c| alloc.free(c);

        const gitignore_path = try std.fs.path.join(alloc, &.{ base, ".gitignore" });
        defer alloc.free(gitignore_path);

        if (std.Io.Dir.cwd().readFileAlloc(io, gitignore_path, alloc, .unlimited)) |data| {
            file_content = data;
            is_base = true;
        } else |err| {
            log.debug("failed to read gitignore from base path {s}: {any}, trying cwd", .{ gitignore_path, err });
            if (std.Io.Dir.cwd().readFileAlloc(io, ".gitignore", alloc, .unlimited)) |data| {
                file_content = data;
                is_base = false;
            } else |cwd_err| {
                log.debug("failed to read gitignore from cwd: {any}", .{cwd_err});
            }
        }

        if (file_content) |content| {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                var trimmed = std.mem.trim(u8, line, " \r\t");
                if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

                var is_dir_only = false;
                var is_anchored = false;

                if (std.mem.endsWith(u8, trimmed, "/")) {
                    is_dir_only = true;
                    trimmed = trimmed[0 .. trimmed.len - 1];
                }

                if (std.mem.startsWith(u8, trimmed, "/")) {
                    is_anchored = true;
                    trimmed = trimmed[1..];
                }

                if (trimmed.len == 0) continue;

                try patterns.append(alloc, .{
                    .pattern = try alloc.dupe(u8, trimmed),
                    .is_dir_only = is_dir_only,
                    .is_anchored = is_anchored,
                });
            }
        }

        return .{
            .patterns = patterns,
            .is_base = is_base,
        };
    }

    pub fn deinit(self: *Gitignore, alloc: std.mem.Allocator) void {
        for (self.patterns.items) |p| {
            alloc.free(p.pattern);
        }
        self.patterns.deinit(alloc);
        self.* = undefined;
    }

    pub fn isIgnored(self: Gitignore, alloc: std.mem.Allocator, base: []const u8, rel: []const u8, name: []const u8, is_dir: bool) !bool {
        // Auto ignore .git/ path
        if (std.mem.eql(u8, name, ".git")) return true;

        const rel_path = if (self.is_base)
            (if (rel.len == 0) try alloc.dupe(u8, name) else try std.fs.path.join(alloc, &.{ rel, name }))
        else
            (if (rel.len == 0) try std.fs.path.join(alloc, &.{ base, name }) else try std.fs.path.join(alloc, &.{ base, rel, name }));
        defer alloc.free(rel_path);

        // Standardize path separator to '/' for gitignore matching
        var i: usize = 0;
        while (i < rel_path.len) : (i += 1) {
            if (rel_path[i] == '\\') {
                rel_path[i] = '/';
            }
        }

        for (self.patterns.items) |p| {
            if (p.is_dir_only and !is_dir) continue;

            if (p.is_anchored) {
                if (globMatch(p.pattern, rel_path)) return true;
                if (std.mem.startsWith(u8, rel_path, p.pattern)) {
                    if (rel_path.len > p.pattern.len and rel_path[p.pattern.len] == '/') {
                        return true;
                    }
                }
            } else {
                if (globMatch(p.pattern, rel_path)) return true;
                var segments = std.mem.splitScalar(u8, rel_path, '/');
                while (segments.next()) |seg| {
                    if (globMatch(p.pattern, seg)) return true;
                }
            }
        }

        return false;
    }
};

fn globMatch(pattern: []const u8, input: []const u8) bool {
    if (pattern.len == 0) return input.len == 0;
    if (pattern[0] == '*') {
        if (pattern.len == 1) return true;
        var i: usize = 0;
        while (i <= input.len) : (i += 1) {
            if (globMatch(pattern[1..], input[i..])) return true;
        }
        return false;
    }
    if (input.len == 0) return false;
    if (pattern[0] == input[0]) {
        return globMatch(pattern[1..], input[1..]);
    }
    return false;
}

test "globMatch tests" {
    try std.testing.expect(globMatch("*.tmp", "foo.tmp"));
    try std.testing.expect(!globMatch("*.tmp", "foo.log"));
    try std.testing.expect(globMatch("zig-cache", "zig-cache"));
    try std.testing.expect(globMatch("zig-*", "zig-cache"));
    try std.testing.expect(globMatch("*cache", "zig-cache"));
    try std.testing.expect(globMatch("a*b*c", "abbbc"));
    try std.testing.expect(!globMatch("a*b*c", "abbbd"));
}

test "Gitignore load and match tests" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();

    const temp_base = "test_gitignore_temp";
    var cwd_dir = std.Io.Dir.cwd();
    
    cwd_dir.deleteTree(io, temp_base) catch |err| {
        std.log.debug("cleanup temp base failed: {any}", .{err});
    };

    var temp_dir = try cwd_dir.createDirPathOpen(io, temp_base, .{});
    defer {
        temp_dir.close(io);
        cwd_dir.deleteTree(io, temp_base) catch {};
    }

    try temp_dir.writeFile(io, .{ 
        .sub_path = ".gitignore", 
        .data = 
            \\# comments
            \\zig-cache/
            \\*.tmp
            \\*.log
            \\/anchored
            \\
    });

    var gitignore = try Gitignore.init(allocator, io, temp_base);
    defer gitignore.deinit(allocator);

    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "", ".git", true));
    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "", "zig-cache", true));
    try testing.expect(!try gitignore.isIgnored(allocator, temp_base, "", "zig-cache", false));
    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "sub", "test.tmp", false));
    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "", "tech.md.log", false));
    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "sub", "tech.md.log", false));
    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "", "anchored", false));
    try testing.expect(try gitignore.isIgnored(allocator, temp_base, "", "anchored", true));
    try testing.expect(!try gitignore.isIgnored(allocator, temp_base, "sub", "anchored", false));
}
