# Zig Reserved Keywords

## Rule: Avoid Using Reserved Keywords as Field Names

In Zig, `error` is a reserved keyword used for error handling. It cannot be used as a field name in structs.

### Problem

Using `error` as a field name causes compilation errors:

```zig
const MyStruct = struct {
    error: ?[]const u8 = null,  // ❌ Compilation error
};
```

### Solution

Use alternative field names like `err_msg` or `error_msg`:

```zig
const MyStruct = struct {
    err_msg: ?[]const u8 = null,  // ✅ Works correctly
};
```

### Real Example

When fixing the OpenRouter provider, we had to change:

```zig
// Before (causes error)
const ChatAsyncResult = struct {
    error: ?[]const u8 = null,
};

// After (works correctly)
const ChatAsyncResult = struct {
    err_msg: ?[]const u8 = null,
};
```

### Common Reserved Keywords to Avoid

- `error`
- `fn`
- `const`
- `var`
- `struct`
- `enum`
- `union`
- `pub`
- `extern`
- `export`
- `inline`
- `noinline`
- `comptime`
- `nosuspend`
- `suspend`
- `async`
- `await`
- `try`
- `catch`
- `orelse`
- `defer`
- `errdefer`
- `unreachable`
- `return`
- `break`
- `continue`
- `if`
- `else`
- `switch`
- `while`
- `for`

Always check if a word is a reserved keyword before using it as an identifier.
