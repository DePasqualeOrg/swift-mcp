// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
import MCPTool
import Testing

// MARK: - Test Tool Definitions

/// A simple tool with basic string parameter
@Tool
struct EchoTool {
    static let name = "echo"
    static let description = "Echo the input message"

    @Parameter(description: "Message to echo")
    var message: String

    func perform(context _: HandlerContext) async throws -> String {
        "Echo: \(message)"
    }
}

/// Tool with multiple parameter types
@Tool
struct CalculatorTool {
    static let name = "calculator"
    static let description = "Perform arithmetic operations"

    @Parameter(description: "First operand")
    var a: Double

    @Parameter(description: "Second operand")
    var b: Double

    @Parameter(description: "Operation to perform")
    var operation: String

    func perform(context _: HandlerContext) async throws -> String {
        let result: Double = switch operation {
            case "add": a + b
            case "subtract": a - b
            case "multiply": a * b
            case "divide": b != 0 ? a / b : .nan
            default: .nan
        }
        return "Result: \(result)"
    }
}

/// Tool with optional parameter
@Tool
struct GreetTool {
    static let name = "greet"
    static let description = "Greet a user"

    @Parameter(description: "Name to greet")
    var name: String

    @Parameter(description: "Optional greeting prefix")
    var prefix: String?

    func perform(context _: HandlerContext) async throws -> String {
        let greeting = prefix ?? "Hello"
        return "\(greeting), \(name)!"
    }
}

/// Tool with default value
@Tool
struct PaginatedListTool {
    static let name = "list_items"
    static let description = "List items with pagination"

    @Parameter(description: "Page size", minimum: 1, maximum: 100)
    var pageSize: Int = 25

    @Parameter(description: "Page number", minimum: 1)
    var page: Int = 1

    func perform(context _: HandlerContext) async throws -> String {
        "Showing page \(page) with \(pageSize) items"
    }
}

/// Tool with array parameter
@Tool
struct ProcessItemsTool {
    static let name = "process_items"
    static let description = "Process a list of items"

    @Parameter(description: "Items to process")
    var items: [String]

    func perform(context _: HandlerContext) async throws -> String {
        "Processed \(items.count) items: \(items.joined(separator: ", "))"
    }
}

/// Tool with Date parameter
@Tool
struct ScheduleTool {
    static let name = "schedule"
    static let description = "Schedule an event"

    @Parameter(description: "Event name")
    var eventName: String

    @Parameter(description: "Event date")
    var eventDate: Date

    func perform(context _: HandlerContext) async throws -> String {
        let formatter = ISO8601DateFormatter()
        return "Scheduled '\(eventName)' for \(formatter.string(from: eventDate))"
    }
}

/// Tool with custom JSON key
@Tool
struct CustomKeyTool {
    static let name = "custom_key"
    static let description = "Tool with custom JSON keys"

    @Parameter(key: "start_date", description: "Start date")
    var startDate: String

    @Parameter(key: "end_date", description: "End date")
    var endDate: String

    func perform(context _: HandlerContext) async throws -> String {
        "Range: \(startDate) to \(endDate)"
    }
}

/// Tool with parameter titles for UI display
@Tool
struct ParameterTitlesTool {
    static let name = "parameter_titles"
    static let description = "Tool with parameter titles"

    @Parameter(title: "City Name", description: "City to get weather for")
    var city: String

    @Parameter(title: "Temperature Units", description: "Temperature unit system")
    var units: String?

    @Parameter(description: "No title specified")
    var other: String?

    func perform(context _: HandlerContext) async throws -> String {
        "Weather in \(city)"
    }
}

/// Tool with annotations
@Tool
struct ReadOnlyTool {
    static let name = "read_config"
    static let description = "Read configuration (read-only)"
    static let annotations: [AnnotationOption] = [.readOnly, .title("Configuration Reader")]

    @Parameter(description: "Config key")
    var key: String

    func perform(context _: HandlerContext) async throws -> String {
        "Config[\(key)] = some_value"
    }
}

/// Tool with Bool and Int parameters
@Tool
struct FilterTool {
    static let name = "filter"
    static let description = "Filter items"

    @Parameter(description: "Include archived items")
    var includeArchived: Bool

    @Parameter(description: "Maximum items to return")
    var limit: Int

    func perform(context _: HandlerContext) async throws -> String {
        "Filtered with archived=\(includeArchived), limit=\(limit)"
    }
}

/// Tool with string constraints
@Tool
struct ConstrainedTool {
    static let name = "constrained"
    static let description = "Tool with constraints"

    @Parameter(description: "Username", minLength: 3, maxLength: 20)
    var username: String

    func perform(context _: HandlerContext) async throws -> String {
        username
    }
}

/// Enum for priority levels
@Schemable
enum Priority: String, CaseIterable {
    case low
    case medium
    case high
    case critical
}

/// Tool with enum parameter
@Tool
struct CreateTaskTool {
    static let name = "create_task"
    static let description = "Create a task with priority"

    @Parameter(description: "Task title")
    var title: String

    @Parameter(description: "Task priority")
    var priority: Priority

    func perform(context _: HandlerContext) async throws -> String {
        "Created task '\(title)' with priority: \(priority.rawValue)"
    }
}

/// Structured output for search results
@OutputSchema
struct SearchResult: Encodable {
    let query: String
    let totalCount: Int
    let items: [String]
}

/// Tool with structured output
@Tool
struct SearchTool {
    static let name = "search"
    static let description = "Search for items"

    @Parameter(description: "Search query")
    var query: String

    @Parameter(description: "Maximum results")
    var maxResults: Int = 10

    func perform(context _: HandlerContext) async throws -> SearchResult {
        SearchResult(
            query: query,
            totalCount: 42,
            items: ["result1", "result2", "result3"],
        )
    }
}

