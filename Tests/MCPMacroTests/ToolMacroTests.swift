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
}
#endif
