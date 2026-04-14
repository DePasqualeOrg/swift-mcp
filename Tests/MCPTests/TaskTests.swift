// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import Testing

// MARK: - Task Type Tests

struct TaskTypeTests {
    // MARK: - TaskStatus Tests

    @Test(
        arguments: [
            (TaskStatus.working, "working"),
            (TaskStatus.inputRequired, "input_required"),
            (TaskStatus.completed, "completed"),
            (TaskStatus.failed, "failed"),
            (TaskStatus.cancelled, "cancelled"),
        ],
    )
    func `TaskStatus raw values match spec`(testCase: (status: TaskStatus, rawValue: String)) {
        #expect(testCase.status.rawValue == testCase.rawValue)
    }

    @Test(
        arguments: [
            (TaskStatus.working, false),
            (TaskStatus.inputRequired, false),
            (TaskStatus.completed, true),
            (TaskStatus.failed, true),
            (TaskStatus.cancelled, true),
        ],
    )
    func `TaskStatus.isTerminal returns correct values`(testCase: (status: TaskStatus, isTerminal: Bool)) {
        #expect(testCase.status.isTerminal == testCase.isTerminal)
    }

    @Test
    func `isTerminalStatus helper function matches TaskStatus.isTerminal`() {
        #expect(isTerminalStatus(.working) == false)
        #expect(isTerminalStatus(.inputRequired) == false)
        #expect(isTerminalStatus(.completed) == true)
        #expect(isTerminalStatus(.failed) == true)
        #expect(isTerminalStatus(.cancelled) == true)
    }

    @Test
    func `TaskStatus encodes and decodes correctly`() throws {
        let statuses: [TaskStatus] = [.working, .inputRequired, .completed, .failed, .cancelled]

        for status in statuses {
            let data = try JSONEncoder().encode(status)
            let decoded = try JSONDecoder().decode(TaskStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    // MARK: - MCPTask Tests

    @Test
    func `MCPTask encoding and decoding with all fields`() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:05Z",
            pollInterval: 1000,
            statusMessage: "Processing...",
        )

        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(MCPTask.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .working)
        #expect(decoded.ttl == 60000)
        #expect(decoded.createdAt == "2024-01-15T10:30:00Z")
        #expect(decoded.lastUpdatedAt == "2024-01-15T10:30:05Z")
        #expect(decoded.pollInterval == 1000)
        #expect(decoded.statusMessage == "Processing...")
    }

    @Test
    func `MCPTask with nil ttl encodes as null (per spec requirement)`() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:05Z",
        )

        let data = try JSONEncoder().encode(task)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        // Per MCP spec, ttl must always be present (encoded as null when nil)
        #expect(jsonString.contains("\"ttl\":null"))
    }

    @Test
    func `MCPTask decodes ttl as null correctly`() throws {
        let jsonString = """
        {
            "taskId": "task-123",
            "status": "working",
            "ttl": null,
            "createdAt": "2024-01-15T10:30:00Z",
            "lastUpdatedAt": "2024-01-15T10:30:05Z"
        }
        """

        let data = try #require(jsonString.data(using: .utf8))
        let task = try JSONDecoder().decode(MCPTask.self, from: data)

        #expect(task.ttl == nil)
    }

    @Test
    func `MCPTask with optional fields omitted`() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .completed,
            ttl: 30000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:10Z",
        )

        let data = try JSONEncoder().encode(task)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        // Optional fields should not be present
        #expect(!jsonString.contains("pollInterval"))
        #expect(!jsonString.contains("statusMessage"))
    }

    // MARK: - TaskMetadata Tests

    @Test
    func `TaskMetadata encoding and decoding`() throws {
        let metadata = TaskMetadata(ttl: 60000)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TaskMetadata.self, from: data)

        #expect(decoded.ttl == 60000)
    }

    @Test
    func `TaskMetadata with nil ttl`() throws {
        let metadata = TaskMetadata(ttl: nil)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TaskMetadata.self, from: data)

        #expect(decoded.ttl == nil)
    }

    // MARK: - RelatedTaskMetadata Tests

    @Test
    func `RelatedTaskMetadata encoding and decoding`() throws {
        let metadata = RelatedTaskMetadata(taskId: "task-456")

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RelatedTaskMetadata.self, from: data)

        #expect(decoded.taskId == "task-456")
    }

    // MARK: - Metadata Key Tests

    @Test
    func `relatedTaskMetaKey has correct value`() {
        #expect(relatedTaskMetaKey == "io.modelcontextprotocol/related-task")
    }

    @Test
    func `modelImmediateResponseKey has correct value`() {
        #expect(modelImmediateResponseKey == "io.modelcontextprotocol/model-immediate-response")
    }
}

// MARK: - CreateTaskResult Tests

