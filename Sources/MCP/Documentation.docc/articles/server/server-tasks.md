# Tasks

Enable long-running operations with task tracking

## Overview

Tasks provide a way to track the progress of long-running server operations. Clients can poll for status updates and retrieve results when complete.

> Note: This is an experimental API that may change without notice.

## Enabling Task Support

Enable task support on your server:

```swift
let server = Server(
    name: "MyServer",
    version: "1.0.0",
    capabilities: .init(tools: .init())
)

// Enable with default in-memory storage
await server.experimental.tasks.enable()
```

This automatically:
- Sets the tasks capability
- Registers handlers for `tasks/get`, `tasks/list`, `tasks/cancel`, and `tasks/result`

## Task-Augmented Tools

Declare that a tool supports task execution:

```swift
Tool(
    name: "long-operation",
    description: "A long-running operation",
    inputSchema: [...],
    execution: .init(taskSupport: .optional)
)
```

Task support levels:
- `.required`: Clients MUST invoke as a task
- `.optional`: Clients MAY invoke as a task
- `.forbidden`: Clients MUST NOT invoke as a task (default)

## Sending Task Status Updates

Update task status during execution:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    let taskId = UUID().uuidString

    // Create initial task
    var task = createTaskState(metadata: TaskMetadata(), taskId: taskId)
    task.statusMessage = "Starting..."
    try await context.sendTaskStatus(task: task)

    // Process with updates
    for i in 1...10 {
        await processChunk(i)

        task.statusMessage = "Processing chunk \(i)/10"
        try await context.sendTaskStatus(task: task)
    }

    // Mark complete
    task.status = .completed
    task.statusMessage = "Done"
    try await context.sendTaskStatus(task: task)

    return CallTool.Result(content: [.text("Complete")])
}
```

## Task States

Tasks move through these states:

| Status | Description |
|--------|-------------|
| `working` | Task is actively being processed |
| `inputRequired` | Task needs user input to continue |
| `completed` | Task finished successfully |
| `failed` | Task encountered an error |
| `cancelled` | Task was cancelled |

Terminal states (`completed`, `failed`, `cancelled`) indicate no further updates.

## Requesting User Input

Tasks can pause for user input:

```swift
// Set status to input required
task.status = .inputRequired
task.statusMessage = "Please provide configuration"
try await context.sendTaskStatus(task: task)

// Request input via elicitation
let result = try await context.elicit(
    message: "Configure the operation",
    requestedSchema: configSchema
)

// Resume processing
task.status = .working
task.statusMessage = "Continuing with configuration..."
try await context.sendTaskStatus(task: task)
```

## Task Metadata

Create tasks with timing and polling information:

```swift
let now = ISO8601DateFormatter().string(from: Date())
let task = MCPTask(
    taskId: taskId,
    status: .working,
    ttl: nil,                  // Optional time-to-live
    createdAt: now,
    lastUpdatedAt: now,
    pollInterval: 500,         // Suggested polling interval (ms)
    statusMessage: "Processing..."
)
```

## Related Task Metadata

Check if a request is part of an existing task:

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    if let taskId = context.taskId {
        print("This request is part of task: \(taskId)")
    }
    // ...
}
```

## Custom Task Storage

For production systems, implement custom storage:

```swift
let taskSupport = TaskSupport(
    store: MyDatabaseTaskStore(),
    messageQueue: MyRedisMessageQueue()
)

await server.experimental.tasks.enable(taskSupport)
```

### TaskStore Protocol

Implement these methods:
- `createTask(metadata:taskId:)`: Create a new task
- `getTask(taskId:)`: Retrieve a task by ID
- `updateTask(taskId:status:statusMessage:)`: Update task status
- `listTasks(cursor:)`: List all tasks with pagination
- `deleteTask(taskId:)`: Remove a task

### TaskMessageQueue Protocol

Implement these methods:
- `enqueue(taskId:message:maxSize:)`: Queue a message for a task
- `dequeue(taskId:)`: Get next message for a task
- `dequeueAll(taskId:)`: Remove all messages for a task

## Complete Example

```swift
await server.withRequestHandler(CallTool.self) { params, context in
    guard params.name == "analyze-data" else { ... }

    let taskId = UUID().uuidString
    var task = createTaskState(metadata: TaskMetadata(), taskId: taskId)

    // Phase 1: Load data
    task.statusMessage = "Loading data..."
    try await context.sendTaskStatus(task: task)
    let data = try await loadData()

    // Phase 2: May need configuration
    if data.needsConfiguration {
        task.status = .inputRequired
        task.statusMessage = "Configuration required"
        try await context.sendTaskStatus(task: task)

        let config = try await context.elicit(
            message: "Configure analysis parameters",
            requestedSchema: configSchema
        )

        task.status = .working
        task.statusMessage = "Analyzing with configuration..."
        try await context.sendTaskStatus(task: task)
    }

    // Phase 3: Analyze
    let result = try await analyze(data)

    // Complete
    task.status = .completed
    task.statusMessage = "Analysis complete"
    try await context.sendTaskStatus(task: task)

    return CallTool.Result(content: [.text(result.summary)])
}
```

## See Also

- <doc:server-setup>
- <doc:server-tools>
- <doc:client-tasks>
- ``Server``
