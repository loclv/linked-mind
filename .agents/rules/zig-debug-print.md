# Zig Debug Print Usage

## Rule: Always Provide Arguments to std.debug.print

In Zig, `std.debug.print` always requires two arguments: a format string and an arguments tuple.

### Problem

Calling `std.debug.print` with only a format string causes compilation errors:

```zig
// ❌ This will not compile
std.debug.print("Hello, world!");
```

Error:

```text
error: expected 2 argument(s), found 1
```

### Solution

Always provide the arguments tuple, even if empty:

```zig
// ✅ Correct usage
std.debug.print("Hello, world!\n", .{});
```

### Format String and Arguments

The format string uses `{}` as placeholders for arguments:

```zig
// ✅ With arguments
const name = "Alice";
const age = 25;
std.debug.print("Name: {s}, Age: {d}\n", .{ name, age });

// ✅ Without arguments (empty tuple)
std.debug.print("Process completed successfully\n", .{});
```

### Common Format Specifiers

- `{s}` - String (null-terminated or slice)
- `{d}` - Decimal integer
- `{x}` - Hexadecimal integer
- `{b}` - Binary integer
- `{any}` - Any type (uses default formatting)
- `{}` - Same as `{any}`

### Examples

#### Basic Usage

```zig
// Print a simple message
std.debug.print("Starting application...\n", .{});

// Print with variables
const count = 42;
std.debug.print("Count: {d}\n", .{count});

// Print multiple variables
const user = "bob";
const score = 98.5;
std.debug.print("User: {s}, Score: {d}\n", .{ user, score });
```

#### Error Messages

```zig
// Print error messages
std.debug.print("Error: File not found: {s}\n", .{filename});

// Print debug information
std.debug.print("Debug: value={any}, type={}\n", .{ value, @TypeOf(value) });
```

#### Special Characters

Remember to include `\n` for newlines:

```zig
// ✅ With newline
std.debug.print("Process complete\n", .{});

// ❌ Without newline (prints on same line)
std.debug.print("Process complete", .{});
```

### Common Mistakes to Avoid

1. **Forgetting the arguments tuple**

```zig
// ❌ Wrong
std.debug.print("Hello");

// ✅ Correct
std.debug.print("Hello\n", .{});
```

1. **Mismatched format specifiers and arguments**

```zig
// ❌ Wrong (using {s} for integer)
const num = 42;
std.debug.print("Number: {s}\n", .{num});

// ✅ Correct
std.debug.print("Number: {d}\n", .{num});
```

1. **Wrong number of arguments**

```zig
// ❌ Wrong (too few arguments)
std.debug.print("{s} {d}\n", .{"Hello"});

// ✅ Correct
std.debug.print("{s} {d}\n", .{"Hello", 42});
```

Unescaped braces in format strings:

When printing text that contains literal `{` or `}` characters (like JSON), you must escape them by doubling: `{{` and `}}`.

```zig
// ❌ Wrong (unescaped braces cause compile error)
const help_text =
    \\\\Error: Configuration not found
    \\\\Please add: "tools": { "token": "abc" }
;
std.debug.print(help_text, .{});
// Compile error: expected . or }, found ' '

// ✅ Correct (escaped braces)
const help_text =
    \\\\Error: Configuration not found
    \\\\Please add: "tools": {{ "token": "abc" }}
;
std.debug.print(help_text, .{});
// Output: Error: Configuration not found
//         Please add: "tools": { "token": "abc" }
```

Common scenarios requiring escaped braces:

- JSON examples in error messages
- Code snippets in help text
- Regular expressions or templates
- Any documentation containing `{` or `}` literals

**Rule:** In Zig format strings, always double braces for literal characters: `{{` = `{`, `}}` = `}`

### Best Practices

1. **Always include `\n`** at the end of debug messages for proper formatting
2. **Use descriptive messages** that help with debugging
3. **Include relevant data** in the message (IDs, values, states)
4. **Be consistent** with formatting across the codebase

### Alternative: std.log

For production code, consider using `std.log` instead:

```zig
const std = @import("std");

const log = std.log.scoped(.my_module);

pub fn myFunction() void {
    log.info("Processing item {d}", .{item_id});
    log.err("Failed to process: {s}", .{error_message});
}
```

`std.log` provides:

- Log levels (debug, info, warn, err)
- Scoped logging
- Configurable output
- Better performance in release builds

### Quick Reference

| Pattern        | Usage                                              |
| -------------- | ------------------------------------------------- |
| No arguments   | `std.debug.print("Message\n", .{});`              |
| One argument   | `std.debug.print("Value: {d}\n", .{value});`      |
| Multiple args  | `std.debug.print("{s}: {d}\n", .{name, count});`  |
| Any type       | `std.debug.print("Data: {any}\n", .{complex_data});` |

Remember: `std.debug.print` always needs two arguments - never forget the `.{}`!
