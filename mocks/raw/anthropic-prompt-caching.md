# Prompt Caching with the Claude API

Prompt caching lets you store and reuse context within your prompts, reducing latency by >2x and costs by up to 90% for repetitive tasks.

There are two ways to enable prompt caching:

- **Automatic caching** (recommended): Add a single `cache_control` field at the top level of your request. The system automatically manages cache breakpoints for you.
- **Explicit cache breakpoints**: Place `cache_control` on individual content blocks for fine-grained control over exactly what gets cached.

## Setup

```python
import time
import anthropic

client = anthropic.Anthropic()
MODEL_NAME = "claude-sonnet-4-6"
TIMESTAMP = int(time.time())
```

## Example 1: Automatic caching (single turn)

Automatic caching is the easiest way to get started. Add `cache_control={"type": "ephemeral"}` at the **top level** of your `messages.create()` call and the system handles the rest — automatically placing the cache breakpoint on the last cacheable block.

We compare three scenarios:
1. **No caching** — baseline
2. **First cached call** — creates the cache entry (similar timing to baseline)
3. **Second cached call** — reads from cache (the big speedup)

### Baseline: no caching

```python
start = time.time()
baseline_response = client.messages.create(
    model=MODEL_NAME,
    max_tokens=300,
    messages=[
        {
            "role": "user",
            "content": str(TIMESTAMP)
            + "<book>"
            + book_content
            + "</book>"
            + "\n\nWhat is the title of this book? Only output the title.",
        }
    ],
)
baseline_time = time.time() - start
```

### First call with automatic caching (cache write)

The only change is the top-level `cache_control` parameter. The first call writes to the cache, so timing is similar to the baseline.

```python
start = time.time()
write_response = client.messages.create(
    model=MODEL_NAME,
    max_tokens=300,
    cache_control={"type": "ephemeral"},  # <-- one-line change
    messages=[
        {
            "role": "user",
            "content": str(TIMESTAMP)
            + "<book>"
            + book_content
            + "</book>"
            + "\n\nWhat is the title of this book? Only output the title.",
        }
    ],
)
write_time = time.time() - start
```

### Second call with automatic caching (cache hit)

Same request again. This time the cached prefix is reused, so you should see a significant speedup.

```python
start = time.time()
hit_response = client.messages.create(
    model=MODEL_NAME,
    max_tokens=300,
    cache_control={"type": "ephemeral"},
    messages=[
        {
            "role": "user",
            "content": str(TIMESTAMP)
            + "<book>"
            + book_content
            + "</book>"
            + "\n\nWhat is the title of this book? Only output the title.",
        }
    ],
)
hit_time = time.time() - start

# Results:
# No caching:     4.89s
# Cache write:    4.28s
# Cache hit:      1.48s
# Speedup:        3.3x
```

## Example 2: Automatic caching in a multi-turn conversation

Automatic caching really shines in multi-turn conversations. The cache breakpoint **automatically moves forward** as the conversation grows — you don't need to manage any markers yourself.

| Request | Cache behavior |
|---------|----------------|
| Request 1 | System + User:A cached (write) |
| Request 2 | System + User:A read from cache; Asst:B + User:C written to cache |
| Request 3 | System through User:C read from cache; Asst:D + User:E written to cache |

```python
system_message = f"{TIMESTAMP} <file_contents> {book_content} </file_contents>"

questions = [
    "What is the title of this novel?",
    "Who are Mr. and Mrs. Bennet?",
    "What is Netherfield Park?",
    "What is the main theme of this novel?",
]

conversation = []

for i, question in enumerate(questions, 1):
    conversation.append({"role": "user", "content": question})

    start = time.time()
    response = client.messages.create(
        model=MODEL_NAME,
        max_tokens=300,
        cache_control={"type": "ephemeral"},  # automatic caching
        system=system_message,
        messages=conversation,
    )
    elapsed = time.time() - start

    assistant_reply = response.content[0].text
    conversation.append({"role": "assistant", "content": assistant_reply})
```

After the first turn, nearly 100% of input tokens are read from cache on every subsequent turn.

## Example 3: Explicit cache breakpoints

For more control, you can place `cache_control` directly on individual content blocks. This is useful when:

- You want to cache different sections with different TTLs
- You need to cache a system prompt independently from message content
- You want fine-grained control over what gets cached

You can also combine both approaches: use explicit breakpoints for your system prompt while automatic caching handles the conversation.

```python
# Explicit cache breakpoint on the book content block
response = client.messages.create(
    model=MODEL_NAME,
    max_tokens=300,
    system=[
        {
            "type": "text",
            "text": system_prompt,
        },
        {
            "type": "text",
            "text": book_content,
            "cache_control": {"type": "ephemeral"},  # explicit breakpoint
        },
    ],
    messages=conversation,
)
```
