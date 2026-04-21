// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation
@testable import MCP
import Testing

struct PromptTests {
    @Test
    func `Prompt initialization with valid parameters`() {
        let argument = Prompt.Argument(
            name: "test_arg",
            description: "A test argument",
            required: true,
        )

        let prompt = Prompt(
            name: "test_prompt",
            description: "A test prompt",
            arguments: [argument],
        )

        #expect(prompt.name == "test_prompt")
        #expect(prompt.description == "A test prompt")
        #expect(prompt.arguments?.count == 1)
        #expect(prompt.arguments?[0].name == "test_arg")
        #expect(prompt.arguments?[0].description == "A test argument")
        #expect(prompt.arguments?[0].required == true)
    }

    @Test
    func `Prompt Message encoding and decoding`() throws {
        let textMessage: Prompt.Message = .user("Hello, world!")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(textMessage)
        let decoded = try decoder.decode(Prompt.Message.self, from: data)

        #expect(decoded.role == .user)
        if case let .text(text, _, _) = decoded.content {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test
    func `Prompt Message Content types encoding and decoding`() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test text content
        let textContent = ContentBlock.text("Test text")
        let textData = try encoder.encode(textContent)
        let decodedText = try decoder.decode(ContentBlock.self, from: textData)
        if case let .text(text, _, _) = decodedText {
            #expect(text == "Test text")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test audio content
        let audioContent = ContentBlock.audio(
            data: "base64audiodata", mimeType: "audio/wav",
        )
        let audioData = try encoder.encode(audioContent)
        let decodedAudio = try decoder.decode(ContentBlock.self, from: audioData)
        if case let .audio(data, mimeType, _, _) = decodedAudio {
            #expect(data == "base64audiodata")
            #expect(mimeType == "audio/wav")
        } else {
            #expect(Bool(false), "Expected audio content")
        }

        // Test image content
        let imageContent = ContentBlock.image(data: "base64data", mimeType: "image/png")
        let imageData = try encoder.encode(imageContent)
        let decodedImage = try decoder.decode(ContentBlock.self, from: imageData)
        if case let .image(data, mimeType, _, _) = decodedImage {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }

        // Test resource content
        let resourceContent = ContentBlock.resource(
            uri: "file://test.txt",
            mimeType: "text/plain",
            text: "Sample text",
        )
        let resourceData = try encoder.encode(resourceContent)
        let decodedResource = try decoder.decode(ContentBlock.self, from: resourceData)
        if case let .resource(resourceData, _, _) = decodedResource {
            #expect(resourceData.uri == "file://test.txt")
            #expect(resourceData.mimeType == "text/plain")
            #expect(resourceData.text == "Sample text")
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test
    func `Prompt Reference validation`() throws {
        let reference = Prompt.Reference(name: "test_prompt")
        #expect(reference.name == "test_prompt")
        #expect(reference.title == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(Prompt.Reference.self, from: data)

        #expect(decoded.name == "test_prompt")
        #expect(decoded.title == nil)
    }

    @Test
    func `Prompt Reference with title validation`() throws {
        let reference = Prompt.Reference(name: "test_prompt", title: "Test Prompt")
        #expect(reference.name == "test_prompt")
        #expect(reference.title == "Test Prompt")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(reference)
        let decoded = try decoder.decode(Prompt.Reference.self, from: data)

        #expect(decoded.name == "test_prompt")
        #expect(decoded.title == "Test Prompt")

        // Verify JSON structure includes title
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(jsonObject["type"] as? String == "ref/prompt")
        #expect(jsonObject["name"] as? String == "test_prompt")
        #expect(jsonObject["title"] as? String == "Test Prompt")
    }

    @Test
    func `GetPrompt parameters validation`() {
        // Per MCP spec, prompt arguments must be string values
        let arguments: [String: String] = [
            "param1": "value1",
            "param2": "42",
        ]

        let params = GetPrompt.Parameters(name: "test_prompt", arguments: arguments)
        #expect(params.name == "test_prompt")
        #expect(params.arguments?["param1"] == "value1")
        #expect(params.arguments?["param2"] == "42")
    }

    @Test
    func `GetPrompt result validation`() {
        let messages: [Prompt.Message] = [
            .user("User message"),
            .assistant("Assistant response"),
        ]

        let result = GetPrompt.Result(description: "Test description", messages: messages)
        #expect(result.description == "Test description")
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[1].role == .assistant)
    }

    @Test
    func `ListPrompts parameters validation`() {
        let params = ListPrompts.Parameters(cursor: "next_page")
        #expect(params.cursor == "next_page")

        let emptyParams = ListPrompts.Parameters()
        #expect(emptyParams.cursor == nil)
    }

    @Test
    func `ListPrompts request decoding with omitted params`() throws {
        // Test decoding when params field is omitted
        let jsonString = """
        {"jsonrpc":"2.0","id":"test-id","method":"prompts/list"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListPrompts>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListPrompts.name)
    }

    @Test
    func `ListPrompts request decoding with null params`() throws {
        // Test decoding when params field is null
        let jsonString = """
        {"jsonrpc":"2.0","id":"test-id","method":"prompts/list","params":null}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<ListPrompts>.self, from: data)

        #expect(decoded.id == "test-id")
        #expect(decoded.method == ListPrompts.name)
    }

    @Test
    func `ListPrompts result validation`() {
        let prompts = [
            Prompt(name: "prompt1", description: "First prompt"),
            Prompt(name: "prompt2", description: "Second prompt"),
        ]

        let result = ListPrompts.Result(prompts: prompts, nextCursor: "next_page")
        #expect(result.prompts.count == 2)
        #expect(result.prompts[0].name == "prompt1")
        #expect(result.prompts[1].name == "prompt2")
        #expect(result.nextCursor == "next_page")
    }

    @Test
    func `PromptListChanged notification name validation`() {
        #expect(PromptListChangedNotification.name == "notifications/prompts/list_changed")
    }

    @Test
    func `Prompt Message factory methods`() {
        // Test user message factory method
        let userMessage: Prompt.Message = .user("Hello, world!")
        #expect(userMessage.role == .user)
        if case let .text(text, _, _) = userMessage.content {
            #expect(text == "Hello, world!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message factory method
        let assistantMessage: Prompt.Message = .assistant("Hi there!")
        #expect(assistantMessage.role == .assistant)
        if case let .text(text, _, _) = assistantMessage.content {
            #expect(text == "Hi there!")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test with image content
        let imageMessage: Prompt.Message = .user(.image(data: "base64data", mimeType: "image/png"))
        #expect(imageMessage.role == .user)
        if case let .image(data, mimeType, _, _) = imageMessage.content {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
        } else {
            #expect(Bool(false), "Expected image content")
        }

        // Test with audio content
        let audioMessage: Prompt.Message = .assistant(
            .audio(data: "base64audio", mimeType: "audio/wav"),
        )
        #expect(audioMessage.role == .assistant)
        if case let .audio(data, mimeType, _, _) = audioMessage.content {
            #expect(data == "base64audio")
            #expect(mimeType == "audio/wav")
        } else {
            #expect(Bool(false), "Expected audio content")
        }

        // Test with resource content
        let resourceMessage: Prompt.Message = .user(
            .resource(uri: "file://test.txt", mimeType: "text/plain", text: "Sample text"),
        )
        #expect(resourceMessage.role == .user)
        if case let .resource(resourceContent, _, _) = resourceMessage.content {
            #expect(resourceContent.uri == "file://test.txt")
            #expect(resourceContent.mimeType == "text/plain")
            #expect(resourceContent.text == "Sample text")
        } else {
            #expect(Bool(false), "Expected resource content")
        }
    }

    @Test
    func `Prompt Content ExpressibleByStringLiteral`() {
        // Test string literal assignment
        let content: ContentBlock = "Hello from string literal"

        if case let .text(text, _, _) = content {
            #expect(text == "Hello from string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation
        let message: Prompt.Message = .user("Direct string literal")
        if case let .text(text, _, _) = message.content {
            #expect(text == "Direct string literal")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in array context
        let messages: [Prompt.Message] = [
            .user("First message"),
            .assistant("Second message"),
            .user("Third message"),
        ]

        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[2].role == .user)
    }

    @Test
    func `Prompt Content ExpressibleByStringInterpolation`() {
        let userName = "Alice"
        let position = "Software Engineer"
        let company = "TechCorp"

        // Test string interpolation
        let content: ContentBlock =
            "Hello \(userName), welcome to your \(position) interview at \(company)"

        if case let .text(text, _, _) = content {
            #expect(text == "Hello Alice, welcome to your Software Engineer interview at TechCorp")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in message creation with interpolation
        let message: Prompt.Message = .user(
            "Hi \(userName), I'm excited about the \(position) role at \(company)",
        )
        if case let .text(text, _, _) = message.content {
            #expect(text == "Hi Alice, I'm excited about the Software Engineer role at TechCorp")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test complex interpolation
        let skills = ["Swift", "Python", "JavaScript"]
        let experience = 5
        let interviewMessage: Prompt.Message = .assistant(
            "I see you have \(experience) years of experience with \(skills.joined(separator: ", ")). That's impressive!",
        )

        if case let .text(text, _, _) = interviewMessage.content {
            #expect(
                text
                    == "I see you have 5 years of experience with Swift, Python, JavaScript. That's impressive!",
            )
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test
    func `Prompt Message factory methods with string interpolation`() {
        let candidateName = "Bob"
        let position = "Data Scientist"
        let company = "DataCorp"
        let experience = 3

        // Test user message with interpolation
        let userMessage: Prompt.Message = .user(
            "Hello, I'm \(candidateName) and I'm interviewing for the \(position) position",
        )
        #expect(userMessage.role == .user)
        if case let .text(text, _, _) = userMessage.content {
            #expect(text == "Hello, I'm Bob and I'm interviewing for the Data Scientist position")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test assistant message with interpolation
        let assistantMessage: Prompt.Message = .assistant(
            "Welcome \(candidateName)! Tell me about your \(experience) years of experience in data science",
        )
        #expect(assistantMessage.role == .assistant)
        if case let .text(text, _, _) = assistantMessage.content {
            #expect(text == "Welcome Bob! Tell me about your 3 years of experience in data science")
        } else {
            #expect(Bool(false), "Expected text content")
        }

        // Test in conversation array
        let conversation: [Prompt.Message] = [
            .user("Hi, I'm \(candidateName) applying for \(position) at \(company)"),
            .assistant("Welcome \(candidateName)! How many years of experience do you have?"),
            .user("I have \(experience) years of experience in the field"),
            .assistant(
                "Great! \(experience) years is solid experience for a \(position) role at \(company)",
            ),
        ]

        #expect(conversation.count == 4)

        // Verify interpolated content
        if case let .text(text, _, _) = conversation[2].content {
            #expect(text == "I have 3 years of experience in the field")
        } else {
            #expect(Bool(false), "Expected text content")
        }
    }

    @Test
    func `Prompt ergonomic API usage patterns`() throws {
        // Test various ergonomic usage patterns enabled by the new API

        // Pattern 1: Simple interview conversation
        let interviewConversation: [Prompt.Message] = [
            .user("Tell me about yourself"),
            .assistant("I'm a software engineer with 5 years of experience"),
            .user("What's your biggest strength?"),
            .assistant("I'm great at problem-solving and team collaboration"),
        ]
        #expect(interviewConversation.count == 4)

        // Pattern 2: Dynamic content with interpolation
        let candidateName = "Sarah"
        let role = "Product Manager"
        let yearsExp = 7

        let dynamicConversation: [Prompt.Message] = [
            .user("Welcome \(candidateName) to the \(role) interview"),
            .assistant("Thank you! I'm excited about this \(role) opportunity"),
            .user("I see you have \(yearsExp) years of experience. Tell me about your background"),
            .assistant(
                "In my \(yearsExp) years as a \(role), I've led multiple successful product launches",
            ),
        ]
        #expect(dynamicConversation.count == 4)

        // Pattern 3: Mixed content types
        let mixedContent: [Prompt.Message] = [
            .user("Please review this design mockup"),
            .assistant(.image(data: "design_mockup_data", mimeType: "image/png")),
            .user("What do you think of the user flow?"),
            .assistant(
                "The design looks clean and intuitive. I particularly like the navigation structure.",
            ),
        ]
        #expect(mixedContent.count == 4)

        // Verify content types
        if case .text = mixedContent[0].content,
           case .image = mixedContent[1].content,
           case .text = mixedContent[2].content,
           case .text = mixedContent[3].content
        {
            // All content types are correct
        } else {
            #expect(Bool(false), "Content types don't match expected pattern")
        }

        // Pattern 4: Encoding/decoding still works
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(interviewConversation)
        let decoded = try decoder.decode([Prompt.Message].self, from: data)

        #expect(decoded.count == 4)
        #expect(decoded[0].role == .user)
        #expect(decoded[1].role == .assistant)
        #expect(decoded[2].role == .user)
        #expect(decoded[3].role == .assistant)
    }
}

// MARK: - Prompt Pagination Tests

struct PromptPaginationTests {
    @Test
    func `ListPrompts cursor parameter encodes correctly`() throws {
        let testCursor = "test-cursor-123"
        let params = ListPrompts.Parameters(cursor: testCursor)

        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(jsonString.contains("\"cursor\":\"test-cursor-123\""))
    }

    @Test
    func `ListPrompts result with nextCursor encodes correctly`() throws {
        let prompts = [
            Prompt(name: "prompt1", description: "First prompt"),
            Prompt(name: "prompt2", description: "Second prompt"),
        ]
        let result = ListPrompts.Result(prompts: prompts, nextCursor: "next-page-token")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListPrompts.Result.self, from: data)

        #expect(decoded.prompts.count == 2)
        #expect(decoded.nextCursor == "next-page-token")
    }

    @Test
    func `ListPrompts result without nextCursor indicates end of pagination`() throws {
        let prompts = [
            Prompt(name: "final_prompt", description: "Final prompt"),
        ]
        let result = ListPrompts.Result(prompts: prompts, nextCursor: nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListPrompts.Result.self, from: data)

        #expect(decoded.nextCursor == nil)

        // Verify null cursor is not included in JSON
        let jsonString = try #require(String(data: data, encoding: .utf8))
        #expect(!jsonString.contains("nextCursor"))
    }

    @Test
    func `ListPrompts request with cursor decodes correctly`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":"page-2","method":"prompts/list","params":{"cursor":"page-1-token"}}
        """
        let jsonData = try #require(jsonString.data(using: .utf8))

        let decoded = try JSONDecoder().decode(Request<ListPrompts>.self, from: jsonData)

        #expect(decoded.id == "page-2")
        #expect(decoded.params.cursor == "page-1-token")
    }

    @Test
    func `Simulated multi-page prompt listing`() throws {
        // Simulate a server that returns 20 prompts across multiple pages
        let allPrompts = (0 ..< 20).map { i in
            Prompt(name: "prompt_\(i)", description: "Prompt number \(i)")
        }

        let pageSize = 7
        var collectedPrompts: [Prompt] = []
        var currentCursor: String?

        // Simulate pagination
        for pageIndex in 0 ..< 3 {
            let startIndex = pageIndex * pageSize
            let endIndex = min(startIndex + pageSize, allPrompts.count)
            let pagePrompts = Array(allPrompts[startIndex ..< endIndex])

            let nextCursor = endIndex < allPrompts.count ? "page-\(pageIndex + 1)" : nil
            let result = ListPrompts.Result(prompts: pagePrompts, nextCursor: nextCursor)

            // Encode and decode to verify serialization
            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            let data = try encoder.encode(result)
            let decoded = try decoder.decode(ListPrompts.Result.self, from: data)

            collectedPrompts.append(contentsOf: decoded.prompts)
            currentCursor = decoded.nextCursor

            if currentCursor == nil {
                break
            }
        }

        #expect(collectedPrompts.count == 20)
        #expect(currentCursor == nil)

        // Verify all prompts are unique and have correct names
        let promptNames = Set(collectedPrompts.map { $0.name })
        #expect(promptNames.count == 20)

        let expectedNames = Set((0 ..< 20).map { "prompt_\($0)" })
        #expect(promptNames == expectedNames)
    }

    @Test
    func `Paginated prompt listing`() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        // Track pagination state
        let paginationState = PromptPaginationState()

        let server = Server(
            name: "PaginatedPromptServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init()),
        )

        // Handler returns paginated prompts
        await server.withRequestHandler(ListPrompts.self) { [paginationState] params, _ in
            let cursor = params.cursor
            return await paginationState.getPage(cursor: cursor)
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "PromptPaginationClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // First page (no cursor)
        let page1 = try await client.listPrompts()
        #expect(page1.prompts.count == 3)
        #expect(page1.prompts[0].name == "prompt_1")
        #expect(page1.prompts[1].name == "prompt_2")
        #expect(page1.prompts[2].name == "prompt_3")
        #expect(page1.nextCursor == "page_2")

        // Second page (with cursor)
        let page2 = try await client.listPrompts(cursor: page1.nextCursor)
        #expect(page2.prompts.count == 3)
        #expect(page2.prompts[0].name == "prompt_4")
        #expect(page2.prompts[1].name == "prompt_5")
        #expect(page2.prompts[2].name == "prompt_6")
        #expect(page2.nextCursor == "page_3")

        // Third page (last page)
        let page3 = try await client.listPrompts(cursor: page2.nextCursor)
        #expect(page3.prompts.count == 2)
        #expect(page3.prompts[0].name == "prompt_7")
        #expect(page3.prompts[1].name == "prompt_8")
        #expect(page3.nextCursor == nil)

        await client.disconnect()
        await server.stop()
    }

    @Test
    func `Empty prompt listing result`() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()

        let server = Server(
            name: "EmptyPromptServer",
            version: "1.0.0",
            capabilities: .init(prompts: .init()),
        )

        // Handler returns empty prompt list
        await server.withRequestHandler(ListPrompts.self) { _, _ in
            ListPrompts.Result(prompts: [])
        }

        try await server.start(transport: serverTransport)

        let client = Client(name: "EmptyPromptClient", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // Verify empty list is handled correctly
        let result = try await client.listPrompts()
        #expect(result.prompts.isEmpty)
        #expect(result.nextCursor == nil)

        await client.disconnect()
        await server.stop()
    }
}

// MARK: - Prompt ResourceLink Tests

struct PromptResourceLinkTests {
    @Test
    func `Prompt Message with ResourceLink content encoding and decoding`() throws {
        let resourceLink = ResourceLink(
            name: "main.rs",
            uri: "file:///project/src/main.rs",
            description: "Primary application entry point",
            mimeType: "text/x-rust",
        )

        let message: Prompt.Message = .assistant(.resourceLink(resourceLink))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(Prompt.Message.self, from: data)

        #expect(decoded.role == .assistant)
        if case let .resourceLink(decodedLink) = decoded.content {
            #expect(decodedLink.uri == "file:///project/src/main.rs")
            #expect(decodedLink.name == "main.rs")
            #expect(decodedLink.description == "Primary application entry point")
            #expect(decodedLink.mimeType == "text/x-rust")
        } else {
            #expect(Bool(false), "Expected resourceLink content")
        }
    }

    @Test
    func `Prompt Message with ResourceLink minimal fields`() throws {
        let resourceLink = ResourceLink(
            name: "file.txt",
            uri: "file:///path/to/file.txt",
        )

        let message: Prompt.Message = .user(.resourceLink(resourceLink))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(Prompt.Message.self, from: data)

        #expect(decoded.role == .user)
        if case let .resourceLink(decodedLink) = decoded.content {
            #expect(decodedLink.uri == "file:///path/to/file.txt")
            #expect(decodedLink.name == "file.txt")
            #expect(decodedLink.description == nil)
            #expect(decodedLink.mimeType == nil)
        } else {
            #expect(Bool(false), "Expected resourceLink content")
        }
    }

    @Test
    func `GetPrompt result with mixed content types including ResourceLink`() throws {
        let resourceLink = ResourceLink(
            name: "README.md",
            uri: "file:///project/README.md",
            mimeType: "text/markdown",
        )

        let messages: [Prompt.Message] = [
            .user("Please review this file:"),
            .assistant(.resourceLink(resourceLink)),
            .assistant("I'll analyze the README file for you."),
        ]

        let result = GetPrompt.Result(description: "File review prompt", messages: messages)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(GetPrompt.Result.self, from: data)

        #expect(decoded.messages.count == 3)
        #expect(decoded.description == "File review prompt")

        // Verify first message is text
        if case let .text(text, _, _) = decoded.messages[0].content {
            #expect(text == "Please review this file:")
        } else {
            #expect(Bool(false), "Expected text content for first message")
        }

        // Verify second message is resourceLink
        if case let .resourceLink(link) = decoded.messages[1].content {
            #expect(link.uri == "file:///project/README.md")
            #expect(link.name == "README.md")
        } else {
            #expect(Bool(false), "Expected resourceLink content for second message")
        }

        // Verify third message is text
        if case let .text(text, _, _) = decoded.messages[2].content {
            #expect(text == "I'll analyze the README file for you.")
        } else {
            #expect(Bool(false), "Expected text content for third message")
        }
    }
}

// MARK: - Prompt Advanced Features Tests

struct PromptAdvancedFeaturesTests {
    @Test
    func `Prompt with icons encoding and decoding`() throws {
        let icons = [
            Icon(src: "https://example.com/icon.png", mimeType: "image/png", sizes: ["48x48", "96x96"]),
            Icon(src: "data:image/svg+xml;base64,PHN2Zz4=", mimeType: "image/svg+xml", sizes: ["any"], theme: .light),
        ]

        let prompt = Prompt(
            name: "my_prompt",
            title: "My Prompt",
            description: "A prompt with icons",
            icons: icons,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(prompt)
        let decoded = try decoder.decode(Prompt.self, from: data)

        #expect(decoded.name == "my_prompt")
        #expect(decoded.title == "My Prompt")
        #expect(decoded.icons?.count == 2)
        #expect(decoded.icons?[0].src == "https://example.com/icon.png")
        #expect(decoded.icons?[0].mimeType == "image/png")
        #expect(decoded.icons?[0].sizes == ["48x48", "96x96"])
        #expect(decoded.icons?[1].theme == .light)
    }

    @Test
    func `Prompt with _meta encoding and decoding`() throws {
        let meta: [String: Value] = [
            "customField": "customValue",
            "version": 2,
            "tags": ["interview", "technical"],
        ]

        let prompt = Prompt(
            name: "meta_prompt",
            description: "A prompt with metadata",
            _meta: meta,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(prompt)
        let decoded = try decoder.decode(Prompt.self, from: data)

        #expect(decoded.name == "meta_prompt")
        #expect(decoded._meta?["customField"]?.stringValue == "customValue")
        #expect(decoded._meta?["version"]?.intValue == 2)
        #expect(decoded._meta?["tags"]?.arrayValue?.count == 2)
    }

    @Test
    func `Prompt Argument with title encoding and decoding`() throws {
        let argument = Prompt.Argument(
            name: "candidate_name",
            title: "Candidate Name",
            description: "The name of the candidate being interviewed",
            required: true,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(argument)
        let decoded = try decoder.decode(Prompt.Argument.self, from: data)

        #expect(decoded.name == "candidate_name")
        #expect(decoded.title == "Candidate Name")
        #expect(decoded.description == "The name of the candidate being interviewed")
        #expect(decoded.required == true)
    }

    @Test
    func `Prompt Message Content with annotations`() throws {
        let annotations = Annotations(
            audience: [.user, .assistant],
            priority: 0.8,
            lastModified: "2025-01-03T12:00:00Z",
        )

        let content = ContentBlock.text(
            "Important message",
            annotations: annotations,
            _meta: ["source": "test"],
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(ContentBlock.self, from: data)

        if case let .text(text, decodedAnnotations, meta) = decoded {
            #expect(text == "Important message")
            #expect(decodedAnnotations?.audience == [.user, .assistant])
            #expect(decodedAnnotations?.priority == 0.8)
            #expect(decodedAnnotations?.lastModified == "2025-01-03T12:00:00Z")
            #expect(meta?["source"]?.stringValue == "test")
        } else {
            #expect(Bool(false), "Expected text content with annotations")
        }
    }

    @Test
    func `Image content with annotations`() throws {
        let annotations = Annotations(audience: [.user], priority: 0.5)

        let content = ContentBlock.image(
            data: "base64imagedata",
            mimeType: "image/png",
            annotations: annotations,
            _meta: nil,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(ContentBlock.self, from: data)

        if case let .image(imageData, mimeType, decodedAnnotations, _) = decoded {
            #expect(imageData == "base64imagedata")
            #expect(mimeType == "image/png")
            #expect(decodedAnnotations?.audience == [.user])
            #expect(decodedAnnotations?.priority == 0.5)
        } else {
            #expect(Bool(false), "Expected image content with annotations")
        }
    }

    @Test
    func `Audio content with annotations`() throws {
        let annotations = Annotations(priority: 1.0)

        let content = ContentBlock.audio(
            data: "base64audiodata",
            mimeType: "audio/wav",
            annotations: annotations,
            _meta: ["duration": 120],
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(ContentBlock.self, from: data)

        if case let .audio(audioData, mimeType, decodedAnnotations, meta) = decoded {
            #expect(audioData == "base64audiodata")
            #expect(mimeType == "audio/wav")
            #expect(decodedAnnotations?.priority == 1.0)
            #expect(meta?["duration"]?.intValue == 120)
        } else {
            #expect(Bool(false), "Expected audio content with annotations")
        }
    }

    @Test
    func `Resource content with annotations`() throws {
        let annotations = Annotations(
            audience: [.assistant],
            lastModified: "2025-01-01T00:00:00Z",
        )
        let resourceContent = Resource.Content.text("File content", uri: "file:///test.txt", mimeType: "text/plain")

        let content = ContentBlock.resource(
            resource: resourceContent,
            annotations: annotations,
            _meta: nil,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(content)
        let decoded = try decoder.decode(ContentBlock.self, from: data)

        if case let .resource(resource, decodedAnnotations, _) = decoded {
            #expect(resource.uri == "file:///test.txt")
            #expect(resource.text == "File content")
            #expect(decodedAnnotations?.audience == [.assistant])
            #expect(decodedAnnotations?.lastModified == "2025-01-01T00:00:00Z")
        } else {
            #expect(Bool(false), "Expected resource content with annotations")
        }
    }

    @Test
    func `GetPrompt result with _meta`() throws {
        let messages: [Prompt.Message] = [
            .user("Hello"),
            .assistant("Hi there!"),
        ]

        let result = GetPrompt.Result(
            description: "Test prompt",
            messages: messages,
            _meta: ["generatedAt": "2025-01-03", "version": 1],
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(GetPrompt.Result.self, from: data)

        #expect(decoded.description == "Test prompt")
        #expect(decoded.messages.count == 2)
        #expect(decoded._meta?["generatedAt"]?.stringValue == "2025-01-03")
        #expect(decoded._meta?["version"]?.intValue == 1)
    }

    @Test
    func `ListPrompts result with _meta`() throws {
        let prompts = [
            Prompt(name: "prompt1", description: "First prompt"),
        ]

        let result = ListPrompts.Result(
            prompts: prompts,
            nextCursor: nil,
            _meta: ["totalCount": 100, "filteredBy": "category"],
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(result)
        let decoded = try decoder.decode(ListPrompts.Result.self, from: data)

        #expect(decoded.prompts.count == 1)
        #expect(decoded._meta?["totalCount"]?.intValue == 100)
        #expect(decoded._meta?["filteredBy"]?.stringValue == "category")
    }

    @Test
    func `Full prompt with all optional fields`() throws {
        let icons = [
            Icon(src: "https://example.com/icon.svg", mimeType: "image/svg+xml"),
        ]
        let arguments = [
            Prompt.Argument(
                name: "role",
                title: "Job Role",
                description: "The role to interview for",
                required: true,
            ),
            Prompt.Argument(
                name: "level",
                title: "Experience Level",
                description: "Junior, Mid, or Senior",
                required: false,
            ),
        ]
        let meta: [String: Value] = ["category": "interview", "author": "system"]

        let prompt = Prompt(
            name: "interview_prompt",
            title: "Technical Interview",
            description: "A comprehensive technical interview prompt",
            arguments: arguments,
            _meta: meta,
            icons: icons,
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(prompt)
        let decoded = try decoder.decode(Prompt.self, from: data)

        #expect(decoded.name == "interview_prompt")
        #expect(decoded.title == "Technical Interview")
        #expect(decoded.description == "A comprehensive technical interview prompt")
        #expect(decoded.arguments?.count == 2)
        #expect(decoded.arguments?[0].title == "Job Role")
        #expect(decoded.arguments?[1].required == false)
        #expect(decoded._meta?["category"]?.stringValue == "interview")
        #expect(decoded.icons?.count == 1)
        #expect(decoded.icons?[0].mimeType == "image/svg+xml")
    }

    @Test
    func `ResourceLink with all optional fields in prompt message`() throws {
        let annotations = Annotations(audience: [.user], priority: 0.9)
        let icons = [Icon(src: "https://example.com/file-icon.png")]

        let resourceLink = ResourceLink(
            name: "config.json",
            title: "Configuration File",
            uri: "file:///project/config.json",
            description: "Project configuration",
            mimeType: "application/json",
            size: 1024,
            annotations: annotations,
            icons: icons,
            _meta: ["editable": true],
        )

        let message: Prompt.Message = .user(.resourceLink(resourceLink))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(message)
        let decoded = try decoder.decode(Prompt.Message.self, from: data)

        if case let .resourceLink(link) = decoded.content {
            #expect(link.name == "config.json")
            #expect(link.title == "Configuration File")
            #expect(link.uri == "file:///project/config.json")
            #expect(link.description == "Project configuration")
            #expect(link.mimeType == "application/json")
            #expect(link.size == 1024)
            #expect(link.annotations?.audience == [.user])
            #expect(link.annotations?.priority == 0.9)
            #expect(link.icons?.count == 1)
            #expect(link._meta?["editable"]?.boolValue == true)
        } else {
            #expect(Bool(false), "Expected resourceLink content")
        }
    }
}

// MARK: - Test Helpers

/// Actor to track pagination state for prompt tests
private actor PromptPaginationState {
    private let allPrompts: [Prompt] = (1 ... 8).map { i in
        Prompt(name: "prompt_\(i)", description: "Prompt number \(i)")
    }

    private let pageSize = 3

    func getPage(cursor: String?) -> ListPrompts.Result {
        let startIndex: Int
        let nextCursor: String?

        switch cursor {
            case nil:
                startIndex = 0
                nextCursor = "page_2"
            case "page_2":
                startIndex = 3
                nextCursor = "page_3"
            case "page_3":
                startIndex = 6
                nextCursor = nil
            default:
                return ListPrompts.Result(prompts: [])
        }

        let endIndex = min(startIndex + pageSize, allPrompts.count)
        let pagePrompts = Array(allPrompts[startIndex ..< endIndex])

        return ListPrompts.Result(prompts: pagePrompts, nextCursor: nextCursor)
    }
}
