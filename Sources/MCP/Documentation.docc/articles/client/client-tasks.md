# Tasks

Call tools as background tasks and poll for results

## Overview

The Tasks feature enables long-running tool calls that return immediately with a task reference. Instead of blocking until completion, you can poll for status updates and retrieve results when ready.

> Note: This is an experimental API that may change without notice.

## Calling a Tool as a Task

Use ``Client/experimental-swift.property`` to access task APIs:

```swift
let createResult = try await client.experimental.tasks.callToolAsTask(
    name: "process_large_file",
    arguments: ["file": "/path/to/large.csv"]
)

print("Task started: \(createResult.task.taskId)")
print("Initial status: \(createResult.task.status)")
```

## Polling for Status

Poll the task until it completes:

```swift
for try await status in await client.experimental.tasks.pollTask(taskId) {
    print("Status: \(status.task.status)")
    if let message = status.task.statusMessage {
        print("Message: \(message)")
    }
}
// Task is now terminal (completed, failed, or cancelled)
```

Or wait for completion directly:

```swift
let finalStatus = try await client.experimental.tasks.pollUntilTerminal(taskId)
```

## Getting Task Results

Once a task is complete, retrieve the result:

```swift
// Get the raw result
let result = try await client.experimental.tasks.getTaskResult(taskId)

// Or get a typed tool result
let toolResult = try await client.experimental.tasks.getToolResult(taskId)
for content in toolResult.content {
    switch content {
    case .text(let text, _, _):
        print("Result: \(text)")
    default:
        break
    }
}
```

## Streaming Tool Calls

Combine task creation, polling, and result retrieval in a single stream:

```swift
for try await message in await client.experimental.tasks.callToolStream(name: "myTool") {
    switch message {
    case .taskCreated(let task):
        print("Task started: \(task.taskId)")
    case .taskStatus(let task):
        print("Status: \(task.status)")
        if let message = task.statusMessage {
            print("Message: \(message)")
        }
    case .result(let result):
        print("Completed with \(result.content.count) content blocks")
    case .error(let error):
        print("Error: \(error)")
    }
}
```

## Convenience Methods

Call a tool and wait for the result in one call:

```swift
let result = try await client.experimental.tasks.callToolAsTaskAndWait(
    name: "slow_tool",
    arguments: ["input": "data"]
)
```

## Managing Tasks

### List Tasks

```swift
let result = try await client.experimental.tasks.listTasks()
for task in result.tasks {
    print("\(task.taskId): \(task.status)")
}
```

### Get Task Status

```swift
let status = try await client.experimental.tasks.getTask(taskId)
print("Status: \(status.task.status)")
```

### Cancel a Task

```swift
let result = try await client.experimental.tasks.cancelTask(taskId)
print("Cancelled: \(result.task.status)")
```

## Task Time-to-Live

Specify how long task results should be retained:

```swift
let createResult = try await client.experimental.tasks.callToolAsTask(
    name: "generate_report",
    arguments: [:],
    ttl: 300000  // Keep result for 5 minutes
)
```

## Handling Task Requests from Servers

If your client needs to handle task requests from servers (bidirectional task support), enable task handlers:

```swift
let taskSupport = ClientTaskSupport.inMemory(handlers: ExperimentalClientTaskHandlers(
    getTask: { taskId in
        // Return task status
        GetTask.Result(task: myTaskStore.get(taskId))
    },
    listTasks: { cursor in
        // Return list of tasks
        ListTasks.Result(tasks: myTaskStore.list())
    },
    cancelTask: { taskId in
        // Cancel the task
        myTaskStore.cancel(taskId)
        return CancelTask.Result(task: myTaskStore.get(taskId))
    }
))

client.enableTaskHandlers(taskSupport)
```

## See Also

- <doc:client-setup>
- <doc:client-tools>
- <doc:server-tasks>
- ``Client``
