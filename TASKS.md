# 📝 Linked-Mind Task Manager
This checklist tracks the implementation of recommended features to enhance the Linked-Mind Knowledge Base system.
## 🛠 Core Features (Structural)
- [x] Backlinks Analysis: Show nodes that link to the current node.
  - [x] Update `src/graph.zig` to track incoming edges.
  - [x] Include backlinks in `getContext` for LLM bundle.
- [x] YAML Frontmatter Support: Extract metadata from the start of Markdown files.
  - [x] Implement YAML-like parser (regex or simple state machine).
  - [x] Store metadata in `Node` struct.
  - [x] Include metadata in `getContext` for LLM bundle.
  - [x] Allow filtering export by tags/status.
- [x] Typed Links Support: Specific relationships (e.g., `[[depends_on::Node]]`).
  - [x] Extend `parser.zig` to detect `::` separator.
  - [x] Update `getContext` to describe the nature of the link.
## 🧠 Advanced Analysis (Logic)
- [x] Shortest Path / Graph Traversal: Find connections between distant concepts.
  - [x] Implement BFS/Dijkstra in Zig for the graph structure.
  - [x] CLI command to find "How Node A relates to Node B".
- [x] Community Detection (Clustering): Automatically group related notes.
  - [x] Implement simple cluster detection (e.g., weakly connected components).
  - [x] Export "Map of Content" (MOC) based on clusters.
- [x] Hybrid Search (Graph + Vector): Integrate with LLM embeddings.
  - [x] (Implemented as Jaccard Similarity) Add a tool to generate/store content for each node.
  - [x] Enable similarity-based linking for nodes without explicit wikilinks (via `similar` command).
## ⚡ Performance & UX
- [x] Incremental Scanning: Only parse changed files.
  - [x] Persist a `cache.json` with file `mtime` and hashes.
  - [x] Skip parsing for unchanged files to speed up large KBs.
- [x] Web-based Graph Visualizer: Interactive UI for the graph.
  - [x] Export a `graph.json` compatible with D3.js/Force-Graph.
  - [x] Create a simple HTML/JS dashboard to view the network.
  - [x] Create a persistent HTTP server (`li serve`) to serve visualizer resources and API queries.
- [x] Knowledge "Garbage Collection":
  - [x] Identify and report "Orphan Notes" (no incoming/outgoing links).
  - [x] Identify "Island Nodes" (small detached cliques).
## ✅ Completed Tasks
- [x] Add mdlint CLI tool to check Markdown frontmatter metadata (name, description, tags) and print JSON errors.
- [x] Add agent skill for creating markdown files under `.agents/skills/add-markdown/SKILL.md`.
- [x] Optimize map-builder output and disk IO by checking if generated index matches existing file contents.
- [x] Initial Zig implementation (v0.15.2).
- [x] Wikilinks extraction.
- [x] Hashtag support.
- [x] Basic Link Resolution (Fuzzy Title Match).
- [x] LLM Export Mode (`llm_knowledge.md`).
- [x] Recursive Directory Scanning.
- [x] Memory Leak Prevention (GPA clean shutdown).
- [x] Documentation (`README`, `ARCHITECTURE`, `LLM_STRATEGY`).
## 🚀 Phase 2: Advanced Intelligence (COMPLETED)
- [x] Technical Optimization:
  - [x] Implement O(N) Link Resolution using title map.
  - [x] Optimize Jaccard Similarity with pre-computed word sets.
- [x] Advanced Graph Logic:
  - [x] PageRank Centrality: Identify core concepts.
  - [x] Louvain Clustering: Modularity-based community detection.
  - [x] Link Suggestion: Predict missing links via content similarity.
- [x] Enhanced Visualizer:
  - [x] Integrated Previewer (sidebar showing Rank/Metadata and rendered Markdown/text content).
  - [x] Node Search in UI.
  - [x] "Ask AI" Natural Language Query integration with live RAG responses and highlighted source nodes.
  - [x] Temporal Graph View (interactive timeline slider filtering nodes based on file modification times).
  - [x] Interactive Relationship Editor (sidebar form supporting quick targeted linking, updating notes on disk, and instant visualizer sync).

## 🛠 Zig 0.16.0 Compatibility & Migration (COMPLETED)
- [x] Migrate codebase from Zig 0.15.2 to Zig 0.16.0 compatibility.
    - [x] Refactor I/O operations to use new `std.Io` unified interface.
    - [x] Convert empty list initializations `.{}` to `.empty`.
    - [x] Adopt Juicy Main pattern (`std.process.Init`) in `main.zig` and `li.zig`.
    - [x] Use `std.Io.Writer.Allocating` for dynamic string buffering.
    - [x] Replace `std.Thread.sleep` with `std.Io.sleep`.
    - [x] Verify complete test suite and CLI compilation and run successfully.

## LLM Client Improvements (COMPLETED)
- [x] Add robust HTTP request retry logic with exponential backoff inside LLMService.chat to handle transient errors and rate limits.
- [x] Introduce fallback_model field to LLMConfig to support seamless model downgrades when primary request limits are reached.
- [x] Add configuration validation unit tests.
- [x] Support dynamic configuration loading from .li/config.json file in workspace root.
- [x] Parse and propagate the actual finish_reason from LLM responses.
- [x] Optimize allocating writer memory usage in request serialization.
