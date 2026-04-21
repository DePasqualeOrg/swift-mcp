// Copyright © Anthony DePasquale

import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

#if canImport(MCPMacros)
import MCPMacros

struct ToolMacroTests {
    let testMacros: [String: Macro.Type] = [
        "Tool": ToolMacro.self,
    ]

    // MARK: - Compile-Time Validation Tests

    @Test
    func `missing name error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let description = "Missing name"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let description = "Missing name"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'static let name: String' property", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `missing description error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'static let description: String' property", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `not A struct error`() {
        assertMacroExpansion(
            """
            @Tool
            class BadClass {
                static let name = "bad"
                static let description = "Bad"
            }
            """,
            expandedSource: """
            class BadClass {
                static let name = "bad"
                static let description = "Bad"
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool can only be applied to structs", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `invalid tool name with spaces`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "invalid tool name"
                static let description = "Has spaces"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "invalid tool name"
                static let description = "Has spaces"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Invalid tool name: Tool name contains invalid characters: ' ', ' '. Only A-Z, a-z, 0-9, _, -, . are allowed", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `invalid tool name too long`() {
        let longName = String(repeating: "a", count: 129)
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "\(longName)"
                static let description = "Name too long"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "\(longName)"
                static let description = "Name too long"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Invalid tool name: Tool name exceeds maximum length of 128 characters (got 129)", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `duplicate annotation error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Duplicate annotations"
                static let annotations: [AnnotationOption] = [.readOnly, .readOnly]

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Duplicate annotations"
                static let annotations: [AnnotationOption] = [.readOnly, .readOnly]

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Duplicate annotation: readOnly", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `non literal default value error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-literal default"

                @Parameter(description: "Start date")
                var startDate: Date = Date()

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-literal default"

                @Parameter(description: "Start date")
                var startDate: Date = Date()

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Parameter 'startDate' has a non-literal default value. Only literal values (numbers, strings, booleans) are supported. For complex defaults, make the parameter optional and handle the default in perform().", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `interpolated string default value error`() {
        assertMacroExpansion(
            #"""
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Interpolated string default"

                @Parameter(description: "Greeting")
                var greeting: String = "Hello, \(name)"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """#,
            expandedSource: #"""
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Interpolated string default"

                @Parameter(description: "Greeting")
                var greeting: String = "Hello, \(name)"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """#,
            diagnostics: [
                DiagnosticSpec(message: "Parameter 'greeting' has a non-literal default value. Only literal values (numbers, strings, booleans) are supported. For complex defaults, make the parameter optional and handle the default in perform().", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    // MARK: - Access Level Propagation Tests

    @Test
    func `public struct generates public members`() {
        assertMacroExpansion(
            """
            @Tool
            public struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            public struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                public init() {
                }

                public func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                public static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                public static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `public struct with annotations`() {
        assertMacroExpansion(
            """
            @Tool
            public struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"
                static let annotations: [AnnotationOption] = [.readOnly, .title("My Tool")]

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            public struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"
                static let annotations: [AnnotationOption] = [.readOnly, .title("My Tool")]

                func perform() async throws -> String {
                    "done"
                }

                public init() {
                }

                public func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                public static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                public static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `internal struct generates internal members`() {
        assertMacroExpansion(
            """
            @Tool
            struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `package struct generates package members`() {
        assertMacroExpansion(
            """
            @Tool
            package struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            package struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                package init() {
                }

                package func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                package static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                package static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `public struct with perform context`() {
        assertMacroExpansion(
            """
            @Tool
            public struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform(context: HandlerContext) async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            public struct MyTool {
                static let name = "my_tool"
                static let description = "A tool"

                func perform(context: HandlerContext) async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                public init() {
                }

                public func _perform(context: HandlerContext) async throws -> String {
                    try await perform(context: context)
                }

                public static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                public static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    // MARK: - Signature Validation Tests

    @Test
    func `perform missing async error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing async"

                func perform() throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing async"

                func perform() throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'perform()' to be marked 'async'", line: 6, column: 10),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `perform missing throws error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing throws"

                func perform() async -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing throws"

                func perform() async -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'perform()' to be marked 'throws'", line: 6, column: 10),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `perform missing return type expands as void`() {
        // A `perform()` with no return clause is treated as `Void`. The
        // synthesized `_perform(context:)` bridge runs the handler, discards
        // the empty tuple, and emits the `VoidOutput` sentinel so the wire
        // shape matches `Optional<T>` returning `nil`.
        assertMacroExpansion(
            """
            @Tool
            struct ActionTool {
                static let name = "action_tool"
                static let description = "Runs an action with no return value"

                func perform() async throws {
                }
            }
            """,
            expandedSource: """
            struct ActionTool {
                static let name = "action_tool"
                static let description = "Runs an action with no return value"

                func perform() async throws {
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> MCPCore.VoidOutput {
                    try await perform()
                    return MCPCore.VoidOutput()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension ActionTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `perform has unexpected parameters error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Unexpected parameters"

                func perform(input: String) async throws -> String {
                    input
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Unexpected parameters"

                func perform(input: String) async throws -> String {
                    input
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'perform()' to take no arguments besides an optional 'context: HandlerContext'. Use '@Parameter' properties on the struct to declare inputs.", line: 6, column: 17),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `perform context wrong type error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Wrong context type"

                func perform(context: Int) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Wrong context type"

                func perform(context: Int) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "The 'context' parameter of 'perform()' must be of type 'HandlerContext' (or 'MCP.HandlerContext'); got 'Int'.", line: 6, column: 27),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `static perform method error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Static perform"

                static func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Static perform"

                static func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'perform()' to be an instance method, not static.", line: 6, column: 17),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `parameter on static property error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Static parameter"

                @Parameter(description: "A static property")
                static var shared: String = "oops"

                func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Static parameter"

                @Parameter(description: "A static property")
                static var shared: String = "oops"

                func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Parameter cannot be applied to static property 'shared'. Tool parameters must be instance properties.", line: 6, column: 5),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `duplicate parameter key error`() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Duplicate keys"

                @Parameter(key: "query", description: "First")
                var first: String

                @Parameter(key: "query", description: "Second")
                var second: String

                func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Duplicate keys"

                @Parameter(key: "query", description: "First")
                var first: String

                @Parameter(key: "query", description: "Second")
                var second: String

                func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Duplicate @Parameter key 'query'. Each @Parameter key must be unique.", line: 6, column: 5),
                DiagnosticSpec(message: "Duplicate @Parameter key 'query'. Each @Parameter key must be unique.", line: 9, column: 5),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `perform access level warning when more restrictive`() {
        assertMacroExpansion(
            """
            @Tool
            public struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with restrictive perform"

                private func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            public struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with restrictive perform"

                private func perform() async throws -> String {
                    "Result"
                }

                static let annotations: [AnnotationOption] = []

                public init() {
                }

                public func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                public static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                public static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'perform()' has more restrictive access (private) than the enclosing struct (public). If the return type is similarly restricted, the generated '_perform(context:)' bridge will fail to compile.",
                    line: 6,
                    column: 5,
                    severity: .warning,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `missing perform does not cascade conformance error`() {
        // Regression test: when perform() is missing, the ExtensionMacro must NOT add the
        // ToolSpec conformance — otherwise the user sees both the attribute-level
        // missingPerformMethod error AND a generated "does not conform to ToolSpec" error.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing perform"
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing perform"
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Tool requires a 'perform' method (e.g., 'func perform() async throws -> String')",
                    line: 1,
                    column: 1,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `MCP qualified handler context accepted`() {
        // Regression test: `MCP.HandlerContext` should be accepted as the context type.
        assertMacroExpansion(
            """
            @Tool
            public struct MyTool {
                static let name = "my_tool"
                static let description = "Qualified context type"

                func perform(context: MCP.HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            public struct MyTool {
                static let name = "my_tool"
                static let description = "Qualified context type"

                func perform(context: MCP.HandlerContext) async throws -> String {
                    "Result"
                }

                static let annotations: [AnnotationOption] = []

                public init() {
                }

                public func _perform(context: HandlerContext) async throws -> String {
                    try await perform(context: context)
                }

                public static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                public static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `parameter missing type annotation error`() {
        // `@Parameter var count = 1` relies on type inference from the default value.
        // The macro needs an explicit annotation to pick the schema and parse code,
        // so it must reject this up front — otherwise it would emit String.schema
        // and the user would see a downstream "cannot assign String to Int" error.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing type annotation"

                @Parameter(description: "Count")
                var count = 1

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing type annotation"

                @Parameter(description: "Count")
                var count = 1

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Parameter property 'count' requires an explicit type annotation (e.g. 'var count: Int').",
                    line: 7,
                    column: 9,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `perform with two context parameters error`() {
        // Swift allows duplicate parameter labels at declaration time, so
        // `perform(context:, context:)` would otherwise pass macro validation
        // and fail later with a misleading compiler error from the generated
        // `_perform(context:)` bridge.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Two context parameters"

                func perform(context: HandlerContext, context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Two context parameters"

                func perform(context: HandlerContext, context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Tool allows at most one 'context' parameter on 'perform()'.",
                    line: 6,
                    column: 43,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `negative literal default`() {
        // Covers PrefixOperatorExpr('-') in both isLiteralExpression (accept) and
        // convertToValueLiteral (map to .int/.double). If the two drift, the second
        // now traps via preconditionFailure rather than silently emitting .null.
        assertMacroExpansion(
            """
            @Tool
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with negative default"

                @Parameter(description: "Count")
                var count: Int = -5

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with negative default"

                @Parameter(description: "Count")
                var count: Int = -5

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: [
                                MCPTool.ToolMacroSupport.makeSchemaParameterDescriptor(
                    name: "count",
                    title: nil,
                    description: "Count",
                    schema: Int.schema,
                    isOptional: false,
                    hasDefault: true,
                    defaultValue: .int(-5),
                    minLength: nil,
                    maxLength: nil,
                    minimum: nil,
                    maximum: nil
                                )
                            ]
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    var _instance = Self()
                    let _args = arguments ?? [:]
                    if let _value = _args["count"], !_value.isNull {
                        _instance.count = try MCPTool.ToolMacroSupport.parseParameter(Int.schema, from: _value, parameterName: "count")
                    }
                    return _instance
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `explicit optional parameter type`() {
        // Covers `unwrapExplicitOptional` — the non-sugared `Optional<T>` form
        // must be treated the same as `T?` (isOptional: true, typeName: T).
        assertMacroExpansion(
            """
            @Tool
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with explicit Optional"

                @Parameter(description: "Limit")
                var limit: Optional<Int>

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with explicit Optional"

                @Parameter(description: "Limit")
                var limit: Optional<Int>

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: [
                                MCPTool.ToolMacroSupport.makeSchemaParameterDescriptor(
                    name: "limit",
                    title: nil,
                    description: "Limit",
                    schema: Int.schema,
                    isOptional: true,
                    hasDefault: false,
                    defaultValue: nil,
                    minLength: nil,
                    maxLength: nil,
                    minimum: nil,
                    maximum: nil
                                )
                            ]
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    var _instance = Self()
                    let _args = arguments ?? [:]
                    if let _value = _args["limit"], !_value.isNull {
                        _instance.limit = try MCPTool.ToolMacroSupport.parseParameter(Int.schema, from: _value, parameterName: "limit")
                    }
                    return _instance
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `parameter with did set observer accepted`() {
        // Stored properties with observers remain assignable by the generated
        // parser, so they must not be rejected as computed.
        assertMacroExpansion(
            """
            @Tool
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with observer-backed parameter"

                @Parameter(description: "City")
                var city: String = "" {
                    didSet {}
                }

                func perform() async throws -> String {
                    city
                }
            }
            """,
            expandedSource: """
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with observer-backed parameter"

                @Parameter(description: "City")
                var city: String = "" {
                    didSet {}
                }

                func perform() async throws -> String {
                    city
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: [
                                MCPTool.ToolMacroSupport.makeSchemaParameterDescriptor(
                    name: "city",
                    title: nil,
                    description: "City",
                    schema: String.schema,
                    isOptional: false,
                    hasDefault: true,
                    defaultValue: .string(""),
                    minLength: nil,
                    maxLength: nil,
                    minimum: nil,
                    maximum: nil
                                )
                            ]
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    var _instance = Self()
                    let _args = arguments ?? [:]
                    if let _value = _args["city"], !_value.isNull {
                        _instance.city = try MCPTool.ToolMacroSupport.parseParameter(String.schema, from: _value, parameterName: "city")
                    }
                    return _instance
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `computed parameter property error`() {
        // Getter-backed properties cannot be assigned by the generated parser.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Computed parameter"

                @Parameter(description: "City")
                var city: String {
                    "Paris"
                }

                func perform() async throws -> String {
                    city
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Computed parameter"

                @Parameter(description: "City")
                var city: String {
                    "Paris"
                }

                func perform() async throws -> String {
                    city
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Parameter property 'city' must be a stored property, not computed (the macro-generated parser assigns to it).",
                    line: 7,
                    column: 9,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `special chars in parameter description`() {
        // Covers swiftStringLiteral's escape path for backslash + quote. Without the
        // re-escaping, the generated source would contain a raw `"` that closes the
        // enclosing string literal and fails to compile. (This test avoids `\n` / `\t`
        // in the description because a non-sugared newline splits StringSegmentSyntax,
        // which is a separate orthogonal concern from escaping.)
        assertMacroExpansion(
            #"""
            @Tool
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool"

                @Parameter(description: "She said \"hi\" and left")
                var message: String

                func perform() async throws -> String {
                    "done"
                }
            }
            """#,
            expandedSource: #"""
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool"

                @Parameter(description: "She said \"hi\" and left")
                var message: String

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: [
                                MCPTool.ToolMacroSupport.makeSchemaParameterDescriptor(
                    name: "message",
                    title: nil,
                    description: "She said \\\"hi\\\" and left",
                    schema: String.schema,
                    isOptional: false,
                    hasDefault: false,
                    defaultValue: nil,
                    minLength: nil,
                    maxLength: nil,
                    minimum: nil,
                    maximum: nil
                                )
                            ]
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\(name)': \(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    var _instance = Self()
                    let _args = arguments ?? [:]
                    guard let _messageValue = _args["message"] else {
                        throw MCPError.invalidParams("Missing required parameter 'message'")
                    }
                    _instance.message = try MCPTool.ToolMacroSupport.parseParameter(String.schema, from: _messageValue, parameterName: "message")
                    return _instance
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """#,
            macros: testMacros,
        )
    }

    @Test
    func `qualified MCP parameter attribute`() {
        // Covers isParameterAttribute's qualified-attribute branch: `@MCP.Parameter`
        // must be recognized the same as the bare `@Parameter`. Used when a file
        // imports both MCP and AI and needs to disambiguate.
        assertMacroExpansion(
            """
            @Tool
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with qualified parameter"

                @MCP.Parameter(description: "Query string")
                var query: String

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            struct MyTool {
                static let name = "my_tool"
                static let description = "Tool with qualified parameter"

                @MCP.Parameter(description: "Query string")
                var query: String

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: [
                                MCPTool.ToolMacroSupport.makeSchemaParameterDescriptor(
                    name: "query",
                    title: nil,
                    description: "Query string",
                    schema: String.schema,
                    isOptional: false,
                    hasDefault: false,
                    defaultValue: nil,
                    minLength: nil,
                    maxLength: nil,
                    minimum: nil,
                    maximum: nil
                                )
                            ]
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    var _instance = Self()
                    let _args = arguments ?? [:]
                    guard let _queryValue = _args["query"] else {
                        throw MCPError.invalidParams("Missing required parameter 'query'")
                    }
                    _instance.query = try MCPTool.ToolMacroSupport.parseParameter(String.schema, from: _queryValue, parameterName: "query")
                    return _instance
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `tool name style warning for trailing dash`() {
        // Tool name "foo-" has valid characters but ends with '-', which some
        // downstream hosts reject. The macro emits a warning but still generates
        // members so the user sees the warning in context of a working tool.
        assertMacroExpansion(
            """
            @Tool
            struct MyTool {
                static let name = "foo-"
                static let description = "Trailing dash in name"

                func perform() async throws -> String {
                    "done"
                }
            }
            """,
            expandedSource: """
            struct MyTool {
                static let name = "foo-"
                static let description = "Trailing dash in name"

                func perform() async throws -> String {
                    "done"
                }

                static let annotations: [AnnotationOption] = []

                init() {
                }

                func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Tool name 'foo-' ends with '-' which may cause compatibility issues",
                    line: 3,
                    column: 23,
                    severity: .warning,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `unmarked perform in public struct does not warn`() {
        // Regression test: the canonical `public struct` + unmarked `func perform()`
        // pattern must NOT trigger the access-level warning. That warning only fires
        // for explicit more-restrictive modifiers.
        assertMacroExpansion(
            """
            @Tool
            public struct MyTool {
                static let name = "my_tool"
                static let description = "Canonical public tool"

                func perform() async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            public struct MyTool {
                static let name = "my_tool"
                static let description = "Canonical public tool"

                func perform() async throws -> String {
                    "Result"
                }

                static let annotations: [AnnotationOption] = []

                public init() {
                }

                public func _perform(context: HandlerContext) async throws -> String {
                    try await perform()
                }

                public static var toolDefinition: MCP.Tool {
                    // Schema-build failures here (e.g. duplicate parameter names) are programmer
                    // errors that must trap at registration rather than silently shipping an empty
                    // schema to clients. We trap with a tool-named precondition for a readable
                    // crash log instead of a bare `try!` trap.
                    let _schema: [String: MCP.Value]
                    do {
                        _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                            parameters: []
                        )
                    } catch {
                        preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
                    }
                    return MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object(_schema),
                        outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                        annotations: AnnotationOption.buildAnnotations(from: annotations)
                    )
                }

                public static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                    Self()
                }
            }

            extension MyTool: MCP.ToolSpec, Sendable {
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `negative non numeric literal default rejected`() {
        // `isLiteralExpression` used to accept any `PrefixOperatorExpr('-')` wrapping a
        // literal (including Bool/String/nil), but `convertToValueLiteral` only knows how
        // to emit `.int`/`.double` for negative numerics — anything else hit
        // `preconditionFailure` and crashed the macro plugin. The validator now restricts
        // the prefix-minus branch to numeric literals so nonsense defaults like `-true`
        // get the normal "non-literal default" diagnostic instead of a plugin crash.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Negative non-numeric default"

                @Parameter(description: "Flag")
                var flag: Bool = -true

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Negative non-numeric default"

                @Parameter(description: "Flag")
                var flag: Bool = -true

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Parameter 'flag' has a non-literal default value. Only literal values (numbers, strings, booleans) are supported. For complex defaults, make the parameter optional and handle the default in perform().", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `non literal parameter description rejected`() {
        // `@Parameter(key:/title:/description:)` values are baked into generated Swift
        // source, so the macro used to silently drop non-literal expressions and fall
        // back to nil metadata — producing a silent divergence between the declared tool
        // interface and the generated schema. The shared helper now emits a node-level
        // diagnostic so the mismatch surfaces at compile time.
        assertMacroExpansion(
            #"""
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-literal parameter metadata"

                @Parameter(description: sharedDescription)
                var city: String

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """#,
            expandedSource: #"""
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-literal parameter metadata"

                @Parameter(description: sharedDescription)
                var city: String

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """#,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Parameter 'description' on 'city' must be a string literal.",
                    line: 6,
                    column: 29,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `non literal tool name does not add conformance`() {
        // When `static let name` isn't a plain string literal the member macro refuses to
        // generate the required members. The diagnostic points at the offending
        // expression (matching the `@Parameter` treatment), not at the attribute — a
        // generic "property is missing" error would mislead the user, since the property
        // is present but has a non-literal value.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = someComputedName
                static let description = "Non-literal name"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = someComputedName
                static let description = "Non-literal name"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Tool 'name' must be a string literal.",
                    line: 3,
                    column: 23,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `non literal strict schema diagnostic`() {
        // `strictSchema` is read at macro expansion time to decide whether to insert
        // the strict-mode validation call. A non-literal initializer would have been
        // silently treated as `false` and disabled the assertion without warning.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-literal strictSchema"
                static let strictSchema = sharedFlag

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-literal strictSchema"
                static let strictSchema = sharedFlag

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Tool 'strictSchema' must be a boolean literal (true or false).",
                    line: 5,
                    column: 31,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `non array literal annotations diagnostic`() {
        // `annotations` is inspected at macro expansion time for duplicate detection
        // and to decide whether to synthesize an empty default. A non-array
        // initializer (e.g. `static let annotations = 1`) used to bypass both checks
        // and only fail later as a type-mismatch error in the generated code.
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-array annotations"
                static let annotations = 1

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Non-array annotations"
                static let annotations = 1

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Tool 'annotations' must be an array literal of AnnotationOption values.",
                    line: 5,
                    column: 30,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `interpolated tool description diagnostic`() {
        // Interpolated `static let description = "prefix \\(suffix)"` used to silently
        // fall through to the generic `missingDescription` error. It now gets a targeted
        // diagnostic explaining that interpolation isn't supported.
        assertMacroExpansion(
            #"""
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Prefix \(suffix)"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """#,
            expandedSource: #"""
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Prefix \(suffix)"

                func perform(context: HandlerContext) async throws -> String {
                    "Result"
                }
            }
            """#,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Tool 'description' must be a plain string literal without interpolation.",
                    line: 4,
                    column: 30,
                ),
            ],
            macros: testMacros,
        )
    }
}
#endif
