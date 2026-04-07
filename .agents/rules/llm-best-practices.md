---
trigger: always_on
---

# LLM Best Practices

## API Integration

### Error Handling

- Always log error messages when catching LLM API errors
- Never use `catch unreachable` for operations that can fail
- Implement proper retry logic for network failures
- Validate API responses before processing

### Memory Management

- Free allocated response data after processing
- Use proper allocator patterns for request/response handling
- Clean up temporary buffers after API calls

### Request/Response Patterns

- Use structured JSON parsing for API responses
- Validate required fields before using response data
- Implement timeout handling for long-running requests
- Handle rate limiting and API quota limits

### Model Configuration

- Use configurable model names from config files
- Support model fallbacks for reliability
- Validate model availability before use
- Log model selection for debugging

### Security

- Never hardcode API keys in source code
- Use environment variables or config files for credentials
- Implement proper token refresh mechanisms
- Validate input data before sending to LLM APIs

### Performance

- Batch multiple requests when possible
- Implement request caching for repeated queries
- Use connection pooling for HTTP clients
- Monitor API usage and costs

### Testing

- Test error handling scenarios
- Validate request formatting
- Test rate limiting behavior

## Integration Patterns

### Error Recovery

```zig
const llm_response = makeLLMRequest(prompt) catch |err| {
    log.err("LLM request failed: {any}", .{err});
    
    // Implement retry logic
    if (shouldRetry(err)) {
        return retryLLMRequest(prompt, retry_count + 1);
    }
    
    // Fallback behavior
    return handleLLMFailure(err);
};
```
