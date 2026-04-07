# 📝 Linked-Mind Task Manager

This checklist tracks the implementation of recommended features to enhance the Linked-Mind Knowledge Base system.

## 🛠 Core Features (Structural)
- [x] **Backlinks Analysis**: Show nodes that link *to* the current node.
    - [x] Update `src/graph.zig` to track incoming edges.
    - [x] Include backlinks in `getContext` for LLM bundle.
- [x] **YAML Frontmatter Support**: Extract metadata from the start of Markdown files.
    - [x] Implement YAML-like parser (regex or simple state machine).
    - [x] Store metadata in `Node` struct.
    - [x] Include metadata in `getContext` for LLM bundle.
    - [ ] Allow filtering export by tags/status.
- [ ] **Typed Links Support**: Specific relationships (e.g., `[[depends_on::Node]]`).
    - [ ] Extend `parser.zig` to detect `::` separator.
    - [ ] Update `getContext` to describe the *nature* of the link.

## 🧠 Advanced Analysis (Logic)
- [ ] **Shortest Path / Graph Traversal**: Find connections between distant concepts.
    - [ ] Implement BFS/Dijkstra in Zig for the graph structure.
    - [ ] CLI command to find "How Node A relates to Node B".
- [ ] **Community Detection (Clustering)**: Automatically group related notes.
    - [ ] Implement simple cluster detection (e.g., strongly connected components).
    - [ ] Export "Map of Content" (MOC) based on clusters.
- [ ] **Hybrid Search (Graph + Vector)**: Integrate with LLM embeddings.
    - [ ] (Optional) Add a tool to generate/store vector embeddings for each node.
    - [ ] Enable similarity-based linking for nodes without explicit wikilinks.

## ⚡ Performance & UX
- [ ] **Incremental Scanning**: Only parse changed files.
    - [ ] Persist a `cache.json` with file `mtime` and hashes.
    - [ ] Skip parsing for unchanged files to speed up large KBs.
- [ ] **Web-based Graph Visualizer**: Interactive UI for the graph.
    - [ ] Export a `graph.json` compatible with D3.js/Force-Graph.
    - [ ] Create a simple HTML/JS dashboard to view the network.
- [ ] **Knowledge "Garbage Collection"**:
    - [ ] Identify and report "Orphan Notes" (no incoming/outgoing links).
    - [ ] Identify "Island Nodes" (small detached cliques).

## ✅ Completed Tasks
- [x] Initial Zig implementation (v0.15.2).
- [x] Wikilinks extraction.
- [x] Hashtag support.
- [x] Basic Link Resolution (Fuzzy Title Match).
- [x] LLM Export Mode (`llm_knowledge.md`).
- [x] Recursive Directory Scanning.
- [x] Memory Leak Prevention (GPA clean shutdown).
- [x] Documentation (`README`, `ARCHITECTURE`, `LLM_STRATEGY`).
