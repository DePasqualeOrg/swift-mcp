// Copyright © Anthony DePasquale

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(MCPMacros)
import MCPMacros

final class OutputSchemaMacroTests: XCTestCase {
    let testMacros: [String: Macro.Type] = [
        "OutputSchema": OutputSchemaMacro.self,
    ]

    func testBasicOutputSchemaExpansion() {
        assertMacroExpansion(
            """
            @OutputSchema
            struct SearchResult {
                let items: [String]
                let totalCount: Int
            }
            """,
            expandedSource: """
            struct SearchResult {
                let items: [String]
                let totalCount: Int

                public static var schema: Value {
                    .object([
                        "type": .string("object"),
                        "properties": .object([
                            "items": .object(["type": .string("array"), "items": .object(["type": .string("string")])]), "totalCount": .object(["type": .string("integer")])
                        ]),
                        "required": .array([.string("items"), .string("totalCount")])
                    ])
                }
            }

            extension SearchResult: MCP.StructuredOutput {
            }
            """,
            macros: testMacros,
        )
    }

    func testOutputSchemaWithOptionalProperty() {
        assertMacroExpansion(
            """
            @OutputSchema
            struct UserProfile {
                let name: String
                let email: String?
            }
            """,
            expandedSource: """
            struct UserProfile {
                let name: String
                let email: String?

                public static var schema: Value {
                    .object([
                        "type": .string("object"),
                        "properties": .object([
                            "name": .object(["type": .string("string")]), "email": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("name")])
                    ])
                }
            }

            extension UserProfile: MCP.StructuredOutput {
            }
            """,
            macros: testMacros,
        )
    }

    func testOutputSchemaWithMultipleTypes() {
        assertMacroExpansion(
            """
            @OutputSchema
            struct AnalysisResult {
                let score: Double
                let passed: Bool
                let message: String
            }
            """,
            expandedSource: """
            struct AnalysisResult {
                let score: Double
                let passed: Bool
                let message: String

                public static var schema: Value {
                    .object([
                        "type": .string("object"),
                        "properties": .object([
                            "score": .object(["type": .string("number")]), "passed": .object(["type": .string("boolean")]), "message": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("score"), .string("passed"), .string("message")])
                    ])
                }
            }

            extension AnalysisResult: MCP.StructuredOutput {
            }
            """,
            macros: testMacros,
        )
    }

    func testOutputSchemaNotAStructError() {
        assertMacroExpansion(
            """
            @OutputSchema
            class BadOutput {
                var value: String
            }
            """,
            expandedSource: """
            class BadOutput {
                var value: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@OutputSchema can only be applied to structs", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }
}
#endif
