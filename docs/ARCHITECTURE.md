# 🏗 Architecture & Design

Linked-Mind is built using Zig, prioritizing performance and low memory footprint while providing a robust Knowledge Graph structure.

## 🧱 Core Modules

### 1. `parser.zig`

The Unified Multi-Format Parser tokenizes Markdown (`.md`), Emacs Org-mode (`.org`), Plain Text (`.txt`), and PDF (`.pdf`) files for knowledge-base metadata:

- Wikilinks (`[[ ]]`): These are the primary edges of the graph. We extract them across all formats, including Org-style `[[target][description]]` links.
- Hashtags (`#tag`): Extracted from raw text and specialized syntax (such as Org `#+filetags:` and heading-end `:tag1:tag2:` properties).
- PDF Text Extraction: Scans PDF files for stream blocks, automatically decompressing `/FlateDecode` filters using Zig's `std.compress.flate.Decompress` (zlib format), then extracts parenthesized text `(...)` and parses it for links and tags.
- Memory Safety: Uses `std.ArrayListUnmanaged` patterns to ensure minimal allocations when walking the filesystem and parsing documents.

### 2. `graph.zig`

The heart of Linked-Mind is the Knowledge Graph:

- Node Storage: Uses a `StringHashMap` where the key is the absolute file path and the value is a `Node` struct.
- Link Resolution: When querying a node's context, the graph system iterates to find if any other registered node matches the title in a wikilink.
- Resolution Logic: Currently, it performs a partial title match, making it resilient to slight variations in linking (e.g., `[[My Note]]` matching `path/to/My Note.md`).

### 3. `li.zig`

The workspace-aware CLI orchestration layer:

- Workspace Discovery: `findWorkspaceRoot` walks up from cwd to find `.li/` marker, enabling in-workspace commands without explicit path args.
- Init: `initWorkspace` creates `.li/` directory with cache storage.
- Global Parser: Efficiently handles common flags (`--tag`, `--status`, `--threshold`) across all execution modes.
- Recursive Walker: Uses `std.fs.Dir.walk` to traverse directories deeply, skipping hidden dirs (`.li`, `.git`).
- Filtered Dumps: The terminal output can be scoped using tags to preview context before a full export.
- Memory Management: Implements a `GeneralPurposeAllocator` with full leak detection to ensure a clean exit after scanning thousands of files.
- Native File Watcher Daemon: Implements a polling loop under the `li watch` command that monitors the workspace for Markdown changes, outputs structured events, and triggers efficient, incremental graph regenerations.

### 4. `index.html` (Web Visualization)

The browser UI implementation:

- Force-Graph Engine: Uses D3/Physics-based Force-Graph to lay out relationships in 2D space.
- Dynamic Clusters: Colors particles depending on community clusters resolved by Zig backend.
- Rich Aesthetics: Built with modern Glassmorphism logic, tailored interactions, animations, and node-tracking sidebars.
- Incremental Awareness: Uses the `Cache` module to skip unchanged files by checking `mtime` and content hashes.
- Live UI Rehydration: Performs periodic polling of graph.json and updates the Force-Graph in real time without page reload, merging new node coordinates to preserve positions and physics stability, complemented by dynamic toast alerts.

### 5. `cache.zig`

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
- [x] Tree-shaking: `gc` command identifies orphan and island nodes for cleanup.
- [x] Web UI: Interactive Force-Graph visualization of the generated graph context via exportable JSON.

## Application Contexts

### Approach 1: Section-Tree Mind-Map (Recommended)

Use the document's heading hierarchy as the mind-map backbone. Each heading becomes a node with an LLM-generated summary. Causal links are extracted between concepts across sections. Retrieval: top-down tree search with LLM reasoning at each level, following causal cross-links.

Trade-off: Closest to PageIndex's proven model, but enriched with typed causal edges. Simple to implement incrementally.

### Approach 2: Flat Concept Graph

Ignore headings entirely. LLM extracts all key concepts from the document as a flat set, then identifies causal relationships between them. The mind-map is a pure graph. Retrieval: start at any node, traverse via causal edges, LLM decides relevance at each step.

Trade-off: More flexible, but harder to navigate long documents — LLM has no "table of contents" to guide search. Less predictable retrieval paths.

### Approach 3: Hierarchical Topic Clusters

Cluster concepts into topic groups (LLM-driven), forming a 2-level hierarchy (topic → concepts). Within each cluster, concepts connect via causal edges. Retrieval: LLM selects relevant topics first, then traverses concepts within them.

Trade-off: Middle ground — structured like a mind-map's central-topic-with-branches, but clusters are LLM-determined rather than following document structure. More complex to implement.
