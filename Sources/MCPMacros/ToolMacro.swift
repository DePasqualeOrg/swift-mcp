// Copyright © Anthony DePasquale

import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// The `@Tool` macro generates `ToolSpec` protocol conformance.
///
/// It inspects the struct to find:
/// - `static let name: String` — The tool name
/// - `static let description: String` — The tool description
/// - `static let annotations: [AnnotationOption]` (optional) — Tool behavior annotations
/// - `static let strictSchema: Bool` (optional) — Opt-in assertion that the tool's
///   schema is strict JSON Schema-compatible. Defaults to `false`. When set to `true`,
///   the generated `toolDefinition` accessor traps at first access (typically when the
///   tool is registered) if the schema is not strict-compatible. The MCP wire format
///   accepts any valid JSON Schema for tool inputs; this flag is purely a
///   declaration-site self-check for tools shared with hosts that enforce a stricter
///   subset.
/// - Properties with `@Parameter` attribute — Tool parameters
/// - `func perform()` or `func perform(context:)` — The execution method
///
/// It generates:
/// - `static var toolDefinition: Tool` — The tool definition with JSON Schema
/// - `static func parse(from:)` — Argument parsing
/// - `init()` — Empty initializer
/// - `_perform(context:)` — Bridges to the user's `perform()` or `perform(context:)` method
/// - `static let annotations: [AnnotationOption]` — Empty default (only if not declared on the struct)
public struct ToolMacro: MemberMacro, ExtensionMacro {
    // MARK: - MemberMacro

    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        // Ensure we're applied to a struct
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw ToolMacroError.notAStruct
        }

        // Determine access level from the struct declaration
        let accessLevel = structDecl.modifiers.first(where: {
            $0.name.text == "public" || $0.name.text == "package" || $0.name.text == "internal"
        })?.name.text
        let accessPrefix = accessLevel.map { "\($0) " } ?? ""

        // Extract tool metadata
        let toolInfo: ToolInfo
        do {
            toolInfo = try extractToolInfo(from: structDecl, context: context)
        } catch is AbortMacroExpansion {
            // Node-level diagnostic already emitted; skip member generation to
            // avoid a second error at the attribute.
            return []
        }

        // Generate members
        var members: [DeclSyntax] = []

        // Generate default annotations if the struct doesn't declare one
        if toolInfo.annotations.isEmpty {
            let hasAnnotationsProperty = structDecl.memberBlock.members.contains { member in
                guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                      varDecl.modifiers.contains(where: { $0.name.text == "static" })
                else { return false }
                return varDecl.bindings.contains { binding in
                    binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "annotations"
                }
            }
            if !hasAnnotationsProperty {
                members.append("""
                static let annotations: [AnnotationOption] = []
                """)
            }
        }

        // Generate init()
        members.append("""
        \(raw: accessPrefix)init() {}
        """)

        // Generate _perform(context:) bridging to the user's perform() or perform(context:).
        // For Void returns, run the handler, discard the empty tuple, and emit
        // the `VoidOutput` sentinel so the wire shape matches an `Optional<T>`
        // returning `nil`.
        let callExpression = toolInfo.hasContextParameter ? "perform(context: context)" : "perform()"
        let bridgeBody = toolInfo.returnsVoid
            ? "try await \(callExpression)\n    return MCPCore.VoidOutput()"
            : "try await \(callExpression)"
        members.append("""
        \(raw: accessPrefix)func _perform(context: HandlerContext) async throws -> \(raw: toolInfo.outputType) {
            \(raw: bridgeBody)
        }
        """)

        // Generate toolDefinition
        let toolDefinitionDecl = generateToolDefinition(
            toolInfo: toolInfo,
            accessPrefix: accessPrefix,
        )
        members.append(toolDefinitionDecl)

        // Generate parse(from:)
        let parseDecl = generateParseMethod(toolInfo: toolInfo, accessPrefix: accessPrefix)
        members.append(parseDecl)

        return members
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext,
    ) throws -> [ExtensionDeclSyntax] {
        // Validate before adding conformance
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            // Let member macro report the error
            return []
        }

        // Validation checks below must mirror those in `extractToolInfo`. If one side
        // rejects a tool but the other generates code for it, the user sees a cascade
        // of "type does not conform to ToolSpec" errors on top of the real problem.
        var hasName = false
        var hasDescription = false
        var toolName: String?
        var annotations: [String] = []
        var parameterInfos: [ParameterInfo] = []
        var performDecls: [FunctionDeclSyntax] = []

        for member in structDecl.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
               varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                // @Parameter on static properties is an error in `extractToolInfo`
                if hasParameterAttribute(varDecl) {
                    return []
                }
                for binding in varDecl.bindings {
                    if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                        let propName = identifier.identifier.text
                        // `hasName` / `hasDescription` must mirror `extractToolInfo`'s
                        // plain-string-literal requirement. Flipping them on for any
                        // initializer would let the extension add ToolSpec conformance
                        // when the member macro refuses to generate the required members,
                        // producing a secondary "does not conform" error.
                        if propName == "name",
                           let initializer = binding.initializer,
                           let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                           let content = plainLiteralStringContent(stringLiteral)
                        {
                            hasName = true
                            toolName = content
                        }
                        if propName == "description",
                           let initializer = binding.initializer,
                           let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                           plainLiteralStringContent(stringLiteral) != nil
                        {
                            hasDescription = true
                        }
                        if propName == "annotations",
                           let initializer = binding.initializer
                        {
                            // Mirror the MemberMacro's "annotations must be an array literal"
                            // check — bail silently so the MemberMacro is the sole source of
                            // the node-level diagnostic.
                            guard initializer.value.is(ArrayExprSyntax.self) else {
                                return []
                            }
                            annotations = extractAnnotationNames(from: initializer.value)
                        }
                        // Mirror the MemberMacro's "strictSchema must be a boolean literal" check.
                        if propName == "strictSchema",
                           let initializer = binding.initializer,
                           !initializer.value.is(BooleanLiteralExprSyntax.self)
                        {
                            return []
                        }
                    }
                }
            }

            // Check for @Parameter properties with non-literal defaults
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
               !varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                if hasParameterAttribute(varDecl) {
                    // Mirror the MemberMacro's "@Parameter key/title/description must be
                    // a single-segment string literal" check — bail silently so the
                    // MemberMacro is the sole source of the node-level diagnostic.
                    if hasNonLiteralParameterMetadata(varDecl) {
                        return []
                    }
                    // Mirror the MemberMacro's "@Parameter must be a mutable stored var"
                    // check.
                    if varDecl.bindingSpecifier.text != "var" {
                        return []
                    }
                    for binding in varDecl.bindings {
                        // Mirror the MemberMacro's "explicit type annotation required"
                        // check — bail silently so the MemberMacro is the sole source
                        // of the node-level diagnostic.
                        if binding.typeAnnotation == nil {
                            return []
                        }
                        // Mirror the MemberMacro's "no computed properties" check.
                        if hasNonStoredAccessorBlock(binding) {
                            return []
                        }
                        if let initializer = binding.initializer,
                           !isLiteralExpression(initializer.value)
                        {
                            // Non-literal default - don't add conformance
                            return []
                        }
                        // Catches only `ToolMacroError` (parameter-shape problems the
                        // MemberMacro will report). `AbortMacroExpansion` is re-thrown
                        // so an abort from upstream still cancels extension generation,
                        // and any other error propagates rather than being silently
                        // swallowed — a bare `try?` would hide both.
                        do {
                            if let info = try extractParameterInfo(from: varDecl, binding: binding, context: context) {
                                parameterInfos.append(info)
                            }
                        } catch is ToolMacroError {
                            // MemberMacro path will diagnose; skip this parameter and continue.
                        }
                    }
                }
            }

            // Capture perform methods (must mirror checks in extractToolInfo). We
            // collect all of them so the duplicate-overload check below can bail.
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "perform"
            {
                if funcDecl.modifiers.contains(where: { $0.name.text == "static" }) {
                    return []
                }
                performDecls.append(funcDecl)
            }
        }

        // Mirror the MemberMacro's "exactly one perform" check — bail silently so
        // the MemberMacro's diagnostic is the only one the user sees.
        if performDecls.count > 1 {
            return []
        }
        let performDecl = performDecls.first

        // Don't add conformance if basic validation fails
        guard hasName, hasDescription else {
            return []
        }

        // Validate tool name
        if let name = toolName, validateToolName(name) != nil {
            return []
        }

        // Check for duplicate annotations (uses same helper as MemberMacro so rules
        // can't drift between the two paths).
        if hasDuplicateAnnotations(annotations) {
            return []
        }

        // Reject if duplicate @Parameter keys would make the schema invalid
        if !duplicateParameterKeys(in: parameterInfos).isEmpty {
            return []
        }

        // Reject if perform() is missing — otherwise the extension would claim conformance
        // while the MemberMacro failed to generate `_perform`, producing a second error.
        guard let performDecl else {
            return []
        }

        // Reject if perform() signature is invalid. Uses the same validator as the
        // MemberMacro so the two paths can't drift.
        if case .invalid = validatePerformSignature(performDecl) {
            return []
        }

        // Add ToolSpec and Sendable conformance (fully qualified for compatibility with AI imports)
        let extensionDecl: DeclSyntax = """
        extension \(type): MCP.ToolSpec, Sendable {}
        """

        guard let ext = extensionDecl.as(ExtensionDeclSyntax.self) else {
            return []
        }

        return [ext]
    }

    // MARK: - Tool Info Extraction

    private struct ToolInfo {
        var name: String
        var description: String
        var parameters: [ParameterInfo]
        var outputType: String
        var annotations: [String] // Annotation case names for validation
        var strictSchema: Bool
        var hasContextParameter: Bool // Whether perform() takes a context parameter

        /// `true` when the user's `perform()` returns `Void` (or has no
        /// return clause). The synthesized `_perform(context:)` runs the
        /// user's handler, discards the empty tuple, and returns
        /// `VoidOutput()` so the wire shape matches `Optional<T>` returning
        /// `nil`. Derived from `outputType` so the two can't drift.
        var returnsVoid: Bool {
            outputType == voidOutputType
        }
    }

    /// Sentinel `outputType` string that stands in for `Void` returns.
    /// Also the target of the macro's `return MCPCore.VoidOutput()` bridge.
    private static let voidOutputType = "MCPCore.VoidOutput"

    private static func extractToolInfo(
        from structDecl: StructDeclSyntax,
        context: some MacroExpansionContext,
    ) throws -> ToolInfo {
        var name: String?
        var nameSyntax: SyntaxProtocol?
        var description: String?
        var parameters: [ParameterInfo] = []
        // Default when `perform()` has no return clause: treat as Void.
        var outputType = voidOutputType
        var annotations: [String] = []
        var annotationsSyntax: SyntaxProtocol?
        var strictSchema = false
        var hasContextParameter = false
        var performDecls: [FunctionDeclSyntax] = []

        for member in structDecl.memberBlock.members {
            let decl = member.decl

            // Look for static let name/description/annotations
            if let varDecl = decl.as(VariableDeclSyntax.self),
               varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                // Reject @Parameter on static properties
                if hasParameterAttribute(varDecl) {
                    let propName = varDecl.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? "?"
                    try diagnoseAndAbort(
                        message: "@Parameter cannot be applied to static property '\(propName)'. Tool parameters must be instance properties.",
                        node: varDecl,
                        in: context,
                    )
                }

                for binding in varDecl.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                        continue
                    }

                    let propertyName = identifier.identifier.text

                    if propertyName == "name", let initializer = binding.initializer {
                        name = try requireStaticStringLiteralProperty(
                            initializerValue: initializer.value,
                            propertyName: "name",
                            context: context,
                        )
                        nameSyntax = initializer.value
                    }

                    if propertyName == "description", let initializer = binding.initializer {
                        description = try requireStaticStringLiteralProperty(
                            initializerValue: initializer.value,
                            propertyName: "description",
                            context: context,
                        )
                    }

                    // Extract annotations for validation. The macro's duplicate-detection
                    // pass needs the literal array form to inspect each element. A
                    // non-array initializer (e.g. `static let annotations = 1`) used to
                    // silently bypass the duplicate check and only fail later as a
                    // type-mismatch error in the generated code that references
                    // `Self.annotations: [AnnotationOption]`.
                    if propertyName == "annotations",
                       let initializer = binding.initializer
                    {
                        guard initializer.value.is(ArrayExprSyntax.self) else {
                            try diagnoseAndAbort(
                                message: "@Tool 'annotations' must be an array literal of AnnotationOption values.",
                                node: initializer.value,
                                in: context,
                            )
                        }
                        annotationsSyntax = initializer.value
                        annotations = extractAnnotationNames(from: initializer.value)
                    }

                    // Extract strictSchema flag
                    if propertyName == "strictSchema", let initializer = binding.initializer {
                        strictSchema = try requireStaticBooleanLiteralProperty(
                            initializerValue: initializer.value,
                            propertyName: "strictSchema",
                            context: context,
                        )
                    }
                }
            }

            // Look for @Parameter properties
            if let varDecl = decl.as(VariableDeclSyntax.self),
               !varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                if hasParameterAttribute(varDecl) {
                    for binding in varDecl.bindings {
                        if let paramInfo = try extractParameterInfo(from: varDecl, binding: binding, context: context) {
                            parameters.append(paramInfo)
                        }
                    }
                }
            }

            // Collect all `perform` declarations. We pick after the loop so we can
            // explicitly diagnose multiple overloads instead of silently letting the
            // last declaration win, which would make the generated bridge depend on
            // source order.
            if let funcDecl = decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "perform"
            {
                if funcDecl.modifiers.contains(where: { $0.name.text == "static" }) {
                    try diagnoseAndAbort(
                        message: "@Tool requires 'perform()' to be an instance method, not static.",
                        node: funcDecl.name,
                        in: context,
                    )
                }
                performDecls.append(funcDecl)
            }
        }

        guard let toolName = name else {
            throw ToolMacroError.missingName
        }

        guard let toolDescription = description else {
            throw ToolMacroError.missingDescription
        }

        // Reject multiple `perform` declarations explicitly. Helper methods that
        // happen to share the name (e.g. `perform(verbose:)`) need to be renamed
        // — the macro picks one to bridge into `_perform(context:)` and would
        // otherwise pick whichever appears last in source order.
        if performDecls.count > 1 {
            try diagnoseAndAbort(
                message: "@Tool requires exactly one 'perform' method, but found \(performDecls.count). Rename helper methods to avoid the 'perform' name.",
                node: performDecls[1].name,
                in: context,
            )
        }

        guard let performDecl = performDecls.first else {
            throw ToolMacroError.missingPerformMethod
        }

        if let returnClause = performDecl.signature.returnClause {
            let declaredType = returnClause.type.trimmedDescription
            // Normalize explicit `Void` / `()` to the `VoidOutput` sentinel
            // so the schema dispatch and `_perform` wrapping paths don't
            // need a second Void-detection branch.
            //
            // Limitation: this is a syntactic string match. Type aliases
            // for `Void` (e.g. `typealias Nothing = Void` declared
            // elsewhere and used as `-> Nothing`) aren't detected — macros
            // can't resolve types at expansion time. A tool author who
            // does this sees `outputSchema = nil` on the wire; the
            // workaround is to drop the return clause entirely or use
            // `-> Void` directly.
            if declaredType == "Void" || declaredType == "()" || declaredType == "Swift.Void" {
                outputType = voidOutputType
            } else {
                outputType = declaredType
            }
        }

        // Validate perform() signature using the shared validator so MemberMacro and
        // ExtensionMacro can never disagree on what's accepted.
        switch validatePerformSignature(performDecl) {
            case let .invalid(message, blameNode):
                try diagnoseAndAbort(message: message, node: blameNode, in: context)
            case let .valid(hasContext):
                hasContextParameter = hasContext
        }

        // Warn if perform() has an explicit access modifier more restrictive than the struct.
        // Only flag explicit modifiers; an unmarked `perform()` is the canonical case this
        // macro is designed for, so it must not produce a diagnostic.
        let structAccess = accessLevelRank(of: structDecl.modifiers)
        if let performAccess = explicitAccessLevelRank(of: performDecl.modifiers),
           performAccess < structAccess
        {
            context.diagnose(Diagnostic(
                node: Syntax(performDecl),
                message: ToolMacroDiagnostic.warning(
                    "'perform()' has more restrictive access (\(accessLevelName(performAccess))) than the enclosing struct (\(accessLevelName(structAccess))). If the return type is similarly restricted, the generated '_perform(context:)' bridge will fail to compile.",
                ),
            ))
        }

        // Validate tool name
        if let validationError = validateToolName(toolName) {
            throw ToolMacroError.invalidToolName(validationError)
        }

        // Reject duplicate @Parameter keys (silent overwrite in the schema otherwise).
        // Emit one diagnostic per offending property so the user can locate each one.
        let duplicates = Set(duplicateParameterKeys(in: parameters))
        if !duplicates.isEmpty {
            for param in parameters where duplicates.contains(param.jsonKey) {
                let node: any SyntaxProtocol = param.declSyntax ?? structDecl.name
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ToolMacroDiagnostic.error(
                        "Duplicate @Parameter key '\(param.jsonKey)'. Each @Parameter key must be unique.",
                    ),
                ))
            }
            throw AbortMacroExpansion()
        }

        // Warn about tool name style issues
        if let styleWarning = toolNameStyleWarning(toolName),
           let syntax = nameSyntax
        {
            context.diagnose(Diagnostic(
                node: Syntax(syntax),
                message: ToolMacroDiagnostic.warning(styleWarning),
            ))
        }

        // Validate annotations
        try validateAnnotations(annotations, syntax: annotationsSyntax, context: context)

        return ToolInfo(
            name: toolName,
            description: toolDescription,
            parameters: parameters,
            outputType: outputType,
            annotations: annotations,
            strictSchema: strictSchema,
            hasContextParameter: hasContextParameter,
        )
    }

    /// Extracts annotation case names from an array literal expression.
    ///
    /// Only the case name is returned (e.g. `.title("Foo")` → `"title"`). This is used
    /// solely for duplicate/redundancy detection at compile time; the runtime still
    /// receives the full annotations array and extracts values via
    /// `AnnotationOption.buildAnnotations(from:)`.
    ///
    /// Matches both leading-dot shorthand (`.readOnly`, `.title("Foo")`) and explicit
    /// qualification (`AnnotationOption.readOnly`). Unrecognized shapes are skipped.
    private static func extractAnnotationNames(from expr: ExprSyntax) -> [String] {
        guard let arrayExpr = expr.as(ArrayExprSyntax.self) else {
            return []
        }

        var names: [String] = []
        for element in arrayExpr.elements {
            var target = element.expression
            // `.title("Foo")` is a FunctionCallExpr whose callee is a MemberAccessExpr;
            // unwrap the call first so we inspect the case name rather than the call.
            if let call = target.as(FunctionCallExprSyntax.self) {
                target = call.calledExpression
            }
            if let member = target.as(MemberAccessExprSyntax.self) {
                names.append(member.declName.baseName.text)
            }
        }
        return names
    }

    /// Returns `true` if any annotation name appears more than once. Shared between
    /// the MemberMacro (which turns this into a `duplicateAnnotation` error) and the
    /// ExtensionMacro (which silently bails), so the two paths stay in lockstep.
    static func hasDuplicateAnnotations(_ annotations: [String]) -> Bool {
        Set(annotations).count != annotations.count
    }

    /// Returns the first duplicated annotation name, or nil if none duplicate.
    private static func firstDuplicateAnnotation(_ annotations: [String]) -> String? {
        var seen: Set<String> = []
        for annotation in annotations {
            if !seen.insert(annotation).inserted {
                return annotation
            }
        }
        return nil
    }

    /// Validates annotation array for duplicates and redundant combinations.
    private static func validateAnnotations(
        _ annotations: [String],
        syntax: SyntaxProtocol?,
        context: some MacroExpansionContext,
    ) throws {
        if let duplicate = firstDuplicateAnnotation(annotations) {
            throw ToolMacroError.duplicateAnnotation(duplicate)
        }

        // Warn about redundant combinations
        if annotations.contains("readOnly"), annotations.contains("idempotent") {
            if let syntax {
                context.diagnose(Diagnostic(
                    node: Syntax(syntax),
                    message: ToolMacroDiagnostic.warning(
                        "'.idempotent' is redundant when '.readOnly' is specified (readOnly implies idempotent)",
                    ),
                ))
            }
        }
    }

    // MARK: - Code Generation

    private static func generateToolDefinition(
        toolInfo: ToolInfo,
        accessPrefix: String,
    ) -> DeclSyntax {
        let descriptorEntries = toolInfo.parameters.map { param in
            let defaultValueLiteral = if let defaultExpr = param.defaultValueExpr {
                convertToValueLiteral(defaultExpr)
            } else {
                "nil"
            }
            let titleLiteral = swiftStringLiteral(param.title)
            let descriptionLiteral = swiftStringLiteral(param.description)
            let minLengthLiteral = param.minLength ?? "nil"
            let maxLengthLiteral = param.maxLength ?? "nil"
            let minimumLiteral = param.minimum ?? "nil"
            let maximumLiteral = param.maximum ?? "nil"

            return """
            MCPTool.ToolMacroSupport.makeSchemaParameterDescriptor(
                name: "\(param.jsonKey)",
                title: \(titleLiteral),
                description: \(descriptionLiteral),
                schema: \(param.typeName).schema,
                isOptional: \(param.isOptional),
                hasDefault: \(param.hasDefault),
                defaultValue: \(defaultValueLiteral),
                minLength: \(minLengthLiteral),
                maxLength: \(maxLengthLiteral),
                minimum: \(minimumLiteral),
                maximum: \(maximumLiteral)
            )
            """
        }.joined(separator: ",\n                ")

        let descriptorsLiteral = descriptorEntries.isEmpty ? "[]" : "[\n                \(descriptorEntries)\n            ]"

        let strictValidationStmt = toolInfo.strictSchema
            ? """
            do {
                    try MCPTool.ToolMacroSupport.validateStrictCompatibility(_schema, toolName: name)
                } catch {
                    preconditionFailure("Strict schema validation failed for tool '\\(name)': \\(error)")
                }

            """
            : ""
        return """
        \(raw: accessPrefix)static var toolDefinition: MCP.Tool {
            // Schema-build failures here (e.g. duplicate parameter names) are programmer
            // errors that must trap at registration rather than silently shipping an empty
            // schema to clients. We trap with a tool-named precondition for a readable
            // crash log instead of a bare `try!` trap.
            let _schema: [String: MCP.Value]
            do {
                _schema = try MCPTool.ToolMacroSupport.buildObjectSchema(
                    parameters: \(raw: descriptorsLiteral)
                )
            } catch {
                preconditionFailure("Failed to build schema for tool '\\(name)': \\(error)")
            }
            \(raw: strictValidationStmt)return MCP.Tool(
                name: name,
                description: description,
                inputSchema: .object(_schema),
                outputSchema: MCP.MCPSchema.outputSchema(for: Output.self),
                annotations: AnnotationOption.buildAnnotations(from: annotations)
            )
        }
        """
    }

    private static func generateParseMethod(toolInfo: ToolInfo, accessPrefix: String) -> DeclSyntax {
        // For tools with no parameters, generate a simple parse method
        if toolInfo.parameters.isEmpty {
            return """
            \(raw: accessPrefix)static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
                Self()
            }
            """
        }

        var parseStatements: [String] = []

        for param in toolInfo.parameters {
            let key = param.jsonKey
            let prop = param.propertyName
            let type = param.typeName

            if param.isOptional {
                // Optional: parse only if present and non-null; leave as nil otherwise.
                parseStatements.append(
                    "if let _value = _args[\"\(key)\"], !_value.isNull { _instance.\(prop) = try MCPTool.ToolMacroSupport.parseParameter(\(type).schema, from: _value, parameterName: \"\(key)\") }",
                )
            } else if param.hasDefault {
                // Has default: only parse if key is present and non-null; otherwise keep the struct's default.
                parseStatements.append(
                    "if let _value = _args[\"\(key)\"], !_value.isNull { _instance.\(prop) = try MCPTool.ToolMacroSupport.parseParameter(\(type).schema, from: _value, parameterName: \"\(key)\") }",
                )
            } else {
                // Required: must be present; parse throws with detail if the value shape is wrong.
                parseStatements.append(
                    "guard let _\(prop)Value = _args[\"\(key)\"] else { throw MCPError.invalidParams(\"Missing required parameter '\(key)'\") }",
                )
                parseStatements.append(
                    "_instance.\(prop) = try MCPTool.ToolMacroSupport.parseParameter(\(type).schema, from: _\(prop)Value, parameterName: \"\(key)\")",
                )
            }
        }

        let statements = parseStatements.joined(separator: "\n    ")

        return """
        \(raw: accessPrefix)static func parse(from arguments: [String: MCP.Value]?) throws -> Self {
            var _instance = Self()
            let _args = arguments ?? [:]
            \(raw: statements)
            return _instance
        }
        """
    }

    /// Converts a literal ExprSyntax default value into the matching `MCP.Value` case.
    ///
    /// Dispatch is by the literal node's syntax type, not by scanning its string form —
    /// a parameter like `var version: Version = "1.0"` (`ExpressibleByStringLiteral`) is
    /// a string literal in the source and must stay a `.string`, even though the text
    /// happens to parse as a double.
    private static func convertToValueLiteral(_ expr: ExprSyntax) -> String {
        if expr.is(NilLiteralExprSyntax.self) {
            return ".null"
        }
        if expr.is(BooleanLiteralExprSyntax.self) {
            return ".bool(\(expr.trimmedDescription))"
        }
        if expr.is(IntegerLiteralExprSyntax.self) {
            return ".int(\(expr.trimmedDescription))"
        }
        if expr.is(FloatLiteralExprSyntax.self) {
            return ".double(\(expr.trimmedDescription))"
        }
        if expr.is(StringLiteralExprSyntax.self) {
            // Preserve the literal verbatim — it's already a well-formed Swift string literal.
            return ".string(\(expr.trimmedDescription))"
        }
        // Negative numeric literals: `PrefixOperatorExpr('-')` wrapping an IntegerLit/FloatLit.
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            if prefix.expression.is(IntegerLiteralExprSyntax.self) {
                return ".int(\(expr.trimmedDescription))"
            }
            if prefix.expression.is(FloatLiteralExprSyntax.self) {
                return ".double(\(expr.trimmedDescription))"
            }
        }
        // Contract: `isLiteralExpression` gates every call to this function, so the two
        // must accept exactly the same set of syntax kinds. Trapping here means a drift
        // between the two surfaces as a plugin crash at compile time (with this message
        // in stderr), not as a silent `.null` default that corrupts the generated schema.
        preconditionFailure("convertToValueLiteral: unmapped literal kind \(expr.syntaxNodeType); add a case here or update isLiteralExpression")
    }
}

