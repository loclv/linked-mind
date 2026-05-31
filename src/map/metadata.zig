const std = @import("std");
const utils = @import("utils.zig");

/// Holds the name and description extracted from a single file.
pub const Metadata = struct {
    name: []const u8,
    description: []const u8,

    pub fn deinit(self: Metadata, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
    }
};

/// Reads an entire file into an allocator-owned buffer.
pub fn readFileAlloc(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
}

/// Parses YAML frontmatter (`--- ... ---`) for `name:` and `description:`.
/// Returns null if the file has no frontmatter or the keys are missing.
pub fn extractFrontmatter(alloc: std.mem.Allocator, content: []const u8) !?Metadata {
    if (!std.mem.startsWith(u8, content, "---\n")) return null;
    const end = std.mem.indexOf(u8, content[4..], "\n---") orelse return null;
    const fm = content[4 .. 4 + end];

    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, fm, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            name = std.mem.trim(u8, trimmed[5..], " \r\t\"'");
        } else if (std.mem.startsWith(u8, trimmed, "description:")) {
            desc = std.mem.trim(u8, trimmed[12..], " \r\t\"'");
        }
    }

    if (name == null or desc == null) return null;
    return .{
        .name = try alloc.dupe(u8, name.?),
        .description = try alloc.dupe(u8, desc.?),
    };
}

/// Extracts the description from a Zig file.
///
/// Strategy (in priority order):
///   1. Collect all leading `//!` module-doc lines and return them joined by a
///      single space.  This is the idiomatic Zig module description.
///   2. Fall back to the first `//` comment line when no `//!` block exists.
pub fn extractZigDesc(content: []const u8) []const u8 {
    // Find the end of the leading //! block.
    var doc_end: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//!")) {
            doc_end = lines.index orelse content.len;
        } else {
            break;
        }
    }

    if (doc_end > 0) {
        // Return the raw slice covering the //! block so the caller can use it
        // as a single trimmed string.  We return up to the last //! line's newline
        // so the caller gets all module-doc text in one go.
        // Because we can't allocate here, return just the first //! line's text.
        const first_line = std.mem.sliceTo(content, '\n');
        const t = std.mem.trim(u8, first_line, " \r\t");
        if (std.mem.startsWith(u8, t, "//!")) {
            return std.mem.trim(u8, t[3..], " \r\t");
        }
    }

    // Fallback: first ordinary // comment (skip //! lines).
    var fb = std.mem.splitScalar(u8, content, '\n');
    while (fb.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//!")) continue;
        if (std.mem.startsWith(u8, t, "//")) {
            return std.mem.trim(u8, t[2..], " \r\t");
        }
        if (t.len > 0) break;
    }
    return "";
}

/// Extracts the description from a JS/TS file.
///
/// Strategy (in priority order):
///   1. First `/** ... */` block: returns the first non-empty, non-`*` line
///      inside the block (i.e. the summary sentence).
///   2. First `//` line comment.
pub fn extractJsTsDesc(content: []const u8) []const u8 {
    // Look for a /** block.
    if (std.mem.indexOf(u8, content, "/**")) |start| {
        const body_start = start + 3;
        const block_end = std.mem.indexOf(u8, content[body_start..], "*/") orelse content.len - body_start;
        const block = content[body_start .. body_start + block_end];
        var blines = std.mem.splitScalar(u8, block, '\n');
        while (blines.next()) |line| {
            // Strip leading whitespace and * characters used for alignment.
            const t = std.mem.trim(u8, line, " \r\t*");
            if (t.len > 0) return t;
        }
    }

    // Fallback: first // line.
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//")) {
            return std.mem.trim(u8, t[2..], " \r\t");
        }
        if (t.len > 0) break;
    }
    return "";
}

/// Extracts the description from a Rust file.
///
/// Strategy (in priority order):
///   1. First `//!` inner-doc line (crate/module level, analogous to Zig `//!`).
///   2. First `///` outer-doc line.
///   3. First `//` line comment.
pub fn extractRustDesc(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//!")) return std.mem.trim(u8, t[3..], " \r\t");
        // Stop at the first non-empty, non-attribute, non-whitespace-only line.
        if (t.len > 0 and t[0] != '#') break;
    }

    var lines2 = std.mem.splitScalar(u8, content, '\n');
    while (lines2.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "///")) return std.mem.trim(u8, t[3..], " \r\t");
        if (t.len > 0 and !std.mem.startsWith(u8, t, "//") and t[0] != '#') break;
    }

    // Last resort: first // comment.
    var lines3 = std.mem.splitScalar(u8, content, '\n');
    while (lines3.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "//")) return std.mem.trim(u8, t[2..], " \r\t");
        if (t.len > 0) break;
    }
    return "";
}

