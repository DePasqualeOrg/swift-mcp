# Advanced

Configure timeouts, handle cancellation, and track progress

## Overview

This guide covers advanced client features including request timeouts, cancellation handling, and progress tracking for long-running operations.

## Request Timeouts

Configure timeouts using ``Client/RequestOptions``:

```swift
// Simple timeout
let result = try await client.send(
    ListTools.request(.init()),
    options: RequestOptions(timeout: .seconds(30))
)
```

### Default Timeout

Use the predefined default timeout (60 seconds):

```swift
let result = try await client.send(
    CallTool.request(.init(name: "slow_tool")),
    options: .withDefaultTimeout
)
```

### No Timeout

Disable timeout for requests that may take a long time:

```swift
let result = try await client.send(
    CallTool.request(.init(name: "very_slow_tool")),
    options: .noTimeout
)
```

### Progress-Aware Timeouts

For long-running operations that report progress, reset the timeout each time progress is received:

```swift
let result = try await client.send(
    CallTool.request(.init(name: "long_operation")),
    options: RequestOptions(
        timeout: .seconds(30),
        resetTimeoutOnProgress: true
    )
) { progress in
    print("Progress: \(progress.value)")
}
```

This allows operations to take longer than the timeout as long as they keep reporting progress.

### Maximum Total Timeout

Combine progress-aware timeouts with a hard limit:

```swift
let result = try await client.send(
    CallTool.request(.init(name: "long_operation")),
    options: RequestOptions(
        timeout: .seconds(30),         // Reset on progress
        resetTimeoutOnProgress: true,
        maxTotalTimeout: .minutes(10)  // Hard limit
    )
) { progress in
    print("Progress: \(progress.value) / \(progress.total ?? 100)")
}
```

## Progress Tracking

### Convenience Method

For tool calls, ``Client/callTool(name:arguments:onProgress:)`` automatically manages progress tokens:

```swift
let result = try await client.callTool(
    name: "process_data",
    arguments: ["input": "data.csv"],
    onProgress: { progress in
        print("Progress: \(progress.value) / \(progress.total ?? 100)")
    }
)
```

### Low-Level Progress

For other request types or when you need full control, use ``Client/send(_:onProgress:)`` directly:

```swift
let result = try await client.send(
    CallTool.request(.init(name: "process_data")),
    onProgress: { progress in
        print("Progress: \(progress.value)")
        if let total = progress.total {
            let percent = (progress.value / total) * 100
            print("Percent complete: \(percent)%")
        }
        if let message = progress.message {
            print("Status: \(message)")
        }
    }
)
```

The ``Progress`` struct contains:

- `value`: The current progress (increases monotonically)
- `total`: The total value, if known
- `message`: An optional status message

### Progress with Options

Combine progress tracking with request options:

```swift
let result = try await client.send(
    CallTool.request(.init(name: "process_data")),
    options: RequestOptions(
        timeout: .seconds(60),
        resetTimeoutOnProgress: true
    ),
    onProgress: { progress in
        updateProgressBar(progress.value, total: progress.total)
    }
)
```

## Cancellation

### Handling Timeout Cancellation

When a request times out, the client automatically sends a cancellation notification to the server:

```swift
do {
    let result = try await client.send(
        CallTool.request(.init(name: "slow_tool")),
        options: RequestOptions(timeout: .seconds(5))
    )
} catch let error as MCPError {
    if case .requestTimeout(let timeout, _) = error {
        print("Request timed out after \(timeout)")
        // Server has been notified of cancellation
    }
}
```

### Manual Cancellation

Cancel requests using Swift's task cancellation:

```swift
let task = Task {
    try await client.callTool(name: "long_operation")
}

// Later, cancel the request
task.cancel()

do {
    let result = try await task.value
} catch is CancellationError {
    print("Request was cancelled")
}
```

## Concurrent Requests

Make multiple requests concurrently using Swift concurrency:

```swift
async let tools = client.listTools()
async let resources = client.listResources()
async let prompts = client.listPrompts()

let (toolResult, resourceResult, promptResult) = try await (tools, resources, prompts)
```

Or using a task group:

```swift
let results = try await withThrowingTaskGroup(of: String.self) { group in
    for toolName in toolNames {
        group.addTask {
            let result = try await client.callTool(name: toolName)
            // Process result
            return toolName
        }
    }

    var completed: [String] = []
    for try await name in group {
        completed.append(name)
    }
    return completed
}
```

## Notification Handler Dispatch

Notification handlers registered via ``Client/onNotification(_:handler:)`` are dispatched outside the message loop. This means handlers can safely make requests back to the server (such as calling `listTools()` in response to a `ToolListChangedNotification`) without deadlocking the message processing pipeline.

## See Also

- <doc:client-setup>
- <doc:client-tools>
- ``MCPClient``
- ``Client``
- ``Client/RequestOptions``
