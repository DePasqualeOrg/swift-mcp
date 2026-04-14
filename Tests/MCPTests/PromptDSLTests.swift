// Copyright © Anthony DePasquale

import Foundation
@testable import MCP
import MCPPrompt
import Testing

// MARK: - Test Prompt Definitions

/// A simple prompt with basic string argument
@Prompt
struct GreetingPrompt {
    static let name = "greeting"
    static let description = "Greet a user by name"

    @Argument(description: "The person's name")
    var userName: String

    func render(context _: HandlerContext) async throws -> [Prompt.Message] {
        [.user(.text("Hello, \(userName)! How can I help you today?"))]
    }
}

/// Prompt with multiple arguments
@Prompt
struct InterviewPrompt {
    static let name = "interview"
    static let description = "Generate interview questions"

    @Argument(description: "Role to interview for")
    var role: String

    @Argument(description: "Years of experience required")
    var experience: String

    func render(context _: HandlerContext) async throws -> [Prompt.Message] {
        [.user(.text("Prepare interview questions for a \(role) with \(experience) years of experience."))]
    }
}

/// Prompt with optional argument
@Prompt
struct SummarizePrompt {
    static let name = "summarize"
    static let description = "Summarize text content"

    @Argument(description: "Text to summarize")
    var text: String

    @Argument(description: "Maximum length of summary")
    var maxLength: String?

    func render(context _: HandlerContext) async throws -> [Prompt.Message] {
        var instruction = "Please summarize the following:\n\n\(text)"
        if let maxLength {
            instruction += "\n\nKeep the summary under \(maxLength) words."
        }
        return [.user(.text(instruction))]
    }
}

/// Prompt with custom argument key
@Prompt
struct CodeReviewPrompt {
    static let name = "code_review"
    static let description = "Review code for quality"

    @Argument(key: "source_code", description: "The code to review")
    var sourceCode: String

    @Argument(key: "review_focus", description: "Areas to focus on")
    var reviewFocus: String?

    func render(context _: HandlerContext) async throws -> [Prompt.Message] {
        var messages: [Prompt.Message] = []
        messages.append(.user(.text("Please review this code:\n\n```\n\(sourceCode)\n```")))
        if let focus = reviewFocus {
            messages.append(.user(.text("Focus particularly on: \(focus)")))
        }
        return messages
    }
}

/// Prompt with title
@Prompt
struct BrainstormPrompt {
    static let name = "brainstorm"
    static let title = "Brainstorming Session"
    static let description = "Generate creative ideas"

    @Argument(title: "Topic", description: "Topic to brainstorm about")
    var topic: String

    func render(context _: HandlerContext) async throws -> [Prompt.Message] {
        [.user(.text("Let's brainstorm ideas about: \(topic)"))]
    }
}

/// Prompt with no arguments
@Prompt
struct SimpleGreetingPrompt {
    static let name = "simple_greeting"
    static let description = "A simple greeting prompt"

    func render(context _: HandlerContext) async throws -> [Prompt.Message] {
        [.user(.text("Hello! How can I assist you today?"))]
    }
}

/// Prompt returning a single message
@Prompt
struct SingleMessagePrompt {
    static let name = "single_message"
    static let description = "Returns a single message"

    @Argument(description: "Message content")
    var content: String

    func render(context _: HandlerContext) async throws -> Prompt.Message {
        .user(.text(content))
    }
}

/// Prompt returning a simple string
@Prompt
struct StringOutputPrompt {
    static let name = "string_output"
    static let description = "Returns a simple string"

    @Argument(description: "Topic")
    var topic: String

    func render(context _: HandlerContext) async throws -> String {
        "Tell me about \(topic)"
    }
}

/// Prompt with render() that doesn't require HandlerContext
@Prompt
struct SimpleRenderPrompt {
    static let name = "simple_render_prompt"
    static let description = "A prompt that doesn't need context"

    @Argument(description: "User input")
    var input: String

    func render() async throws -> [Prompt.Message] {
        [.user(.text("Simple render: \(input)"))]
    }
}

