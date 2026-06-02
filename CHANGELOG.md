# CHANGELOG

## [Unreleased] - 2026-06-02

### Added

- **Mind-Map RAG subsystem** (`src/mindmap/`): reasoning-based vectorless RAG that structures markdown documents as concept mind-maps.
  - `mindmap.zig`: Core data structures (`ConceptNode`, `CausalLink`, `MindMap`) with `jsonStringify`/`fromJson` serialization.
  - `llm.zig`: LLM HTTP client types (`LLMConfig`, `LLMRequest`, `LLMResponse`) for OpenAI-compatible chat completions.
  - `serialize.zig`: Convenience wrappers (`serializeToJson`/`deserializeFromJson`).
  - `builder.zig`: Build pipeline — heading extraction (`extractHeadings`), URL-safe ID generation (`headingId`), and tree construction (`buildHeadingTree`) using indexed parent-mapping with reverse-order child stealing.
  - `query.zig`: Query pipeline — leaf collection, node selection by ID, and context assembly from source document lines.
- `li mind build <file.md>`: CLI subcommand to build a mind-map from any markdown file, written to `mind-map.json` in the workspace root.
- `li mind query "<question>"`: CLI subcommand to load and query a pre-built mind-map (preview — full LLM query pipeline requires API integration).
- `src/root.zig` re-exports for all mind-map modules.
- Updated `README.md` with mind-map RAG documentation and `li mind build`/`li mind query` command reference.

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
