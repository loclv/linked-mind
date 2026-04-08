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
    - [x] Allow filtering export by tags/status.
- [x] **Typed Links Support**: Specific relationships (e.g., `[[depends_on::Node]]`).
    - [x] Extend `parser.zig` to detect `::` separator.
    - [x] Update `getContext` to describe the *nature* of the link.

## 🧠 Advanced Analysis (Logic)
- [x] **Shortest Path / Graph Traversal**: Find connections between distant concepts.
    - [x] Implement BFS/Dijkstra in Zig for the graph structure.
    - [x] CLI command to find "How Node A relates to Node B".
- [x] **Community Detection (Clustering)**: Automatically group related notes.
    - [x] Implement simple cluster detection (e.g., weakly connected components).
    - [x] Export "Map of Content" (MOC) based on clusters.
- [x] **Hybrid Search (Graph + Vector)**: Integrate with LLM embeddings.
    - [x] (Implemented as Jaccard Similarity) Add a tool to generate/store content for each node.
    - [x] Enable similarity-based linking for nodes without explicit wikilinks (via `similar` command).

## ⚡ Performance & UX
- [x] **Incremental Scanning**: Only parse changed files.
    - [x] Persist a `cache.json` with file `mtime` and hashes.
    - [x] Skip parsing for unchanged files to speed up large KBs.
- [x] **Web-based Graph Visualizer**: Interactive UI for the graph.
    - [x] Export a `graph.json` compatible with D3.js/Force-Graph.
    - [x] Create a simple HTML/JS dashboard to view the network.
- [x] **Knowledge "Garbage Collection"**:
    - [x] Identify and report "Orphan Notes" (no incoming/outgoing links).
    - [x] Identify "Island Nodes" (small detached cliques).

## ✅ Completed Tasks
- [x] Initial Zig implementation (v0.15.2).
- [x] Wikilinks extraction.
- [x] Hashtag support.
- [x] Basic Link Resolution (Fuzzy Title Match).
- [x] LLM Export Mode (`llm_knowledge.md`).
- [x] Recursive Directory Scanning.
- [x] Memory Leak Prevention (GPA clean shutdown).
- [x] Documentation (`README`, `ARCHITECTURE`, `LLM_STRATEGY`).

## 🚀 Phase 2: Advanced Intelligence (COMPLETED)
- [x] **Technical Optimization**:
    - [x] Implement O(N) Link Resolution using title map.
    - [x] Optimize Jaccard Similarity with pre-computed word sets.
- [x] **Advanced Graph Logic**:
    - [x] PageRank Centrality: Identify core concepts.
    - [x] Louvain Clustering: Modularity-based community detection.
    - [x] Link Suggestion: Predict missing links via content similarity.
- [x] **Enhanced Visualizer**:
    - [x] Integrated Previewer (sidebar showing Rank/Metadata).
    - [x] Node Search in UI.
