# Experimental Features

Experimental APIs that may change in future releases.

## Overview

This guide covers experimental features in the MCP Swift SDK. These APIs are functional but may change without notice in future releases.

> Warning: Experimental APIs are subject to change. Use them with the understanding that updates may require code changes.

## Tasks

Tasks provide a way to track the progress of long-running operations. This feature was introduced in MCP protocol version 2025-11-25.

### Enabling Task Support

#### Server

Enable task support on your server:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)

// Enable with default in-memory storage
await server.experimental.tasks.enable()

// Or with custom configuration
let taskSupport = TaskSupport.inMemory()
await server.experimental.tasks.enable(taskSupport)
```

This automatically:
- Sets the tasks capability
- Registers handlers for `tasks/get`, `tasks/list`, `tasks/cancel`, and `tasks/result`

#### Client

Clients can poll for task status:

```swift
// Get a specific task
let task = try await client.experimental.tasks.get(taskId)

// List all tasks
let tasks = try await client.experimental.tasks.list()

// Cancel a task
try await client.experimental.tasks.cancel(taskId, reason: "User requested")
```

### Task Lifecycle

Tasks move through these states:

| Status | Description |
|--------|-------------|
| `working` | Task is actively being processed |
| `inputRequired` | Task needs user input to continue |
| `completed` | Task finished successfully |
| `failed` | Task encountered an error |
| `cancelled` | Task was cancelled |

Terminal states (`completed`, `failed`, `cancelled`) indicate no further updates will occur.

### Task-Augmented Tool Calls

Tools can declare task support:

```swift
Tool(
    name: "long-operation",
    description: "A long-running operation",
    inputSchema: [...],
    execution: .init(taskSupport: .supported)  // or .required
)
```

Task support levels:
- `.required` - Clients MUST invoke as a task
- `.optional` - Clients MAY invoke as a task
- `.forbidden` - Clients MUST NOT invoke as a task (default)

### Sending Task Status Updates

From within a request handler, send task status updates:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    // Create a task
    let task = MCPTask(
        id: UUID().uuidString,
        status: .working,
        message: "Starting operation..."
    )

    // Send initial status
    try await context.sendTaskStatus(task: task)

    // Do work...
    for i in 1...10 {
        await processChunk(i)

        // Update status
        var updated = task
        updated.message = "Processing chunk \(i)/10"
        try await context.sendTaskStatus(task: updated)
    }

    // Mark complete
    var completed = task
    completed.status = .completed
    completed.message = "Operation finished"
    try await context.sendTaskStatus(task: completed)

    return .init(content: [.text("Done")])
}
```

### Task Metadata

Tasks include metadata that can be read by clients:

```swift
let task = MCPTask(
    id: taskId,
    status: .working,
    message: "Processing...",
    progress: 0.5,           // 50% complete
    progressTotal: 1.0,
    createdAt: Date(),
    updatedAt: Date()
)
```

### Related Task Metadata

Requests, responses, and notifications can include a related task ID:

```swift
// Check if a request is part of a task
if let taskId = params._meta?.relatedTaskId {
    print("This request is part of task: \(taskId)")
}
```

The metadata key is `io.modelcontextprotocol/related-task`.

### Model Immediate Response

When creating a task, provide an immediate response for the model:

```swift
// In _meta, include an immediate response
let meta: [String: Value] = [
    "io.modelcontextprotocol/model-immediate-response": .string(
        "I've started processing your request. This may take a few minutes..."
    )
]
```

This allows the model to acknowledge the request while the actual work continues in the background.

### Custom Task Storage

For production distributed systems, implement custom storage:

```swift
// TaskSupport with custom store and queue
let taskSupport = TaskSupport(
    store: MyDatabaseTaskStore(),
    messageQueue: MyRedisMessageQueue()
)

await server.experimental.tasks.enable(taskSupport)
```

The `TaskStore` protocol requires:
- `store(_:)` - Save a task
- `get(_:)` - Retrieve a task by ID
- `list()` - List all tasks
- `delete(_:)` - Remove a task

The `TaskMessageQueue` protocol requires:
- `enqueue(_:forTask:)` - Queue a message for a task
- `dequeue(forTask:)` - Get next message for a task

### Example: Long-Running Analysis

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    guard params.name == "analyze-data" else { ... }

    let taskId = UUID().uuidString

    // Create and register task
    var task = MCPTask(id: taskId, status: .working, message: "Initializing...")
    try await context.sendTaskStatus(task: task)

    // Phase 1: Load data
    task.message = "Loading data..."
    try await context.sendTaskStatus(task: task)
    let data = try await loadData()

    // Phase 2: Analyze (might need user input)
    if data.needsConfiguration {
        task.status = .inputRequired
        task.message = "Please configure analysis parameters"
        try await context.sendTaskStatus(task: task)

        // Request configuration from user
        let config = try await context.elicit(
            message: "Configure analysis",
            requestedSchema: analysisConfigSchema
        )

        task.status = .working
        task.message = "Analyzing with configuration..."
        try await context.sendTaskStatus(task: task)
    }

    // Phase 3: Complete
    let result = try await analyze(data)

    task.status = .completed
    task.message = "Analysis complete"
    try await context.sendTaskStatus(task: task)

    return .init(content: [.text(result.summary)])
}
```

## See Also

- <doc:ServerGuide>
- <doc:ClientGuide>