/// Prompt with render() returning a single message
@Prompt
struct SimpleRenderSingleMessagePrompt {
    static let name = "simple_render_single"
    static let description = "Prompt with single message"

    @Argument(description: "Message")
    var message: String

    func render() async throws -> Prompt.Message {
        .assistant(.text("Response to: \(message)"))
    }
}

// MARK: - PromptSpec Conformance Tests

struct PromptSpecConformanceTests {
    @Test
    func `@Prompt macro generates PromptSpec conformance`() {
        let _: any PromptSpec.Type = GreetingPrompt.self
        let _: any PromptSpec.Type = InterviewPrompt.self
        let _: any PromptSpec.Type = SummarizePrompt.self
        let _: any PromptSpec.Type = CodeReviewPrompt.self
    }

    @Test
    func `Prompt with render() generates PromptSpec conformance`() {
        // Verify that prompts with render() (no context) also conform to PromptSpec
        let _: any PromptSpec.Type = SimpleRenderPrompt.self
        let _: any PromptSpec.Type = SimpleRenderSingleMessagePrompt.self
    }

    @Test
    func `promptDefinition contains correct name and description`() {
        let definition = GreetingPrompt.promptDefinition

        #expect(definition.name == "greeting")
        #expect(definition.description == "Greet a user by name")
    }

    @Test
    func `promptDefinition includes title when provided`() {
        let definition = BrainstormPrompt.promptDefinition

        #expect(definition.name == "brainstorm")
        #expect(definition.title == "Brainstorming Session")
        #expect(definition.description == "Generate creative ideas")
    }

    @Test
    func `promptDefinition includes arguments`() {
        let definition = GreetingPrompt.promptDefinition

        #expect(definition.arguments?.count == 1)
        let arg = definition.arguments?.first
        #expect(arg?.name == "userName")
        #expect(arg?.description == "The person's name")
        #expect(arg?.required == true)
    }

    @Test
    func `promptDefinition handles multiple arguments`() {
        let definition = InterviewPrompt.promptDefinition

        #expect(definition.arguments?.count == 2)

        let roleArg = definition.arguments?.first { $0.name == "role" }
        #expect(roleArg?.description == "Role to interview for")
        #expect(roleArg?.required == true)

        let expArg = definition.arguments?.first { $0.name == "experience" }
        #expect(expArg?.description == "Years of experience required")
        #expect(expArg?.required == true)
    }

    @Test
    func `promptDefinition handles optional arguments`() {
        let definition = SummarizePrompt.promptDefinition

        #expect(definition.arguments?.count == 2)

        let textArg = definition.arguments?.first { $0.name == "text" }
        #expect(textArg?.required == true)

        let maxLengthArg = definition.arguments?.first { $0.name == "maxLength" }
        #expect(maxLengthArg?.required == false)
    }

    @Test
    func `promptDefinition respects custom keys`() {
        let definition = CodeReviewPrompt.promptDefinition

        let sourceArg = definition.arguments?.first { $0.name == "source_code" }
        #expect(sourceArg != nil)
        #expect(sourceArg?.description == "The code to review")

        let focusArg = definition.arguments?.first { $0.name == "review_focus" }
        #expect(focusArg != nil)
    }

    @Test
    func `promptDefinition handles no arguments`() {
        let definition = SimpleGreetingPrompt.promptDefinition

        #expect(definition.arguments == nil || definition.arguments?.isEmpty == true)
    }

    @Test
    func `promptDefinition includes argument title`() {
        let definition = BrainstormPrompt.promptDefinition

        let arg = definition.arguments?.first
        #expect(arg?.title == "Topic")
    }
}

// MARK: - Parse Method Tests

struct PromptParseMethodTests {
    @Test
    func `parse extracts string argument`() throws {
        let args = ["userName": "Alice"]
        let prompt = try GreetingPrompt.parse(from: args)

        #expect(prompt.userName == "Alice")
    }

