//! Library root for Linked-Mind.
//!
//! Exposes the public API surface of the `linked-mind` library crate so that
//! downstream consumers can import individual modules without depending on the
//! CLI executables.  Currently re-exports `bufferedPrint`, a thin wrapper
//! around a buffered stdout writer used by CLI subcommands.
const std = @import("std");

pub const embeddings = @import("embeddings.zig");
pub const hybrid_search = @import("hybrid_search.zig");
pub const builder = @import("mindmap/builder.zig");
pub const llm = @import("mindmap/llm.zig");
pub const mindmap = @import("mindmap/mindmap.zig");
pub const query = @import("mindmap/query.zig");
pub const serialize = @import("mindmap/serialize.zig");

pub fn bufferedPrint() !void {
    var test_threaded_io = std.Io.Threaded.global_single_threaded;
    const io = test_threaded_io.io();
    try std.Io.File.stdout().writeStreamingAll(io, "Run `zig build test` to run the tests.\n");
}

test {
    std.testing.refAllDecls(@This());
}