struct CreateTaskResultTests {
    @Test
    func `CreateTaskResult encoding and decoding`() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
            pollInterval: 1000,
        )

        let result = CreateTaskResult(task: task)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)

        #expect(decoded.task.taskId == "task-123")
        #expect(decoded.task.status == .working)
        #expect(decoded.task.ttl == 60000)
        #expect(decoded.task.pollInterval == 1000)
    }

    @Test
    func `CreateTaskResult with model immediate response`() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
        )

        let result = CreateTaskResult(task: task, modelImmediateResponse: "Starting task...")

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)

        #expect(decoded._meta?[modelImmediateResponseKey]?.stringValue == "Starting task...")
    }

    @Test
    func `CreateTaskResult with _meta`() throws {
        let task = MCPTask(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
        )

        let meta: [String: Value] = [
            "custom": .string("value"),
            modelImmediateResponseKey: .string("Processing your request..."),
        ]

        let result = CreateTaskResult(task: task, _meta: meta)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CreateTaskResult.self, from: data)

        #expect(decoded._meta?["custom"]?.stringValue == "value")
        #expect(decoded._meta?[modelImmediateResponseKey]?.stringValue == "Processing your request...")
    }
}

// MARK: - GetTask Tests

struct GetTaskMethodTests {
    @Test
    func `GetTask.name is correct`() {
        #expect(GetTask.name == "tasks/get")
    }

    @Test
    func `GetTask.Parameters encoding and decoding`() throws {
        let params = GetTask.Parameters(taskId: "task-123")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(GetTask.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
    }

    @Test
    func `GetTask.Result encoding and decoding`() throws {
        let result = GetTask.Result(
            taskId: "task-123",
            status: .completed,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:30Z",
            pollInterval: 1000,
            statusMessage: "Done",
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(GetTask.Result.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .completed)
        #expect(decoded.ttl == 60000)
        #expect(decoded.pollInterval == 1000)
        #expect(decoded.statusMessage == "Done")
    }

    @Test
    func `GetTask.Result from MCPTask`() {
        let task = MCPTask(
            taskId: "task-456",
            status: .failed,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:15Z",
            statusMessage: "Connection timeout",
        )

        let result = GetTask.Result(task: task)

        #expect(result.taskId == task.taskId)
        #expect(result.status == task.status)
        #expect(result.statusMessage == "Connection timeout")
    }

    @Test
    func `GetTask.Result ttl encodes as null when nil`() throws {
        let result = GetTask.Result(
            taskId: "task-123",
            status: .working,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
        )

        let data = try JSONEncoder().encode(result)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(jsonString.contains("\"ttl\":null"))
    }
}

// MARK: - GetTaskPayload Tests

struct GetTaskPayloadMethodTests {
    @Test
    func `GetTaskPayload.name is correct`() {
        #expect(GetTaskPayload.name == "tasks/result")
    }

    @Test
    func `GetTaskPayload.Parameters encoding and decoding`() throws {
        let params = GetTaskPayload.Parameters(taskId: "task-123")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(GetTaskPayload.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
    }

    @Test
    func `GetTaskPayload.Result with extraFields (flattened result)`() throws {
        // Simulate a tools/call result flattened into extraFields
        let extraFields: [String: Value] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Hello, world!"),
                ]),
            ]),
            "isError": .bool(false),
        ]

        let meta: [String: Value] = [
            relatedTaskMetaKey: .object(["taskId": .string("task-123")]),
        ]

        let result = GetTaskPayload.Result(_meta: meta, extraFields: extraFields)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(GetTaskPayload.Result.self, from: data)

        #expect(decoded._meta?[relatedTaskMetaKey] != nil)
        #expect(decoded.extraFields?["isError"]?.boolValue == false)
    }

    @Test
    func `GetTaskPayload.Result fromResultValue convenience initializer`() {
        let resultValue: Value = .object([
            "content": .array([.object(["type": .string("text"), "text": .string("Result")])]),
            "isError": .bool(false),
        ])

        let result = GetTaskPayload.Result(fromResultValue: resultValue)

        #expect(result.extraFields?["isError"]?.boolValue == false)
    }
}

// MARK: - ListTasks Tests

struct ListTasksMethodTests {
    @Test
    func `ListTasks.name is correct`() {
        #expect(ListTasks.name == "tasks/list")
    }

    @Test
    func `ListTasks.Parameters encoding and decoding with cursor`() throws {
        let params = ListTasks.Parameters(cursor: "page-2-token")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(ListTasks.Parameters.self, from: data)

        #expect(decoded.cursor == "page-2-token")
    }

    @Test
    func `ListTasks.Parameters empty initializer`() {
        let params = ListTasks.Parameters()

        #expect(params.cursor == nil)
        #expect(params._meta == nil)
    }