// MARK: - Errors

enum ToolMacroError: Error, CustomStringConvertible {
    case notAStruct
    case missingName
    case missingDescription
    case missingPerformMethod
    case invalidToolName(String)
    case nonLiteralDefaultValue(String)
    case duplicateAnnotation(String)

    var description: String {
        switch self {
            case .notAStruct:
                "@Tool can only be applied to structs"
            case .missingName:
                "@Tool requires 'static let name: String' property"
            case .missingDescription:
                "@Tool requires 'static let description: String' property"
            case .missingPerformMethod:
                "@Tool requires a 'perform' method (e.g., 'func perform() async throws -> String')"
            case let .invalidToolName(reason):
                "Invalid tool name: \(reason)"
            case let .nonLiteralDefaultValue(param):
                "Parameter '\(param)' has a non-literal default value. Only literal values (numbers, strings, booleans) are supported. For complex defaults, make the parameter optional and handle the default in perform()."
            case let .duplicateAnnotation(annotation):
                "Duplicate annotation: \(annotation)"
        }
    }
}

// MARK: - Repo-specific knob for shared helpers

extension ToolMacro {
    /// Module name to recognize in qualified `@<Module>.Parameter` attributes.
    /// Read by `isParameterAttribute` in `ToolMacroSharedHelpers.swift`.
    static let parameterAttributeModuleName = "MCP"
}

