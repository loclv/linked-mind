# 🏗 Architecture & Design

Linked-Mind is built using Zig, prioritizing performance and low memory footprint while providing a robust Knowledge Graph structure.

## 🧱 Core Modules

### 1. `parser.zig`
The Markdown parser doesn't just read the file; it tokenizes it specifically for knowledge-base metadata:
- Wikilinks (`[[ ]]`): These are the primary edges of the graph. We extract them early to build the relationship schema.
- Hashtags (`#tag`): These are categories or labels that help group nodes into clusters.
- Memory Safety: Uses `std.ArrayListUnmanaged` to ensure we only allocate what's absolutely necessary when walking the filesystem.

### 2. `graph.zig`
The heart of Linked-Mind is the Knowledge Graph:
- Node Storage: Uses a `StringHashMap` where the key is the absolute file path and the value is a `Node` struct.
- Link Resolution: When querying a node's context, the graph system iterates to find if any other registered node matches the title in a wikilink.
- Resolution Logic: Currently, it performs a partial title match, making it resilient to slight variations in linking (e.g., `[[My Note]]` matching `path/to/My Note.md`).

### 3. `main.zig`
The CLI orchestration layer:
- Global Parser: Efficiently handles common flags (`--tag`, `--status`) across all execution modes.
- Recursive Walker: Uses `std.fs.Dir.walk` to traverse directories deeply.
- Filtered Dumps: The terminal output can be scoped using tags to preview context before a full export.
- Memory Management: Implements a `GeneralPurposeAllocator` with full leak detection to ensure a clean exit after scanning thousands of files.

### 4. `index.html` (Web Visualization)
The browser UI implementation:
- Force-Graph Engine: Uses D3/Physics-based Force-Graph to lay out relationships in 2D space.
- Dynamic Clusters: Colors particles depending on community clusters resolved by Zig backend.
- Rich Aesthetics: Built with modern Glassmorphism logic, tailored interactions, animations, and node-tracking sidebars.
- Incremental Awareness: Uses the `Cache` module to skip unchanged files by checking `mtime` and content hashes.

### 4. `cache.zig`
The incremental scanning engine:
- Persisted State: Saves file metadata and parsed results into `cache.json`.
- Double-Check: Uses file modification times (`mtime`) for fast skips and SHA-256 content hashes for accuracy.
- Speeds up large knowledge base scans by 10-100x on subsequent runs.

## 💾 Memory Model
Linked-Mind is designed to be extremely memory-efficient:
- All strings are duped (duplicated) into a central allocator.
- `deinit` methods are used throughout to ensure every allocated byte is freed.
- The graph is built once per execution, making it a fast "one-shot" tool for CI/CD or desktop scripts.

## 🛠 Future Roadmap
- [x] Frontmatter Support: Parsing YAML metadata (Tags, Status) for complex relationship types.
- [x] Bidirectional Links: Automatically identifying what notes link to the current note (backlinks).
- [x] Inverted Index: For even faster link resolution in Massive KBs.
- [ ] Tree-shaking: Excluding orphan nodes that have no links or tags for cleaner AI input.
- [x] Web UI: Interactive Force-Graph visualization of the generated graph context via exportable JSON.
