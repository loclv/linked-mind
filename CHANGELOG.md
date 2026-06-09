# CHANGELOG

## [Unreleased] - 2026-06-09

### Added

- Added `li --version` / `li -v` command to print version info.
- Added plain-text summary of IDEALS.md in `docs/plain/IDEALS.txt`.

### Fixed

- Fixed AGENTS.md reference to `TASK.md` → `TASKS.md` (caused ralph loop error).

### Added

- Added local TF-IDF embedding engine (`src/embeddings.zig`) for pure-Zig vector search without external dependencies. Includes vocabulary building, sparse TF-IDF vector computation, cosine similarity, and top-k query retrieval.
- Added hybrid search engine (`src/hybrid_search.zig`) combining BFS graph traversal with TF-IDF vector similarity. New `li search <query> [--seed <title>] [--hops <n>]` CLI command finds content-similar nodes optionally constrained within N graph hops of a seed node.
- Both modules exported from `src/root.zig` with comprehensive unit tests covering tokenization, vector similarity, corpus building, hop distance computation, and combined search scenarios.

### Fixed

- Fixed memory leaks in `cache` key cleanup for `EmbeddingEngine`.

### Changed

- Updated `IDEALS.md`: marked Local Embeddings, Hybrid Search Engine, and Multi-Format Support as completed.

## [Unreleased] - 2026-06-08

### Added

- Added `mdlint` CLI tool (`src/mdlint.zig`) to scan files and directories recursively for Markdown files and validate that they contain non-empty `name`, `description`, and `tags` frontmatter metadata, reporting failures as a structured JSON array.
- Added `add-markdown` agent skill under `.agents/skills/add-markdown/SKILL.md` to guide agents when creating markdown files with proper YAML metadata, tags, and formatting (no emojis, no bold text).

### Fixed

- Fixed pre-existing compile error in `src/li.zig` around line 624 by using proper Zig optional payload capture syntax `if (type_opt) |t_opt|`.
- Robust HTTP request retry logic with exponential backoff inside LLMService.chat to handle rate limits (HTTP 429), transient server errors (HTTP 5xx), and network failures.
- Optional fallback_model parameter in LLMConfig, allowing the query engine to seamlessly downgrade or fallback to alternative models if the primary model fails all retry attempts.
- Configuration assertions in the test suite to verify default LLMConfig model settings.
- Dynamic file loading support in LLMConfig.load to parse configuration from .li/config.json at workspace root, with proper deinit support.
- Propagation of finish_reason in LLMResponse.fromJson by parsing it from choice results.
- Optimized payload serialization memory in LLMRequest.toJson by avoiding redundant allocations.

## [Unreleased] - 2026-06-07

### Added

- Persistent API and Visualizer server subcommand `li serve` allowing real-time context and graph visualization rendering over HTTP.
- Fully comprehensive unit testing verifying HTTP header generation and payload serialization logic for 200, 404, 405, and 500 responses.
- Integrated the `li_tests` unit test runner into `build.zig` under the standard `zig build test` command, enabling continuous validation of CLI commands.
- Enabled recursive test resolution in `src/root.zig` via `std.testing.refAllDecls(@This())`.
- Integrated browser-based sidebar "Content Preview" pane in the visualizer displaying rendered Markdown (using `marked.js` library via CDN) or raw text for selected nodes.
- Integrated backend API support in `li serve` to allow reading/serving supported note file formats (`.md`, `.org`, `.txt`, `.pdf`) directly from the workspace.
- Added natural language AI query search input ("Ask AI") in the Web visualizer, sending requests to the server's new `/api/query` endpoint and showing the response in the sidebar.
- Enabled interactive visualizer rehydration by highlighting AI-referenced nodes in the force-graph and listing them as clickable context source cards in the sidebar.
- Added Temporal Graph View timeline slider in the web visualizer to allow smooth dynamic filtering of nodes based on file modification times.
- Exported `mtime` modification timestamps (in milliseconds) from parsed node metadata to the D3 force graph visualizer data (`graph.json`).
- Auto-cached `mtime` fields in the workspace index (`cache.json`) for instant rendering and high-performance live-updates.
- Integrated an Interactive Relationship Editor form directly into the node sidebar of the Web Visualizer. Users can select target nodes from an autocompleting list, input relationship types, and save them.
- Created `/api/add-link` backend endpoint in the server (`li serve`) which maps source nodes to absolute file paths, appends the new wikilink (`[[type::target]]`) safely to the end of the file, and regenerates visualizer artifacts.
- Implemented comprehensive `urlDecode` utility tests and an integration test verifying the add-link endpoint logic.

