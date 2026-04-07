# Zig 0.15.2 Quick Reference - Breaking Changes

## ArrayList API Changes

```zig
// Before (Zig < 0.15)
var list = std.ArrayList(T).init(allocator);
list.append(item);
list.deinit();

// After (Zig 0.15+)
var list = std.ArrayList(T).initCapacity(allocator, 0);
try list.append(allocator, item);
list.deinit(allocator);
```

## Signal Handler Signature

```zig
// Before
fn handler(sig: i32) callconv(.c) void { ... }

// After
fn handler(sig: i32, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void { ... }
```

## Sigaction Setup

```zig
// Before
.handler = .{ .handler = handler_fn }

// After
.handler = .{ .sigaction = handler_fn }
```

## Type Casting

```zig
// Before
const value = @intCast(optional_int);

// After
const value = @as(u64, @intCast(optional_int));
```

## Enum Type Conversion

```zig
// Before - This fails even with same values
schedule.kind = other_enum.kind;

// After
schedule.kind = @enumFromInt(@intFromEnum(other_enum.kind));
```

## HTTP Response Status

```zig
// Before
if (response.status_code == 200) { ... }

// After
if (response.status == .ok) { ... }
```

## Build System Module Creation

```zig
// Before
const exe = b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    ...
});

// After
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{.{ .name = "dep", .module = dep_module }},
    }),
});
```

## Async/Await - REMOVED

```zig
// Before (Zig < 0.15)
const frame = async myFunction();
const result = await frame;

// After - Use threads instead
const thread = try std.Thread.spawn(.{}, myFunction, .{});
thread.join();
```

## Most Common Error Messages

- "expected ',' after initializer" --> Check struct initialization syntax
- "member function expected N argument(s)" --> ArrayList needs allocator
- "has no member named 'handler'" --> Use .sigaction instead
- "expected type 'u64', found 'i64'" --> Use @as wrapper for @intCast