/// Tool with dictionary parameter
@Tool
struct HttpRequestTool {
    static let name = "http_request"
    static let description = "Make an HTTP request with custom headers"

    @Parameter(description: "Request URL")
    var url: String

    @Parameter(description: "HTTP headers")
    var headers: [String: String]

    func perform(context _: HandlerContext) async throws -> String {
        let headerList = headers.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        return "Request to \(url) with headers: \(headerList)"
    }
}

/// Tool with strict schema (rejects extra properties)
@Tool
struct StrictTool {
    static let name = "strict_tool"
    static let description = "A tool with strict schema validation"
    static let strictSchema = true

    @Parameter(description: "Input value")
    var input: String

    func perform(context _: HandlerContext) async throws -> String {
        "Received: \(input)"
    }
}

/// Tool with strict schema, optional, and default parameters
@Tool
struct StrictToolWithOptionals {
    static let name = "strict_optionals"
    static let description = "Strict tool with optional and default parameters"
    static let strictSchema = true

    @Parameter(description: "Required input")
    var input: String

    @Parameter(description: "Optional filter")
    var filter: String?

    @Parameter(description: "Page size", minimum: 1, maximum: 100)
    var pageSize: Int = 25

    func perform(context _: HandlerContext) async throws -> String {
        let filterStr = filter ?? "none"
        return "input=\(input) filter=\(filterStr) pageSize=\(pageSize)"
    }
}

/// Tool with perform() that doesn't require HandlerContext
@Tool
struct SimplePerformTool {
    static let name = "simple_perform"
    static let description = "A tool that doesn't need context"

    @Parameter(description: "Input value")
    var value: String

    func perform() async throws -> String {
        "Processed: \(value)"
    }
}

/// Tool with perform() that returns structured output
@Tool
struct SimplePerformStructuredTool {
    static let name = "simple_perform_structured"
    static let description = "A tool with structured output"

    @Parameter(description: "Search term")
    var term: String

    func perform() async throws -> SearchResult {
        SearchResult(
            query: term,
            totalCount: 5,
            items: ["a", "b", "c"],
        )
    }
}

/// Tool with nested array parameter
@Tool
struct MatrixTool {
    static let name = "matrix_tool"
    static let description = "Process a 2D matrix of numbers"

    @Parameter(description: "2D matrix of integers")
    var matrix: [[Int]]

    func perform(context _: HandlerContext) async throws -> String {
        let rows = matrix.count
        let cols = matrix.first?.count ?? 0
        return "Matrix: \(rows)x\(cols)"
    }
}

/// Tool with array of dictionaries parameter
@Tool
struct RecordsTool {
    static let name = "records_tool"
    static let description = "Process an array of record dictionaries"

    @Parameter(description: "Array of record dictionaries")
    var records: [[String: String]]

    func perform(context _: HandlerContext) async throws -> String {
        "Processed \(records.count) records"
    }
}

/// Tool with dictionary of arrays parameter
@Tool
struct GroupedDataTool {
    static let name = "grouped_data_tool"
    static let description = "Process grouped data with array values"

    @Parameter(description: "Dictionary mapping group names to arrays of integers")
    var groups: [String: [Int]]

    func perform(context _: HandlerContext) async throws -> String {
        let totalItems = groups.values.reduce(0) { $0 + $1.count }
        return "Processed \(groups.count) groups with \(totalItems) total items"
    }
}

/// Tool with no parameters
@Tool
struct HeartbeatTool {
    static let name = "heartbeat"
    static let description = "Returns OK"

    func perform() async throws -> String {
        "OK"
    }
}

// MARK: - ToolSpec Conformance Tests

struct ToolSpecConformanceTests {
    @Test
    func `@Tool macro generates ToolSpec conformance`() {
        // Verify that the macro-generated types conform to ToolSpec
        let _: any ToolSpec.Type = EchoTool.self
        let _: any ToolSpec.Type = CalculatorTool.self
        let _: any ToolSpec.Type = GreetTool.self
        let _: any ToolSpec.Type = PaginatedListTool.self
    }

    @Test
    func `Tool with perform() generates ToolSpec conformance`() {
        // Verify that tools with perform() (no context) also conform to ToolSpec
        let _: any ToolSpec.Type = SimplePerformTool.self
        let _: any ToolSpec.Type = SimplePerformStructuredTool.self
    }

    @Test
    func `toolDefinition contains correct name and description`() {
        let definition = EchoTool.toolDefinition

        #expect(definition.name == "echo")
        #expect(definition.description == "Echo the input message")
    }

    @Test
    func `toolDefinition contains correct inputSchema structure`() {
        let definition = EchoTool.toolDefinition
        let schema = definition.inputSchema

        // Verify schema is an object type
        #expect(schema.objectValue?["type"]?.stringValue == "object")

        // Verify properties exist
        let properties = schema.objectValue?["properties"]?.objectValue
        #expect(properties != nil)
        #expect(properties?["message"] != nil)

        // Verify message property schema
        let messageSchema = properties?["message"]?.objectValue
        #expect(messageSchema?["type"]?.stringValue == "string")
        #expect(messageSchema?["description"]?.stringValue == "Message to echo")

        // Verify required fields
        let required = schema.objectValue?["required"]?.arrayValue
        #expect(required?.contains(.string("message")) == true)
    }

    @Test
    func `toolDefinition includes string constraints`() {
        let definition = ConstrainedTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let usernameSchema = properties?["username"]?.objectValue

        #expect(usernameSchema?["minLength"]?.intValue == 3)
        #expect(usernameSchema?["maxLength"]?.intValue == 20)
    }