    @Test
    func `ListTasks.Result encoding and decoding`() throws {
        let tasks = [
            MCPTask(
                taskId: "task-1",
                status: .completed,
                ttl: nil,
                createdAt: "2024-01-15T10:00:00Z",
                lastUpdatedAt: "2024-01-15T10:05:00Z",
            ),
            MCPTask(
                taskId: "task-2",
                status: .working,
                ttl: 60000,
                createdAt: "2024-01-15T10:10:00Z",
                lastUpdatedAt: "2024-01-15T10:10:00Z",
            ),
        ]

        let result = ListTasks.Result(tasks: tasks, nextCursor: "page-2")

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ListTasks.Result.self, from: data)

        #expect(decoded.tasks.count == 2)
        #expect(decoded.tasks[0].taskId == "task-1")
        #expect(decoded.tasks[1].taskId == "task-2")
        #expect(decoded.nextCursor == "page-2")
    }

    @Test
    func `ListTasks.Result without nextCursor indicates end of pagination`() throws {
        let result = ListTasks.Result(tasks: [], nextCursor: nil)

        let data = try JSONEncoder().encode(result)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(!jsonString.contains("nextCursor"))
    }
}

// MARK: - CancelTask Tests

struct CancelTaskMethodTests {
    @Test
    func `CancelTask.name is correct`() {
        #expect(CancelTask.name == "tasks/cancel")
    }

    @Test
    func `CancelTask.Parameters encoding and decoding`() throws {
        let params = CancelTask.Parameters(taskId: "task-123")

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(CancelTask.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
    }

    @Test
    func `CancelTask.Result encoding and decoding`() throws {
        let result = CancelTask.Result(
            taskId: "task-123",
            status: .cancelled,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:45Z",
            statusMessage: "Cancelled by user",
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CancelTask.Result.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .cancelled)
        #expect(decoded.statusMessage == "Cancelled by user")
    }

    @Test
    func `CancelTask.Result from MCPTask`() {
        let task = MCPTask(
            taskId: "task-456",
            status: .cancelled,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:30Z",
        )

        let result = CancelTask.Result(task: task)

        #expect(result.taskId == task.taskId)
        #expect(result.status == .cancelled)
    }
}

// MARK: - TaskStatusNotification Tests

struct TaskStatusNotificationTests {
    @Test
    func `TaskStatusNotification.name is correct`() {
        #expect(TaskStatusNotification.name == "notifications/tasks/status")
    }

    @Test
    func `TaskStatusNotification.Parameters encoding and decoding`() throws {
        let params = TaskStatusNotification.Parameters(
            taskId: "task-123",
            status: .inputRequired,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:10Z",
            pollInterval: 500,
            statusMessage: "Waiting for user input",
        )

        let data = try JSONEncoder().encode(params)
        let decoded = try JSONDecoder().decode(TaskStatusNotification.Parameters.self, from: data)

        #expect(decoded.taskId == "task-123")
        #expect(decoded.status == .inputRequired)
        #expect(decoded.ttl == 60000)
        #expect(decoded.pollInterval == 500)
        #expect(decoded.statusMessage == "Waiting for user input")
    }

    @Test
    func `TaskStatusNotification.Parameters from MCPTask`() {
        let task = MCPTask(
            taskId: "task-789",
            status: .completed,
            ttl: nil,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:31:00Z",
        )

        let params = TaskStatusNotification.Parameters(task: task)

        #expect(params.taskId == task.taskId)
        #expect(params.status == task.status)
        #expect(params.createdAt == task.createdAt)
        #expect(params.lastUpdatedAt == task.lastUpdatedAt)
    }
}

// MARK: - Server Capabilities Tests

struct ServerTasksCapabilitiesTests {
    @Test
    func `Server.Capabilities.Tasks encoding and decoding`() throws {
        let capabilities = Server.Capabilities.Tasks(
            list: .init(),
            cancel: .init(),
            requests: .init(tools: .init(call: .init())),
        )

        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(Server.Capabilities.Tasks.self, from: data)

        #expect(decoded.list != nil)
        #expect(decoded.cancel != nil)
        #expect(decoded.requests?.tools?.call != nil)
    }

    @Test
    func `Server.Capabilities.Tasks.full() creates complete capability`() {
        let capabilities = Server.Capabilities.Tasks.full()

        #expect(capabilities.list != nil)
        #expect(capabilities.cancel != nil)
        #expect(capabilities.requests?.tools?.call != nil)
    }

