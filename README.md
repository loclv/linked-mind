# 🥦 Linked-Mind

<div align="center">
  <img src="assets/broccoli_kun.png" width="150" alt="Broccoli Kun Avatar" />
</div>

WARNING: This project is currently in active development.

Linked-Mind is a high-performance Knowledge Base (KB) tool written in [Zig](https://ziglang.org/). Inspired by [Andrej Karpathy's LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f), it bridges the gap between static Markdown files and LLM context by representing your documents as a Knowledge Graph.
Instead of feeding an AI random files, Linked-Mind helps the LLM understand how ideas are connected by extracting links, tags, and structure into a machine-readable "Graph Context".

A reasoning-based, human-like retrieval RAG system over long documents (like [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex)) but using mind-map method to structure the document. No Vectors Needed. No Chunking Needed. No approximate semantic search. Image instead of reading a full text book, you can just read the mind-map and understand the content of the book.

Save tokens, read less, understand more.

## 🚀 Features

- Multi-Format Parsing: Unified scanner supporting Markdown (`.md`), Emacs Org-mode (`.org`), Plain Text (`.txt`), and PDF (`.pdf`) extraction.
- Wikilink Extraction: Automatically identifies `[[Internal Links]]` (including org-style `[[target][desc]]`) between documents across all supported formats.
- Tag System: Supports `#hashtags` (and Org `#+filetags:` or heading `:tags:`) to categorize knowledge nodes.
- Link Resolution: Automatically maps human-readable wikilinks to absolute file paths, ignoring extensions.
- Incremental Scanning: Blazing fast re-scans using `cache.json`, `mtime`, and SHA-256 (only parses changed files).
- Documentation Index Map: Recursively scans documentation files to generate a structured map of the workspace, defaulting to flat CSV format (map.csv) containing parent-child relations with optional JSON (map.json) or TOON (map.toon) output.
- Web Visualizer: Export an interactive D3-powered Knowledge Graph dashboard to `graph.json` with live UI rehydration and physics-stabilized real-time updates.
- Native File Watcher: Background daemon that monitors folder changes across all format extensions, outputs JSON events, and triggers instant incremental visualizer re-exports.
- LLM Export: Generates a single, structured `llm_knowledge.md` file designed for transformer-based LLMs to consume.
- Mind-Map RAG: Structure long Markdown documents as concept mind-maps (section tree + causal links). Retrieve answers via LLM-guided tree traversal — no vectors, no chunking. Includes build (`li mind build`) and query (`li mind query`) subcommands.

## 🛠 Usage

### Prerequisites

- [Zig 0.16.0+](https://ziglang.org/download/)

### Building

```bash
zig build
```

This produces the `li` binary in `zig-out/bin/`. You can link it to your path for easy access.

### 1. Workspace Initialization

Initialize a directory as a Linked-Mind workspace. This creates a `.li/` folder to store cache and configuration.

```bash
# In your notes directory
li init
```

### 2. Scan & Analysis

Scan the workspace and update the graph cache.

```bash
li scan

# Filtered view
li scan --tag work --status active
```

### 3. LLM Export (The "Power Move")

Generate `llm_knowledge.md` in your workspace root.

```bash
li export --tag research --status completed
```

### 4. Advanced Analysis

- Graph Traversal: Find connections between concepts.
  ```bash
  li path "Quantum Computing" "Shor's Algorithm"
  ```
- Community Detection: Generate `map.csv`.
  ```bash
  li clusters
  ```
- Similarity Search: Find related nodes.
  ```bash
  li similar "Artificial Intelligence"
  ```
- Link Suggestion: Discover missing connections.
  ```bash
  li suggest --threshold 0.1
  ```
- Knowledge GC: Find orphans and islands.
  ```bash
  li gc --threshold 3
  ```
- Interactive Visualization: Export `graph.json`.
  ```bash
  li visualize
  ```
- Real-Time File Watcher: Run the native background daemon to monitor note changes and automatically rebuild and export visualizer data.
  ```bash
  li watch
  ```
- Mind-Map RAG (Preview): Build and query a concept mind-map from any Markdown document. The system extracts headings into a section tree, then (optionally) uses an LLM to identify causal cross-links. Queries traverse the tree guided by the LLM.
  ```bash
  # Build a mind-map from a markdown file (generates mind-map.json)
  li mind build document.md

  # Query the mind-map
  li mind query "What are the key causes of X?"
  ```
- Documentation Indexing Map: Run the map-builder executable to scan your documentation and regenerate the map index. It automatically ignores the .git directory and respects any patterns defined in the .gitignore file when scanning.
  ```bash
  # Generates map.csv from current directory "."
  map-builder

  # Generates map.json from current directory "."
  map-builder --json

  # Generates map.toon from current directory "."
  map-builder --toon

  # Generates map.csv from a custom target folder (e.g. "my_notes")
  map-builder my_notes

  # Generates map.csv from custom target folder and writes to custom output path
  map-builder my_notes --output custom_map.csv
  ```

## 🧠 Why Graph-based KB for LLMs?

Standard RAG (Retrieval-Augmented Generation) often treats files as isolated chunks. However, human knowledge is a web. By using Linked-Mind, you provide the LLM with:

1. Contextual Proximity: If Node A links to Node B, the LLM knows they are related even if they don't share keywords.
2. Structural Understanding: The AI sees the hierarchy and tags, allowing it to "browse" your brain more effectively.

## 📂 Project Structure

- `src/parser.zig`: Unified parser for multiple formats (.md, .org, .txt, .pdf) extracting `[[links]]` and `#tags`.
- `src/graph.zig`: Adjacency-list based graph representation and link resolver.
- `src/li.zig`: Workspace-aware CLI with `init`, `scan`, `export`, `path`, `clusters`, `gc`, `similar`, `suggest`, `visualize`.
- `src/cache.zig`: Incremental scanning engine with `mtime` + SHA-256 cache.
- `src/main.zig`: Legacy CLI handler (direct path mode).
- `src/mindmap/`: Mind-Map RAG subsystem.
  - `mindmap.zig`: Core data structures (`ConceptNode`, `CausalLink`, `MindMap`) with JSON serialization.
  - `llm.zig`: LLM HTTP client types (`LLMConfig`, `LLMRequest`, `LLMResponse`).
  - `serialize.zig`: Convenience wrappers for JSON serialization/deserialization.
  - `builder.zig`: Build pipeline — markdown heading extraction and tree construction.
  - `query.zig`: Query pipeline — leaf collection, context assembly, reasoning traversal.

Built with speed and precision in Zig.
