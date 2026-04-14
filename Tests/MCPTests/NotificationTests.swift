// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
@testable import MCP
import Testing

struct NotificationTests {
    struct TestNotification: Notification {
        struct Parameters: Codable, Hashable {
            let event: String
        }

        static let name = "test.notification"
    }

    struct InitializedNotification: Notification {
        static let name = "notifications/initialized"
    }

    @Test
    func `Notification initialization with parameters`() throws {
        let params = TestNotification.Parameters(event: "test-event")
        let notification = TestNotification.message(params)

        #expect(notification.method == TestNotification.name)
        #expect(notification.params.event == "test-event")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(Message<TestNotification>.self, from: data)

        #expect(decoded.method == notification.method)
        #expect(decoded.params.event == notification.params.event)
    }

    @Test
    func `Empty parameters notification`() throws {
        struct EmptyNotification: Notification {
            static let name = "empty.notification"
        }

        let notification = EmptyNotification.message()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(Message<EmptyNotification>.self, from: data)

        #expect(decoded.method == notification.method)
    }

    @Test
    func `Initialized notification encoding`() throws {
        let notification = InitializedNotification.message()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)

        // Verify the exact JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/initialized")
        #expect(json.count == 2, "Should only contain jsonrpc and method fields")

        // Verify we can decode it back
        let decoded = try decoder.decode(Message<InitializedNotification>.self, from: data)
        #expect(decoded.method == InitializedNotification.name)
    }

    @Test
    func `Initialized notification decoding`() throws {
        // Create a minimal JSON string
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<InitializedNotification>.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test
    func `Resource updated notification with parameters`() throws {
        let params = ResourceUpdatedNotification.Parameters(uri: "test://resource")
        let notification = ResourceUpdatedNotification.message(params)

        #expect(notification.method == ResourceUpdatedNotification.name)
        #expect(notification.params.uri == "test://resource")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(notification)

        // Verify the exact JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/resources/updated")
        #expect(json["params"] != nil)
        #expect(json.count == 3, "Should contain jsonrpc, method, and params fields")

        // Verify we can decode it back
        let decoded = try decoder.decode(Message<ResourceUpdatedNotification>.self, from: data)
        #expect(decoded.method == ResourceUpdatedNotification.name)
        #expect(decoded.params.uri == "test://resource")
    }

    @Test
    func `AnyNotification decoding - without params`() throws {
        // Test decoding when params field is missing
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test
    func `AnyNotification decoding - with null params`() throws {
        // Test decoding when params field is null
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/initialized","params":null}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test
    func `AnyNotification decoding - with empty params`() throws {
        // Test decoding when params field is empty
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == InitializedNotification.name)
    }

    @Test
    func `AnyNotification decoding - with non-empty params`() throws {
        // Test decoding when params field has values
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/resources/updated","params":{"uri":"test://resource"}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyMessage.self, from: data)

        #expect(decoded.method == ResourceUpdatedNotification.name)
        #expect(decoded.params.objectValue?["uri"]?.stringValue == "test://resource")
    }

    // MARK: - LogMessageNotification Tests

    @Test
    func `LogMessageNotification encoding with all fields`() throws {
        let params = LogMessageNotification.Parameters(
            level: .info,
            logger: "test-logger",
            data: .string("Test log message"),
        )
        let notification = LogMessageNotification.message(params)

        #expect(notification.method == LogMessageNotification.name)
        #expect(notification.params.level == .info)
        #expect(notification.params.logger == "test-logger")
        #expect(notification.params.data == .string("Test log message"))

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/message")
        #expect(json["params"]?.objectValue?["level"] == "info")
        #expect(json["params"]?.objectValue?["logger"] == "test-logger")
        #expect(json["params"]?.objectValue?["data"] == "Test log message")
    }

    @Test
    func `LogMessageNotification encoding with minimal fields`() throws {
        let params = LogMessageNotification.Parameters(
            level: .warning,
            data: .string("Warning message"),
        )
        let notification = LogMessageNotification.message(params)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure (logger should be omitted)
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["method"] == "notifications/message")
        #expect(json["params"]?.objectValue?["level"] == "warning")
        #expect(json["params"]?.objectValue?["logger"] == nil)
        #expect(json["params"]?.objectValue?["data"] == "Warning message")
    }

    @Test
    func `LogMessageNotification decoding`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"error","logger":"app","data":"Error occurred"}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<LogMessageNotification>.self, from: data)

        #expect(decoded.method == LogMessageNotification.name)
        #expect(decoded.params.level == .error)
        #expect(decoded.params.logger == "app")
        #expect(decoded.params.data == .string("Error occurred"))
    }

    @Test
    func `LogMessageNotification with object data`() throws {
        let params = LogMessageNotification.Parameters(
            level: .debug,
            data: .object(["key": .string("value"), "count": .int(42)]),
        )
        let notification = LogMessageNotification.message(params)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)
        let decoded = try JSONDecoder().decode(Message<LogMessageNotification>.self, from: data)

        #expect(decoded.params.level == .debug)
        #expect(decoded.params.data.objectValue?["key"] == .string("value"))
        #expect(decoded.params.data.objectValue?["count"] == .int(42))
    }

    @Test
    func `LogMessageNotification all log levels`() throws {
        let levels: [LoggingLevel] = [
            .debug, .info, .notice, .warning, .error, .critical, .alert, .emergency,
        ]

        for level in levels {
            let params = LogMessageNotification.Parameters(level: level, data: .string("test"))
            let notification = LogMessageNotification.message(params)

            let encoder = JSONEncoder()
            let data = try encoder.encode(notification)
            let decoded = try JSONDecoder().decode(Message<LogMessageNotification>.self, from: data)

            #expect(decoded.params.level == level, "Log level \(level) should roundtrip correctly")
        }
    }

    // MARK: - ToolListChangedNotification Tests

    @Test
    func `ToolListChangedNotification encoding`() throws {
        let notification = ToolListChangedNotification.message()

        #expect(notification.method == ToolListChangedNotification.name)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/tools/list_changed")
        // Empty params may be included as {} per JSON-RPC conventions
        if let params = json["params"] {
            #expect(params == .object([:]), "Params should be empty object if present")
        }
    }

    @Test
    func `ToolListChangedNotification decoding`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ToolListChangedNotification>.self, from: data)

        #expect(decoded.method == ToolListChangedNotification.name)
    }

    @Test
    func `ToolListChangedNotification decoding with empty params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ToolListChangedNotification>.self, from: data)

        #expect(decoded.method == ToolListChangedNotification.name)
    }

    // MARK: - PromptListChangedNotification Tests

    @Test
    func `PromptListChangedNotification encoding`() throws {
        let notification = PromptListChangedNotification.message()

        #expect(notification.method == PromptListChangedNotification.name)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/prompts/list_changed")
        // Empty params may be included as {} per JSON-RPC conventions
        if let params = json["params"] {
            #expect(params == .object([:]), "Params should be empty object if present")
        }
    }

    @Test
    func `PromptListChangedNotification decoding`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/prompts/list_changed"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<PromptListChangedNotification>.self, from: data)

        #expect(decoded.method == PromptListChangedNotification.name)
    }

    @Test
    func `PromptListChangedNotification decoding with empty params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/prompts/list_changed","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<PromptListChangedNotification>.self, from: data)

        #expect(decoded.method == PromptListChangedNotification.name)
    }

    // MARK: - ResourceListChangedNotification Tests

    @Test
    func `ResourceListChangedNotification encoding`() throws {
        let notification = ResourceListChangedNotification.message()

        #expect(notification.method == ResourceListChangedNotification.name)

        let encoder = JSONEncoder()
        let data = try encoder.encode(notification)

        // Verify JSON structure
        let json = try JSONDecoder().decode([String: Value].self, from: data)
        #expect(json["jsonrpc"] == "2.0")
        #expect(json["method"] == "notifications/resources/list_changed")
        // Empty params may be included as {} per JSON-RPC conventions
        if let params = json["params"] {
            #expect(params == .object([:]), "Params should be empty object if present")
        }
    }

    @Test
    func `ResourceListChangedNotification decoding`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/resources/list_changed"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ResourceListChangedNotification>.self, from: data)

        #expect(decoded.method == ResourceListChangedNotification.name)
    }

    @Test
    func `ResourceListChangedNotification decoding with empty params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","method":"notifications/resources/list_changed","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message<ResourceListChangedNotification>.self, from: data)

        #expect(decoded.method == ResourceListChangedNotification.name)
    }
}