### Fixed

- Resolved Zig 0.16.0 deprecations in `src/li.zig` unit tests by migrating them to the unified `std.Io` / `std.process` APIs.
- Fixed a memory leak in `findWorkspaceRoot` where `current_path` was not freed when returning `error.NoWorkspaceFound`.
- Fixed a GPA size-mismatch panic (`Allocation size does not match free size`) by changing the return type of `findWorkspaceRoot` to `![:0]u8` to preserve sentinel-allocated string lengths.
- Corrected path comparisons in tests to support macOS `/private/tmp` symlinks by pre-resolving paths using `realPathFileAlloc`.
- Corrected helper parameter ordering in `std.mem.indexOf` inside `src/li.zig` tests.
- Fixed deprecation/lint warnings for indexOf and indexOfScalar in `src/li.zig` by replacing them with `std.mem.find` and `std.mem.findScalar`.
- Resolved `ziglint` warnings for empty catch blocks by properly logging exceptions.

## [Unreleased] - 2026-06-05

### Added

- Graph traversal query optimization in QueryEngine (`src/mindmap/query.zig`).
- Tarjan's Strongly Connected Components (SCC) algorithm (`TarjanContext`) to pre-detect directed cycles and loops within the mind-map tree and causal graph.
- Loop/cycle merging logic during traversal to resolve cyclic dependency infinite loops.
- Visited list tracking (`visitedList`) to prevent re-entering visited nodes.
- Recursion depth control (`MaxDepth`) to prevent stack overflow in deep graphs.
- Custom keyword matching (`findStartNodes`) to resolve query entry points from user questions.
- High-coverage unit tests for `findStartNodes` and `traverseGraph` with cycle detection and max depth constraints.

## [Unreleased] - 2026-06-02

### Added

- Flat CSV output support in map-builder (src/map.zig and src/map/entry.zig) with standard RFC 4180 double-quoting and escaping rules.
- Public helper structures (FlatEntry), recursive flattening (collectFlat), alphabetical path sorting (flatEntryLessThan), and custom CSV field escaping (writeCsvField) in entry.zig for clean modular reuse.
- High-coverage unit testing covering all aspects of the new flat CSV formatting, hierarchy traversal, path sorting, and comma/quote escaping.

### Changed

- Defaulted the map-builder target folder to the current directory "." instead of "./docs/", making "map-builder" equivalent to "map-builder .".
- Set flat CSV (map.csv) as the default output format for the map-builder executable.
- Added --toon (or -t) command line option to map-builder to optionally output TOON format (map.toon).
- Modified workspace synchronization (updateGraphAndExport in src/li.zig) to generate and export map.csv instead of map.toon as the default mapping index format.
- Updated README.md map-builder documentation and examples to show CSV by default and explain the --toon option.

### Fixed

- Resolved deprecation/lint warnings for indexOf in src/map/metadata.zig by replacing them with std.mem.find.
- Restored type safety in LLM API key environment lookup (c.getenv in src/mindmap/llm.zig) using std.mem.span to convert [*:0]const u8 to []const u8 slice.
- Resolved compilation errors inside src/li.zig query subcommands by defining config and result appropriately as const or var based on mutability.

### Added

- Mind-Map RAG subsystem (`src/mindmap/`): reasoning-based vectorless RAG that structures markdown documents as concept mind-maps.
  - `mindmap.zig`: Core data structures (`ConceptNode`, `CausalLink`, `MindMap`) with `jsonStringify`/`fromJson` serialization.
  - `llm.zig`: LLM HTTP client types (`LLMConfig`, `LLMRequest`, `LLMResponse`) for OpenAI-compatible chat completions.
  - `serialize.zig`: Convenience wrappers (`serializeToJson`/`deserializeFromJson`).
  - `builder.zig`: Build pipeline — heading extraction (`extractHeadings`), URL-safe ID generation (`headingId`), and tree construction (`buildHeadingTree`) using indexed parent-mapping with reverse-order child stealing.
  - `query.zig`: Query pipeline — leaf collection, node selection by ID, and context assembly from source document lines.
