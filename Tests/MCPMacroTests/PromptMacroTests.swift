// Copyright © Anthony DePasquale

import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

#if canImport(MCPMacros)
import MCPMacros

struct PromptMacroTests {
    let testMacros: [String: Macro.Type] = [
        "Prompt": PromptMacro.self,
    ]

    // MARK: - Compile-Time Validation Tests

    @Test
    func `missing name error`() {
        assertMacroExpansion(
            """
            @Prompt
            struct BadPrompt {
                static let description = "Missing name"

                func render(context: HandlerContext) async throws -> [Prompt.Message] {
                    []
                }
            }
            """,
            expandedSource: """
            struct BadPrompt {
                static let description = "Missing name"

                func render(context: HandlerContext) async throws -> [Prompt.Message] {
                    []
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Prompt requires 'static let name: String' property", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `missing description error`() {
        assertMacroExpansion(
            """
            @Prompt
            struct BadPrompt {
                static let name = "bad_prompt"

                func render(context: HandlerContext) async throws -> [Prompt.Message] {
                    []
                }
            }
            """,
            expandedSource: """
            struct BadPrompt {
                static let name = "bad_prompt"

                func render(context: HandlerContext) async throws -> [Prompt.Message] {
                    []
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Prompt requires 'static let description: String' property", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `not A struct error`() {
        assertMacroExpansion(
            """
            @Prompt
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
                DiagnosticSpec(message: "@Prompt can only be applied to structs", line: 1, column: 1),
            ],
            macros: testMacros,
        )
    }
}
#endif