    @Test
    func `hasTaskAugmentedToolsCall helper`() {
        // No capabilities
        #expect(hasTaskAugmentedToolsCall(nil) == false)

        // Empty capabilities
        #expect(hasTaskAugmentedToolsCall(Server.Capabilities()) == false)

        // Tasks without requests
        let capsNoRequests = Server.Capabilities(tasks: .init(list: .init()))
        #expect(hasTaskAugmentedToolsCall(capsNoRequests) == false)

        // Full task support
        let capsFull = Server.Capabilities(tasks: .full())
        #expect(hasTaskAugmentedToolsCall(capsFull) == true)
    }

    @Test
    func `requireTaskAugmentedToolsCall throws when not supported`() throws {
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedToolsCall(nil)
        }

        #expect(throws: MCPError.self) {
            try requireTaskAugmentedToolsCall(Server.Capabilities())
        }

        // Should not throw with full support
        try requireTaskAugmentedToolsCall(Server.Capabilities(tasks: .full()))
    }
}

// MARK: - Client Capabilities Tests

struct ClientTasksCapabilitiesTests {
    @Test
    func `Client.Capabilities.Tasks encoding and decoding`() throws {
        let capabilities = Client.Capabilities.Tasks(
            list: .init(),
            cancel: .init(),
            requests: .init(
                sampling: .init(createMessage: .init()),
                elicitation: .init(create: .init()),
            ),
        )

        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(Client.Capabilities.Tasks.self, from: data)

        #expect(decoded.list != nil)
        #expect(decoded.cancel != nil)
        #expect(decoded.requests?.sampling?.createMessage != nil)
        #expect(decoded.requests?.elicitation?.create != nil)
    }

    @Test
    func `Client.Capabilities.Tasks.full() creates complete capability`() {
        let capabilities = Client.Capabilities.Tasks.full()

        #expect(capabilities.list != nil)
        #expect(capabilities.cancel != nil)
        #expect(capabilities.requests?.sampling?.createMessage != nil)
        #expect(capabilities.requests?.elicitation?.create != nil)
    }

    @Test
    func `hasTaskAugmentedElicitation helper`() {
        #expect(hasTaskAugmentedElicitation(nil) == false)
        #expect(hasTaskAugmentedElicitation(Client.Capabilities()) == false)

        let capsWithElicitation = Client.Capabilities(
            tasks: .init(requests: .init(elicitation: .init(create: .init()))),
        )
        #expect(hasTaskAugmentedElicitation(capsWithElicitation) == true)
    }

    @Test
    func `hasTaskAugmentedSampling helper`() {
        #expect(hasTaskAugmentedSampling(nil) == false)
        #expect(hasTaskAugmentedSampling(Client.Capabilities()) == false)

        let capsWithSampling = Client.Capabilities(
            tasks: .init(requests: .init(sampling: .init(createMessage: .init()))),
        )
        #expect(hasTaskAugmentedSampling(capsWithSampling) == true)
    }

    @Test
    func `requireTaskAugmentedElicitation throws when not supported`() throws {
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedElicitation(nil)
        }

        // Should not throw with support
        let caps = Client.Capabilities(tasks: .full())
        try requireTaskAugmentedElicitation(caps)
    }

    @Test
    func `requireTaskAugmentedSampling throws when not supported`() throws {
        #expect(throws: MCPError.self) {
            try requireTaskAugmentedSampling(nil)
        }

        // Should not throw with support
        let caps = Client.Capabilities(tasks: .full())
        try requireTaskAugmentedSampling(caps)
    }
}

// MARK: - InMemoryTaskStore Tests

struct InMemoryTaskStoreTests {
    let defaultSessionId = "session-1"

    @Test
    func `createTask creates task with working status`() async throws {
        let store = InMemoryTaskStore()
        let metadata = TaskMetadata(ttl: 60000)

        let task = try await store.createTask(metadata: metadata, taskId: nil, sessionId: defaultSessionId)

        #expect(task.status == .working)
        #expect(task.ttl == 60000)
        #expect(!task.taskId.isEmpty)
    }

    @Test
    func `createTask with custom taskId`() async throws {
        let store = InMemoryTaskStore()
        let metadata = TaskMetadata(ttl: nil)

        let task = try await store.createTask(metadata: metadata, taskId: "custom-id-123", sessionId: defaultSessionId)

        #expect(task.taskId == "custom-id-123")
    }