// MARK: - Perform Signature Validation

extension ToolMacro {
    /// Outcome of validating a `perform(...)` declaration. The MemberMacro turns
    /// `.invalid` into a node-level diagnostic; the ExtensionMacro silently bails so
    /// the user only sees the MemberMacro's diagnostic, not a duplicate cascade.
    enum PerformValidation {
        case valid(hasContext: Bool)
        case invalid(message: String, blameNode: any SyntaxProtocol)
    }

    /// Validates the signature of a `perform(...)` method. Both expansion paths share
    /// this so the rules can never drift between them.
    static func validatePerformSignature(_ decl: FunctionDeclSyntax) -> PerformValidation {
        let params = decl.signature.parameterClause.parameters
        let extraParams = params.filter { $0.firstName.text != "context" }
        let contextParams = Array(params.filter { $0.firstName.text == "context" })
        if !extraParams.isEmpty {
            return .invalid(
                message: "@Tool requires 'perform()' to take no arguments besides an optional 'context: HandlerContext'. Use '@Parameter' properties on the struct to declare inputs.",
                blameNode: decl.signature.parameterClause,
            )
        }
        // Swift allows duplicate parameter labels at declaration time, so without
        // this check a signature like `perform(context:, context:)` passes macro
        // validation and the generated `_perform(context:)` bridge fails later
        // with a misleading "missing argument" error instead of a targeted diagnostic.
        if contextParams.count > 1 {
            return .invalid(
                message: "@Tool allows at most one 'context' parameter on 'perform()'.",
                blameNode: contextParams[1],
            )
        }
        if let contextParam = contextParams.first {
            let typeName = contextParam.type.trimmedDescription
            if typeName != "HandlerContext", typeName != "MCP.HandlerContext" {
                return .invalid(
                    message: "The 'context' parameter of 'perform()' must be of type 'HandlerContext' (or 'MCP.HandlerContext'); got '\(typeName)'.",
                    blameNode: contextParam.type,
                )
            }
        }
        if decl.signature.effectSpecifiers?.asyncSpecifier == nil {
            return .invalid(
                message: "@Tool requires 'perform()' to be marked 'async'",
                blameNode: decl.name,
            )
        }
        if decl.signature.effectSpecifiers?.throwsClause == nil {
            return .invalid(
                message: "@Tool requires 'perform()' to be marked 'throws'",
                blameNode: decl.name,
            )
        }
        // `perform()` with no return clause is treated as Void — the macro
        // substitutes `VoidOutput` at `outputType` derivation and the
        // synthesized `_perform` bridge discards `()` and returns
        // `VoidOutput()`. Declaring `-> Void` / `-> ()` explicitly is also
        // accepted and normalized the same way.
        return .valid(hasContext: !contextParams.isEmpty)
    }
}
