// Copyright © Anthony DePasquale

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(MCPMacros)
import MCPMacros

final class ToolMacroTests: XCTestCase {
    let testMacros: [String: Macro.Type] = [
        "Tool": ToolMacro.self,
    ]

    // MARK: - Compile-Time Validation Tests

    func testMissingNameError() throws {
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
            macros: testMacros
        )
    }

    func testMissingDescriptionError() throws {
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
            macros: testMacros
        )
    }

    func testNotAStructError() throws {
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
            macros: testMacros
        )
    }

    func testInvalidToolNameWithSpaces() throws {
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
                DiagnosticSpec(message: "Invalid tool name: Tool name contains invalid characters: '  '. Only A-Z, a-z, 0-9, _, -, . are allowed", line: 1, column: 1),
            ],
            macros: testMacros
        )
    }

    func testInvalidToolNameTooLong() throws {
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
            macros: testMacros
        )
    }

    func testDuplicateAnnotationError() throws {
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
            macros: testMacros
        )
    }

    func testNonLiteralDefaultValueError() throws {
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
            macros: testMacros
        )
    }

    // MARK: - Access Level Propagation Tests

    func testPublicStructGeneratesPublicMembers() throws {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }

    func testPublicStructWithAnnotations() throws {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }

    func testInternalStructGeneratesInternalMembers() throws {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }

    func testPackageStructGeneratesPackageMembers() throws {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }

    func testPublicStructWithPerformContext() throws {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }

    // MARK: - Signature Validation Tests

    func testPerformMissingAsyncError() {
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
            macros: testMacros
        )
    }

    func testPerformMissingThrowsError() {
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
            macros: testMacros
        )
    }

    func testPerformMissingReturnTypeError() {
        assertMacroExpansion(
            """
            @Tool
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing return"

                func perform() async throws {
                }
            }
            """,
            expandedSource: """
            struct BadTool {
                static let name = "bad_tool"
                static let description = "Missing return"

                func perform() async throws {
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Tool requires 'perform()' to return a value conforming to 'ToolOutput'", line: 6, column: 10),
            ],
            macros: testMacros
        )
    }

    func testPerformHasUnexpectedParametersError() {
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
            macros: testMacros
        )
    }

    func testPerformContextWrongTypeError() {
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
            macros: testMacros
        )
    }

    func testStaticPerformMethodError() {
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
            macros: testMacros
        )
    }

    func testParameterOnStaticPropertyError() {
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
            macros: testMacros
        )
    }

    func testDuplicateParameterKeyError() {
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
            macros: testMacros
        )
    }

    func testPerformAccessLevelWarningWhenMoreRestrictive() {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
                    message: "'perform()' has more restrictive access (private) than the enclosing struct (public). If the return type is similarly restricted, the generated '_perform()' bridge will fail to compile.",
                    line: 6,
                    column: 5,
                    severity: .warning
                ),
            ],
            macros: testMacros
        )
    }

    func testMissingPerformDoesNotCascadeConformanceError() {
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
                    column: 1
                ),
            ],
            macros: testMacros
        )
    }

    func testMCPQualifiedHandlerContextAccepted() {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }

    func testUnmarkedPerformInPublicStructDoesNotWarn() {
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
                    MCP.Tool(
                        name: name,
                        description: description,
                        inputSchema: .object([
                            "type": .string("object"),
                                    "properties": .object([:]),
                                    "required": .array([])
                        ]),
                        outputSchema: outputSchema(for: Output.self),
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
            macros: testMacros
        )
    }
}
#endif