    @Test
    func `toolDefinition includes numeric constraints`() {
        let definition = PaginatedListTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let pageSizeSchema = properties?["pageSize"]?.objectValue

        #expect(pageSizeSchema?["minimum"]?.doubleValue == 1)
        #expect(pageSizeSchema?["maximum"]?.doubleValue == 100)
    }

    @Test
    func `toolDefinition includes default values`() {
        let definition = PaginatedListTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue

        let pageSizeSchema = properties?["pageSize"]?.objectValue
        #expect(pageSizeSchema?["default"]?.intValue == 25)

        let pageSchema = properties?["page"]?.objectValue
        #expect(pageSchema?["default"]?.intValue == 1)

        // Parameters with defaults should not be in required
        let required = definition.inputSchema.objectValue?["required"]?.arrayValue ?? []
        #expect(!required.contains(.string("pageSize")))
        #expect(!required.contains(.string("page")))
    }

    @Test
    func `toolDefinition handles optional parameters`() {
        let definition = GreetTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let required = definition.inputSchema.objectValue?["required"]?.arrayValue ?? []

        // Required parameter should be in required array with non-nullable type
        #expect(required.contains(.string("name")))
        let nameSchema = properties?["name"]?.objectValue
        #expect(nameSchema?["type"]?.stringValue == "string")

        // Optional parameter should not be in required array and should have nullable type
        #expect(!required.contains(.string("prefix")))
        let prefixSchema = properties?["prefix"]?.objectValue
        let prefixType = prefixSchema?["type"]?.arrayValue
        #expect(prefixType == [.string("string"), .string("null")])
    }

    @Test
    func `toolDefinition handles array parameters`() {
        let definition = ProcessItemsTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let itemsSchema = properties?["items"]?.objectValue

        #expect(itemsSchema?["type"]?.stringValue == "array")

        // Check items schema
        let itemsItemsSchema = itemsSchema?["items"]?.objectValue
        #expect(itemsItemsSchema?["type"]?.stringValue == "string")
    }

    @Test
    func `toolDefinition handles dictionary parameters`() {
        let definition = HttpRequestTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let headersSchema = properties?["headers"]?.objectValue

        #expect(headersSchema?["type"]?.stringValue == "object")

        // Check additionalProperties schema
        let additionalPropsSchema = headersSchema?["additionalProperties"]?.objectValue
        #expect(additionalPropsSchema?["type"]?.stringValue == "string")
    }

    @Test
    func `toolDefinition stores raw schema regardless of strictSchema flag`() throws {
        // `strictSchema: true` is a capability assertion: the stored schema is
        // the raw, provider-agnostic MCP wire form in both cases. OpenAI
        // strict-mode transforms happen on the client side of the wire.
        let strictDefinition = StrictTool.toolDefinition
        let additionalProps = strictDefinition.inputSchema.objectValue?["additionalProperties"]
        #expect(additionalProps == nil)

        let nonStrictDefinition = EchoTool.toolDefinition
        let nonStrictAdditionalProps = nonStrictDefinition.inputSchema.objectValue?["additionalProperties"]
        #expect(nonStrictAdditionalProps == nil)

        // Normalizing the strict tool's schema still produces the OpenAI shape.
        let strictSchema = try #require(strictDefinition.inputSchema.objectValue)
        let normalized = try ToolSchema.normalizeForStrictMode(strictSchema)
        #expect(normalized["additionalProperties"]?.boolValue == false)
    }

    @Test
    func `raw schema excludes optional/default params from required regardless of strictSchema`() throws {
        let definition = StrictToolWithOptionals.toolDefinition
        let schema = try #require(definition.inputSchema.objectValue)
        let properties = schema["properties"]?.objectValue
        let required = schema["required"]?.arrayValue ?? []

        // Raw: only required, non-defaulted params appear in `required`.
        #expect(required.contains(.string("input")))
        #expect(!required.contains(.string("filter")))
        #expect(!required.contains(.string("pageSize")))

        // Required param: non-nullable type
        let inputSchema = properties?["input"]?.objectValue
        #expect(inputSchema?["type"]?.stringValue == "string")

        // Optional param: nullable type (needed so the raw schema is still
        // strict-mode-compatible — a property that's not in `required` must
        // be either nullable or have a default).
        let filterSchema = properties?["filter"]?.objectValue
        #expect(filterSchema?["type"]?.arrayValue == [.string("string"), .string("null")])

        // Default param: scalar type; the `default` is what satisfies strict
        // mode's compatibility check, no nullable wrapping needed.
        let pageSizeSchema = properties?["pageSize"]?.objectValue
        #expect(pageSizeSchema?["type"]?.stringValue == "integer")
        #expect(pageSizeSchema?["default"]?.intValue == 25)

        // Send-time normalization puts every property into `required`.
        let normalized = try ToolSchema.normalizeForStrictMode(schema)
        let normalizedRequired = normalized["required"]?.arrayValue ?? []
        #expect(normalizedRequired.contains(.string("input")))
        #expect(normalizedRequired.contains(.string("filter")))
        #expect(normalizedRequired.contains(.string("pageSize")))
    }

    @Test
    func `non-strict schema does not make default params nullable`() {
        let definition = PaginatedListTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue

        // Default params in non-strict mode: non-nullable type
        let pageSizeSchema = properties?["pageSize"]?.objectValue
        #expect(pageSizeSchema?["type"]?.stringValue == "integer")
    }