- `li mind build <file.md>`: CLI subcommand to build a mind-map from any markdown file, written to `mind-map.json` in the workspace root.
- `li mind query "<question>"`: CLI subcommand to query a pre-built mind-map using LLM (set `OPENAI_API_KEY` env var).
- `src/root.zig` re-exports for all mind-map modules.
- Updated `README.md` with mind-map RAG documentation and `li mind build`/`li mind query` command reference.

### Changed

- LLM API integration: `LLMService` with native Zig HTTP client (`std.http.Client`) for real OpenAI-compatible API calls. `li mind query` now makes live HTTP requests.
  - `llm.zig`: Added `LLMService` struct with `chat()` method — sends JSON payload, parses response.
  - `query.zig`: Added `query()` method to `QueryEngine` — collects leaf context, builds tree representation, constructs system/user prompts, calls LLM.
  - `li.zig`: Wired `li mind query` to use `LLMService`; reads `OPENAI_API_KEY` from environment.

### Fixed

- `map.toon` descriptions: removed leading `!` from all Zig file descriptions.
- `extractZigDesc` in `src/map/metadata.zig:78`: `//` fallback now skips `//!` lines.
- `CausalLink.deinit` removed (was misleading no-op; `ConceptNode.deinit` handles all cleanup).
- `MindMap.toJson` unused `alloc` parameter removed.
- ArrayList initialization: replaced non-existent `init(alloc)` with `.empty` pattern across mindmap module.

## [Unreleased] - 2026-05-31

### Added

- Support for .gitignore pattern matching in map-builder, allowing files and directories defined in .gitignore to be automatically excluded from the documentation index.
- Native auto-ignore of .git directory paths during directory scanning.
- Fully configurable command-line interface in the map-builder executable target, exposing `-d`/`--dir` options for custom target folders and `-o`/`--output` options for custom map file destinations, defaulting to "docs" and standard format.
- Comprehensive integration testing suite in `src/map.zig` to verify scanning of custom target folders.
- Support for TOON format (Token-Oriented Object Notation) as the new default output format (map.toon) for documentation mapping, reducing token usage for Large Language Models by 30% to 60%.
- Custom high-performance recursive TOON serialization and string escaping engine for the Entry index tree.
- Command-line argument parser in the map-builder executable target supporting --json, -j, and --format json options to output in standard JSON.
- Dual-format real-time concurrent synchronization in the native watch daemon (li watch and li visualize), instantly updating both map.toon and map.json on any note changes.
- Comprehensive unit tests covering leaf and group node TOON serialization in Entry.writeToon.
- Modularized Documentation Index map building system (map-builder target) that recursively scans documentation files and generates a structured map.json index tree.
- High-precision custom allocation-free streaming JSON serialization (`jsonStringify` method) for the documentation index tree.
- Comprehensive unit tests covering YAML frontmatter extraction, comment parsing, kebab casing, and tree JSON serialization.
- Unified Multi-Format Parser in `src/parser.zig` supporting Markdown (`.md`), Emacs Org-mode (`.org`), Plain Text (`.txt`), and PDF (`.pdf`) extraction.
- Native zlib decompression in PDF stream parser using Zig's `std.compress.flate.Decompress` for `/FlateDecode` streams.
- Comprehensive unit tests covering all new formats in `src/parser.zig` and `src/map/metadata.zig`.
- Native background file watcher daemon accessible via the `li watch` command.
- Live UI rehydration for the Web Visualizer in `index.html`, enabling real-time Force-Graph updates via automatic polling without page reloads.
- Physics-coordinate preservation mechanism to prevent node jumping during graph rehydration.
- Custom glassmorphism toast notification system for real-time visualizer updates.

### Changed

