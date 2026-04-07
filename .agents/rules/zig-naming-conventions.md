# Zig Naming Conventions

## Rule: Avoid Reserved Keywords as Identifiers

When writing Zig code, never use reserved keywords as identifiers (variable names, function names, struct field names, etc.).

### Why This Matters

Zig reserves certain words for its grammar and special features. Using these as identifiers causes compilation errors and confusion.

### Common Mistakes

#### 1. Using `error` as a field name

```zig
// ❌ This will not compile
const Result = struct {
    success: bool,
    error: ?[]const u8,  // 'error' is a reserved keyword
};

// ✅ Use alternative names
const Result = struct {
    success: bool,
    err_msg: ?[]const u8,  // or error_msg, error_str, etc.
};
```

#### 2. Using other reserved keywords

```zig
// ❌ These will all fail
const Struct = struct {
    fn: i32,        // 'fn' is reserved
    const: bool,    // 'const' is reserved
    var: u64,       // 'var' is reserved
    return: void,   // 'return' is reserved
};

// ✅ Use descriptive alternatives
const Struct = struct {
    function_id: i32,
    is_constant: bool,
    variable_value: u64,
    return_value: void,
};
```

### Complete List of Zig Reserved Keywords

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
- `usingnamespace`

### Best Practices

1. **Use descriptive names**: Instead of single words, use phrases that describe the purpose

   ```zig
   // Good
   error_message: []const u8,
   function_name: []const u8,
   is_constant: bool,
   
   // Bad (if they weren't keywords)
   error: []const u8,
   fn: []const u8,
   const: bool,
   ```

2. **Add suffixes or prefixes**: When a reserved word is the most natural choice, modify it

   ```zig
   // Good alternatives for 'error'
   error_msg
   error_str
   error_code
   last_error
   has_error
   
   // Good alternatives for 'type'
   type_id
   type_name
   data_type
   value_type
   ```

3. **Use snake_case for fields and variables**: This is Zig's convention

   ```zig
   const MyStruct = struct {
     field_name: Type,
     another_field: Type,
   };
   ```

4. **Use PascalCase for type names**: This is Zig's convention

   ```zig
   const MyStruct = struct { ... };
   const MyEnum = enum { ... };
   const MyUnion = union { ... };
   ```

### Real-World Example from SatiBot

When fixing the OpenRouter provider, we encountered this issue:

```zig
// Original code (compilation error)
const ChatAsyncResult = struct {
    request_id: []const u8,
    success: bool,
    response: ?base.LLMResponse = null,
    error: ?[]const u8 = null,  // ❌ 'error' is reserved
};

// Fixed code (compiles successfully)
const ChatAsyncResult = struct {
    request_id: []const u8,
    success: bool,
    response: ?base.LLMResponse = null,
    err_msg: ?[]const u8 = null,  // ✅ Uses alternative name
};
```

### Quick Check Before Naming

Before using a name, ask yourself:

1. Is this word a Zig keyword? (Check the list above)
2. Is there a more descriptive alternative?
3. Can I add a suffix/prefix to make it unique?

### Tools to Help

- Your IDE will highlight reserved keywords
- The compiler will give clear error messages
- Keep this list handy when naming new identifiers

Remember: It's better to be slightly more verbose than to hit a compilation error!