    @Test
    func `createTask throws on duplicate taskId`() async throws {
        let store = InMemoryTaskStore()
        let metadata = TaskMetadata()

        _ = try await store.createTask(metadata: metadata, taskId: "task-1", sessionId: defaultSessionId)

        await #expect(throws: MCPError.self) {
            _ = try await store.createTask(metadata: metadata, taskId: "task-1", sessionId: defaultSessionId)
        }
    }

    @Test
    func `getTask returns created task`() async throws {
        let store = InMemoryTaskStore()
        let created = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        let retrieved = await store.getTask(taskId: "task-123", sessionId: defaultSessionId)

        #expect(retrieved?.taskId == created.taskId)
        #expect(retrieved?.status == created.status)
    }

    @Test
    func `getTask returns nil for non-existent task`() async {
        let store = InMemoryTaskStore()

        let result = await store.getTask(taskId: "non-existent", sessionId: defaultSessionId)

        #expect(result == nil)
    }

    @Test
    func `updateTask changes status`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        let updated = try await store.updateTask(taskId: "task-123", status: .completed, statusMessage: "Done", sessionId: defaultSessionId)

        #expect(updated.status == .completed)
        #expect(updated.statusMessage == "Done")
    }

    @Test
    func `updateTask throws when transitioning from terminal status`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        // Complete the task
        _ = try await store.updateTask(taskId: "task-123", status: .completed, statusMessage: nil, sessionId: defaultSessionId)

        // Try to update again - should throw
        await #expect(throws: MCPError.self) {
            _ = try await store.updateTask(taskId: "task-123", status: .working, statusMessage: nil, sessionId: defaultSessionId)
        }
    }

    @Test
    func `updateTask throws for non-existent task`() async {
        let store = InMemoryTaskStore()

        await #expect(throws: MCPError.self) {
            _ = try await store.updateTask(taskId: "non-existent", status: .completed, statusMessage: nil, sessionId: defaultSessionId)
        }
    }

    @Test
    func `storeResult and getResult work correctly`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        let result: Value = .object(["data": .string("test result")])
        try await store.storeResult(taskId: "task-123", result: result, sessionId: defaultSessionId)

        let retrieved = await store.getResult(taskId: "task-123", sessionId: defaultSessionId)

        #expect(retrieved?.objectValue?["data"]?.stringValue == "test result")
    }

    @Test
    func `getResult returns nil when no result stored`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        let result = await store.getResult(taskId: "task-123", sessionId: defaultSessionId)

        #expect(result == nil)
    }

    @Test
    func `listTasks returns all tasks for session`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: defaultSessionId)
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-2", sessionId: defaultSessionId)
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-3", sessionId: defaultSessionId)

        let result = try await store.listTasks(cursor: nil, sessionId: defaultSessionId)

        #expect(result.tasks.count == 3)
    }

    @Test
    func `listTasks pagination works correctly`() async throws {
        let store = InMemoryTaskStore(pageSize: 2)

        // Create 5 tasks
        for i in 1 ... 5 {
            _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-\(i)", sessionId: defaultSessionId)
        }

        // First page
        let page1Result = try await store.listTasks(cursor: nil, sessionId: defaultSessionId)
        #expect(page1Result.tasks.count == 2)
        #expect(page1Result.nextCursor != nil)

        // Second page
        let page2Result = try await store.listTasks(cursor: page1Result.nextCursor, sessionId: defaultSessionId)
        #expect(page2Result.tasks.count == 2)
        #expect(page2Result.nextCursor != nil)

        // Third page
        let page3Result = try await store.listTasks(cursor: page2Result.nextCursor, sessionId: defaultSessionId)
        #expect(page3Result.tasks.count == 1)
        #expect(page3Result.nextCursor == nil)
    }

    @Test
    func `listTasks throws invalidParams on invalid cursor`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: defaultSessionId)

        do {
            _ = try await store.listTasks(cursor: "nonexistent-cursor", sessionId: defaultSessionId)
            Issue.record("Expected listTasks to throw for invalid cursor")
        } catch {
            guard case let MCPError.invalidParams(message) = error else {
                Issue.record("Expected MCPError.invalidParams, got \(error)")
                return
            }
            #expect(message?.contains("Invalid cursor") == true)
            #expect(message?.contains("nonexistent-cursor") == true)
        }
    }

    @Test
    func `listTasks throws when cursor task is deleted between pages`() async throws {
        let store = InMemoryTaskStore(pageSize: 1)
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: defaultSessionId)
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-2", sessionId: defaultSessionId)

        // Get first page – cursor points to task-1
        let page1 = try await store.listTasks(cursor: nil, sessionId: defaultSessionId)
        let staleCursor = try #require(page1.nextCursor)

        // Delete the task that the cursor points to
        let deleted = await store.deleteTask(taskId: staleCursor, sessionId: defaultSessionId)
        #expect(deleted)

        // Using the stale cursor should throw invalidParams
        do {
            _ = try await store.listTasks(cursor: staleCursor, sessionId: defaultSessionId)
            Issue.record("Expected listTasks to throw for stale cursor")
        } catch {
            guard case let MCPError.invalidParams(message) = error else {
                Issue.record("Expected MCPError.invalidParams, got \(error)")
                return
            }
            #expect(message?.contains("Invalid cursor") == true)
            #expect(message?.contains(staleCursor) == true)
        }
    }

    @Test
    func `deleteTask removes task`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        let deleted = await store.deleteTask(taskId: "task-123", sessionId: defaultSessionId)
        #expect(deleted == true)

        let result = await store.getTask(taskId: "task-123", sessionId: defaultSessionId)
        #expect(result == nil)
    }

    @Test
    func `deleteTask returns false for non-existent task`() async {
        let store = InMemoryTaskStore()

        let deleted = await store.deleteTask(taskId: "non-existent", sessionId: defaultSessionId)

        #expect(deleted == false)
    }

    @Test
    func `waitForUpdate and notifyUpdate work together`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-123", sessionId: defaultSessionId)

        // Start waiting in a separate task
        let waitTask = Task {
            try await store.waitForUpdate(taskId: "task-123")
            return true
        }

        // Give the wait a moment to start
        try await Task.sleep(for: .milliseconds(50))

        // Notify update
        await store.notifyUpdate(taskId: "task-123")

        // Wait should complete
        let result = try await waitTask.value
        #expect(result == true)
    }
}

