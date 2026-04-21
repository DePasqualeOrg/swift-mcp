// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
@testable import MCPCore
import MCPTool
import Testing

// MARK: - Fixtures

@Schemable
@StructuredOutput
struct PrimitiveTestItem: Equatable {
    let name: String
    let count: Int
}

/// Test helper: registers a zero-input tool returning `Output`, round-trips
/// through an in-memory client/server pair, and returns the tool definition
/// plus the call result for assertions.
private func registerAndCall(
    toolName: String,
    handler: @escaping @Sendable (HandlerContext) async throws -> some ToolOutput,
) async throws -> (toolDef: Tool, result: CallTool.Result) {
    let mcpServer = MCPServer(name: "test-server", version: "1.0.0")
    try await mcpServer.register(
        name: toolName,
        description: "Primitive-output integration test tool",
        handler: handler,
    )

    let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
    let session = await mcpServer.createSession()
    try await session.start(transport: serverTransport)

    let client = Client(name: "test-client", version: "1.0.0")
    try await client.connect(transport: clientTransport)

    let tools = try await client.listTools()
    let toolDef = try #require(tools.tools.first { $0.name == toolName })
    let result = try await client.callTool(name: toolName)
    return (toolDef, result)
}

private func wrapSchema(_ inner: Value) -> Value {
    .object([
        "type": .string("object"),
        "properties": .object(["result": inner]),
        "required": .array([.string("result")]),
        "additionalProperties": .bool(false),
    ])
}

// MARK: - Integer

