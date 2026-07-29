---
name: Map Index
description: The Documentation Index Map System (compiled as the map-builder executable target) scans the target directory (defaulting to the current directory) in your workspace, extracts metadata from each file (frontmatter for Markdown, comments and filenames for Zig), and rebuilds the structured index map representing your knowledge base.
tags:
  - map
  - index
  - json
  - token-efficient

---

# Documentation Index Map System

The Documentation Index Map System (compiled as the map-builder executable target) scans the target directory (defaulting to the current directory) in your workspace, extracts metadata from each file (frontmatter for Markdown, comments and filenames for Zig), and rebuilds the structured index map representing your knowledge base.

## File Formats

By default, the mapping system generates the index map in TOON format (Token-Oriented Object Notation) as map.toon. It also supports exporting to standard JSON format as map.json.

### TOON Format (map.toon)

TOON is a compact, line-oriented, and indentation-based serialization format engineered specifically to optimize structured data for Large Language Models (LLMs). It preserves the lossless semantic data model of JSON but removes syntactic overhead like curly braces, brackets, and redundant quotes.

Key advantages of TOON format:

- High Token Efficiency: Reduces token consumption by 30% to 60% compared to standard JSON, lowering API costs and maximizing context window usage.
- YAML-like Indentation: Employs clean 2-space indentation levels instead of curly braces to establish hierarchy.
- LLM-friendly Structure: Uses explicit array lengths [N] and field list headers to provide clear guardrails that help LLMs parse and validate structures reliably.

Example of map.toon index structure:

[2]:

  - description: Root Directory Description
    path: docs/
    children[1]:
      - name: welcome-node
        description: Welcome to your Knowledge Base
        path: docs/welcome.md
  - name: settings-node
    description: Configuration Settings
    path: docs/config.txt

### JSON Format (map.json)

Standard JSON output format is fully supported. It uses standard brackets and braces with 2-space indentation, making it suitable for classic web APIs, parsers, and browser-based client applications.

Example of map.json index structure:

[
  {
    "description": "Root Directory Description",
    "path": "docs/",
    "children": [
      {
        "name": "welcome-node",
        "description": "Welcome to your Knowledge Base",
        "path": "docs/welcome.md"
      }
    ]
  },
  {
    "name": "settings-node",
    "description": "Configuration Settings",
    "path": "docs/config.txt"
  }
]

## CLI Target map-builder Usage

The map-builder target binary can be executed directly to scan a target directory and generate index files.

To optimize disk performance and keep console outputs clean, map-builder compares newly scanned and built indexes with the existing files. The index file is only written to disk and an update message printed when actual changes in the contents or entry list have occurred. Otherwise, it runs silently.

### Auto Ignore & Gitignore Support

To ensure that internal build artifacts, system files, caches, and VCS directories are kept out of generated index maps, map-builder features a high-performance built-in ignore engine:

- Recursive .git Exclusion: The scanning walker natively ignores any .git directories encountered at any depth.
- Standard .gitignore Matching: Before starting a directory walk, map-builder parses the .gitignore file present in the scanned directory (or the root workspace). It automatically applies standard matching rules, including trailing slash directory matches, glob wildcards, and anchored root paths, to skip matching files and folders.

### Basic Usage

Generate map.toon from the current directory:

```bash
zig-out/bin/map-builder
```

Generate map.json (JSON option) from the current directory:
You can explicitly request the JSON format by passing --json, -j, or --format json:

```bash
zig-out/bin/map-builder --json
# or
zig-out/bin/map-builder -j
# or
zig-out/bin/map-builder --format json
```

### Advanced Usage

You can customize the target folder to scan as a positional argument or via `-d`/`--dir` options. You can also specify a custom output destination using `-o`/`--output`.

```bash
# Scan a custom folder named "my_kb" and output to "map.toon" in cwd
zig-out/bin/map-builder my_kb

# Scan a custom folder named "my_kb" using the explicit --dir flag
zig-out/bin/map-builder --dir my_kb

# Scan "my_kb" and output in JSON format
zig-out/bin/map-builder my_kb --json

# Scan "my_kb" and save the generated index to a custom location
zig-out/bin/map-builder my_kb --output build/custom_map.toon

# Print version information
zig-out/bin/map-builder -v
# or
zig-out/bin/map-builder --version
```

Use `zig-out/bin/map-builder --help` or `-h` to view the comprehensive help and usage details.

## Background Watch Daemon Integration

The native watch daemon (run via the command li watch or li visualize) monitors your workspace for note creation, modification, or deletion events.

Whenever changes are detected:

- The watcher automatically and incrementally re-scans the docs directory.
- It concurrently regenerates both map.toon and map.json in sync.
- This ensures that downstream LLM pipelines expecting map.toon and visualizers expecting map.json always receive the latest representation of your workspace.
