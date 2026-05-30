# AGENTS.md
## Task Workflow
### Validate After Every Code Change
After each code change, always run these commands:
```bash
zig build test
make lint
```
### Log Your Work
Whenever you finish a task or change codes, always log your work using the l-log bash command:
```bash
l-log add ./logs/chat.csv "<Task Name>" --tags="<tags>" --problem="<problem>" --solution="<solution>" --action="<action>" --files="<files>" --tech-stack="<tech>" --created-by-agent="<agent-name>"
```

Note: `--last-commit-short-sha` is optional and will be auto-populated by the CLI if not provided.
Before run:

- Install the l-log CLI if not already installed: `bun add -g llm-lean-log-cli`
- If need, run CLI help command: `l-log -h` for more information
- Log path: `./logs/chat.csv`
### Write Comments
Write comments explaining why the code exists, not just what it does. Document non-obvious thresholds, timing values, and protocol details.
## Build Commands
```bash
zig build # Build all targets (debug)
zig build -Doptimize=ReleaseFast # Release build
zig build test # Run all tests
```
## Zig Development
### Zigdoc
Use `zigdoc` - <https://github.com/rockorager/zigdoc> to discover APIs:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
```
### Common Patterns
ArrayList (Zig 0.15+):
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

HashMap (unmanaged):
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

Writer:
```zig
var buf: [4096]u8 = undefined;
const writer = std.fs.File.stdout().writer(&buf);
defer writer.flush() catch {};
try writer.print("hello {s}\n", .{"world"});
```
### std.debug.print Rules
Always require two arguments - format string + empty tuple:
```zig
std.debug.print("Message\n", .{}); // No args
std.debug.print("Value: {d}\n", .{count}); // With args
```

For literal braces in text (JSON examples), escape them:
```zig
std.debug.print("JSON: {{ \"key\": \"value\" }}\n", .{});
```
### Reserved Keywords
Never use Zig keywords as field/variable names. Use alternatives:
```zig
// Do not use `error` as a field name
err_msg: ?[]const u8, // Use `err_msg` instead
```
### Zig 0.15 Breaking Changes
- `ArrayList.init` → `ArrayList.initCapacity` + allocator on `append`/`deinit`
- `@intCast(x)` → `@as(Type, @intCast(x))`
- `response.status_code == 200` → `response.status == .ok`
- `async/await` removed - use threads instead
- Signal handler: `@enumFromInt(@intFromEnum(...))` for enum conversion
## Memory Management
Free owned fields before deiniting containers:
```zig
for (self.queue.items) |msg| {
    self.allocator.free(msg.text);
}
self.queue.deinit(self.allocator);
```

Never store pointers to stack-local variables. Use pre-calculated constants (e.g., `1048576`).
## Code Style
### Naming
- `camelCase` for functions/methods
- `snake_case` for variables/parameters
- `PascalCase` for types/structs/enums
- `SCREAMING_SNAKE_CASE` for constants
### File Structure
1. `//!` doc comment for module
2. `const Self = @This();`
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`
### Functions
Order: `init` → `deinit` → public API → private helpers. Soft limit: 70 lines.
### Struct Initialization
```zig
const foo: Type = .{ .field = value };  // Good
```
## Functional Programming
- Favor Pure Functions: Input → Output, no side effects
- Avoid OOP: Minimize long-lived stateful objects
- Separate IO from Logic: Core logic should be pure and testable without mocks
- Stateless Handlers: Design event handlers as stateless transformations
## Safety
- Add assertions at API boundaries and state transitions
- Good: bounds checks, null checks, state machine transitions
- Avoid: asserting values immediately after setting them
- Never use `catch unreachable` for operations that can fail

<!-- gitnexus:start -->
# GitNexus — Code Intelligence
This project is indexed by GitNexus as linked-mind (180 symbols, 157 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

>If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.
## Always Do
- MUST run impact analysis before editing any symbol. Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- MUST run `gitnexus_detect_changes()` before committing to verify your changes only affect expected symbols and execution flows.
- MUST warn the user if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.
## Never Do
- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.
## Resources
| Resource | Use for |
|---|---|
| `gitnexus://repo/linked-mind/context` | Codebase overview, check index freshness |
| `gitnexus://repo/linked-mind/clusters` | All functional areas |
| `gitnexus://repo/linked-mind/processes` | All execution flows |
| `gitnexus://repo/linked-mind/process/{name}` | Step-by-step execution trace |
## CLI
| Task | Read this skill file |
|---|---|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
