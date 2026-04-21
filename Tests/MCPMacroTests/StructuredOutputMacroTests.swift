// Copyright © Anthony DePasquale

import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

#if canImport(MCPMacros)
import MCPMacros

struct StructuredOutputMacroTests {
    let testMacros: [String: Macro.Type] = [
        "StructuredOutput": StructuredOutputMacro.self,
        "ManualEncoding": ManualEncodingMacro.self,
        // `@Schemable` is defined in JSONSchemaBuilder. We don't expand it
        // here — we only assert our macro's expansion under the assumption
        // that the user has applied `@Schemable` at the call site.
    ]

    @Test
    func `basic expansion`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let items: [String]
                let totalCount: Int
                let note: String?
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let items: [String]
                let totalCount: Int
                let note: String?

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.items, forKey: .items)
                    try container.encode(self.totalCount, forKey: .totalCount)
                    try container.encode(self.note, forKey: .note)
                }

                enum CodingKeys: String, CodingKey {
                    case items, totalCount, note
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `user provided coding keys wins`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let firstName: String
                let age: Int

                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                    case age
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let firstName: String
                let age: Int

                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                    case age
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.firstName, forKey: .firstName)
                    try container.encode(self.age, forKey: .age)
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `public struct public encode`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            public struct MyResult {
                public let items: [String]
            }
            """,
            expandedSource: """
            @Schemable
            public struct MyResult {
                public let items: [String]

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.items, forKey: .items)
                }

                public enum CodingKeys: String, CodingKey {
                    case items
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                public static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `fileprivate struct matches access level`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            fileprivate struct MyResult {
                let items: [String]
            }
            """,
            expandedSource: """
            @Schemable
            fileprivate struct MyResult {
                let items: [String]

                fileprivate func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.items, forKey: .items)
                }

                fileprivate enum CodingKeys: String, CodingKey {
                    case items
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                fileprivate static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `private struct matches access level`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            private struct MyResult {
                let items: [String]
            }
            """,
            expandedSource: """
            @Schemable
            private struct MyResult {
                let items: [String]

                private func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.items, forKey: .items)
                }

                private enum CodingKeys: String, CodingKey {
                    case items
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                private static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `generic struct diagnostic`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct Container<T> {
                let value: T
            }
            """,
            expandedSource: """
            @Schemable
            struct Container<T> {
                let value: T
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@StructuredOutput doesn't support generic structs. The synthesized 'outputJSONSchema' is a static property that requires a concrete type. Declare a non-generic wrapper struct (e.g. 'struct MyResult { let container: Container<Int> }') and attach '@StructuredOutput' to the wrapper — attached macros can't be applied to a 'typealias'.",
                    line: 3,
                    column: 17,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `missing schemable diagnostic`() {
        assertMacroExpansion(
            """
            @StructuredOutput
            struct MyResult {
                let items: [String]
            }
            """,
            expandedSource: """
            struct MyResult {
                let items: [String]
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@StructuredOutput requires @Schemable. Add '@Schemable' to 'MyResult' so the schema can be generated.",
                    line: 1,
                    column: 1,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `custom encode without manual encoding diagnostic`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let items: [String]

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeIfPresent(self.items, forKey: .items)
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let items: [String]

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeIfPresent(self.items, forKey: .items)
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@StructuredOutput synthesizes 'encode(to:)' to guarantee a stable wire shape (every optional emits as 'null'). Remove this custom 'encode(to:)' and let the macro synthesize one, or mark the struct '@ManualEncoding' to opt out and take responsibility for stable-shape correctness.",
                    line: 6,
                    column: 10,
                ),
            ],
            macros: testMacros,
        )
    }

    /// Regression test: a non-`encode(to:)` single-argument helper named
    /// `encode` (here `encode(_:)`) must not trip the custom-encoder
    /// diagnostic. Swift overload resolution allows it to coexist with the
    /// synthesized `encode(to:)`, so the macro should still synthesize.
    @Test
    func `unrelated encode overload does not block synthesis`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let items: [String]

                func encode(_ mode: String) -> String {
                    "encoded in \\(mode)"
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let items: [String]

                func encode(_ mode: String) -> String {
                    "encoded in \\(mode)"
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.items, forKey: .items)
                }

                enum CodingKeys: String, CodingKey {
                    case items
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    /// Regression test: a `func encode(to format: OutputFormat) -> String`
    /// helper uses the same external label as the `Encodable` witness but a
    /// different parameter type, so it doesn't collide with synthesis and
    /// must not trip the custom-encoder diagnostic.
    @Test
    func `labeled encode overload with non encoder type does not block synthesis`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let items: [String]

                func encode(to format: String) -> String {
                    "encoded in \\(format)"
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let items: [String]

                func encode(to format: String) -> String {
                    "encoded in \\(format)"
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.items, forKey: .items)
                }

                enum CodingKeys: String, CodingKey {
                    case items
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    /// Regression test: an empty `@StructuredOutput` struct must not emit
    /// an invalid `enum CodingKeys: String, CodingKey { case }` or an
    /// `encode(to:)` body that references a non-existent `CodingKeys.self`.
    /// Swift's default Codable synthesis produces `{}` on the wire, matching
    /// the stable-shape contract vacuously (no optionals to preserve).
    @Test
    func `empty struct skips coding keys and encode synthesis`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct EmptyResult {
            }
            """,
            expandedSource: """
            @Schemable
            struct EmptyResult {
            }

            extension EmptyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `manual encoding opt out`() {
        // `@ManualEncoding` also keeps the user's CodingKeys as-is (if any).
        // The expanded form here has none; the user's hand-rolled encoder uses
        // string-based lookup, which the compiler resolves from the Swift
        // property names via default Codable synthesis on the `Decodable`
        // side if the type ever adopts it.
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            @ManualEncoding
            struct MyResult {
                let items: [String]

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeIfPresent(self.items, forKey: .items)
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let items: [String]

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encodeIfPresent(self.items, forKey: .items)
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `manual encoding without user encode warns`() {
        // `@ManualEncoding` means "I'm hand-rolling the encoder" — if the
        // type doesn't actually define `encode(to:)`, Swift falls back to
        // the default Codable synthesis, which uses `encodeIfPresent` and
        // silently breaks the stable-shape contract. The macro warns.
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            @ManualEncoding
            struct MyResult {
                let items: [String]
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let items: [String]
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ManualEncoding opts out of @StructuredOutput's encoder synthesis, but no 'encode(to:)' was found in the struct body. If your encoder lives in an extension, ignore this warning — macros can't see extensions. Otherwise, the compiler falls back to Swift's default Codable synthesis (which omits nil optionals and breaks the stable-shape contract): add a hand-rolled 'encode(to:)' in the struct body, or remove '@ManualEncoding' to let the macro synthesize a stable encoder.",
                    line: 3,
                    column: 1,
                    severity: .warning,
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `skips static and computed properties`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                static let constant = "x"
                let stored: Int
                var computed: String { "" }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                static let constant = "x"
                let stored: Int
                var computed: String { "" }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(self.stored, forKey: .stored)
                }

                enum CodingKeys: String, CodingKey {
                    case stored
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            macros: testMacros,
        )
    }

    @Test
    func `user coding keys missing case diagnostic`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let firstName: String
                let age: Int
                let nickname: String

                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                    case age
                    // `nickname` missing — synthesized encoder would
                    // fail with "cannot find '.nickname' in CodingKeys".
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let firstName: String
                let age: Int
                let nickname: String

                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                    case age
                    // `nickname` missing — synthesized encoder would
                    // fail with "cannot find '.nickname' in CodingKeys".
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "CodingKeys is missing case(s) for stored property 'nickname'. Add `case nickname` to CodingKeys, or mark the struct '@ManualEncoding' if you intentionally want to exclude properties from the wire shape.",
                    line: 8,
                    column: 10,
                    fixIts: [FixItSpec(message: "Add case 'nickname' to CodingKeys")],
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `user coding keys missing multiple cases diagnostic`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            struct MyResult {
                let firstName: String
                let age: Int
                let nickname: String
                let city: String

                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                }
            }
            """,
            expandedSource: """
            @Schemable
            struct MyResult {
                let firstName: String
                let age: Int
                let nickname: String
                let city: String

                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                }
            }

            extension MyResult: MCPCore.StructuredOutput, MCPCore.WrappableValue {
                static var outputJSONSchema: MCPCore.Value {
                    _structuredOutputSchema
                }
                private static let _structuredOutputSchema: MCPCore.Value = {
                    do {
                        return .object(try MCPCore.SchemableAdapter.structuredOutputSchemaDictionary(from: Self.schema))
                    } catch {
                        fatalError("@StructuredOutput failed to derive outputJSONSchema for \\(Self.self) — the @Schemable component returned a non-object schema or the schema → Value round-trip threw: \\(error)")
                    }
                }()
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "CodingKeys is missing case(s) for stored properties 'age', 'nickname', 'city'. Add `case age, nickname, city` to CodingKeys, or mark the struct '@ManualEncoding' if you intentionally want to exclude properties from the wire shape.",
                    line: 9,
                    column: 10,
                    fixIts: [FixItSpec(message: "Add cases 'age', 'nickname', 'city' to CodingKeys")],
                ),
            ],
            macros: testMacros,
        )
    }

    @Test
    func `not A struct diagnostic`() {
        assertMacroExpansion(
            """
            @Schemable
            @StructuredOutput
            class BadResult {
                var items: [String] = []
            }
            """,
            expandedSource: """
            @Schemable
            class BadResult {
                var items: [String] = []
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@StructuredOutput can only be applied to structs.",
                    line: 2,
                    column: 1,
                ),
            ],
            macros: testMacros,
        )
    }
}
#endif