    @Test
    func `defaulted enum parameter stays scalar in raw and normalized schemas`() throws {
        // A non-optional enum parameter with a default emits a scalar
        // `type: "string"` with `default: "low"` — no `null` in either
        // the enum values or the type array. Defaults alone satisfy the
        // strict-subset compatibility check; nullable wrapping is extra clutter.
        let descriptor = ToolMacroSupport.SchemaParameterDescriptor(
            name: "priority",
            description: "Priority level",
            jsonSchemaType: "string",
            jsonSchemaProperties: [
                "enum": .array([.string("low"), .string("medium"), .string("high")]),
            ],
            isOptional: false,
            hasDefault: true,
            defaultValue: .string("low"),
        )
        let schema = try ToolMacroSupport.buildObjectSchema(parameters: [descriptor])

        let properties = schema["properties"]?.objectValue
        let priorityProp = try #require(properties?["priority"]?.objectValue)
        #expect(priorityProp["type"]?.stringValue == "string")
        #expect(priorityProp["default"]?.stringValue == "low")
        let enumValues = priorityProp["enum"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(Set(enumValues) == Set(["low", "medium", "high"]))
        #expect(priorityProp["enum"]?.arrayValue?.contains(Value.null) == false)
        let required = schema["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        #expect(!required.contains("priority"))

        let normalized = try ToolSchema.normalizeForStrictMode(schema)
        let normalizedProps = normalized["properties"]?.objectValue
        let normalizedPriority = try #require(normalizedProps?["priority"]?.objectValue)
        #expect(normalizedPriority["type"]?.stringValue == "string")
        #expect(normalizedPriority["default"]?.stringValue == "low")
        #expect(normalizedPriority["enum"]?.arrayValue?.contains(Value.null) == false)
    }

    @Test
    func `empty-properties tool stays strict-compatible after normalization`() throws {
        let schema = try #require(HeartbeatTool.toolDefinition.inputSchema.objectValue)
        let normalized = try ToolSchema.normalizeForStrictMode(schema)

        #expect(normalized["type"]?.stringValue == "object")
        #expect(normalized["properties"]?.objectValue?.isEmpty == true)
        #expect(normalized["additionalProperties"]?.boolValue == false)
        // Current normalizer behavior: `required` is omitted when there are
        // no properties. If that changes, update this assertion intentionally.
        #expect(normalized["required"] == nil)
    }

    @Test
    func `validateStrictCompatibility throws StrictSchemaAssertionFailure on incompatible schema`() throws {
        let descriptor = ToolMacroSupport.SchemaParameterDescriptor(
            name: "settings",
            description: "Settings object",
            jsonSchemaType: "object",
            jsonSchemaProperties: [
                "properties": .object([
                    "mode": .object(["type": "string"]),
                ]),
            ],
            isOptional: false,
        )

        // Build itself always returns raw, so no throw here.
        let schema = try ToolMacroSupport.buildObjectSchema(parameters: [descriptor])

        // Opt-in validation throws the wrapped error carrying the tool name.
        #expect(throws: ToolMacroSupport.StrictSchemaAssertionFailure.self) {
            try ToolMacroSupport.validateStrictCompatibility(schema, toolName: "demo_tool")
        }
    }

    @Test
    func `toolDefinition handles nested array parameters`() {
        let definition = MatrixTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let matrixSchema = properties?["matrix"]?.objectValue

        // Outer array
        #expect(matrixSchema?["type"]?.stringValue == "array")

        // Inner array (items of outer)
        let innerArraySchema = matrixSchema?["items"]?.objectValue
        #expect(innerArraySchema?["type"]?.stringValue == "array")

        // Element type (items of inner)
        let elementSchema = innerArraySchema?["items"]?.objectValue
        #expect(elementSchema?["type"]?.stringValue == "integer")
    }

    @Test
    func `toolDefinition handles array of dictionaries parameters`() {
        let definition = RecordsTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let recordsSchema = properties?["records"]?.objectValue

        // Outer array
        #expect(recordsSchema?["type"]?.stringValue == "array")

        // Inner dictionary (items of outer)
        let innerDictSchema = recordsSchema?["items"]?.objectValue
        #expect(innerDictSchema?["type"]?.stringValue == "object")

        // Value type of dictionary (additionalProperties)
        let valueSchema = innerDictSchema?["additionalProperties"]?.objectValue
        #expect(valueSchema?["type"]?.stringValue == "string")
    }

    @Test
    func `toolDefinition handles dictionary of arrays parameters`() {
        let definition = GroupedDataTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let groupsSchema = properties?["groups"]?.objectValue

        // Outer dictionary
        #expect(groupsSchema?["type"]?.stringValue == "object")

        // Inner array (additionalProperties)
        let innerArraySchema = groupsSchema?["additionalProperties"]?.objectValue
        #expect(innerArraySchema?["type"]?.stringValue == "array")

        // Element type of array (items)
        let elementSchema = innerArraySchema?["items"]?.objectValue
        #expect(elementSchema?["type"]?.stringValue == "integer")
    }

    @Test
    func `toolDefinition handles Date parameters`() {
        let definition = ScheduleTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let dateSchema = properties?["eventDate"]?.objectValue

        #expect(dateSchema?["type"]?.stringValue == "string")
        #expect(dateSchema?["format"]?.stringValue == "date-time")
    }

    @Test
    func `toolDefinition respects custom JSON keys`() {
        let definition = CustomKeyTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue

        // Should use custom keys, not property names
        #expect(properties?["start_date"] != nil)
        #expect(properties?["end_date"] != nil)
        #expect(properties?["startDate"] == nil)
        #expect(properties?["endDate"] == nil)
    }

    @Test
    func `toolDefinition includes annotations`() {
        let definition = ReadOnlyTool.toolDefinition

        #expect(definition.annotations.readOnlyHint == true)
        #expect(definition.annotations.title == "Configuration Reader")
    }

    @Test
    func `toolDefinition handles enum parameters`() {
        let definition = CreateTaskTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue
        let prioritySchema = properties?["priority"]?.objectValue

        #expect(prioritySchema?["type"]?.stringValue == "string")

        // Should have enum values
        let enumValues = prioritySchema?["enum"]?.arrayValue
        #expect(enumValues != nil)
        #expect(enumValues?.contains(.string("low")) == true)
        #expect(enumValues?.contains(.string("medium")) == true)
        #expect(enumValues?.contains(.string("high")) == true)
        #expect(enumValues?.contains(.string("critical")) == true)
    }

    @Test
    func `toolDefinition includes parameter titles`() {
        let definition = ParameterTitlesTool.toolDefinition
        let properties = definition.inputSchema.objectValue?["properties"]?.objectValue

        // Parameter with title should have it in schema
        let citySchema = properties?["city"]?.objectValue
        #expect(citySchema?["title"]?.stringValue == "City Name")

        let unitsSchema = properties?["units"]?.objectValue
        #expect(unitsSchema?["title"]?.stringValue == "Temperature Units")

        // Parameter without title should not have title in schema
        let otherSchema = properties?["other"]?.objectValue
        #expect(otherSchema?["title"] == nil)
    }
}

// MARK: - Parse Tests

struct ParseMethodTests {
    @Test
    func `parse extracts string parameter`() throws {
        let args: [String: Value] = ["message": .string("Hello, World!")]
        let tool = try EchoTool.parse(from: args)

        #expect(tool.message == "Hello, World!")
    }

