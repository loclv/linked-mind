# `map.csv` - CSV Data Format for mapping knowledge base

Think like a real life events, objects - learn from Buddha's teachings:
- every thing happens has many causes and effects (karma) - strong relationship:
  - graph structure: cause -> effect
- every thing changes over time (anicca): documents evolve, new information emerges:
  - versioning, updates, deprecations is controlled by "git".
- every thing is connected (pratītyasamutpāda): documents are connected through links, references, and relationships - normal relationship:
  - graph structure: document -- document

🪴 Create a simple, single, flat, CSV data format file for graph.
🌟 Headers:

- 'id': document ID (required), UUID for unique identifier, used for Directed Graph, cause and effect.
- 'path': path to the document. (required)
- 'tags': tags to categorize the document, comma separated, wrap with double quotes if multiple tags. Example: `"IT,error,api,auth"`. (required)
- 'summary': summary, context of the document. (required)
- 'problem': problem that was encountered. (optional)
- 'solution': description of the solution, method to fix the problem. (optional)
- 'action': action (web search, etc.) that was taken to fix the problem. (optional)
- 'causeIds': cause document IDs of the document (optional).
  - Example: `"UUID,UUID"`
  - Format: comma separated list of other document IDs, wrap with double quotes if multiple cause document IDs.

- 'effectIds': effect document IDs of the document (optional).
  - Example: `"UUID,UUID"`
  - Format: comma separated list of other document IDs, wrap with double quotes if multiple effect document IDs.
- 'nextPartOfIds': next part of document IDs (optional).
  - Example: `"UUID"`
  - Format: document IDs, wrap with double quotes.
- 'previousPartOfIds': previous part of document IDs (optional).
  - Example: `"UUID"`
  - Format: document IDs, wrap with double quotes.

Row:
- Each row is a document entry.
- No new lines, or use `\n`, just use comma - `,`, dot - `.`, semicolon - `;` to separate information.
