# AGENTS.md

## Task Workflow

### Validate After Every Code Change

After each code change, always run these commands to confirm the project still passes build and lint checks:

If a Makefile exists:

```bash
rtk zig build test
rtk make lint
```

Otherwise, run build and lint checks directly:

```bash
rtk zig build
rtk ziglint
```

Do not skip these checks.

### Log Your Work

Whenever you finish a task or change codes, always log your work using the l-log bash command:

```bash
l-log add ./logs/chat.csv "<Task Name>" --tags="<tags>" --problem="<problem>" --solution="<solution>" --action="<action>" --files="<files>" --tech-stack="<tech>" --created-by-agent="<agent-name>"
```

Note: --last-commit-short-sha is optional and will be auto-populated by the CLI if not provided.
Before run:

- Install the l-log CLI if not already installed: `bun add -g llm-lean-log-cli`
- If need, run CLI help command: `l-log -h` for more information
- Log path: `./logs/chat.csv`

### Write Comments

Write comments explaining why the code exists, not just what it does. Document non-obvious thresholds, timing values, and protocol details.

### Update Documentation and Changelog

After completing a task, always make sure to add necessary comments to the code and update the following project documents and folders to reflect the changes:

- Run `rtk ziglint` to check for any lint errors.
- Run `rtk zig build test` to check for any build errors.
- `./CHANGELOG.md`: Record all changes, fixes, and new features introduced.
- `./README.md`: Update usage information, features, or architectural details if they have changed.
- `./docs/` folder: Add, update, or revise the documentation files in the `docs` directory to match the latest implementation.
- `./TASK.md`: Update task list if they have changed.

## Build Commands

```bash
rtk zig build
rtk zig build -Doptimize=ReleaseFast
rtk zig build test
```

## Token Optimized CLI Proxy (rtk Rules)

Always prefix shell commands with `rtk` to minimize token consumption except `rtk npx gitnexus <option>`.

Examples:

- rtk read file.ts (signatures only, strips bodies)
- rtk smart file.ts (two-line heuristic code summary)
- rtk find "*.rs" .
- rtk grep "pattern" .
- rtk git status
- rtk git log -n 10
- rtk git diff
- rtk git add
- rtk git commit -m "msg"
- rtk git push
- rtk git pull
- rtk lint
- rtk lint biome
- rtk tsc
- rtk ls src/
- rtk curl <url>

## Zig Development

### Zigdoc

Use `zigdoc` to discover APIs for the Zig standard library and any third-party dependencies:

```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

### std.debug.print Rules

Always require two arguments - format string + empty tuple:

```zig
std.debug.print("Message\n", .{});
std.debug.print("Value: {d}\n", .{count});
```

For literal braces in text (JSON examples), escape them:

```zig
std.debug.print("JSON: {{ \"key\": \"value\" }}\n", .{});
```

Reduce the number of std.debug.print calls by combining them into single multiline strings. For multi-line output, use a single string literal with backslash escape sequences and one std.debug.print call.

### Reserved Keywords

Never use Zig keywords as field/variable names. Use alternatives:

```zig
err_msg: ?[]const u8,
```

## Zig 0.16.0 API Guidance

Linked-Mind is pinned to Zig 0.16.0 (stable).

### Juicy Main Execution Model

Zig 0.16.0 introduces std.process.Init as the preferred main parameter:

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try std.Io.File.stdout().writeStreamingAll(io, "Hello, world!\n");

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args, 0..) |arg, i| {
        std.log.info("arg[{d}] = {s}", .{ i, arg });
    }
}
```

Environment variables and process arguments are non-global and must be accessed via this init structure.

### Thread.Pool Removed

Use std.Io.Group, std.Io.async, or std.Io.concurrent instead. Convert Thread.Mutex, Thread.Condition, Thread.ResetEvent to Io.Mutex, Io.Condition, Io.Event.

### Common Patterns in Zig 0.16.0

ArrayList (allocator passed explicitly, initCapacity preferred):

```zig
var list = try std.ArrayList(u8).initCapacity(gpa, 16);
defer list.deinit(gpa);
try list.append(gpa, 'a');
const owned = try list.toOwnedSlice(gpa);
defer gpa.free(owned);
```