struct PrimitiveOutputIntegrationTests {
    @Test
    func `Int round trips with wrapped structuredContent and outputSchema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "int_tool") { _ async throws -> Int in
            42
        }
        #expect(toolDef.outputSchema == wrapSchema(.object(["type": .string("integer")])))
        #expect(result.structuredContent == .object(["result": .int(42)]))
        #expect(result.content.count == 1)
        guard case let .text(text, _, _) = result.content[0] else {
            Issue.record("expected text, got \(result.content[0])")
            return
        }
        #expect(text == "42")
    }

    // MARK: - Double

    @Test
    func `Double round trips with number schema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "double_tool") { _ async throws -> Double in
            3.25
        }
        #expect(toolDef.outputSchema == wrapSchema(.object(["type": .string("number")])))
        #expect(result.structuredContent == .object(["result": .double(3.25)]))
    }

    @Test
    func `Double NaN fails with a tool error surfaced by the server`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")
        try await mcpServer.register(name: "nan_tool", description: "emits NaN") { _ async throws -> Double in
            .nan
        }
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        // NaN has no JSON representation; the server surfaces the encoder's
        // failure as a tool error (`isError: true`) with a message that
        // names the unrepresentable value, rather than producing garbage on
        // the wire.
        let result = try await client.callTool(name: "nan_tool")
        #expect(result.isError == true)
        guard case let .text(text, _, _) = result.content.first ?? .text("") else {
            Issue.record("expected text content in NaN failure result")
            return
        }
        #expect(text.contains("nan") || text.contains("NaN"))
    }

    // MARK: - Bool

    @Test
    func `Bool round trips with boolean schema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "bool_tool") { _ async throws -> Bool in
            true
        }
        #expect(toolDef.outputSchema == wrapSchema(.object(["type": .string("boolean")])))
        #expect(result.structuredContent == .object(["result": .bool(true)]))
        guard case let .text(text, _, _) = result.content[0] else {
            Issue.record("expected text")
            return
        }
        #expect(text == "true")
    }

    // MARK: - String

    @Test
    func `String now emits structuredContent and outputSchema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "string_tool") { _ async throws -> String in
            "hello"
        }
        #expect(toolDef.outputSchema == wrapSchema(.object(["type": .string("string")])))
        #expect(result.structuredContent == .object(["result": .string("hello")]))
        guard case let .text(text, _, _) = result.content[0] else {
            Issue.record("expected text")
            return
        }
        #expect(text == "hello")
    }

    // MARK: - Date

    @Test
    func `Date display text matches the wire ISO string`() throws {
        // Guard against Foundation-side drift: `asDisplayText()` uses
        // `ISO8601DateFormatter` directly while `asJSONValue()` routes
        // through `MCPEncoding.defaultEncoder()` (which uses `.iso8601`).
        // Both should produce byte-equivalent strings for any given date;
        // if Apple ever changes the default options on one side, this test
        // catches it before the wire form and display form diverge.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let display = try date.asDisplayText()
        guard case let .string(wire) = try date.asJSONValue() else {
            Issue.record("Date should encode as a JSON string")
            return
        }
        #expect(display == wire)
    }

    @Test
    func `Date round trips with date-time format and ISO 8601 string`() async throws {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01T00:00:00Z
        let (toolDef, result) = try await registerAndCall(toolName: "date_tool") { _ async throws -> Date in
            date
        }
        #expect(toolDef.outputSchema == wrapSchema(.object([
            "type": .string("string"),
            "format": .string("date-time"),
        ])))
        guard case let .object(struc) = result.structuredContent ?? .null,
              case let .string(iso) = struc["result"] ?? .null
        else {
            Issue.record("expected {\"result\": \"<iso>\"}, got \(String(describing: result.structuredContent))")
            return
        }
        #expect(iso == "1970-01-01T00:00:00Z")
    }

    // MARK: - Arrays

    @Test
    func `Int array round trips with wrapped array schema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "int_array_tool") { _ async throws -> [Int] in
            [1, 2, 3]
        }
        #expect(toolDef.outputSchema == wrapSchema(.object([
            "type": .string("array"),
            "items": .object(["type": .string("integer")]),
        ])))
        #expect(result.structuredContent == .object([
            "result": .array([.int(1), .int(2), .int(3)]),
        ]))
    }

    @Test
    func `Empty Int array round trips as empty array under result`() async throws {
        let (_, result) = try await registerAndCall(toolName: "empty_array_tool") { _ async throws -> [Int] in
            []
        }
        #expect(result.structuredContent == .object(["result": .array([])]))
    }

    @Test
    func `Nested Int arrays compose through conditional conformance`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "nested_array_tool") { _ async throws -> [[Int]] in
            [[1, 2], [3]]
        }
        #expect(toolDef.outputSchema == wrapSchema(.object([
            "type": .string("array"),
            "items": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")]),
            ]),
        ])))
        #expect(result.structuredContent == .object([
            "result": .array([
                .array([.int(1), .int(2)]),
                .array([.int(3)]),
            ]),
        ]))
    }

    // MARK: - Optionals

    @Test
    func `Optional Int some case emits wrapped integer`() async throws {
        let (_, result) = try await registerAndCall(toolName: "opt_int_some") { _ async throws -> Int? in
            42
        }
        #expect(result.structuredContent == .object(["result": .int(42)]))
    }

    @Test
    func `Optional Int nil case emits result null`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "opt_int_nil") { _ async throws -> Int? in
            nil
        }
        #expect(toolDef.outputSchema == wrapSchema(.object([
            "type": .array([.string("integer"), .string("null")]),
        ])))
        #expect(result.structuredContent == .object(["result": .null]))
        guard case let .text(text, _, _) = result.content[0] else {
            Issue.record("expected text")
            return
        }
        #expect(text == "null")
    }

    @Test
    func `Optional of String quotes the display text where bare String does not`() async throws {
        // Bare `String` passes through `asDisplayText()` verbatim, but
        // `Optional<String>` is a compound type — `asDisplayText()` JSON-
        // encodes it, which quotes the wrapped string. Agents shouldn't
        // be surprised by this: the structured channel is the source of
        // truth; the display channel is a UI-rendering helper.
        let (_, bareResult) = try await registerAndCall(toolName: "bare_string") { _ async throws -> String in
            "hello"
        }
        guard case let .text(bareText, _, _) = bareResult.content[0] else {
            Issue.record("expected text")
            return
        }
        #expect(bareText == "hello")

        let (_, optResult) = try await registerAndCall(toolName: "opt_string") { _ async throws -> String? in
            "hello"
        }
        guard case let .text(optText, _, _) = optResult.content[0] else {
            Issue.record("expected text")
            return
        }
        #expect(optText == "\"hello\"")
        #expect(optResult.structuredContent == .object(["result": .string("hello")]))
    }

    @Test
    func `Nested optional flattens some nil and none both to null`() async throws {
        // Int?? (.some(nil)) and Int?? (.none) both encode as JSON null —
        // the distinction is not preserved on the wire. Authors who need
        // to distinguish should declare a @StructuredOutput enum or struct.
        let (_, resultA) = try await registerAndCall(toolName: "opt_opt_some_nil") { _ async throws -> Int?? in
            .some(nil)
        }
        #expect(resultA.structuredContent == .object(["result": .null]))

        let (_, resultB) = try await registerAndCall(toolName: "opt_opt_none") { _ async throws -> Int?? in
            .none
        }
        #expect(resultB.structuredContent == .object(["result": .null]))
    }

    // MARK: - Structs through the wrap path

    @Test
    func `Array of StructuredOutput elements wraps with struct schema as items`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "struct_array_tool") { _ async throws -> [PrimitiveTestItem] in
            [PrimitiveTestItem(name: "a", count: 1), PrimitiveTestItem(name: "b", count: 2)]
        }
        // Schema should wrap with items = PrimitiveTestItem.outputJSONSchema.
        guard case let .object(schema) = toolDef.outputSchema ?? .null,
              case let .object(props) = schema["properties"] ?? .null,
              case let .object(resultSchema) = props["result"] ?? .null
        else {
            Issue.record("unexpected schema shape: \(String(describing: toolDef.outputSchema))")
            return
        }
        #expect(resultSchema["type"] == .string("array"))
        #expect(resultSchema["items"] == PrimitiveTestItem.outputJSONSchema)

        guard case let .object(struc) = result.structuredContent ?? .null,
              case let .array(items) = struc["result"] ?? .null
        else {
            Issue.record("expected structuredContent.result: array")
            return
        }
        #expect(items.count == 2)
    }

    @Test
    func `Optional StructuredOutput preserves struct property shape and adds null to type`() async throws {
        let (toolDef, _) = try await registerAndCall(toolName: "opt_struct_tool") { _ async throws -> PrimitiveTestItem? in
            PrimitiveTestItem(name: "x", count: 0)
        }
        guard case let .object(schema) = toolDef.outputSchema ?? .null,
              case let .object(props) = schema["properties"] ?? .null,
              case let .object(resultSchema) = props["result"] ?? .null
        else {
            Issue.record("unexpected schema shape")
            return
        }
        // `type` is now a two-entry array of the struct's "object" plus "null".
        guard case let .array(types) = resultSchema["type"] ?? .null else {
            Issue.record("expected two-type array for optional struct")
            return
        }
        #expect(Set(types) == [.string("object"), .string("null")])
        // The struct's property shape is preserved alongside.
        guard case .object = resultSchema["properties"] ?? .null else {
            Issue.record("expected properties preserved on optional struct schema")
            return
        }
    }

    // MARK: - Dictionary (top-level object, no wrap)

    @Test
    func `Dictionary String to Int emits top-level object with additionalProperties schema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "dict_int_tool") { _ async throws -> [String: Int] in
            ["a": 1, "b": 2]
        }
        #expect(toolDef.outputSchema == .object([
            "type": .string("object"),
            "additionalProperties": .object(["type": .string("integer")]),
        ]))
        // The structured content is the dict itself, not wrapped under "result".
        guard case let .object(fields) = result.structuredContent ?? .null else {
            Issue.record("expected object structuredContent")
            return
        }
        #expect(fields["a"] == .int(1))
        #expect(fields["b"] == .int(2))
    }

    @Test
    func `Empty dictionary emits empty object as structuredContent`() async throws {
        let (_, result) = try await registerAndCall(toolName: "dict_empty_tool") { _ async throws -> [String: Int] in
            [:]
        }
        #expect(result.structuredContent == .object([:]))
    }

    @Test
    func `Dictionary of StructuredOutput uses struct schema as additionalProperties`() async throws {
        let (toolDef, _) = try await registerAndCall(toolName: "dict_struct_tool") { _ async throws -> [String: PrimitiveTestItem] in
            ["only": PrimitiveTestItem(name: "x", count: 0)]
        }
        guard case let .object(schema) = toolDef.outputSchema ?? .null else {
            Issue.record("expected object schema")
            return
        }
        #expect(schema["type"] == .string("object"))
        #expect(schema["additionalProperties"] == PrimitiveTestItem.outputJSONSchema)
    }

    @Test
    func `Dictionary with nested Int array values`() async throws {
        let (toolDef, _) = try await registerAndCall(toolName: "dict_nested_tool") { _ async throws -> [String: [Int]] in
            ["xs": [1, 2]]
        }
        #expect(toolDef.outputSchema == .object([
            "type": .string("object"),
            "additionalProperties": .object([
                "type": .string("array"),
                "items": .object(["type": .string("integer")]),
            ]),
        ]))
    }

    @Test
    func `Array of dicts wraps under result because only top-level Dictionary escapes wrapping`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "array_of_dicts_tool") { _ async throws -> [[String: Int]] in
            [["a": 1], ["b": 2]]
        }
        // Should wrap: `{"result": [{"a": 1}, {"b": 2}]}` — Array dispatches
        // through PrimitiveToolOutput, and dict elements serialize via
        // WrappableValue. The dict unwrap path is only taken at top level.
        #expect(toolDef.outputSchema == wrapSchema(.object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "additionalProperties": .object(["type": .string("integer")]),
            ]),
        ])))
        #expect(result.structuredContent == .object([
            "result": .array([
                .object(["a": .int(1)]),
                .object(["b": .int(2)]),
            ]),
        ]))
    }

    // MARK: - Void

    @Test
    func `VoidOutput outputJSONSchema has the exact wrapped-null shape`() {
        // The three round-trip tests below assert `toolDef.outputSchema ==
        // VoidOutput.outputJSONSchema`, which would silently pass if both
        // sides regressed together. Pin the literal shape here so a
        // "simplification" of the schema constant is caught independently.
        let expected: Value = .object([
            "type": .string("object"),
            "properties": .object(["result": .object(["type": .string("null")])]),
            "required": .array([.string("result")]),
            "additionalProperties": .bool(false),
        ])
        #expect(VoidOutput.outputJSONSchema == expected)
    }

    @Test
    func `Void-returning tool via macro emits result null`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")
        try await mcpServer.register(PrimitiveTestVoidTool.self)

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "void_macro_tool" })
        #expect(toolDef.outputSchema == VoidOutput.outputJSONSchema)

        let result = try await client.callTool(name: "void_macro_tool")
        #expect(result.structuredContent == .object(["result": .null]))
        guard case let .text(text, _, _) = result.content[0] else {
            Issue.record("expected text")
            return
        }
        #expect(text == "null")
    }

    @Test
    func `Void closure zero-input register emits result null`() async throws {
        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")
        try await mcpServer.register(
            name: "void_zero_input",
            description: "Void closure zero-input",
        ) { (_: HandlerContext) async throws in
            // no-op
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "void_zero_input" })
        #expect(toolDef.outputSchema == VoidOutput.outputJSONSchema)

        let result = try await client.callTool(name: "void_zero_input")
        #expect(result.structuredContent == .object(["result": .null]))
    }

    @Test
    func `Void closure with-input register emits result null`() async throws {
        struct Echo: Codable, Sendable { let message: String }

        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")
        let inputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object(["message": .object(["type": .string("string")])]),
            "required": .array([.string("message")]),
        ])
        try await mcpServer.register(
            name: "void_with_input",
            description: "Void closure with input",
            inputSchema: inputSchema,
        ) { (_: Echo, _: HandlerContext) async throws in
            // no-op
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "void_with_input" })
        #expect(toolDef.outputSchema == VoidOutput.outputJSONSchema)

        let result = try await client.callTool(
            name: "void_with_input",
            arguments: ["message": .string("ping")],
        )
        #expect(result.structuredContent == .object(["result": .null]))
    }

    // MARK: - Closure-based primitive round trip (regression for zero- and

    // with-input register)

    @Test
    func `Closure-based zero-input register with primitive Output populates outputSchema`() async throws {
        let (toolDef, result) = try await registerAndCall(toolName: "closure_zero_input") { _ async throws -> Int in
            7
        }
        #expect(toolDef.outputSchema == wrapSchema(.object(["type": .string("integer")])))
        #expect(result.structuredContent == .object(["result": .int(7)]))
    }

    @Test
    func `Closure-based with-input register with primitive Output populates outputSchema`() async throws {
        struct Echo: Codable, Sendable { let value: Int }

        let mcpServer = MCPServer(name: "test-server", version: "1.0.0")
        let inputSchema: Value = .object([
            "type": .string("object"),
            "properties": .object(["value": .object(["type": .string("integer")])]),
            "required": .array([.string("value")]),
        ])
        try await mcpServer.register(
            name: "echo_int",
            description: "Echo an int",
            inputSchema: inputSchema,
        ) { (input: Echo, _: HandlerContext) async throws -> Int in
            input.value
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let session = await mcpServer.createSession()
        try await session.start(transport: serverTransport)
        let client = Client(name: "test-client", version: "1.0.0")
        try await client.connect(transport: clientTransport)

        let tools = try await client.listTools()
        let toolDef = try #require(tools.tools.first { $0.name == "echo_int" })
        #expect(toolDef.outputSchema == wrapSchema(.object(["type": .string("integer")])))

        let result = try await client.callTool(name: "echo_int", arguments: ["value": .int(13)])
        #expect(result.structuredContent == .object(["result": .int(13)]))
    }

    // MARK: - Wrapper shape pinning

    @Test
    func `Wrapper schema sets additionalProperties false while dict schema does not`() async throws {
        let (primitiveTool, _) = try await registerAndCall(toolName: "additional_props_primitive") { _ async throws -> Int in
            0
        }
        guard case let .object(primitiveSchema) = primitiveTool.outputSchema ?? .null else {
            Issue.record("expected object schema")
            return
        }
        #expect(primitiveSchema["additionalProperties"] == .bool(false))

        let (dictTool, _) = try await registerAndCall(toolName: "additional_props_dict") { _ async throws -> [String: Int] in
            [:]
        }
        guard case let .object(dictSchema) = dictTool.outputSchema ?? .null else {
            Issue.record("expected object schema")
            return
        }
        // The dict schema's `additionalProperties` is the value schema, not `false`.
        #expect(dictSchema["additionalProperties"] == .object(["type": .string("integer")]))
    }
}

// MARK: - Macro-driven Void fixture

@Tool
struct PrimitiveTestVoidTool {
    static let name = "void_macro_tool"
    static let description = "Runs a side effect with no return value"

    func perform() async throws {
        // no-op
    }
}