// MARK: - Session Isolation Tests

struct InMemoryTaskStoreSessionIsolationTests {
    let sessionA = "session-a"
    let sessionB = "session-b"

    @Test
    func `getTask returns nil for another session's task`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)

        let result = await store.getTask(taskId: "task-1", sessionId: sessionB)
        #expect(result == nil)
    }

    @Test
    func `getTask returns task for owning session`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)

        let result = await store.getTask(taskId: "task-1", sessionId: sessionA)
        #expect(result != nil)
        #expect(result?.taskId == "task-1")
    }

    @Test
    func `updateTask fails for another session's task with opaque error`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)

        // Error should say "not found", not reveal that the task belongs to another session
        do {
            _ = try await store.updateTask(taskId: "task-1", status: .completed, statusMessage: nil, sessionId: sessionB)
            Issue.record("Expected MCPError to be thrown")
        } catch let error as MCPError {
            #expect(error.message.contains("not found"))
        }
    }

    @Test
    func `storeResult fails for another session's task with opaque error`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)

        // Error should say "not found", not reveal that the task belongs to another session
        do {
            try await store.storeResult(taskId: "task-1", result: .string("data"), sessionId: sessionB)
            Issue.record("Expected MCPError to be thrown")
        } catch let error as MCPError {
            #expect(error.message.contains("not found"))
        }
    }

    @Test
    func `getResult returns nil for another session's task`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)
        try await store.storeResult(taskId: "task-1", result: .string("secret"), sessionId: sessionA)

        let result = await store.getResult(taskId: "task-1", sessionId: sessionB)
        #expect(result == nil)
    }

    @Test
    func `listTasks only returns tasks for the requesting session`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "a-task-1", sessionId: sessionA)
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "a-task-2", sessionId: sessionA)
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "b-task-1", sessionId: sessionB)

        let sessionATasks = try await store.listTasks(cursor: nil, sessionId: sessionA)
        #expect(sessionATasks.tasks.count == 2)
        #expect(sessionATasks.tasks.allSatisfy { $0.taskId.hasPrefix("a-task") })

        let sessionBTasks = try await store.listTasks(cursor: nil, sessionId: sessionB)
        #expect(sessionBTasks.tasks.count == 1)
        #expect(sessionBTasks.tasks[0].taskId == "b-task-1")
    }

    @Test
    func `deleteTask fails for another session's task`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)

        let deleted = await store.deleteTask(taskId: "task-1", sessionId: sessionB)
        #expect(deleted == false)

        // Task should still exist for session A
        let task = await store.getTask(taskId: "task-1", sessionId: sessionA)
        #expect(task != nil)
    }

    @Test
    func `Cross-session access is indistinguishable from non-existent task`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "task-1", sessionId: sessionA)

        // Accessing another session's task should look identical to a non-existent task
        let crossSessionGet = await store.getTask(taskId: "task-1", sessionId: sessionB)
        let nonExistentGet = await store.getTask(taskId: "no-such-task", sessionId: sessionA)
        #expect(crossSessionGet == nil)
        #expect(nonExistentGet == nil)

        let crossSessionResult = await store.getResult(taskId: "task-1", sessionId: sessionB)
        let nonExistentResult = await store.getResult(taskId: "no-such-task", sessionId: sessionA)
        #expect(crossSessionResult == nil)
        #expect(nonExistentResult == nil)

        let crossSessionDelete = await store.deleteTask(taskId: "task-1", sessionId: sessionB)
        let nonExistentDelete = await store.deleteTask(taskId: "no-such-task", sessionId: sessionA)
        #expect(crossSessionDelete == false)
        #expect(nonExistentDelete == false)
    }

    @Test
    func `Task IDs are globally unique across sessions`() async throws {
        let store = InMemoryTaskStore()
        _ = try await store.createTask(metadata: TaskMetadata(), taskId: "shared-id", sessionId: sessionA)

        // Another session cannot create a task with the same ID,
        // since task IDs are globally unique in the flat storage
        await #expect(throws: MCPError.self) {
            _ = try await store.createTask(metadata: TaskMetadata(), taskId: "shared-id", sessionId: sessionB)
        }
    }

    @Test
    func `listTasks pagination respects session isolation`() async throws {
        let store = InMemoryTaskStore(pageSize: 2)

        // Create tasks for two sessions
        for i in 1 ... 4 {
            _ = try await store.createTask(metadata: TaskMetadata(), taskId: "a-\(i)", sessionId: sessionA)
        }
        for i in 1 ... 2 {
            _ = try await store.createTask(metadata: TaskMetadata(), taskId: "b-\(i)", sessionId: sessionB)
        }

        // Session A should paginate over its 4 tasks
        let page1 = try await store.listTasks(cursor: nil, sessionId: sessionA)
        #expect(page1.tasks.count == 2)
        #expect(page1.nextCursor != nil)

        let page2 = try await store.listTasks(cursor: page1.nextCursor, sessionId: sessionA)
        #expect(page2.tasks.count == 2)
        #expect(page2.nextCursor == nil)

        // Session B should see only its 2 tasks in one page
        let sessionBPage = try await store.listTasks(cursor: nil, sessionId: sessionB)
        #expect(sessionBPage.tasks.count == 2)
        #expect(sessionBPage.nextCursor == nil)
    }
}