    @Test
    func `parse extracts multiple arguments`() throws {
        let args: [String: String] = [
            "role": "Senior Developer",
            "experience": "5",
        ]
        let prompt = try InterviewPrompt.parse(from: args)

        #expect(prompt.role == "Senior Developer")
        #expect(prompt.experience == "5")
    }

    @Test
    func `parse handles optional argument when present`() throws {
        let args: [String: String] = [
            "text": "This is a long document.",
            "maxLength": "100",
        ]
        let prompt = try SummarizePrompt.parse(from: args)

        #expect(prompt.text == "This is a long document.")
        #expect(prompt.maxLength == "100")
    }

    @Test
    func `parse handles optional argument when absent`() throws {
        let args = ["text": "Short text"]
        let prompt = try SummarizePrompt.parse(from: args)

        #expect(prompt.text == "Short text")
        #expect(prompt.maxLength == nil)
    }

    @Test
    func `parse respects custom keys`() throws {
        let args: [String: String] = [
            "source_code": "func hello() { print(\"Hello\") }",
            "review_focus": "error handling",
        ]
        let prompt = try CodeReviewPrompt.parse(from: args)

        #expect(prompt.sourceCode == "func hello() { print(\"Hello\") }")
        #expect(prompt.reviewFocus == "error handling")
    }

    @Test
    func `parse works with no arguments`() throws {
        let prompt = try SimpleGreetingPrompt.parse(from: nil)
        // Should not throw - prompt has no required arguments
        _ = prompt
    }

    @Test
    func `parse works with empty dictionary`() throws {
        let prompt = try SimpleGreetingPrompt.parse(from: [:])
        _ = prompt
    }

    @Test
    func `parse throws for missing required argument`() throws {
        let args: [String: String] = [:]

        #expect(throws: MCPError.self) {
            _ = try GreetingPrompt.parse(from: args)
        }
    }

    @Test
    func `parse throws for missing one of multiple required arguments`() throws {
        let args = ["role": "Developer"]

        #expect(throws: MCPError.self) {
            _ = try InterviewPrompt.parse(from: args)
        }
    }
}

// MARK: - Render Execution Tests

struct RenderExecutionTests {
    func createMockContext() -> HandlerContext {
        let handlerContext = RequestHandlerContext(
            sessionId: "test-session",
            requestId: .number(1),
            _meta: nil,
            taskId: nil,
            authInfo: nil,
            requestInfo: nil,
            closeResponseStream: nil,
            closeNotificationStream: nil,
            sendNotification: { _ in },
            sendRequest: { _ in throw MCPError.internalError("Not implemented") },
            sendData: { _ in },
            shouldSendLogMessage: { _ in true },
        )
        return HandlerContext(handlerContext: handlerContext)
    }