/// Extracts the description from a Go file.
///
/// Go convention: the package doc comment is the contiguous block of `//` lines
/// immediately preceding the `package` declaration with no blank line in between.
/// A blank line resets the candidate, so copyright headers are automatically
/// skipped when a separate package comment follows.
pub fn extractGoDesc(content: []const u8) []const u8 {
    // `candidate` holds the first line of the current contiguous comment block.
    var candidate: []const u8 = "";

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, t, "package ")) {
            // The comment block adjacent to `package` is the package doc.
            return candidate;
        }
        if (t.len == 0) {
            // Blank line breaks adjacency; reset so a copyright header above
            // doesn't bleed into the package description below.
            candidate = "";
        } else if (std.mem.startsWith(u8, t, "//")) {
            // Record only the first line of each new contiguous comment block.
            if (candidate.len == 0) {
                candidate = std.mem.trim(u8, t[2..], " \r\t");
            }
        } else {
            candidate = "";
        }
    }
    return "";
}

/// Extracts the description from a Python file.
///
/// Strategy (in priority order):
///   1. Module-level triple-quoted docstring (`"""` or `'''`): returns the
///      text on the opening line (after the quotes) or the first non-empty
///      line inside the block.
///   2. First `#` line comment, skipping the shebang (`#!`).
pub fn extractPyDesc(content: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0) continue;

        // Triple-quoted docstring.
        if (std.mem.startsWith(u8, t, "\"\"\"") or std.mem.startsWith(u8, t, "'''")) {
            const q = t[0..3];
            const after = std.mem.trim(u8, t[3..], " \r\t");
            // Text on the same opening line (and not immediately closed).
            if (after.len > 0 and !std.mem.startsWith(u8, after, q)) {
                // Strip trailing closing quotes if present on same line.
                const close = std.mem.indexOf(u8, after, q) orelse after.len;
                return std.mem.trim(u8, after[0..close], " \r\t.");
            }
            // Content starts on the next line.
            while (lines.next()) |next_line| {
                const nt = std.mem.trim(u8, next_line, " \r\t");
                if (nt.len == 0) continue;
                const close = std.mem.indexOf(u8, nt, q) orelse nt.len;
                return std.mem.trim(u8, nt[0..close], " \r\t.");
            }
            return "";
        }

        // Hash comment; skip shebangs.
        if (std.mem.startsWith(u8, t, "#")) {
            if (std.mem.startsWith(u8, t, "#!")) continue;
            return std.mem.trim(u8, t[1..], " \r\t");
        }

        // First non-comment, non-blank line with no docstring: stop.
        break;
    }
    return "";
}

/// For Markdown without frontmatter, extracts the first heading/paragraph text.
pub fn extractMdDesc(content: []const u8) []const u8 {
    const body_start = if (std.mem.find(u8, content, "\n---")) |i|
        if (std.mem.find(u8, content[i + 4 ..], "\n")) |j| i + 4 + j + 1 else content.len
    else
        0;
    const body = content[body_start..];
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t#");
        if (t.len > 0) return t;
    }
    return "";
}

pub fn extractOrgMetadata(alloc: std.mem.Allocator, content: []const u8, basename: []const u8) !Metadata {
    var name: ?[]const u8 = null;
    var desc: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "#+")) {
            if (std.mem.findScalar(u8, trimmed, ':')) |colon_idx| {
                const key = std.mem.trim(u8, trimmed[2..colon_idx], " ");
                const val = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ");
                if (std.ascii.eqlIgnoreCase(key, "title")) {
                    name = val;
                } else if (std.ascii.eqlIgnoreCase(key, "description")) {
                    desc = val;
                }
            }
        }
    }

    const final_name = if (name) |n| try alloc.dupe(u8, n) else try utils.kebabFromFilename(alloc, basename);
    errdefer alloc.free(final_name);

    const final_desc = if (desc) |d| try alloc.dupe(u8, d) else blk: {
        var lines_desc = std.mem.splitScalar(u8, content, '\n');
        while (lines_desc.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#+")) {
                const clean_line = std.mem.trim(u8, trimmed, "* \t");
                break :blk try alloc.dupe(u8, clean_line);
            }
        }
        break :blk try alloc.dupe(u8, "");
    };

    return .{ .name = final_name, .description = final_desc };
}

pub fn extractTxtMetadata(alloc: std.mem.Allocator, content: []const u8, basename: []const u8) !Metadata {
    const name = try utils.kebabFromFilename(alloc, basename);
    errdefer alloc.free(name);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0) {
            return .{ .name = name, .description = try alloc.dupe(u8, trimmed) };
        }
    }
    return .{ .name = name, .description = try alloc.dupe(u8, "") };
}