// MARK: - InMemoryTaskMessageQueue Tests

struct InMemoryTaskMessageQueueTests {
    @Test
    func `enqueue and dequeue work correctly`() async throws {
        let queue = InMemoryTaskMessageQueue()

        let message = try QueuedMessage.notification(
            JSONEncoder().encode(["test": "data"]),
            timestamp: Date(),
        )

        try await queue.enqueue(taskId: "task-123", message: message, maxSize: nil)

        let dequeued = await queue.dequeue(taskId: "task-123")
        #expect(dequeued != nil)

        // Queue should now be empty
        let empty = await queue.dequeue(taskId: "task-123")
        #expect(empty == nil)
    }

    @Test
    func `enqueue respects maxSize`() async throws {
        let queue = InMemoryTaskMessageQueue()

        let message = QueuedMessage.notification(Data(), timestamp: Date())

        try await queue.enqueue(taskId: "task-123", message: message, maxSize: 1)

        // Second enqueue should fail
        await #expect(throws: MCPError.self) {
            try await queue.enqueue(taskId: "task-123", message: message, maxSize: 1)
        }
    }

    @Test
    func `dequeueAll returns all messages`() async throws {
        let queue = InMemoryTaskMessageQueue()

        for i in 0 ..< 3 {
            let message = try QueuedMessage.notification(
                JSONEncoder().encode(["index": i]),
                timestamp: Date(),
            )
            try await queue.enqueue(taskId: "task-123", message: message, maxSize: nil)
        }

        let all = await queue.dequeueAll(taskId: "task-123")
        #expect(all.count == 3)

        // Queue should now be empty
        let empty = await queue.isEmpty(taskId: "task-123")
        #expect(empty == true)
    }

    @Test
    func `isEmpty returns correct value`() async throws {
        let queue = InMemoryTaskMessageQueue()

        #expect(await queue.isEmpty(taskId: "task-123") == true)

        let message = QueuedMessage.notification(Data(), timestamp: Date())
        try await queue.enqueue(taskId: "task-123", message: message, maxSize: nil)

        #expect(await queue.isEmpty(taskId: "task-123") == false)

        _ = await queue.dequeue(taskId: "task-123")

        #expect(await queue.isEmpty(taskId: "task-123") == true)
    }

    @Test
    func `enqueueWithResolver stores resolver`() async throws {
        let queue = InMemoryTaskMessageQueue()
        let resolver = Resolver<Value>()

        let message = QueuedMessage.request(Data(), timestamp: Date())
        let queuedRequest = QueuedRequestWithResolver(
            message: message,
            resolver: resolver,
            originalRequestId: .string("req-1"),
        )

        try await queue.enqueueWithResolver(taskId: "task-123", request: queuedRequest, maxSize: nil)

        // Resolver should be retrievable
        let retrieved = await queue.getResolver(forRequestId: .string("req-1"))
        #expect(retrieved != nil)
    }

    @Test
    func `removeResolver removes and returns resolver`() async throws {
        let queue = InMemoryTaskMessageQueue()
        let resolver = Resolver<Value>()

        let message = QueuedMessage.request(Data(), timestamp: Date())
        let queuedRequest = QueuedRequestWithResolver(
            message: message,
            resolver: resolver,
            originalRequestId: .string("req-1"),
        )

        try await queue.enqueueWithResolver(taskId: "task-123", request: queuedRequest, maxSize: nil)

        let removed = await queue.removeResolver(forRequestId: .string("req-1"))
        #expect(removed != nil)

        // Should no longer be retrievable
        let notFound = await queue.getResolver(forRequestId: .string("req-1"))
        #expect(notFound == nil)
    }
}