    @Test
    func `render returns expected messages`() async throws {
        let args = ["userName": "World"]
        let prompt = try GreetingPrompt.parse(from: args)
        let context = createMockContext()

        let messages = try await prompt.render(context: context)
        #expect(messages.count == 1)

        #expect(messages[0].role == .user)
        if case let .text(text, _, _) = messages[0].content {
            #expect(text == "Hello, World! How can I help you today?")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `render handles optional argument in output`() async throws {
        let context = createMockContext()

        // Without optional
        let args1 = ["text": "Long text here"]
        let prompt1 = try SummarizePrompt.parse(from: args1)
        let messages1 = try await prompt1.render(context: context)
        #expect(messages1[0].role == .user)
        if case let .text(text, _, _) = messages1[0].content {
            #expect(!text.contains("words"))
        } else {
            Issue.record("Expected text content")
        }

        // With optional
        let args2: [String: String] = ["text": "Long text here", "maxLength": "50"]
        let prompt2 = try SummarizePrompt.parse(from: args2)
        let messages2 = try await prompt2.render(context: context)
        #expect(messages2[0].role == .user)
        if case let .text(text, _, _) = messages2[0].content {
            #expect(text.contains("50 words"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `render returns multiple messages`() async throws {
        let args: [String: String] = [
            "source_code": "let x = 1",
            "review_focus": "best practices",
        ]
        let prompt = try CodeReviewPrompt.parse(from: args)
        let context = createMockContext()

        let messages = try await prompt.render(context: context)
        #expect(messages.count == 2)
    }

    @Test
    func `render with no arguments works`() async throws {
        let prompt = try SimpleGreetingPrompt.parse(from: nil)
        let context = createMockContext()

        let messages = try await prompt.render(context: context)
        #expect(messages.count == 1)
    }

    @Test
    func `Prompt with render() works`() async throws {
        let args = ["input": "Hello simple render"]
        let prompt = try SimpleRenderPrompt.parse(from: args)
        let context = createMockContext()

        // Prompts with render() should work with the bridging render(context:)
        let messages = try await prompt.render(context: context)
        #expect(messages.count == 1)
        #expect(messages[0].role == .user)
        if case let .text(text, _, _) = messages[0].content {
            #expect(text == "Simple render: Hello simple render")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `Prompt with render() and single message output`() async throws {
        let args = ["message": "test message"]
        let prompt = try SimpleRenderSingleMessagePrompt.parse(from: args)
        let context = createMockContext()

        let message = try await prompt.render(context: context)
        #expect(message.role == .assistant)
        if case let .text(text, _, _) = message.content {
            #expect(text == "Response to: test message")
        } else {
            Issue.record("Expected text content")
        }
    }
}

// MARK: - PromptOutput Protocol Tests

struct PromptOutputProtocolTests {
    @Test
    func `String conforms to PromptOutput`() {
        let output: any PromptOutput = "Hello, World!"
        let result = output.toGetPromptResult(description: "Test")

        #expect(result.messages.count == 1)
        #expect(result.messages[0].role == .user)
        if case let .text(text, _, _) = result.messages[0].content {
            #expect(text == "Hello, World!")
        } else {
            Issue.record("Expected text content")
        }
        #expect(result.description == "Test")
    }

    @Test
    func `Prompt.Message conforms to PromptOutput`() {
        let message = Prompt.Message.user(.text("Single message"))
        let result = message.toGetPromptResult(description: "Desc")

        #expect(result.messages.count == 1)
        #expect(result.description == "Desc")
    }

    @Test
    func `[Prompt.Message] conforms to PromptOutput`() {
        let messages: [Prompt.Message] = [
            .user(.text("First")),
            .assistant(.text("Second")),
        ]
        let result = messages.toGetPromptResult(description: nil)

        #expect(result.messages.count == 2)
        #expect(result.description == nil)
    }
}

// MARK: - PromptRegistry Tests

struct PromptRegistryTests {
    func createMockContext() -> HandlerContext {
        let handlerContext = RequestHandlerContext(
            sessionId: "test-session",
            requestId: .number(1),
            _meta: nil,
            taskId: nil,
            authInfo: nil,
            requestInfo: nil,
            closeResponseStream: nil,
            closeNotificationStream: nil,
            sendNotification: { _ in },
            sendRequest: { _ in throw MCPError.internalError("Not implemented") },
            sendData: { _ in },
            shouldSendLogMessage: { _ in true },
        )
        return HandlerContext(handlerContext: handlerContext)
    }

    @Test
    func `PromptRegistry registers prompts via result builder`() async {
        let registry = PromptRegistry {
            GreetingPrompt.self
            InterviewPrompt.self
        }

        let prompts = await registry.listPrompts()
        #expect(prompts.count == 2)

        let names = prompts.map { $0.name }
        #expect(names.contains("greeting"))
        #expect(names.contains("interview"))
    }

    @Test
    func `PromptRegistry registers prompts with register method`() async throws {
        let registry = PromptRegistry()
        try await registry.register(GreetingPrompt.self)
        try await registry.register(SummarizePrompt.self)

        let prompts = await registry.listPrompts()
        #expect(prompts.count == 2)
    }

    @Test
    func `PromptRegistry hasPrompt returns correct value`() async {
        let registry = PromptRegistry {
            GreetingPrompt.self
        }

        let hasGreeting = await registry.hasPrompt("greeting")
        let hasUnknown = await registry.hasPrompt("unknown")

        #expect(hasGreeting == true)
        #expect(hasUnknown == false)
    }

    @Test
    func `PromptRegistry listPrompts returns correct definitions`() async {
        let registry = PromptRegistry {
            BrainstormPrompt.self
        }

        let prompts = await registry.listPrompts()
        #expect(prompts.count == 1)

        let prompt = prompts[0]
        #expect(prompt.name == "brainstorm")
        #expect(prompt.title == "Brainstorming Session")
        #expect(prompt.description == "Generate creative ideas")
    }

    @Test
    func `PromptRegistry getPrompt executes DSL prompt`() async throws {
        let registry = PromptRegistry {
            GreetingPrompt.self
        }

        let context = createMockContext()
        let arguments = ["userName": "Test User"]

        let result = try await registry.getPrompt("greeting", arguments: arguments, context: context)

        #expect(result.messages.count == 1)
        #expect(result.messages[0].role == .user)
        if case let .text(text, _, _) = result.messages[0].content {
            #expect(text.contains("Test User"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `PromptRegistry getPrompt throws for unknown prompt`() async throws {
        let registry = PromptRegistry {
            GreetingPrompt.self
        }

        let context = createMockContext()

        await #expect(throws: MCPError.self) {
            _ = try await registry.getPrompt("nonexistent", arguments: nil, context: context)
        }
    }

    @Test
    func `PromptRegistry registers closure-based prompts`() async throws {
        let registry = PromptRegistry()

        try await registry.register(
            name: "dynamic_prompt",
            description: "A dynamically registered prompt",
            arguments: [
                Prompt.Argument(name: "topic", description: "Discussion topic", required: true),
            ],
        ) { args, _ in
            let topic = args?["topic"] ?? "general"
            return [.user(.text("Let's discuss: \(topic)"))]
        }

        let prompts = await registry.listPrompts()
        #expect(prompts.count == 1)
        #expect(prompts[0].name == "dynamic_prompt")

        let context = createMockContext()
        let result = try await registry.getPrompt(
            "dynamic_prompt",
            arguments: ["topic": "Swift"],
            context: context,
        )

        #expect(result.messages[0].role == .user)
        if case let .text(text, _, _) = result.messages[0].content {
            #expect(text.contains("Swift"))
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `PromptRegistry prevents duplicate registration`() async throws {
        let registry = PromptRegistry()
        try await registry.register(GreetingPrompt.self)

        await #expect(throws: MCPError.self) {
            try await registry.register(GreetingPrompt.self)
        }
    }
}

// MARK: - Lifecycle Management Tests

struct PromptLifecycleTests {
    func createMockContext() -> HandlerContext {
        let handlerContext = RequestHandlerContext(
            sessionId: "test-session",
            requestId: .number(1),
            _meta: nil,
            taskId: nil,
            authInfo: nil,
            requestInfo: nil,
            closeResponseStream: nil,
            closeNotificationStream: nil,
            sendNotification: { _ in },
            sendRequest: { _ in throw MCPError.internalError("Not implemented") },
            sendData: { _ in },
            shouldSendLogMessage: { _ in true },
        )
        return HandlerContext(handlerContext: handlerContext)
    }

    @Test
    func `DSL prompt registration returns RegisteredPrompt`() async throws {
        let registry = PromptRegistry()
        let registered = try await registry.register(GreetingPrompt.self)

        #expect(registered.name == "greeting")
        #expect(await registered.isEnabled == true)
    }

    @Test
    func `DSL prompt can be disabled`() async throws {
        let registry = PromptRegistry()
        let registered = try await registry.register(GreetingPrompt.self)

        await registered.disable()

        #expect(await registered.isEnabled == false)

        // Disabled prompt should not appear in listings
        let prompts = await registry.listPrompts()
        #expect(prompts.isEmpty)
    }

    @Test
    func `DSL prompt can be re-enabled`() async throws {
        let registry = PromptRegistry()
        let registered = try await registry.register(GreetingPrompt.self)

        await registered.disable()
        #expect(await registered.isEnabled == false)

        await registered.enable()
        #expect(await registered.isEnabled == true)

        let prompts = await registry.listPrompts()
        #expect(prompts.count == 1)
    }

    @Test
    func `DSL prompt can be removed`() async throws {
        let registry = PromptRegistry()
        let registered = try await registry.register(GreetingPrompt.self)

        #expect(await registry.hasPrompt("greeting") == true)

        await registered.remove()

        #expect(await registry.hasPrompt("greeting") == false)
        let prompts = await registry.listPrompts()
        #expect(prompts.isEmpty)
    }

    @Test
    func `Disabled DSL prompt rejects execution`() async throws {
        let registry = PromptRegistry()
        let registered = try await registry.register(GreetingPrompt.self)
        await registered.disable()

        let context = createMockContext()
        let arguments = ["userName": "Test"]

        await #expect(throws: MCPError.self) {
            _ = try await registry.getPrompt("greeting", arguments: arguments, context: context)
        }
    }

    @Test
    func `Multiple DSL prompts have independent lifecycle`() async throws {
        let registry = PromptRegistry()
        let greeting = try await registry.register(GreetingPrompt.self)
        let interview = try await registry.register(InterviewPrompt.self)

        // Disable only greeting
        await greeting.disable()

        // Greeting should be disabled, interview should still be enabled
        #expect(await greeting.isEnabled == false)
        #expect(await interview.isEnabled == true)

        // Only interview should appear in listings
        let prompts = await registry.listPrompts()
        #expect(prompts.count == 1)
        #expect(prompts.first?.name == "interview")
    }

    @Test
    func `Prompts registered via result builder start enabled`() async {
        let registry = PromptRegistry {
            GreetingPrompt.self
            InterviewPrompt.self
        }

        let prompts = await registry.listPrompts()
        #expect(prompts.count == 2)

        #expect(await registry.isPromptEnabled("greeting") == true)
        #expect(await registry.isPromptEnabled("interview") == true)
    }
}

// MARK: - Edge Cases

struct PromptEdgeCaseTests {
    @Test
    func `Empty string argument is valid`() throws {
        let args = ["userName": ""]
        let prompt = try GreetingPrompt.parse(from: args)
        #expect(prompt.userName == "")
    }

    @Test
    func `Unicode in arguments is preserved`() throws {
        let unicodeName = "世界 \u{1F30D} مرحبا"
        let args: [String: String] = ["userName": unicodeName]
        let prompt = try GreetingPrompt.parse(from: args)
        #expect(prompt.userName == unicodeName)
    }

    @Test
    func `Special characters in arguments are preserved`() throws {
        let specialText = "Line1\nLine2\tTabbed\"Quoted\""
        let args: [String: String] = ["userName": specialText]
        let prompt = try GreetingPrompt.parse(from: args)
        #expect(prompt.userName == specialText)
    }

    @Test
    func `Very long argument is handled`() throws {
        let longText = String(repeating: "a", count: 10000)
        let args: [String: String] = ["userName": longText]
        let prompt = try GreetingPrompt.parse(from: args)
        #expect(prompt.userName == longText)
    }

    @Test
    func `Arguments with nil dictionary`() throws {
        // SimpleGreetingPrompt has no required arguments
        let prompt = try SimpleGreetingPrompt.parse(from: nil)
        _ = prompt // Should not throw
    }
}

// MARK: - ArgumentValue Protocol Tests

struct ArgumentValueProtocolTests {
    @Test
    func `String ArgumentValue properties`() {
        #expect(String.isOptional == false)

        let value = String(argumentString: "hello")
        #expect(value == "hello")

        let nilValue = String(argumentString: nil)
        #expect(nilValue == nil)
    }

    @Test
    func `Optional<String> ArgumentValue properties`() {
        #expect(String?.isOptional == true)

        let value: String?? = String?(argumentString: "hello")
        #expect(value == "hello")

        let nilValue: String?? = String?(argumentString: nil)
        #expect(nilValue == .some(nil))
    }
}
