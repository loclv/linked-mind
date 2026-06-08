---
name: add-markdown
description: Guidelines for agents on how to add and format markdown files, enforcing metadata headers, emoji avoidance, and layout rules.
tags: [markdown, documentation, rules, formatting]
---
# Add Markdown File

When creating a new markdown file in the workspace, follow these rules:

## Metadata
Include a YAML frontmatter block at the very beginning of the file:
```yaml
---
name: file-name-or-topic
description: Clear summary of the document's purpose.
tags: [tag1, tag2]
---
```

## Styling & Syntax
- Do not use emojis anywhere in the document.
- Do not use bold text syntax (like `**text**` or `__text__`). Use headers, lists, or code blocks/backticks for emphasis.
- Maintain flat, clean headers (`#`, `##`, `###`).
- Use standard markdown table syntax when presenting structured data.
- Keep links formatted with clear link text matching the file name, without backticks.