    @Test
    func `parse extracts multiple parameters`() throws {
        let args: [String: Value] = [
            "a": .double(10.5),
            "b": .double(3.5),
            "operation": .string("add"),
        ]
        let tool = try CalculatorTool.parse(from: args)

        #expect(tool.a == 10.5)
        #expect(tool.b == 3.5)
        #expect(tool.operation == "add")
    }

    @Test
    func `parse handles optional parameter when present`() throws {
        let args: [String: Value] = [
            "name": .string("Alice"),
            "prefix": .string("Hi"),
        ]
        let tool = try GreetTool.parse(from: args)

        #expect(tool.name == "Alice")
        #expect(tool.prefix == "Hi")
    }

    @Test
    func `parse handles optional parameter when absent`() throws {
        let args: [String: Value] = ["name": .string("Bob")]
        let tool = try GreetTool.parse(from: args)

        #expect(tool.name == "Bob")
        #expect(tool.prefix == nil)
    }

    @Test
    func `parse handles optional parameter when null`() throws {
        let args: [String: Value] = ["name": .string("Bob"), "prefix": .null]
        let tool = try GreetTool.parse(from: args)

        #expect(tool.name == "Bob")
        #expect(tool.prefix == nil)
    }

    @Test
    func `parse uses default values when parameter is absent`() throws {
        let args: [String: Value] = [:]
        let tool = try PaginatedListTool.parse(from: args)

        // Should use the default values from the property wrapper
        #expect(tool.pageSize == 25)
        #expect(tool.page == 1)
    }

    @Test
    func `parse overrides defaults when values provided`() throws {
        let args: [String: Value] = [
            "pageSize": .int(50),
            "page": .int(3),
        ]
        let tool = try PaginatedListTool.parse(from: args)

        #expect(tool.pageSize == 50)
        #expect(tool.page == 3)
    }

    @Test
    func `parse uses default values when parameter is null`() throws {
        let args: [String: Value] = [
            "pageSize": .null,
            "page": .null,
        ]
        let tool = try PaginatedListTool.parse(from: args)

        // Null should be treated as absent, using the default values
        #expect(tool.pageSize == 25)
        #expect(tool.page == 1)
    }

    @Test
    func `parse throws error when default parameter has wrong type`() throws {
        let args: [String: Value] = [
            "pageSize": .string("not a number"), // Wrong type - should throw, not silently use default
            "page": .int(1),
        ]

        #expect(throws: MCPError.self) {
            _ = try PaginatedListTool.parse(from: args)
        }
    }

    @Test
    func `parse handles array parameters`() throws {
        let args: [String: Value] = [
            "items": .array([.string("one"), .string("two"), .string("three")]),
        ]
        let tool = try ProcessItemsTool.parse(from: args)

        #expect(tool.items == ["one", "two", "three"])
    }

    @Test
    func `parse handles dictionary parameters`() throws {
        let args: [String: Value] = [
            "url": .string("https://example.com"),
            "headers": .object([
                "Content-Type": .string("application/json"),
                "Authorization": .string("Bearer token123"),
            ]),
        ]
        let tool = try HttpRequestTool.parse(from: args)

        #expect(tool.url == "https://example.com")
        #expect(tool.headers["Content-Type"] == "application/json")
        #expect(tool.headers["Authorization"] == "Bearer token123")
        #expect(tool.headers.count == 2)
    }

    @Test
    func `parse handles nested array parameters`() throws {
        let args: [String: Value] = [
            "matrix": .array([
                .array([.int(1), .int(2), .int(3)]),
                .array([.int(4), .int(5), .int(6)]),
            ]),
        ]
        let tool = try MatrixTool.parse(from: args)

        #expect(tool.matrix.count == 2)
        #expect(tool.matrix[0] == [1, 2, 3])
        #expect(tool.matrix[1] == [4, 5, 6])
    }

    @Test
    func `parse handles array of dictionaries parameters`() throws {
        let args: [String: Value] = [
            "records": .array([
                .object(["name": .string("Alice"), "role": .string("admin")]),
                .object(["name": .string("Bob"), "role": .string("user")]),
            ]),
        ]
        let tool = try RecordsTool.parse(from: args)

        #expect(tool.records.count == 2)
        #expect(tool.records[0]["name"] == "Alice")
        #expect(tool.records[0]["role"] == "admin")
        #expect(tool.records[1]["name"] == "Bob")
        #expect(tool.records[1]["role"] == "user")
    }

