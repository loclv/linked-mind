# 🥦 Linked-Mind

<div align="center">
  <img src="assets/broccoli_kun.png" width="150" alt="Broccoli Kun Avatar" />
</div>

WARNING: This project is currently in active development.
Linked-Mind is a high-performance Knowledge Base (KB) tool written in [Zig](https://ziglang.org/). Inspired by [Andrej Karpathy's LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f), it bridges the gap between static Markdown files and LLM context by representing your documents as a Knowledge Graph.
Instead of feeding an AI random files, Linked-Mind helps the LLM understand how ideas are connected by extracting links, tags, and structure into a machine-readable "Graph Context".
The mind-map, a reasoning-based, human-like retrieval RAG system over long documents (like [VectifyAI/PageIndex](https://github.com/VectifyAI/PageIndex)) but using mind-map method to structure the document. No Vectors Needed. No Chunking Needed. No approximate semantic search. Image instead of reading a full text book, you can just read the mind-map and understand the content of the book.

## 🚀 Features

- Fast Markdown Parsing: Written in Zig (v0.15.2) for maximum efficiency.
- Wikilink Extraction: Automatically identifies `[[Internal Links]]` between documents.
- Tag System: Supports `#hashtags` to categorize knowledge nodes.
- Link Resolution: Automatically maps human-readable wikilinks to absolute file paths.
- Incremental Scanning: Blazing fast re-scans using `cache.json`, `mtime`, and SHA-256 (only parses changed files).
- Web Visualizer: Export a interactive D3-powered Knowledge Graph dashboard to `graph.json` and view it in your browser.
- LLM Export: Generates a single, structured `llm_knowledge.md` file designed for transformer-based LLMs to consume.

## 🛠 Usage

### Prerequisites
- [Zig 0.15.2+](https://ziglang.org/download/)

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

## 🧠 Why Graph-based KB for LLMs?

Standard RAG (Retrieval-Augmented Generation) often treats files as isolated chunks. However, human knowledge is a web. By using Linked-Mind, you provide the LLM with:
1. Contextual Proximity: If Node A links to Node B, the LLM knows they are related even if they don't share keywords.
2. Structural Understanding: The AI sees the hierarchy and tags, allowing it to "browse" your brain more effectively.

## 📂 Project Structure

- `src/parser.zig`: Optimized scanner for `[[links]]` and `#tags`.
- `src/graph.zig`: Adjacency-list based graph representation and link resolver.
- `src/li.zig`: Workspace-aware CLI with `init`, `scan`, `export`, `path`, `clusters`, `gc`, `similar`, `suggest`, `visualize`.
- `src/cache.zig`: Incremental scanning engine with `mtime` + SHA-256 cache.
- `src/main.zig`: Legacy CLI handler (direct path mode).

Built with speed and precision in Zig.
