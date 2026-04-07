# Threading Best Practices for Zig

## Thread Management

- Always join threads in `deinit()` functions
- Use `std.Thread.spawn` with explicit function and parameters
- Store thread handles in slices for cleanup

## Shared Data Protection

- Use `std.Thread.Mutex` for protecting shared data
- Use `std.Thread.Condition` for thread synchronization
- Use `std.atomic.Value` for simple atomic flags

## Message Queues

- Use `std.ArrayList` with mutex protection for thread-safe queues
- Always pass allocator to ArrayList operations in Zig 0.15
- Signal condition variable after adding items to queue

## Shutdown Patterns

- Use atomic shutdown flag: `std.atomic.Value(bool)`
- Check shutdown flag regularly in thread loops
- Graceful shutdown: signal all threads, then join them

## Worker Thread Pattern

```zig
// Example worker thread
fn worker(self: *ThreadPool) void {
    while (!self.shutdown_flag.load(.seq_cst)) {
        // Acquire lock
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Wait for work or shutdown
        while (self.queue.items.len == 0 and !self.shutdown_flag.load(.seq_cst)) {
            self.cond.wait(&self.mutex);
        }
        
        // Process work
        if (self.queue.popOrNull()) |item| {
            self.mutex.unlock();
            self.processItem(item);
            self.mutex.lock();
        }
    }
}
```

## Signal Handler Thread Safety

- Signal handlers cannot use mutexes or allocate memory
- Use atomic flags to communicate between signal handler and main code
- Keep signal handlers minimal and fast

## Common Pitfalls

- Don't forget to unlock mutexes (use `defer`)
- Don't access shared data without proper synchronization
- Don't use blocking operations in signal handlers
- Don't create threads in loops without storing handles

## Performance Considerations

- Use thread pools instead of creating/destroying threads frequently
- Consider lock-free data structures for high-contention scenarios
- Profile to determine optimal number of worker threads