    @Test
    func `parse handles dictionary of arrays parameters`() throws {
        let args: [String: Value] = [
            "groups": .object([
                "scores": .array([.int(85), .int(90), .int(78)]),
                "counts": .array([.int(10), .int(20)]),
            ]),
        ]
        let tool = try GroupedDataTool.parse(from: args)

        #expect(tool.groups.count == 2)
        #expect(tool.groups["scores"] == [85, 90, 78])
        #expect(tool.groups["counts"] == [10, 20])
    }

    @Test
    func `parse handles Date parameters`() throws {
        let dateString = "2024-06-15T10:30:00Z"
        let args: [String: Value] = [
            "eventName": .string("Meeting"),
            "eventDate": .string(dateString),
        ]
        let tool = try ScheduleTool.parse(from: args)

        #expect(tool.eventName == "Meeting")

        let formatter = ISO8601DateFormatter()
        let expectedDate = formatter.date(from: dateString)
        #expect(tool.eventDate == expectedDate)
    }

    @Test
    func `parse respects custom JSON keys`() throws {
        let args: [String: Value] = [
            "start_date": .string("2024-01-01"),
            "end_date": .string("2024-12-31"),
        ]
        let tool = try CustomKeyTool.parse(from: args)

        #expect(tool.startDate == "2024-01-01")
        #expect(tool.endDate == "2024-12-31")
    }

    @Test
    func `parse handles Bool parameters`() throws {
        let args: [String: Value] = [
            "includeArchived": .bool(true),
            "limit": .int(50),
        ]
        let tool = try FilterTool.parse(from: args)

        #expect(tool.includeArchived == true)
        #expect(tool.limit == 50)
    }

    @Test
    func `parse handles enum parameters`() throws {
        let args: [String: Value] = [
            "title": .string("Fix bug"),
            "priority": .string("high"),
        ]
        let tool = try CreateTaskTool.parse(from: args)

        #expect(tool.title == "Fix bug")
        #expect(tool.priority == .high)
    }

    @Test
    func `parse throws for missing required parameter`() throws {
        let args: [String: Value] = [:]

        #expect(throws: MCPError.self) {
            _ = try EchoTool.parse(from: args)
        }
    }

    @Test
    func `parse throws for invalid type`() throws {
        let args: [String: Value] = [
            "message": .int(123), // Should be string
        ]

        #expect(throws: MCPError.self) {
            _ = try EchoTool.parse(from: args)
        }
    }
}

// MARK: - Tool Execution Tests

struct ToolExecutionTests {
    /// Creates a mock HandlerContext for testing
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
    func `Tool execution returns expected string output`() async throws {
        let args: [String: Value] = ["message": .string("Test message")]
        let tool = try EchoTool.parse(from: args)
        let context = createMockContext()

        let result = try await tool._perform(context: context)
        #expect(result == "Echo: Test message")
    }

    @Test
    func `Tool execution with calculations`() async throws {
        let args: [String: Value] = [
            "a": .double(10),
            "b": .double(5),
            "operation": .string("multiply"),
        ]
        let tool = try CalculatorTool.parse(from: args)
        let context = createMockContext()

        let result = try await tool._perform(context: context)
        #expect(result == "Result: 50.0")
    }

    @Test
    func `Tool execution with optional parameter`() async throws {
        let context = createMockContext()

        // Without optional
        let args1: [String: Value] = ["name": .string("World")]
        let tool1 = try GreetTool.parse(from: args1)
        let result1 = try await tool1._perform(context: context)
        #expect(result1 == "Hello, World!")

        // With optional
        let args2: [String: Value] = ["name": .string("World"), "prefix": .string("Greetings")]
        let tool2 = try GreetTool.parse(from: args2)
        let result2 = try await tool2._perform(context: context)
        #expect(result2 == "Greetings, World!")
    }

    @Test
    func `Tool execution with array processing`() async throws {
        let args: [String: Value] = [
            "items": .array([.string("apple"), .string("banana"), .string("cherry")]),
        ]
        let tool = try ProcessItemsTool.parse(from: args)
        let context = createMockContext()

        let result = try await tool._perform(context: context)
        #expect(result == "Processed 3 items: apple, banana, cherry")
    }

    @Test
    func `Tool execution with enum parameter`() async throws {
        let args: [String: Value] = [
            "title": .string("Important task"),
            "priority": .string("critical"),
        ]
        let tool = try CreateTaskTool.parse(from: args)
        let context = createMockContext()

        let result = try await tool._perform(context: context)
        #expect(result == "Created task 'Important task' with priority: critical")
    }

    @Test
    func `Tool with perform() returns expected output`() async throws {
        let args: [String: Value] = ["value": .string("test input")]
        let tool = try SimplePerformTool.parse(from: args)
        let context = createMockContext()

        // Tools with perform() should work with the bridging perform(context:)
        let result = try await tool._perform(context: context)
        #expect(result == "Processed: test input")
    }

    @Test
    func `Tool with perform() and structured output`() async throws {
        let args: [String: Value] = ["term": .string("search term")]
        let tool = try SimplePerformStructuredTool.parse(from: args)
        let context = createMockContext()

        let result = try await tool._perform(context: context)
        #expect(result.query == "search term")
        #expect(result.totalCount == 5)
        #expect(result.items == ["a", "b", "c"])
    }
}

// MARK: - StructuredOutput Tests

struct StructuredOutputTests {
    @Test
    func `@OutputSchema generates StructuredOutput conformance`() {
        let _: any StructuredOutput.Type = SearchResult.self
    }

    @Test
    func `@OutputSchema generates correct schema`() {
        let schema = SearchResult.schema

        #expect(schema.objectValue?["type"]?.stringValue == "object")

        let properties = schema.objectValue?["properties"]?.objectValue
        #expect(properties?["query"] != nil)
        #expect(properties?["totalCount"] != nil)
        #expect(properties?["items"] != nil)

        let querySchema = properties?["query"]?.objectValue
        #expect(querySchema?["type"]?.stringValue == "string")

        let countSchema = properties?["totalCount"]?.objectValue
        #expect(countSchema?["type"]?.stringValue == "integer")

        let itemsSchema = properties?["items"]?.objectValue
        #expect(itemsSchema?["type"]?.stringValue == "array")
    }

