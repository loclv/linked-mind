const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const NodeObj = struct {
        id: []const u8,
        title: []const u8,
        group: usize,
    };

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var jw: std.json.Stringify = .{
        .writer = &writer.writer,
    };

    const obj = NodeObj{ .id = "1", .title = "Test", .group = 1 };
    try jw.write(obj);
    
    const out = try writer.toOwnedSlice();
    defer allocator.free(out);
    
    std.debug.print("JSON: {s}\n", .{out});
}
