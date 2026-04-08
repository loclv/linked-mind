# 🔗 Linked-Mind (Zig Edition)

Linked-Mind is a high-performance Knowledge Base (KB) tool written in Zig. It bridges the gap between static Markdown files and LLM context by representing your documents as a Knowledge Graph.
Instead of feeding an AI random files, Linked-Mind helps the LLM understand how ideas are connected by extracting links, tags, and structure into a machine-readable "Graph Context".

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

#### 1. Scan & Analysis
See a detailed breakdown of your knowledge graph directly in the terminal. You can filter by tags or status:
```bash
# Basic scan
zig build run -- scan ./your_notes

# Filtered scan
zig build run -- scan ./your_notes --tag work --status active
```

#### 2. LLM Export (The "Power Move")
Generate a single file that tells the LLM exactly how your notes connect. Filters are also supported here:
```bash
zig build run -- export ./your_notes --tag research --status completed
```
This creates `llm_knowledge.md` in the current directory.

#### 3. Advanced Analysis
- Graph Traversal: Find the shortest path between two concepts.
  ```bash
  zig build run -- path ./your_notes "Quantum Computing" "Shor's Algorithm"
  ```
- Community Detection: Generate a "Map of Content" (MOC) using Louvain modularity-based clustering.
  ```bash
  zig build run -- clusters ./your_notes
  ```
- Similarity Search: Find nodes related to a specific topic (even without explicit links).
  ```bash
  zig build run -- similar ./your_notes "Artificial Intelligence"
  ```
- Link Suggestion: Discover missing connections between content-similar notes.
  ```bash
  zig build run -- suggest ./your_notes --threshold 0.1
  ```
- Interactive Web Visualization: Export your graph to JSON and view it in a sleek interactive web dashboard.
  ```bash
  zig build run -- visualize ./your_notes
  ```
  *(Then start a local server like `bunx serve .` and open the local address)*

## 🧠 Why Graph-based KB for LLMs?

Standard RAG (Retrieval-Augmented Generation) often treats files as isolated chunks. However, human knowledge is a web. By using Linked-Mind, you provide the LLM with:
1. Contextual Proximity: If Node A links to Node B, the LLM knows they are related even if they don't share keywords.
2. Structural Understanding: The AI sees the hierarchy and tags, allowing it to "browse" your brain more effectively.

## 📂 Project Structure

- `src/parser.zig`: Optimized scanner for `[[links]]` and `#tags`.
- `src/graph.zig`: Adjacency-list based graph representation and link resolver.
- `src/main.zig`: CLI handler for scan/export modes.

Built with speed and precision in Zig.