    @Test
    func `StructuredOutput encodes to CallTool.Result correctly`() throws {
        let output = SearchResult(
            query: "test query",
            totalCount: 42,
            items: ["result1", "result2"],
        )

        let result = try output.toCallToolResult()

        // Should have text content
        #expect(!result.content.isEmpty)

        // Should have structured content
        #expect(result.structuredContent != nil)

        let structured = result.structuredContent?.objectValue
        #expect(structured?["query"]?.stringValue == "test query")
        #expect(structured?["totalCount"]?.intValue == 42)

        let items = structured?["items"]?.arrayValue
        #expect(items?.count == 2)
    }

    @Test
    func `Tool with StructuredOutput has outputSchema in definition`() {
        let definition = SearchTool.toolDefinition

        #expect(definition.outputSchema != nil)
        #expect(definition.outputSchema?.objectValue?["type"]?.stringValue == "object")
    }
}

// MARK: - ToolRegistry Tests

struct ToolRegistryTests {
    @Test
    func `ToolRegistry registers tools via result builder`() async {
        let registry = ToolRegistry {
            EchoTool.self
            CalculatorTool.self
        }

        let tools = await registry.definitions
        #expect(tools.count == 2)

        let names = tools.map { $0.name }
        #expect(names.contains("echo"))
        #expect(names.contains("calculator"))
    }

    @Test
    func `ToolRegistry registers tools with register method`() async throws {
        let registry = ToolRegistry()
        try await registry.register(EchoTool.self)
        try await registry.register(GreetTool.self)

        let tools = await registry.definitions
        #expect(tools.count == 2)
    }

    @Test
    func `ToolRegistry hasTool returns correct value`() async {
        let registry = ToolRegistry {
            EchoTool.self
        }

        let hasEcho = await registry.hasTool("echo")
        let hasUnknown = await registry.hasTool("unknown")

        #expect(hasEcho == true)
        #expect(hasUnknown == false)
    }

    @Test
    func `ToolRegistry definitions contain correct tool info`() async {
        let registry = ToolRegistry {
            ReadOnlyTool.self
        }

        let tools = await registry.definitions
        #expect(tools.count == 1)

        let tool = tools[0]
        #expect(tool.name == "read_config")
        #expect(tool.description == "Read configuration (read-only)")
        #expect(tool.annotations.readOnlyHint == true)
        #expect(tool.annotations.title == "Configuration Reader")
    }

    @Test
    func `ToolRegistry execute runs tool and returns result`() async throws {
        let registry = ToolRegistry {
            EchoTool.self
            CalculatorTool.self
        }

        let context = createMockContext()
        let arguments: [String: Value] = ["message": .string("Hello from execute")]

        let result = try await registry.execute("echo", arguments: arguments, context: context)

        #expect(result.content.count == 1)
        if case let .text(text, _, _) = result.content[0] {
            #expect(text == "Echo: Hello from execute")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `ToolRegistry execute throws for unknown tool`() async throws {
        let registry = ToolRegistry {
            EchoTool.self
        }

        let context = createMockContext()

        await #expect(throws: MCPError.self) {
            _ = try await registry.execute("nonexistent", arguments: [:], context: context)
        }
    }

    @Test
    func `ToolRegistry execute handles structured output`() async throws {
        let registry = ToolRegistry {
            SearchTool.self
        }

        let context = createMockContext()
        let arguments: [String: Value] = ["query": .string("test search")]

        let result = try await registry.execute("search", arguments: arguments, context: context)

        // Should have text content
        #expect(!result.content.isEmpty)

        // Should have structured content
        #expect(result.structuredContent != nil)
        let structured = result.structuredContent?.objectValue
        #expect(structured?["query"]?.stringValue == "test search")
    }