- Optimized map-builder to print "nothing changed, didn't update <path>" when the newly scanned index matches the existing file contents exactly, and default the output file inside the target folder when specified.
- Fixed scanner.zig to ignore index files (.toon, .json, .csv) and hidden files (starting with .) to ensure build idempotency and prevent output files from being scanned recursively as entries.
- Integrated automatic real-time `map.json` regeneration into `updateGraphAndExport`, ensuring `map.json` updates dynamically on any file change detected by the background watch daemon.
- Refactored `src/map.zig` into a modular package architecture consisting of `metadata.zig`, `utils.zig`, `entry.zig`, and `scanner.zig`.
- Updated `AGENTS.md` with detailed Zig 0.16.0 experience notes covering `std.Io.Writer.Allocating` and custom JSON stringification.
- Expanded file walkers and watchers to scan `.org`, `.txt`, and `.pdf` files in addition to `.md`.
- Updated link resolution mapping in `src/graph.zig` to strip all new extensions (`.md`, `.org`, `.txt`, `.pdf`) when building the O(1) fast lookup table.
- Updated the documentation indexing metadata scanner (`src/map/metadata.zig`) to extract titles and descriptions from Org-mode and Plain Text files, and to represent PDFs with structured titles/descriptions.
- Cleaned up legacy warnings (e.g. parameter order, redundant `try`, deprecated `indexOf`/`indexOfScalar`) in the linter rules (`ziglint`).
- Refactored `watchWorkspace` to trigger an initial build at startup and execute `updateGraphAndExport` incrementally upon file creation, update, or deletion events.
- Updated `ARCHITECTURE.md`, `LLM_STRATEGY.md`, and `README.md` to document the file watcher, multi-format support, and rehydration features.

### Activity Log

Added comprehensive Multi-Format Support to Linked-Mind to expand the parser to support Emacs Org-mode (`.org`), Plain Text (`.txt`), and PDF (`.pdf`) extraction.

### Summary of Completed Work

1. Parser & Format Support (`src/parser.zig`):
   - Unified `parseFile` routing: Automatically determines the format based on file extensions.
   - Org-Mode Parser (`parseOrgContent`): Parses `#+title:`, `#+filetags:`, heading-level tags (`:tag1:tag2:`), inline tags (`#tag`), wikilinks, and org-style wikilinks (`[[target][desc]]`).
   - Plain Text Parser (`parseTxtContent`): Extracts the title from the first non-empty line and scans for inline tags and wikilinks.
   - PDF Parser (`parsePdfContent`): Walks the PDF binary data to find uncompressed or `/FlateDecode` streams, decodes zlib-wrapped compressed stream blocks using Zig's `std.compress.flate.Decompress` natively, extracts all text sequences enclosed in parentheses `(...)`, unescapes special characters, and parses the consolidated text for wikilinks and tags.
   - Robust Unit Tests: Added detailed unit tests covering all new parser functions (uncompressed PDF, Org-mode, Plain Text) to ensure flawless parsing.

2. Scanner & Walking Updates (`src/main.zig`, `src/li.zig`, `src/graph.zig`, `src/map/metadata.zig`, `src/map/scanner.zig`, `src/map.zig`):
   - Expanded file walkers and watchers to scan `.org`, `.txt`, and `.pdf` files in addition to `.md`.
   - Updated link resolution mapping in `src/graph.zig` to gracefully strip all new extensions (`.md`, `.org`, `.txt`, `.pdf`) when building the $O(1)$ fast lookup table.
   - Updated the documentation indexing metadata scanner (`src/map/metadata.zig`) to extract titles and descriptions from Org-mode and Plain Text files, and to represent PDFs with structured titles/descriptions.
   - Cleaned up legacy warnings (e.g. parameter order, redundant `try`, deprecated `indexOf`/`indexOfScalar`) in the linter rules (`ziglint`).

3. Documentation Updates:
   - Updated `README.md`, `docs/ARCHITECTURE.md`, and `docs/LLM_STRATEGY.md` to document the newly supported formats.

4. Lean Log Integration:
   - Logged the task successfully under `logs/chat.csv` with a complete automated diff payload.
