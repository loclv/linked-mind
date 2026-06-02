# Mind-Map RAG: Reasoning-Based Retrieval Over Long Documents

Date: 2026-06-01
Status: Draft
Author: Agent

## Overview

A reasoning-based, human-like retrieval RAG system that structures long markdown documents as concept mind-maps (hierarchical section tree + causal cross-links). No vector embeddings, no chunking, no approximate semantic search. Retrieval is done via LLM-guided tree traversal — like reading a mind-map instead of a full textbook.

Inspired by [PageIndex](https://github.com/VectifyAI/PageIndex) but using a concept-map model (typed causal edges) instead of a plain TOC tree.

## Data Structures

### ConceptNode

Represents one concept/section in the mind-map.

- `id: []const u8` — unique identifier (derived from heading slug)
- `title: []const u8` — heading text or LLM-extracted concept title
- `summary: []const u8` — LLM-generated 1-2 sentence summary
- `level: u8` — heading level (0=root, 1= `#`, 2=`##`, etc.)
- `source_start: usize` — line number in original document
- `source_end: usize` — line number in original document
- `children: ?[]ConceptNode` — sub-sections
- `causal_links: ?[]CausalLink` — typed relationships to other nodes

### CausalLink

A typed relationship between two concepts.

- `source: []const u8` — source node ID
- `target: []const u8` — target node ID
- `relation: []const u8` — relation type (causes, leads-to, prevents, enables, etc.)
- `description: []const u8` — brief explanation of the relationship

### MindMap

Top-level container for one document's mind-map.

- `title: []const u8` — document title
- `summary: []const u8` — LLM-generated document-level summary
- `nodes: []ConceptNode` — top-level section nodes (recursive via `children`)

## Build Pipeline (`li mind build <file>`)

Two LLM passes:

### Pass 1: Section Summarization

1. Parse the markdown document using the existing parser (`src/parser.zig`) to extract heading hierarchy.
2. Build a heading tree: `#` → `##` → `###` etc.
3. For each node (section), collect the raw text from `source_start` to `source_end`.
4. Send sections to the LLM in batches for summarization. Each request asks the LLM to return a JSON map of `{section_id: "one or two sentence summary"}`.
5. Merge summaries back into the tree.

### Pass 2: Causal Link Extraction

1. Send the full heading tree (ids + titles + summaries) to the LLM.
2. LLM returns a list of causal relationships between nodes.
3. Each relationship includes source, target, relation type, and a brief description.
4. Merge links into the appropriate parent nodes (links are stored at the lowest common ancestor level, or at the source node's parent).

### Output

Serialize to `mind-map.toon` (default) or `mind-map.json`. Uses existing TOON/JSON serialization patterns from `src/map/entry.zig`.

## Query Pipeline (`li mind query "<question>"`)

Reasoning-based tree traversal — no vectors, no chunks.

### Step 1: Root Relevance

Pass root summary + top-level node summaries + question to LLM. LLM selects which top-level sections are relevant.

### Step 2: Tree Descent

For each relevant section:

- Pass node summary + question to LLM.
- LLM decides: relevant? (continue descending) or not? (prune branch).
- If relevant, recurse into children.
- Track visited nodes and their relevance scores.

### Step 3: Causal Following

For visited leaf nodes, evaluate outgoing causal links:

- Pass link description + question to LLM.
- If link target seems relevant, add target node to the frontier (even if its tree branch was pruned).

### Step 4: Context Assembly

Collect the original document text for all selected nodes. Nodes are sorted by document position to reconstruct a coherent excerpt.

### Step 5: Answer Generation

Final LLM call with:

- The assembled context excerpts
- The user's question
- A prompt asking for a concise answer with section citations

## LLM Integration

### Module: `src/mindmap/llm.zig`

- HTTP client via `std.http.Client` (Zig 0.16.0 std library).
- OpenAI-compatible chat completions API.
- Configurable via `.li/config` TOML file or environment variables:

```toml
[llm]
model = "gpt-4o"
endpoint = "https://api.openai.com/v1/chat/completions"
api_key_env = "OPENAI_API_KEY"  # env var name to read
```

- JSON request/response serialization using `std.json`.
- Retry logic: 3 retries with exponential backoff on 5xx / network errors.
- Request timeout: 120 seconds.

## CLI

New subcommand under the existing `li` binary:

```
li mind build <file>                 # Build mind-map from markdown file
li mind build <file> -o <path>       # Specify output path
li mind build <file> --json          # Output JSON instead of TOON
li mind query "<question>"           # Query mind-map (loads from cwd)
li mind query "<question>" -m <path> # Query specific mind-map file
```

The `li` CLI already has workspace discovery, argument parsing, and subcommand dispatch patterns. The `mind` subcommand follows existing conventions.

## Project Structure

New files under `src/mindmap/`:

```
src/mindmap/
  mindmap.zig    # ConceptNode, CausalLink, MindMap structs + deinit
  builder.zig    # Build pipeline: parse + LLM summarization + causal extraction
  query.zig      # Query pipeline: tree traversal + context assembly
  llm.zig        # HTTP client wrapper for LLM API calls
  serialize.zig  # TOON/JSON read/write for mind-map files

src/li.zig       # Modified: add `li mind` subcommand dispatch
build.zig        # Modified: add mindmap module to build
```

## Testing Strategy

- Unit tests: Data structure deinit/alloc, serialization round-trips, tree traversal logic.
- Mocked LLM layer: `llm.zig` exposes a test-friendly interface that accepts canned JSON responses. Builder and query tests use real document input but mocked LLM output.
- Integration: A small `.md` test fixture with a recorded LLM response. Full pipeline test under `zig build test`.
- Document fixtures: Store sample documents in `test_kb/` for build/query tests.

## Future Considerations

- Incremental rebuilds: Only re-summarize sections whose content changed (via content hash).
- Multi-document workspace: Merge per-file mind-maps into a unified workspace concept graph.
- Relationship type expansion: Beyond causal — supporting, contrasting, sequential.