    /// Creates a mock HandlerContext for testing
    private func createMockContext() -> HandlerContext {
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
}

// MARK: - ToolOutput Protocol Tests

struct ToolOutputProtocolTests {
    @Test
    func `String conforms to ToolOutput`() throws {
        let output: any ToolOutput = "Hello, World!"
        let result = try output.toCallToolResult()

        #expect(result.content.count == 1)
        if case let .text(text, _, _) = result.content[0] {
            #expect(text == "Hello, World!")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test
    func `ImageOutput creates correct result`() throws {
        let testData = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        let output = ImageOutput(pngData: testData)

        let result = try output.toCallToolResult()
        #expect(result.content.count == 1)

        if case let .image(data, mimeType, _, _) = result.content[0] {
            #expect(mimeType == "image/png")
            #expect(Data(base64Encoded: data) == testData)
        } else {
            Issue.record("Expected image content")
        }
    }

    @Test
    func `MultiContent creates correct result`() throws {
        let output = MultiContent([
            .text("First"),
            .text("Second"),
        ])

        let result = try output.toCallToolResult()
        #expect(result.content.count == 2)
    }
}

// MARK: - AnnotationOption Tests

struct AnnotationOptionTests {
    @Test
    func `AnnotationOption.buildAnnotations creates correct annotations`() {
        let options: [AnnotationOption] = [
            .readOnly,
            .idempotent,
            .title("Test Tool"),
        ]

        let annotations = AnnotationOption.buildAnnotations(from: options)

        #expect(annotations.readOnlyHint == true)
        #expect(annotations.idempotentHint == true)
        #expect(annotations.title == "Test Tool")
    }

    @Test
    func `AnnotationOption.closedWorld sets hint`() {
        let options: [AnnotationOption] = [.closedWorld]
        let annotations = AnnotationOption.buildAnnotations(from: options)

        #expect(annotations.openWorldHint == false)
    }

    @Test
    func `AnnotationOption.readOnly implies non-destructive and idempotent`() {
        let options: [AnnotationOption] = [.readOnly]
        let annotations = AnnotationOption.buildAnnotations(from: options)

        #expect(annotations.readOnlyHint == true)
        #expect(annotations.destructiveHint == false)
        #expect(annotations.idempotentHint == true)
    }

    @Test
    func `Empty annotations array returns empty annotations`() {
        let options: [AnnotationOption] = []
        let annotations = AnnotationOption.buildAnnotations(from: options)

        #expect(annotations.isEmpty)
    }
}

// MARK: - Edge Cases and Error Handling

struct EdgeCaseTests {
    @Test
    func `Empty string parameter is valid`() throws {
        let args: [String: Value] = ["message": .string("")]
        let tool = try EchoTool.parse(from: args)
        #expect(tool.message == "")
    }

    @Test
    func `Empty array parameter is valid`() throws {
        let args: [String: Value] = ["items": .array([])]
        let tool = try ProcessItemsTool.parse(from: args)
        #expect(tool.items.isEmpty)
    }

    @Test
    func `Large numbers are handled correctly`() throws {
        let args: [String: Value] = [
            "a": .double(1e308),
            "b": .double(1e-308),
            "operation": .string("add"),
        ]
        let tool = try CalculatorTool.parse(from: args)
        #expect(tool.a == 1e308)
        #expect(tool.b == 1e-308)
    }

    @Test
    func `Unicode in parameters is preserved`() throws {
        let unicodeMessage = "Hello 世界 \u{1F30D} مرحبا"
        let args: [String: Value] = ["message": .string(unicodeMessage)]
        let tool = try EchoTool.parse(from: args)
        #expect(tool.message == unicodeMessage)
    }

    @Test
    func `Special characters in strings are preserved`() throws {
        let specialMessage = "Line1\nLine2\tTabbed\"Quoted\""
        let args: [String: Value] = ["message": .string(specialMessage)]
        let tool = try EchoTool.parse(from: args)
        #expect(tool.message == specialMessage)
    }

    @Test
    func `Invalid enum value throws error`() throws {
        let args: [String: Value] = [
            "title": .string("Task"),
            "priority": .string("invalid_priority"),
        ]

        #expect(throws: MCPError.self) {
            _ = try CreateTaskTool.parse(from: args)
        }
    }

    @Test
    func `Negative numbers are handled`() throws {
        let args: [String: Value] = [
            "a": .double(-100.5),
            "b": .double(-50.25),
            "operation": .string("add"),
        ]
        let tool = try CalculatorTool.parse(from: args)
        #expect(tool.a == -100.5)
        #expect(tool.b == -50.25)
    }
}

// MARK: - DSL Tool Lifecycle Tests

struct DSLToolLifecycleTests {
    @Test
    func `DSL tool registration returns RegisteredTool`() async throws {
        let registry = ToolRegistry()
        let registered = try await registry.register(EchoTool.self)

        #expect(registered.name == "echo")
        #expect(await registered.isEnabled == true)
    }

    @Test
    func `DSL tool can be disabled`() async throws {
        let registry = ToolRegistry()
        let registered = try await registry.register(EchoTool.self)

        await registered.disable()

        #expect(await registered.isEnabled == false)

        // Disabled tool should not appear in definitions
        let definitions = await registry.definitions
        #expect(definitions.isEmpty)
    }

    @Test
    func `DSL tool can be re-enabled`() async throws {
        let registry = ToolRegistry()
        let registered = try await registry.register(EchoTool.self)

        await registered.disable()
        #expect(await registered.isEnabled == false)

        await registered.enable()
        #expect(await registered.isEnabled == true)

        let definitions = await registry.definitions
        #expect(definitions.count == 1)
    }

    @Test
    func `DSL tool can be removed`() async throws {
        let registry = ToolRegistry()
        let registered = try await registry.register(EchoTool.self)

        #expect(await registry.hasTool("echo") == true)

        await registered.remove()

        #expect(await registry.hasTool("echo") == false)
        let definitions = await registry.definitions
        #expect(definitions.isEmpty)
    }

    @Test
    func `Disabled DSL tool rejects execution`() async throws {
        let registry = ToolRegistry()
        let registered = try await registry.register(EchoTool.self)
        await registered.disable()

        let context = createMockContext()
        let arguments: [String: Value] = ["message": .string("test")]

        await #expect(throws: MCPError.self) {
            _ = try await registry.execute("echo", arguments: arguments, context: context)
        }
    }

    @Test
    func `Multiple DSL tools can have independent lifecycle`() async throws {
        let registry = ToolRegistry()
        let echo = try await registry.register(EchoTool.self)
        let calc = try await registry.register(CalculatorTool.self)

        // Disable only echo
        await echo.disable()

        // Echo should be disabled, calculator should still be enabled
        #expect(await echo.isEnabled == false)
        #expect(await calc.isEnabled == true)

        // Only calculator should appear in definitions
        let definitions = await registry.definitions
        #expect(definitions.count == 1)
        #expect(definitions.first?.name == "calculator")
    }

    @Test
    func `DSL tools registered via result builder start enabled`() async {
        let registry = ToolRegistry {
            EchoTool.self
            CalculatorTool.self
        }

        let definitions = await registry.definitions
        #expect(definitions.count == 2)

        #expect(await registry.isToolEnabled("echo") == true)
        #expect(await registry.isToolEnabled("calculator") == true)
    }

    /// Creates a mock HandlerContext for testing
    private func createMockContext() -> HandlerContext {
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
}
