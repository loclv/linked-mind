# 🔗 Linked-Mind (Zig Edition)

**Linked-Mind** is a high-performance Knowledge Base (KB) tool written in **Zig**. It bridges the gap between static Markdown files and LLM context by representing your documents as a **Knowledge Graph**.

Instead of feeding an AI random files, Linked-Mind helps the LLM understand how ideas are connected by extracting links, tags, and structure into a machine-readable "Graph Context".

## 🚀 Features

-   **Fast Markdown Parsing**: Written in Zig (v0.15.2) for maximum efficiency.
-   **Wikilink Extraction**: Automatically identifies `[[Internal Links]]` between documents.
-   **Tag System**: Supports `#hashtags` to categorize knowledge nodes.
-   **Link Resolution**: Automatically maps human-readable wikilinks to absolute file paths.
-   **LLM Export**: Generates a single, structured `llm_knowledge.md` file designed for transformer-based LLMs to consume.

## 🛠 Usage

### Prerequisites
-   [Zig 0.15.2+](https://ziglang.org/download/)

### Building
```bash
zig build
```

### Modes

#### 1. Scan & Analysis
See a detailed breakdown of your knowledge graph directly in the terminal:
```bash
zig build run -- scan ./your_notes_folder
```

#### 2. LLM Export (The "Power Move")
Generate a single file that tells the LLM exactly how your notes connect:
```bash
zig build run -- export ./your_notes_folder
```
This creates `llm_knowledge.md` in the current directory.

## 🧠 Why Graph-based KB for LLMs?

Standard RAG (Retrieval-Augmented Generation) often treats files as isolated chunks. However, human knowledge is a web. By using **Linked-Mind**, you provide the LLM with:
1.  **Contextual Proximity**: If Node A links to Node B, the LLM knows they are related even if they don't share keywords.
2.  **Structural Understanding**: The AI sees the hierarchy and tags, allowing it to "browse" your brain more effectively.

## 📂 Project Structure

- `src/parser.zig`: Optimized scanner for `[[links]]` and `#tags`.
- `src/graph.zig`: Adjacency-list based graph representation and link resolver.
- `src/main.zig`: CLI handler for scan/export modes.

---
*Built with speed and precision in Zig.*
