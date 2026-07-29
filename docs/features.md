---
name: Features
description: Overview of features, tools, and CLI subcommands in Linked-Mind.
tags:
  - features
  - documentation
  - overview
---

# Features

Linked-Mind is a high-performance Knowledge Base (KB) tool written in Zig. It bridges static Markdown/Org/Txt files and LLM context by representing documents as a Knowledge Graph.

## Core Features

- Multi-Format Document Scanning: Unified scanner supporting Markdown (`.md`), Emacs Org-mode (`.org`), Plain Text (`.txt`), and PDF (`.pdf`) document extraction.
- Wikilink Extraction: Automatically parses `[[Internal Links]]` (including Org-style `[[target][description]]`) to build bidirectional graph edges between knowledge nodes across all formats.
- Flexible Tagging System: Supports inline `#hashtags` as well as Org-mode file tags (`#+filetags:`) and heading tags (`:tag1:tag2:`).
- Automatic Path Resolution: Resolves human-readable wikilinks to exact workspace relative file paths, ignoring extensions and directory depth.
- High-Performance Incremental Scanner: Caches node metadata using SHA-256 hashes and file modification timestamps (`mtime`) in `.li/cache.json` for instant re-scanning.
- LLM Export Engine: Generates a consolidated `llm_knowledge.md` document structured specifically for LLM context ingestion with optional tag and status filtering.

## Analysis & Search Tools

- Hybrid Search Engine: Combines local TF-IDF vector similarity with Breadth-First Search (BFS) graph traversal to perform contextually constrained semantic queries (`li search`).
- Local TF-IDF Embeddings Engine: Pure-Zig text embedding and vector similarity engine operating without external API dependencies or heavy runtime models.
- Graph Traversal & Path Discovery: Computes shortest paths between concepts (`li path`).
- Community Detection & Clustering: Identifies related clusters of knowledge nodes (`li clusters`).
- Node Similarity & Link Suggestion: Discovers unlinked but content-similar nodes using similarity thresholding (`li similar`, `li suggest`).
- Garbage Collection & Maintenance: Detects isolated orphan nodes and island subgraphs (`li gc`).

## Mind-Map RAG System

- Concept Mind-Map Builder: Parses Markdown heading hierarchies into concept section trees and uses LLM integration to discover causal cross-links (`li mind build`).
- Mind-Map Reasoning Query Engine: Performs reasoning queries across concept trees via LLM-guided traversal without vector databases or chunking (`li mind query`).

## Interactive Dashboard & Background Services

- Web Visualizer Dashboard: Exports graph visualization datasets (`graph.json`) featuring live UI rehydration and real-time D3 physics simulation.
- Native File Watcher Daemon: Real-time background directory monitor watching document changes across all supported extensions and outputting JSON events (`li watch`).
- Built-in HTTP Server: Serves persistent web visualizer UI and REST API endpoints for graph data (`li serve`).

## Standalone Utilities & Executables

- Documentation Index Map Builder (`map-builder`): Scans workspace directories and generates hierarchical map indexes in flat CSV (`map.csv`), JSON (`map.json`), or TOON (`map.toon`) format with standard `.gitignore` rule evaluation. Supports custom target directories (`-d`/`--dir`), custom output paths (`-o`/`--output`), format selection (`--json`, `--toon`, `--format`), and version output (`-v`/`--version`).
- Markdown Metadata Linter (`mdlint`): Validates Markdown documents against frontmatter metadata requirements (`name`, `description`, `tags`) and reports formatted error diagnostics.