HashMap (unmanaged style):

```zig
var map = std.StringHashMap(u32).empty;
defer map.deinit(gpa);
try map.put(gpa, "key", 42);
```

Fixed-Buffer Reader/Writer:

```zig
var reader: std.Io.Reader = .fixed(data);

var buf: [256]u8 = undefined;
var writer: std.Io.Writer = .fixed(&buf);
try writer.interface.print("count: {d}", .{7});
```

File I/O:

```zig
const contents = try std.Io.Dir.cwd().readFileAlloc(io, "input.txt", gpa, .limited(1048576));
defer gpa.free(contents);

var atomic = try std.Io.File.Atomic.init(io, gpa, "output.txt");
try atomic.file_writer.interface.print("data: {s}\n", .{"hello"});
try atomic.commit(io);
```

Custom JSON Serialization:

Implement jsonStringify(self: Self, jws: anytype) !void method on custom structs instead of creating intermediate std.json.Value trees. This ensures highly performant, leak-free execution.

```zig
const MyStruct = struct {
    name: []const u8,
    value: u32,

    pub fn jsonStringify(self: MyStruct, jws: anytype) !void {
        try jw.write(self.value);
    }
};
```

## Memory Management

### Free Owned Fields Before Deiniting Containers

When a struct has a deinit method that destroys a container (ArrayList, HashMap, etc.), always iterate over remaining items and free any heap-allocated fields before calling container.deinit().

```zig
for (self.message_queue.items) |msg| {
    self.allocator.free(msg.text);
    self.allocator.free(msg.session_id);
}
self.message_queue.deinit(self.allocator);
```

### Pre-Calculated Constants

Replace arithmetic expressions with pre-calculated constants in memory allocations. For example, instead of 1024 * 1024, use the result value 1048576 and add a comment to explain the calculation:

```zig
// 1024 * 1024
const buffer_size = 1048576;
```

### Pointer Lifetimes

Never store pointers to stack-local variables in structs that outlive the function. Ensure handler contexts have valid pointer references for async operations. Always verify pointer lifetime when passing to threads or callbacks.

## Error Handling

### Explicit Error Sets

Define specific error sets for functions; avoid anyerror when possible. Specific errors document failure modes.

### Log on Error Catch

When catch error, always log the error message. Never use catch unreachable for operations that can fail.

```zig
const value = operation() catch |err| {
    std.log.err("operation failed: {}", .{err});
    return error.OperationFailed;
};
```

### Cleanup on Error Paths

Use errdefer for cleanup on error paths, and defer for unconditional cleanup. This prevents resource leaks without verbose try-finally boilerplate.

## Functional Programming

Avoid Object-Oriented Programming (OOP) patterns where state is hidden within objects (structs with many methods that mutate self). Instead:

- Favor Pure Functions: Input to Output, no side effects.
- Avoid Instances: Minimize the use of long-lived stateful objects. Only use init patterns for resource management (allocators, connections).
- Separate Data and Logic: Keep data structures simple and process them with external, stateless functions.
- Separate IO from Logic: Isolate Input/Output operations from core logic. Core logic should be pure and testable without mocks.
- Stateless Handlers: Design event handlers as stateless transformations of input data.

## Safety

- Add assertions at API boundaries and state transitions. Focus on bounds checks, null checks before dereferences, and state machine transitions.
- Avoid asserting values immediately after setting them or checking internal function arguments.
- Never use catch unreachable for operations that can fail.

## LLM API Integration Best Practices

### Error Handling & Recovery

Always log error messages when catching LLM API errors. Implement proper retry and fallback logic:

```zig
const llm_response = makeLLMRequest(prompt) catch |err| {
    log.err("LLM request failed: {any}", .{err});
    if (shouldRetry(err)) {
        return retryLLMRequest(prompt, retry_count + 1);
    }
    return handleLLMFailure(err);
};
```

### Memory & Performance

- Free allocated response data and clean up temporary buffers after API calls.
- Batch multiple requests when possible and implement request caching for repeated queries.

### Request & Configuration

- Use structured JSON parsing for API responses and validate required fields before use.
- Use configurable model names from config files, support model fallbacks, and validate model availability.
