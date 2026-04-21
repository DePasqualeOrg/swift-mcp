// Copyright © Anthony DePasquale

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// The `@StructuredOutput` macro pairs with JSONSchemaBuilder's `@Schemable`
/// to give a struct a stable, code-mode-friendly wire encoding and
/// `StructuredOutput` protocol conformance.
///
/// Each attribute owns one concern:
/// - `@Schemable` (JSONSchemaBuilder, unchanged) — generates the schema.
/// - `@StructuredOutput` (this macro) — synthesizes a stable `encode(to:)`
///   that calls `container.encode` for every stored property so optionals
///   emit as `null` rather than being absent, adds `StructuredOutput`
///   conformance, and bridges `outputJSONSchema` to the Schemable component
///   through `SchemableAdapter`.
///
/// Usage:
/// ```swift
/// @Schemable
/// @StructuredOutput
/// struct SearchResult {
///     let items: [String]
///     let note: String?
/// }
/// ```
///
/// Diagnostics:
/// - If the type also defines its own `encode(to:)` and is not marked
///   `@ManualEncoding`, the macro emits an error. The stable-shape contract
///   requires a specific encoding behavior that a silent synthesis-skip would
///   undermine; users opt out explicitly with `@ManualEncoding`.
/// - If the type is missing `@Schemable`, the macro emits a targeted
///   diagnostic ("`@StructuredOutput` requires `@Schemable` — add it").
/// - If the user provides a `CodingKeys` enum that doesn't cover every
///   stored property, the macro emits an error naming the missing
///   property. Without this, the synthesized `encode(to:)` produces a
///   confusing "cannot find '.X' in type 'CodingKeys'" error at the call
///   site in the generated code.
public struct StructuredOutputMacro: MemberMacro, ExtensionMacro {
    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StructuredOutputMacroDiagnostic.error(
                    "@StructuredOutput can only be applied to structs.",
                ),
            ))
            return []
        }

        // Reject generic structs. The synthesized extension references
        // `Self.schema` and `Self.outputJSONSchema` as static properties,
        // which don't exist on an unbound generic type — and the runtime
        // dispatch in `MCPSchema.outputSchema(for:)` casts to
        // `any StructuredOutput.Type`, which also can't resolve an
        // unsubstituted generic. Letting the macro expand anyway produces
        // confusing downstream compile errors pointing at generated code.
        if let genericClause = structDecl.genericParameterClause {
            context.diagnose(Diagnostic(
                node: Syntax(genericClause),
                message: StructuredOutputMacroDiagnostic.error(
                    "@StructuredOutput doesn't support generic structs. The synthesized 'outputJSONSchema' is a static property that requires a concrete type. Declare a non-generic wrapper struct (e.g. 'struct MyResult { let container: Container<Int> }') and attach '@StructuredOutput' to the wrapper — attached macros can't be applied to a 'typealias'.",
                ),
            ))
            return []
        }

        // Require `@Schemable` to be applied alongside. `@Schemable` is what
        // generates the `static var schema: some JSONSchemaComponent<Self>`
        // that our extension's `outputJSONSchema` reads; without it, the
        // expanded extension would fail to compile with a confusing
        // "cannot find 'schema' in scope" error later.
        if !hasSchemableAttribute(structDecl.attributes) {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StructuredOutputMacroDiagnostic.error(
                    "@StructuredOutput requires @Schemable. Add '@Schemable' to '\(structDecl.name.text)' so the schema can be generated.",
                ),
            ))
            return []
        }

        // Determine whether to synthesize `encode(to:)`.
        let userEncodeDecl = findUserEncodeToDecl(in: structDecl)
        let hasManualEncoding = hasManualEncodingAttribute(structDecl.attributes)

        if let userEncodeDecl, !hasManualEncoding {
            context.diagnose(Diagnostic(
                node: Syntax(userEncodeDecl.name),
                message: StructuredOutputMacroDiagnostic.error(
                    "@StructuredOutput synthesizes 'encode(to:)' to guarantee a stable wire shape (every optional emits as 'null'). Remove this custom 'encode(to:)' and let the macro synthesize one, or mark the struct '@ManualEncoding' to opt out and take responsibility for stable-shape correctness.",
                ),
            ))
            return []
        }

        // If the user opted out of synthesis, we still add the conformance via
        // the ExtensionMacro path but generate no members here.
        if hasManualEncoding {
            // `@ManualEncoding` means "I'm hand-rolling the encoder."
            // Without a user `encode(to:)` in the struct body, the compiler
            // falls back to the default Codable synthesis, which uses
            // `encodeIfPresent` for optionals and therefore *omits* nil
            // fields — the opposite of @StructuredOutput's stable-shape
            // contract (every optional emits as JSON `null`). Warn so the
            // author sees the mismatch instead of silently shipping a wire
            // shape that breaks code-mode clients.
            //
            // The warning is a false positive when the encoder lives in a
            // sibling extension (a common Swift pattern) — macros can't see
            // extensions, so we can't distinguish "encoder in extension"
            // from "no encoder at all." The message acknowledges this.
            if userEncodeDecl == nil {
                let anchor = manualEncodingAttribute(structDecl.attributes).map(Syntax.init) ?? Syntax(node)
                context.diagnose(Diagnostic(
                    node: anchor,
                    message: StructuredOutputMacroDiagnostic.warning(
                        "@ManualEncoding opts out of @StructuredOutput's encoder synthesis, but no 'encode(to:)' was found in the struct body. If your encoder lives in an extension, ignore this warning — macros can't see extensions. Otherwise, the compiler falls back to Swift's default Codable synthesis (which omits nil optionals and breaks the stable-shape contract): add a hand-rolled 'encode(to:)' in the struct body, or remove '@ManualEncoding' to let the macro synthesize a stable encoder.",
                    ),
                ))
            }
            return []
        }

        // Gather stored properties (skip static and computed).
        let properties = storedInstanceProperties(in: structDecl)

        // If the user provided a `CodingKeys` enum, verify it covers every
        // stored property. Missing cases would otherwise surface as a
        // confusing "cannot find '.X' in CodingKeys" error in the generated
        // `encode(to:)` — which points the user at macro-generated code
        // rather than their own enum.
        if let codingKeysEnum = findUserCodingKeysDecl(in: structDecl) {
            let cases = codingKeyCaseNames(in: codingKeysEnum)
            let missing = properties.filter { !cases.contains($0) }
            if !missing.isEmpty {
                let missingList = missing.map { "'\($0)'" }.joined(separator: ", ")
                let propertyWord = missing.count == 1 ? "property" : "properties"
                let caseClause = "case \(missing.joined(separator: ", "))"
                context.diagnose(Diagnostic(
                    node: Syntax(codingKeysEnum.name),
                    message: StructuredOutputMacroDiagnostic.error(
                        "CodingKeys is missing case(s) for stored \(propertyWord) \(missingList). Add `\(caseClause)` to CodingKeys, or mark the struct '@ManualEncoding' if you intentionally want to exclude properties from the wire shape.",
                    ),
                    fixIt: buildAddMissingCasesFixIt(codingKeysEnum: codingKeysEnum, missing: missing),
                ))
                return []
            }
        }

        let accessPrefix = accessLevelPrefix(of: structDecl.modifiers)

        // Empty structs: skip `encode(to:)` and `CodingKeys` synthesis.
        // An empty `CodingKeys` enum would have `case ` with no cases, which
        // is invalid Swift. Swift's default Codable synthesis produces `{}`
        // on the wire for empty structs, matching @StructuredOutput's stable-
        // shape contract vacuously (no optionals to preserve).
        if properties.isEmpty {
            return []
        }

        // Synthesize `encode(to:)` using CodingKeys for every property.
        // Using `container.encode(_:forKey:)` (not `encodeIfPresent`) for
        // optionals causes `nil` to encode as JSON `null`, which matches the
        // required-but-nullable schema shape.
        var encodeLines: [String] = []
        encodeLines.append("    var container = encoder.container(keyedBy: CodingKeys.self)")
        for prop in properties {
            encodeLines.append("    try container.encode(self.\(prop), forKey: .\(prop))")
        }
        let encodeBody = encodeLines.joined(separator: "\n")

        let encodeSource = """
        \(accessPrefix)func encode(to encoder: Encoder) throws {
        \(encodeBody)
        }
        """
        let encodeDecl = DeclSyntax(stringLiteral: encodeSource)

        var members: [DeclSyntax] = [encodeDecl]

        // Swift only auto-synthesizes `CodingKeys` when it also synthesizes
        // `encode(to:)`. Providing `encode(to:)` ourselves suppresses that
        // synthesis, so we generate a `CodingKeys` enum when the user didn't
        // provide one — mirroring the compiler's default (one case per stored
        // property, using the Swift property name as the raw value).
        //
        // If the user has their own `CodingKeys`, theirs takes precedence and
        // our encoder picks it up via name lookup; we emit nothing.
        if !hasUserCodingKeys(in: structDecl) {
            let caseList = properties.joined(separator: ", ")
            let codingKeysSource = """
            \(accessPrefix)enum CodingKeys: String, CodingKey {
                case \(caseList)
            }
            """
            members.append(DeclSyntax(stringLiteral: codingKeysSource))
        }

        return members
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }

        // Mirror the MemberMacro's generic-struct rejection. Diagnostics are
        // emitted there; here we just suppress the extension so the generic
        // error isn't compounded by a second "can't extend X with static
        // members referencing Self.schema" failure.
        if structDecl.genericParameterClause != nil {
            return []
        }

        // Mirror the MemberMacro's `@Schemable` check here so we don't add a
        // conformance extension that references `Self.schema` on a type that
        // doesn't have one.
        if !hasSchemableAttribute(structDecl.attributes) {
            return []
        }

        // `MCPCore.StructuredOutput` and `MCPCore.SchemableAdapter` are
        // fully qualified so the extension compiles whether consumers import
        // `MCPCore` directly or transitively via `MCP`.
        //
        // The synthesized `outputJSONSchema` carries the struct's own
        // access modifier so a `fileprivate` or `private` struct does not
        // emit a confusingly `public`-labeled member that Swift caps to
        // file-private effective access anyway. Matches the MemberMacro's
        // access-level propagation above.
        //
        // The schema is computed exactly once per type via a private
        // `static let`. Without caching, every `Self.outputJSONSchema`
        // access (tool listing, output validation, `MCPSchema.outputSchema`
        // dispatch) re-runs `valueDictionary(from:)` and the full
        // `promoteRequired` recursion. Swift's `static let` initializer
        // runs lazily and thread-safely.
        let accessPrefix = accessLevelPrefix(of: structDecl.modifiers)
        let extensionSource = """
        extension \(type.trimmedDescription): MCPCore.StructuredOutput, MCPCore.WrappableValue {
            \(accessPrefix)static var outputJSONSchema: MCPCore.Value {
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
        """

        guard let ext = DeclSyntax(stringLiteral: extensionSource).as(ExtensionDeclSyntax.self) else {
            return []
        }
        return [ext]
    }

    // MARK: - Helpers

    /// Names of instance stored properties, skipping static properties and
    /// computed properties (getter/setter accessor blocks).
    private static func storedInstanceProperties(in structDecl: StructDeclSyntax) -> [String] {
        var names: [String] = []
        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  !varDecl.modifiers.contains(where: { $0.name.text == "static" })
            else { continue }

            for binding in varDecl.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                // Skip computed properties (getter / setter accessors).
                // Property observers (willSet / didSet) still indicate a
                // stored property and remain encodable.
                if let accessorBlock = binding.accessorBlock {
                    switch accessorBlock.accessors {
                        case .getter:
                            continue
                        case let .accessors(accessors):
                            let isComputed = accessors.contains { accessor in
                                switch accessor.accessorSpecifier.text {
                                    case "willSet", "didSet":
                                        false
                                    default:
                                        true
                                }
                            }
                            if isComputed {
                                continue
                            }
                    }
                }
                names.append(identifier.identifier.text)
            }
        }
        return names
    }

    /// Returns a user-defined `encode(to:)` function declaration matching
    /// the `Encodable` witness shape, or nil if there isn't one. Matches on
    /// both the `to` argument label *and* the parameter type (`Encoder` or
    /// `any Encoder`). Helpers like `func encode(_ mode: Mode) -> String`
    /// (unlabeled) or `func encode(to format: OutputFormat) -> String`
    /// (labeled but wrong type) don't conflict with the synthesized
    /// `encode(to:)` and must not trip the diagnostic.
    ///
    /// Limitation: this scan only covers the struct's own `memberBlock`.
    /// An `encode(to:)` defined in a sibling extension is invisible here
    /// because SwiftSyntax macros only see the declaration they're
    /// attached to. Users with extension-based encoders should apply
    /// `@ManualEncoding` — the resulting "no encode(to:) found" warning
    /// acknowledges the extension case as a known false positive.
    private static func findUserEncodeToDecl(in structDecl: StructDeclSyntax) -> FunctionDeclSyntax? {
        for member in structDecl.memberBlock.members {
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
                  funcDecl.name.text == "encode",
                  !funcDecl.modifiers.contains(where: { $0.name.text == "static" })
            else { continue }

            let params = funcDecl.signature.parameterClause.parameters
            guard params.count == 1,
                  let param = params.first,
                  param.firstName.text == "to"
            else { continue }

            // Only the `Encodable.encode(to: Encoder)` witness should trip
            // the diagnostic. Syntactic match on the type name is sufficient
            // because `Encoder` is always referenced unqualified from stdlib.
            let typeText = param.type.trimmedDescription
            guard typeText == "Encoder" || typeText == "any Encoder" else { continue }

            return funcDecl
        }
        return nil
    }

    /// Returns true if the struct already declares a `CodingKeys` enum.
    /// A user-provided `CodingKeys` takes precedence over the macro's default.
    private static func hasUserCodingKeys(in structDecl: StructDeclSyntax) -> Bool {
        findUserCodingKeysDecl(in: structDecl) != nil
    }

    /// Returns the user-declared `CodingKeys` enum, or nil if the struct has none.
    private static func findUserCodingKeysDecl(in structDecl: StructDeclSyntax) -> EnumDeclSyntax? {
        for member in structDecl.memberBlock.members {
            guard let enumDecl = member.decl.as(EnumDeclSyntax.self),
                  enumDecl.name.text == "CodingKeys"
            else { continue }
            return enumDecl
        }
        return nil
    }

    /// Collects the case names (Swift identifier) declared inside a `CodingKeys`
    /// enum. Raw-value renames (e.g. `case foo = "bar"`) are captured by the
    /// Swift name `foo`, since that's what the synthesized `encode(to:)` looks
    /// up via `.foo`.
    private static func codingKeyCaseNames(in enumDecl: EnumDeclSyntax) -> Set<String> {
        var names: Set<String> = []
        for member in enumDecl.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                names.insert(element.name.text)
            }
        }
        return names
    }

    private static func hasSchemableAttribute(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard case let .attribute(attribute) = element else { return false }
            if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
                return identifier.name.text == "Schemable"
            }
            if let memberType = attribute.attributeName.as(MemberTypeSyntax.self) {
                return memberType.name.text == "Schemable"
            }
            return false
        }
    }

    private static func hasManualEncodingAttribute(_ attributes: AttributeListSyntax) -> Bool {
        manualEncodingAttribute(attributes) != nil
    }

    private static func manualEncodingAttribute(_ attributes: AttributeListSyntax) -> AttributeSyntax? {
        for element in attributes {
            guard case let .attribute(attribute) = element else { continue }
            if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self),
               identifier.name.text == "ManualEncoding"
            {
                return attribute
            }
            if let memberType = attribute.attributeName.as(MemberTypeSyntax.self),
               memberType.name.text == "ManualEncoding"
            {
                return attribute
            }
        }
        return nil
    }

    /// Returns the access-level modifier of the struct so the synthesized
    /// `encode(to:)` and `CodingKeys` match. Without this, a `fileprivate`
    /// or `private` struct would get synthesized members declared at the
    /// default (internal) level — which Swift caps to the enclosing type's
    /// access but is stylistically inconsistent and confusing when reading
    /// expanded source.
    private static func accessLevelPrefix(of modifiers: DeclModifierListSyntax) -> String {
        for modifier in modifiers {
            switch modifier.name.text {
                case "public", "package", "internal", "fileprivate", "private":
                    return "\(modifier.name.text) "
                default:
                    continue
            }
        }
        return ""
    }

    /// Builds a FixIt that adds `case <name>` entries for each missing
    /// property to the user's `CodingKeys` enum, inheriting indentation
    /// from the first existing case so the output matches the surrounding
    /// style.
    private static func buildAddMissingCasesFixIt(
        codingKeysEnum: EnumDeclSyntax,
        missing: [String],
    ) -> FixIt {
        let existingCases = codingKeysEnum.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
        let indentTrivia: Trivia = existingCases.first?.caseKeyword.leadingTrivia
            ?? Trivia(pieces: [.newlines(1), .spaces(4)])

        let newItems = missing.map { propName -> MemberBlockItemSyntax in
            let caseDecl = EnumCaseDeclSyntax(
                leadingTrivia: indentTrivia,
                elements: EnumCaseElementListSyntax([
                    EnumCaseElementSyntax(name: .identifier(propName)),
                ]),
            )
            return MemberBlockItemSyntax(decl: caseDecl)
        }

        let updatedMembers = codingKeysEnum.memberBlock.members + newItems
        let newMemberBlock = codingKeysEnum.memberBlock.with(\.members, updatedMembers)
        let newEnum = codingKeysEnum.with(\.memberBlock, newMemberBlock)

        return FixIt(
            message: AddMissingCodingKeysFixIt(missing: missing),
            changes: [
                .replace(
                    oldNode: Syntax(codingKeysEnum),
                    newNode: Syntax(newEnum),
                ),
            ],
        )
    }
}

