# Zig 0.15.2 Compatibility Rules

## Async/Await

- **DO NOT** use `async/await` syntax - removed in Zig 0.15.2
- Use `std.Thread` for concurrent operations instead
- Use thread-safe data structures (`std.Thread.Mutex`, `std.Thread.Condition`)

## Build System API Changes

- Use `root_module` with `createModule` instead of `root_source_file` directly
- Module imports must be explicitly declared in `imports` array
- Use `append` function carefully - it doesn't exist on all types

## Standard Library Changes

### ArrayList

- `init()` --> `initCapacity(allocator, 0)` or provide initial capacity
- `deinit()` --> `deinit(allocator)` - now requires allocator parameter
- `append(item)` --> `append(allocator, item)` - now requires allocator parameter

### URI/URL Encoding

- `std.Uri.Component.escape()` --> Removed
- `std.Uri.escapeString()` --> Removed
- Use proper URL encoding libraries or encode manually if needed

### HTTP Response

- `response.status_code` --> `response.status` (enum type)
- Compare with `.ok` instead of numeric values

### Signal Handlers

- Handler signature changed: `fn(sig: i32)` --> `fn(sig: i32, info: *const std.posix.siginfo_t, ctx: ?*anyopaque)`
- Use `.sigaction` instead of `.handler` in Sigaction struct

### Type System

- `@intCast` requires explicit target type: `@as(u64, @intCast(value))`
- Enum types are not compatible even with same values - use `@enumFromInt(@intFromEnum(value))`

## Module System

- Avoid circular imports between modules
- Import modules directly instead of through umbrella modules when possible
- Each module must have its imports properly configured in build.zig

## Global Variables for Signal Handlers

- Signal handlers cannot capture local variables
- Use global variables or static data structures for shared state
- Ensure thread safety when using globals

## Error Handling

- Always check return types for `!std.json.Parsed(T)` patterns
- Remember to call `deinit()` on parsed JSON values
- Use `.value` to access the actual data

## Build Configuration

- Comment out incompatible code rather than deleting
- Use clear comments explaining Zig version compatibility
- Keep both async and threaded versions for reference during migration
