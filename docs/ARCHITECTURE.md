# 🏗 Architecture & Design

Linked-Mind is built using **Zig**, prioritizing performance and low memory footprint while providing a robust Knowledge Graph structure.

## 🧱 Core Modules

### 1. `parser.zig`
The Markdown parser doesn't just read the file; it **tokenizes** it specifically for knowledge-base metadata:
-   **Wikilinks (`[[ ]]`)**: These are the primary edges of the graph. We extract them early to build the relationship schema.
-   **Hashtags (`#tag`)**: These are categories or labels that help group nodes into clusters.
-   **Memory Safety**: Uses `std.ArrayListUnmanaged` to ensure we only allocate what's absolutely necessary when walking the filesystem.

### 2. `graph.zig`
The heart of Linked-Mind is the **Knowledge Graph**:
-   **Node Storage**: Uses a `StringHashMap` where the key is the absolute file path and the value is a `Node` struct.
-   **Link Resolution**: When querying a node's context, the graph system iterates to find if any other registered node matches the title in a wikilink.
-   **Resolution Logic**: Currently, it performs a partial title match, making it resilient to slight variations in linking (e.g., `[[My Note]]` matching `path/to/My Note.md`).

### 3. `main.zig`
The CLI orchestration layer:
-   **Recursive Walker**: Uses `std.fs.Dir.walk` to traverse directories deeply.
-   **Memory Management**: Implements a `GeneralPurposeAllocator` with full leak detection to ensure a clean exit after scanning thousands of files.

## 💾 Memory Model
Linked-Mind is designed to be extremely memory-efficient:
-   All strings are **duped** (duplicated) into a central allocator.
-   `deinit` methods are used throughout to ensure every allocated byte is freed.
-   The graph is built **once** per execution, making it a fast "one-shot" tool for CI/CD or desktop scripts.

## 🛠 Future Roadmap
-   [ ] **Inverted Index**: For even faster link resolution.
-   [ ] **Frontmatter Support**: Parsing YAML metadata for more complex relationship types.
-   [ ] **Bidirectional Links**: Automatically identifying what notes link *to* the current note (backlinks).
-   [ ] **Tree-shaking**: Excluding orphan nodes that have no links or tags.
