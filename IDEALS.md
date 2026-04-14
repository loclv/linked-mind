# 🌟 Linked-Mind Phase 2: The "Ideal" Future

This document outlines the strategic roadmap for the next evolution of Linked-Mind. Having completed the core structural and analysis features, Phase 2 focuses on automation, deeper intelligence, and seamless user experience.

## 1. ⚡ Real-Time Intelligence & Sync
Currently, the system requires manual rescans. The "ideal" state is a "Living Graph" that breathes with your notes.

- [x] **Native File Watcher**: Implement a cross-platform background daemon in Zig (implemented as `li watch` polling loop).
- [ ] **Live UI Rehydration**: Automatically push updates to the `graph.json` and trigger a refresh in the Web Visualizer when files change.
- [ ] **Hot-Reloading LLM Context**: A persistent API server that always provides the most up-to-date `llm_knowledge.md` via an HTTP endpoint.

## 2. 🧠 Advanced Graph Intelligence
Moving beyond simple connectivity to understanding the *shape* and *importance* of knowledge.

- [x] **PageRank Centrality**: Implement PageRank in Zig to identify "Core Concepts" (nodes with high influence in the KB).
- [x] **Semantic Clustering (Louvain)**: Upgrade from "Weakly Connected Components" to the Louvain Method for modularity-based community detection.
- [x] **Link Prediction / Suggestion**: Analyze the content of nodes to suggest `[[Links]]` that *should* exist but are currently missing (Self-Healing Graph).

## 3. 🤖 AI & LLM Deep Integration
Bridging the gap between the graph structure and vector-based semantics.

- [ ] **Local Embeddings (Vector Search)**: Integrate `llama.cpp` or a small transformer model to generate 384d/768d embeddings locally for all nodes.
- [ ] **Hybrid Search Engine**: Combine Graph BFS paths with Vector Similarity for "Contextual Retrieval" (e.g., "Find notes related to 'Quantum' that are within 2 hops of 'Computing'").
- [ ] **NLQ (Natural Language Query)**: Use an LLM to translate natural language questions into graph traversal queries.

## 4. 🎨 Next-Level Web Visualizer
Transforming the visualizer from a static viewer into an interactive workspace.

- [ ] **Integrated Previewer**: A browser-based side-pane to see rendered Markdown content when clicking a node.
- [ ] **Interactive Relationship Editor**: Drag-and-drop links between nodes visually to update the underlying Markdown files.
- [ ] **Temporal Graph View**: A timeline slider to see how your knowledge graph grew over time (using git history or file creation dates).

## 5. 🛠 Technical Refactoring & Optimization
Improving the foundation for scale.

- [x] **O(N) Link Resolution**: Replace the current O(N squared) `resolveBacklinks` with a high-performance title-to-node lookup map.
- [x] **Incremental Similarity Updates**: Pre-computed word sets avoid redundant tokenization during similarity search.
- [ ] **Multi-Format Support**: Expand the parser to support `.org` (Emacs), `.txt`, and even PDF extraction.

---

> [!TIP]
> The goal is to move Linked-Mind from a **utility** to a **Knowledge Operating System**.
