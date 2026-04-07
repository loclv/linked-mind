# Build System Patterns for Zig 0.15

## Module Creation Pattern

```zig
// Correct way to create executable with modules
const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "module1", .module = module1 },
            .{ .name = "module2", .module = module2 },
        },
    }),
});
```

## Module Dependencies

- Always declare module imports explicitly
- Create modules before referencing them
- Use descriptive names for module imports

## Conditional Compilation

```zig
// Pattern for version-specific code
const enable_async = false; // Zig 0.15 compatibility

if (enable_async) {
    // Async implementation
} else {
    // Threaded implementation
}
```

## Build Steps Organization

- Group related build steps together
- Use clear naming conventions
- Document purpose of each step

## Handling Incompatible Code

```zig
// Comment out but keep for reference
// const async_exe = b.addExecutable(.{
//     .name = "async-app",
//     .root_source_file = b.path("src/async_main.zig"),
//     // ...
// });
```

## Common Build Errors Prevention

### Module Import Errors

- Ensure all imported modules are created before use
- Check module names match exactly
- Verify module paths are correct

### API Mismatch Errors

- Check Zig version compatibility
- Review standard library changelog
- Use conditional compilation for version-specific code

### Dependency Issues

- Declare all required dependencies
- Use correct dependency names
- Pass target and optimize options to dependencies

## Debug Build Tips

- Use `zig build --summary all` to see all steps
- Use `zig build -freference-trace` for better error traces
- Build incrementally to isolate issues