// MARK: - Resolver Tests

struct ResolverTests {
    @Test
    func `setResult and wait work correctly`() async throws {
        let resolver = Resolver<Value>()

        // Set result in background
        Task {
            await resolver.setResult(.string("success"))
        }

        let result = try await resolver.wait()
        #expect(result.stringValue == "success")
    }

    @Test
    func `setError and wait throws correctly`() async throws {
        let resolver = Resolver<Value>()

        // Set error in background
        Task {
            await resolver.setError(MCPError.internalError("test error"))
        }

        await #expect(throws: MCPError.self) {
            _ = try await resolver.wait()
        }
    }

    @Test
    func `isDone returns correct value`() async {
        let resolver = Resolver<Value>()

        #expect(await resolver.isDone == false)

        await resolver.setResult(.string("done"))

        #expect(await resolver.isDone == true)
    }

    @Test
    func `setResult is idempotent`() async throws {
        let resolver = Resolver<Value>()

        await resolver.setResult(.string("first"))
        await resolver.setResult(.string("second")) // Should be ignored

        let result = try await resolver.wait()
        #expect(result.stringValue == "first")
    }
}

// MARK: - QueuedMessage Tests

struct QueuedMessageTests {
    @Test
    func `QueuedMessage.request stores data and timestamp`() {
        let data = Data("test".utf8)
        let timestamp = Date()
        let message = QueuedMessage.request(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }

    @Test
    func `QueuedMessage.notification stores data and timestamp`() {
        let data = Data("notification".utf8)
        let timestamp = Date()
        let message = QueuedMessage.notification(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }

    @Test
    func `QueuedMessage.response stores data and timestamp`() {
        let data = Data("response".utf8)
        let timestamp = Date()
        let message = QueuedMessage.response(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }

    @Test
    func `QueuedMessage.error stores data and timestamp`() {
        let data = Data("error".utf8)
        let timestamp = Date()
        let message = QueuedMessage.error(data, timestamp: timestamp)

        #expect(message.data == data)
        #expect(message.timestamp == timestamp)
    }
}

// MARK: - JSON Round-Trip Tests

struct TaskJSONRoundTripTests {
    @Test
    func `Complete task workflow JSON encoding`() throws {
        // 1. Create task with metadata
        let createParams = CallTool.Parameters(
            name: "long_running_tool",
            arguments: ["input": .string("data")],
            task: TaskMetadata(ttl: 60000),
        )

        let createData = try JSONEncoder().encode(createParams)
        let decodedCreate = try JSONDecoder().decode(CallTool.Parameters.self, from: createData)
        #expect(decodedCreate.task?.ttl == 60000)

        // 2. Create task result
        let task = MCPTask(
            taskId: "task-abc123",
            status: .working,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:00Z",
            pollInterval: 1000,
        )
        let createResult = CreateTaskResult(task: task, modelImmediateResponse: "Starting...")

        let resultData = try JSONEncoder().encode(createResult)
        let decodedResult = try JSONDecoder().decode(CreateTaskResult.self, from: resultData)
        #expect(decodedResult.task.taskId == "task-abc123")
        #expect(decodedResult._meta?[modelImmediateResponseKey]?.stringValue == "Starting...")

        // 3. Task status notification
        let notification = TaskStatusNotification.Parameters(
            taskId: "task-abc123",
            status: .inputRequired,
            ttl: 60000,
            createdAt: "2024-01-15T10:30:00Z",
            lastUpdatedAt: "2024-01-15T10:30:05Z",
            statusMessage: "Waiting for input",
        )

        let notificationData = try JSONEncoder().encode(notification)
        let decodedNotification = try JSONDecoder().decode(
            TaskStatusNotification.Parameters.self, from: notificationData,
        )
        #expect(decodedNotification.status == .inputRequired)

        // 4. Get task result
        let payloadResult = GetTaskPayload.Result(
            _meta: [relatedTaskMetaKey: .object(["taskId": .string("task-abc123")])],
            extraFields: [
                "content": .array([.object(["type": .string("text"), "text": .string("Result")])]),
                "isError": .bool(false),
            ],
        )

        let payloadData = try JSONEncoder().encode(payloadResult)
        let decodedPayload = try JSONDecoder().decode(GetTaskPayload.Result.self, from: payloadData)
        #expect(decodedPayload.extraFields?["isError"]?.boolValue == false)
    }
}