/// Reads a file and builds Metadata based on its extension and contents.
pub fn fileMetadata(alloc: std.mem.Allocator, io: std.Io, full_path: []const u8, basename: []const u8) !Metadata {
    const content = try readFileAlloc(alloc, io, full_path);
    defer alloc.free(content);

    if (std.mem.endsWith(u8, basename, ".md")) {
        if (try extractFrontmatter(alloc, content)) |fm| return fm;
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc = try alloc.dupe(u8, extractMdDesc(content));
        return .{ .name = name, .description = desc };
    }

    if (std.mem.endsWith(u8, basename, ".org")) {
        return extractOrgMetadata(alloc, content, basename);
    }

    if (std.mem.endsWith(u8, basename, ".txt")) {
        return extractTxtMetadata(alloc, content, basename);
    }

    if (std.mem.endsWith(u8, basename, ".pdf")) {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc = try std.fmt.allocPrint(alloc, "PDF document: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    if (std.mem.endsWith(u8, basename, ".zig")) {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractZigDesc(content);
        if (desc_raw.len > 0) {
            const desc = try alloc.dupe(u8, desc_raw);
            return .{ .name = name, .description = desc };
        }
        const desc = try std.fmt.allocPrint(alloc, "Zig source: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    // JS/TS family: extract from /** block or first // comment.
    if (std.mem.endsWith(u8, basename, ".js") or
        std.mem.endsWith(u8, basename, ".ts") or
        std.mem.endsWith(u8, basename, ".jsx") or
        std.mem.endsWith(u8, basename, ".tsx"))
    {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractJsTsDesc(content);
        if (desc_raw.len > 0) {
            const desc = try alloc.dupe(u8, desc_raw);
            return .{ .name = name, .description = desc };
        }
        const desc = try std.fmt.allocPrint(alloc, "JavaScript/TypeScript module: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    // Rust: //! inner-doc > /// outer-doc > // comment.
    if (std.mem.endsWith(u8, basename, ".rs")) {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractRustDesc(content);
        const desc = if (desc_raw.len > 0)
            try alloc.dupe(u8, desc_raw)
        else
            try std.fmt.allocPrint(alloc, "Rust module: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    // Go: package doc comment (block immediately before `package` declaration).
    if (std.mem.endsWith(u8, basename, ".go")) {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractGoDesc(content);
        const desc = if (desc_raw.len > 0)
            try alloc.dupe(u8, desc_raw)
        else
            try std.fmt.allocPrint(alloc, "Go source: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    // C/C++: same /** */ and // style as JS/TS.
    if (std.mem.endsWith(u8, basename, ".c") or
        std.mem.endsWith(u8, basename, ".h") or
        std.mem.endsWith(u8, basename, ".cpp") or
        std.mem.endsWith(u8, basename, ".cc") or
        std.mem.endsWith(u8, basename, ".cxx") or
        std.mem.endsWith(u8, basename, ".hpp") or
        std.mem.endsWith(u8, basename, ".hxx"))
    {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractJsTsDesc(content);
        const desc = if (desc_raw.len > 0)
            try alloc.dupe(u8, desc_raw)
        else
            try std.fmt.allocPrint(alloc, "C/C++ source: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    // Python: module docstring or # comment.
    if (std.mem.endsWith(u8, basename, ".py")) {
        const name = try utils.kebabFromFilename(alloc, basename);
        errdefer alloc.free(name);
        const desc_raw = extractPyDesc(content);
        const desc = if (desc_raw.len > 0)
            try alloc.dupe(u8, desc_raw)
        else
            try std.fmt.allocPrint(alloc, "Python module: {s}.", .{name});
        return .{ .name = name, .description = desc };
    }

    const name = try utils.kebabFromFilename(alloc, basename);
    errdefer alloc.free(name);
    return .{ .name = name, .description = "" };
}

test "extractFrontmatter: valid frontmatter" {
    const alloc = std.testing.allocator;
    const content =
        \\---
        \\name: "My custom name"
        \\description: "This is a great description"
        \\---
        \\Some other body text here.
    ;

    const meta = try extractFrontmatter(alloc, content);
    try std.testing.expect(meta != null);
    defer meta.?.deinit(alloc);

    try std.testing.expectEqualStrings("My custom name", meta.?.name);
    try std.testing.expectEqualStrings("This is a great description", meta.?.description);
}

test "extractFrontmatter: missing keys" {
    const alloc = std.testing.allocator;
    const content =
        \\---
        \\name: "Only Name"
        \\---
    ;

    const meta = try extractFrontmatter(alloc, content);
    try std.testing.expect(meta == null);
}

test "extractZigDesc: prefers //! module-doc over // comment" {
    const content =
        \\//! Module-level doc comment.
        \\//! Second doc line.
        \\// ordinary comment
        \\const std = @import("std");
    ;
    const desc = extractZigDesc(content);
    try std.testing.expectEqualStrings("Module-level doc comment.", desc);
}

test "extractZigDesc: falls back to // when no //! present" {
    const content =
        \\// This is the description comment
        \\const std = @import("std");
    ;
    const desc = extractZigDesc(content);
    try std.testing.expectEqualStrings("This is the description comment", desc);
}

test "extractJsTsDesc: extracts from /** block" {
    const content =
        \\/**
        \\ * Summary of the module.
        \\ * @param x - the value
        \\ */
        \\export function foo() {}
    ;
    const desc = extractJsTsDesc(content);
    try std.testing.expectEqualStrings("Summary of the module.", desc);
}

test "extractJsTsDesc: falls back to // line" {
    const content =
        \\// Simple helper utilities.
        \\export const PI = 3.14;
    ;
    const desc = extractJsTsDesc(content);
    try std.testing.expectEqualStrings("Simple helper utilities.", desc);
}

test "extractRustDesc: prefers //! inner-doc" {
    const content =
        \\//! Crate-level description.
        \\//! Second inner-doc line.
        \\/// outer doc
        \\pub fn foo() {}
    ;
    const desc = extractRustDesc(content);
    try std.testing.expectEqualStrings("Crate-level description.", desc);
}

test "extractRustDesc: falls back to ///" {
    const content =
        \\/// Item-level doc comment.
        \\pub fn bar() {}
    ;
    const desc = extractRustDesc(content);
    try std.testing.expectEqualStrings("Item-level doc comment.", desc);
}

test "extractGoDesc: returns package doc comment" {
    const content =
        \\// Copyright 2024 Acme Corp.
        \\// SPDX-License-Identifier: MIT
        \\
        \\// Package foo provides utilities for working with things.
        \\package foo
    ;
    const desc = extractGoDesc(content);
    try std.testing.expectEqualStrings("Package foo provides utilities for working with things.", desc);
}

test "extractGoDesc: no blank between copyright and package uses copyright" {
    const content =
        \\// A simple Go file.
        \\package main
    ;
    const desc = extractGoDesc(content);
    try std.testing.expectEqualStrings("A simple Go file.", desc);
}

test "extractPyDesc: triple-quoted docstring on same line" {
    const content =
        \\"""Module that does useful things."""
        \\import os
    ;
    const desc = extractPyDesc(content);
    try std.testing.expectEqualStrings("Module that does useful things", desc);
}

test "extractPyDesc: triple-quoted docstring on next line" {
    const content =
        \\"""
        \\Handles configuration loading.
        \\"""
        \\import sys
    ;
    const desc = extractPyDesc(content);
    try std.testing.expectEqualStrings("Handles configuration loading", desc);
}

test "extractPyDesc: hash comment, skips shebang" {
    const content =
        \\#!/usr/bin/env python3
        \\# CLI entry point for the tool.
        \\import argparse
    ;
    const desc = extractPyDesc(content);
    try std.testing.expectEqualStrings("CLI entry point for the tool.", desc);
}

test "extractMdDesc: extracts first text paragraph" {
    const content =
        \\# My Title
        \\
        \\This is the first paragraph.
        \\And another one.
    ;
    const desc = extractMdDesc(content);
    try std.testing.expectEqualStrings("My Title", desc);
}

test "extractOrgMetadata: valid org titles and tags" {
    const alloc = std.testing.allocator;
    const content =
        \\#+TITLE: My Org Note Title
        \\#+DESCRIPTION: A wonderful org-mode description
        \\#+FILETAGS: :work:project:
        \\
        \\* Introduction
        \\Body text.
    ;
    const meta = try extractOrgMetadata(alloc, content, "MyFile.org");
    defer meta.deinit(alloc);

    try std.testing.expectEqualStrings("My Org Note Title", meta.name);
    try std.testing.expectEqualStrings("A wonderful org-mode description", meta.description);
}

test "extractTxtMetadata: extracts first non-empty line" {
    const alloc = std.testing.allocator;
    const content =
        \\
        \\First actual line of plain text.
        \\Second line.
    ;
    const meta = try extractTxtMetadata(alloc, content, "simple.txt");
    defer meta.deinit(alloc);

    try std.testing.expectEqualStrings("simple", meta.name);
    try std.testing.expectEqualStrings("First actual line of plain text.", meta.description);
}