struct AddMissingCodingKeysFixIt: FixItMessage {
    let missing: [String]
    var message: String {
        let joined = missing.map { "'\($0)'" }.joined(separator: ", ")
        return missing.count == 1
            ? "Add case \(joined) to CodingKeys"
            : "Add cases \(joined) to CodingKeys"
    }

    var fixItID: MessageID {
        MessageID(domain: "StructuredOutputMacro", id: "add-missing-coding-keys")
    }
}

// MARK: - Diagnostics

struct StructuredOutputMacroDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    static func error(_ message: String) -> StructuredOutputMacroDiagnostic {
        StructuredOutputMacroDiagnostic(
            message: message,
            diagnosticID: MessageID(domain: "StructuredOutputMacro", id: "error"),
            severity: .error,
        )
    }

    static func warning(_ message: String) -> StructuredOutputMacroDiagnostic {
        StructuredOutputMacroDiagnostic(
            message: message,
            diagnosticID: MessageID(domain: "StructuredOutputMacro", id: "warning"),
            severity: .warning,
        )
    }
}

// MARK: - @ManualEncoding marker

/// `@ManualEncoding` is a marker attribute that opts out of `@StructuredOutput`'s
/// `encode(to:)` synthesis. It generates no code — its presence is the signal
/// that the author is intentionally hand-rolling the encoder (e.g. to emit
/// an additive computed field alongside the declared properties) and takes
/// responsibility for stable-shape correctness. The hand-rolled encoder is
/// still validated against the schema `@Schemable` generates from the Swift
/// struct at `CallTool` time; changing a declared property's wire type (such
/// as Unix seconds for a `Date` field) fails validation, so change the Swift
/// type instead.
public struct ManualEncodingMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        []
    }
}
