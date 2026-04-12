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
/// - `static let strictSchema: Bool` (optional) — Strict JSON Schema flag (defaults to `false`)
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
        in context: some MacroExpansionContext
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

        // Generate _perform(context:) bridging to the user's perform() or perform(context:)
        if toolInfo.hasContextParameter {
            members.append("""
            \(raw: accessPrefix)func _perform(context: HandlerContext) async throws -> \(raw: toolInfo.outputType) {
                try await perform(context: context)
            }
            """)
        } else {
            members.append("""
            \(raw: accessPrefix)func _perform(context: HandlerContext) async throws -> \(raw: toolInfo.outputType) {
                try await perform()
            }
            """)
        }

        // Generate toolDefinition
        let toolDefinitionDecl = generateToolDefinition(
            toolInfo: toolInfo,
            accessPrefix: accessPrefix
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
        in context: some MacroExpansionContext
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
        var performDecl: FunctionDeclSyntax?

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
                        if propName == "name" {
                            hasName = true
                            // Extract name value for validation
                            if let initializer = binding.initializer,
                               let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                toolName = segment.content.text
                            }
                        }
                        if propName == "description" { hasDescription = true }
                        if propName == "annotations",
                           let initializer = binding.initializer
                        {
                            annotations = extractAnnotationNames(from: initializer.value)
                        }
                    }
                }
            }

            // Check for @Parameter properties with non-literal defaults
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
               !varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                if hasParameterAttribute(varDecl) {
                    for binding in varDecl.bindings {
                        if let initializer = binding.initializer,
                           !isLiteralExpression(initializer.value)
                        {
                            // Non-literal default - don't add conformance
                            return []
                        }
                        if let info = try? extractParameterInfo(from: varDecl, binding: binding, context: context) {
                            parameterInfos.append(info)
                        }
                    }
                }
            }

            // Capture perform method (must mirror static/signature checks in extractToolInfo)
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "perform"
            {
                if funcDecl.modifiers.contains(where: { $0.name.text == "static" }) {
                    return []
                }
                performDecl = funcDecl
            }
        }

        // Don't add conformance if basic validation fails
        guard hasName, hasDescription else {
            return []
        }

        // Validate tool name
        if let name = toolName, validateToolName(name) != nil {
            return []
        }

        // Check for duplicate annotations
        var seen: Set<String> = []
        for annotation in annotations {
            if seen.contains(annotation) {
                return []
            }
            seen.insert(annotation)
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

        // Reject if perform() signature is invalid (async, throws, return, params, context type)
        let params = performDecl.signature.parameterClause.parameters
        let extraParams = params.filter { $0.firstName.text != "context" }
        let contextParams = params.filter { $0.firstName.text == "context" }
        let hasAsync = performDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let hasThrows = performDecl.signature.effectSpecifiers?.throwsClause != nil
        let hasReturn = performDecl.signature.returnClause != nil
        if !extraParams.isEmpty || !hasAsync || !hasThrows || !hasReturn {
            return []
        }
        if let contextParam = contextParams.first {
            let typeName = contextParam.type.trimmedDescription
            if typeName != "HandlerContext", typeName != "MCP.HandlerContext" {
                return []
            }
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

    /// Emits a node-level error diagnostic and throws `AbortMacroExpansion` so the
    /// outer expansion returns empty results without producing a second attribute-level error.
    private static func diagnoseAndAbort(
        message: String,
        node: some SyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> Never {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ToolMacroDiagnostic.error(message)
        ))
        throw AbortMacroExpansion()
    }

    private struct ToolInfo {
        var name: String
        var description: String
        var parameters: [ParameterInfo]
        var outputType: String
        var annotations: [String] // Annotation case names for validation
        var strictSchema: Bool
        var hasContextParameter: Bool // Whether perform() takes a context parameter
    }

    private struct ParameterInfo {
        var propertyName: String
        var jsonKey: String
        var typeName: String
        var isOptional: Bool
        var hasDefault: Bool
        var defaultValue: String?
        var title: String?
        var description: String?
        var minLength: String?
        var maxLength: String?
        var minimum: String?
        var maximum: String?
        var declSyntax: VariableDeclSyntax? // For pointing diagnostics at the offending @Parameter
    }

    private static func extractToolInfo(
        from structDecl: StructDeclSyntax,
        context: some MacroExpansionContext
    ) throws -> ToolInfo {
        var name: String?
        var nameSyntax: SyntaxProtocol?
        var description: String?
        var parameters: [ParameterInfo] = []
        var outputType = "String"
        var annotations: [String] = []
        var annotationsSyntax: SyntaxProtocol?
        var strictSchema = false
        var hasContextParameter = false
        var performDecl: FunctionDeclSyntax?

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
                        in: context
                    )
                }

                for binding in varDecl.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                        continue
                    }

                    let propertyName = identifier.identifier.text

                    if propertyName == "name",
                       let initializer = binding.initializer,
                       let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                    {
                        name = segment.content.text
                        nameSyntax = stringLiteral
                    }

                    if propertyName == "description",
                       let initializer = binding.initializer,
                       let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                    {
                        description = segment.content.text
                    }

                    // Extract annotations for validation
                    if propertyName == "annotations",
                       let initializer = binding.initializer
                    {
                        annotationsSyntax = initializer.value
                        annotations = extractAnnotationNames(from: initializer.value)
                    }

                    // Extract strictSchema flag
                    if propertyName == "strictSchema",
                       let initializer = binding.initializer,
                       let boolLiteral = initializer.value.as(BooleanLiteralExprSyntax.self)
                    {
                        strictSchema = boolLiteral.literal.text == "true"
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

            // Look for perform method to get output type and check for context parameter
            if let funcDecl = decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "perform"
            {
                if funcDecl.modifiers.contains(where: { $0.name.text == "static" }) {
                    try diagnoseAndAbort(
                        message: "@Tool requires 'perform()' to be an instance method, not static.",
                        node: funcDecl.name,
                        in: context
                    )
                }
                performDecl = funcDecl
                if let returnClause = funcDecl.signature.returnClause {
                    outputType = returnClause.type.trimmedDescription
                }
            }
        }

        guard let toolName = name else {
            throw ToolMacroError.missingName
        }

        guard let toolDescription = description else {
            throw ToolMacroError.missingDescription
        }

        guard let performDecl else {
            throw ToolMacroError.missingPerformMethod
        }

        // Validate perform() signature. Allow an optional parameter with the canonical
        // label `context: HandlerContext` — any other parameter is rejected.
        // Only the labeled form is accepted: the generated bridge calls
        // `try await perform(context: context)`, which requires `firstName == "context"`.
        // Forms like `_ context:` or `ctx context:` would not compile through the bridge.
        let performParams = performDecl.signature.parameterClause.parameters
        let contextParams = performParams.filter { $0.firstName.text == "context" }
        let extraParams = performParams.filter { $0.firstName.text != "context" }
        if !extraParams.isEmpty {
            try diagnoseAndAbort(
                message: "@Tool requires 'perform()' to take no arguments besides an optional 'context: HandlerContext'. Use '@Parameter' properties on the struct to declare inputs.",
                node: performDecl.signature.parameterClause,
                in: context
            )
        }
        if let contextParam = contextParams.first {
            let typeName = contextParam.type.trimmedDescription
            if typeName != "HandlerContext", typeName != "MCP.HandlerContext" {
                try diagnoseAndAbort(
                    message: "The 'context' parameter of 'perform()' must be of type 'HandlerContext' (or 'MCP.HandlerContext'); got '\(typeName)'.",
                    node: contextParam.type,
                    in: context
                )
            }
        }
        hasContextParameter = !contextParams.isEmpty

        if performDecl.signature.effectSpecifiers?.asyncSpecifier == nil {
            try diagnoseAndAbort(
                message: "@Tool requires 'perform()' to be marked 'async'",
                node: performDecl.name,
                in: context
            )
        }
        if performDecl.signature.effectSpecifiers?.throwsClause == nil {
            try diagnoseAndAbort(
                message: "@Tool requires 'perform()' to be marked 'throws'",
                node: performDecl.name,
                in: context
            )
        }
        if performDecl.signature.returnClause == nil {
            try diagnoseAndAbort(
                message: "@Tool requires 'perform()' to return a value conforming to 'ToolOutput'",
                node: performDecl.name,
                in: context
            )
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
                    "'perform()' has more restrictive access (\(accessLevelName(performAccess))) than the enclosing struct (\(accessLevelName(structAccess))). If the return type is similarly restricted, the generated '_perform()' bridge will fail to compile."
                )
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
                        "Duplicate @Parameter key '\(param.jsonKey)'. Each @Parameter key must be unique."
                    )
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
                message: ToolMacroDiagnostic.warning(styleWarning)
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
            hasContextParameter: hasContextParameter
        )
    }

    /// Extracts annotation case names from an array literal expression.
    private static func extractAnnotationNames(from expr: ExprSyntax) -> [String] {
        guard let arrayExpr = expr.as(ArrayExprSyntax.self) else {
            return []
        }

        var names: [String] = []
        for element in arrayExpr.elements {
            let exprStr = element.expression.trimmedDescription
            // Extract case name: ".readOnly" -> "readOnly", ".title(...)" -> "title"
            if exprStr.hasPrefix(".") {
                let withoutDot = String(exprStr.dropFirst())
                // Handle cases with arguments like .title("...")
                if let parenIndex = withoutDot.firstIndex(of: "(") {
                    names.append(String(withoutDot[..<parenIndex]))
                } else {
                    names.append(withoutDot)
                }
            }
        }
        return names
    }

    /// Validates annotation array for duplicates and redundant combinations.
    private static func validateAnnotations(
        _ annotations: [String],
        syntax: SyntaxProtocol?,
        context: some MacroExpansionContext
    ) throws {
        // Check for duplicates
        var seen: Set<String> = []
        for annotation in annotations {
            if seen.contains(annotation) {
                throw ToolMacroError.duplicateAnnotation(annotation)
            }
            seen.insert(annotation)
        }

        // Warn about redundant combinations
        if annotations.contains("readOnly"), annotations.contains("idempotent") {
            if let syntax {
                context.diagnose(Diagnostic(
                    node: Syntax(syntax),
                    message: ToolMacroDiagnostic.warning(
                        "'.idempotent' is redundant when '.readOnly' is specified (readOnly implies idempotent)"
                    )
                ))
            }
        }
    }

    private static func extractParameterInfo(
        from varDecl: VariableDeclSyntax,
        binding: PatternBindingSyntax,
        context _: some MacroExpansionContext
    ) throws -> ParameterInfo? {
        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return nil
        }

        let propertyName = identifier.identifier.text
        var jsonKey = propertyName
        var typeName = "String"
        var isOptional = false
        var hasDefault = false
        var defaultValue: String?
        var paramTitle: String?
        var paramDescription: String?
        var minLength: String?
        var maxLength: String?
        var minimum: String?
        var maximum: String?

        // Get type annotation
        if let typeAnnotation = binding.typeAnnotation {
            let typeString = typeAnnotation.type.trimmedDescription
            typeName = typeString

            // Check if optional
            if typeString.hasSuffix("?") {
                isOptional = true
                typeName = String(typeString.dropLast())
            } else if typeString.hasPrefix("Optional<") {
                isOptional = true
                typeName = String(typeString.dropFirst(9).dropLast())
            }
        }

        // Check for default value
        if let initializer = binding.initializer {
            hasDefault = true
            defaultValue = initializer.value.trimmedDescription

            // Validate that default value is a literal
            if !isLiteralExpression(initializer.value) {
                throw ToolMacroError.nonLiteralDefaultValue(propertyName)
            }
        }

        // Extract @Parameter arguments
        for attr in varDecl.attributes {
            if case let .attribute(attrSyntax) = attr,
               isParameterAttribute(attr),
               let arguments = attrSyntax.arguments?.as(LabeledExprListSyntax.self)
            {
                for arg in arguments {
                    let label = arg.label?.text

                    switch label {
                        case "key":
                            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                jsonKey = segment.content.text
                            }
                        case "title":
                            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                paramTitle = segment.content.text
                            }
                        case "description":
                            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                paramDescription = segment.content.text
                            }
                        case "minLength":
                            minLength = arg.expression.trimmedDescription
                        case "maxLength":
                            maxLength = arg.expression.trimmedDescription
                        case "minimum":
                            minimum = arg.expression.trimmedDescription
                        case "maximum":
                            maximum = arg.expression.trimmedDescription
                        default:
                            break
                    }
                }
            }
        }

        return ParameterInfo(
            propertyName: propertyName,
            jsonKey: jsonKey,
            typeName: typeName,
            isOptional: isOptional,
            hasDefault: hasDefault,
            defaultValue: defaultValue,
            title: paramTitle,
            description: paramDescription,
            minLength: minLength,
            maxLength: maxLength,
            minimum: minimum,
            maximum: maximum,
            declSyntax: varDecl
        )
    }

    // MARK: - Code Generation

    private static func generateToolDefinition(
        toolInfo: ToolInfo,
        accessPrefix: String
    ) -> DeclSyntax {
        // Generate properties for each parameter
        var propertiesEntries: [String] = []

        for param in toolInfo.parameters {
            var propEntries: [String] = []

            // Get base type for schema
            let baseType = param.typeName
            let schemaType = getJSONSchemaType(for: baseType)

            // Use nullable type for optional params and default params in strict mode
            if param.isOptional || (toolInfo.strictSchema && param.hasDefault) {
                propEntries.append(
                    "\"type\": .array([.string(\"\(schemaType)\"), .string(\"null\")])")
            } else {
                propEntries.append("\"type\": .string(\"\(schemaType)\")")
            }

            if let title = param.title {
                propEntries.append("\"title\": .string(\"\(title)\")")
            }

            if let desc = param.description {
                propEntries.append("\"description\": .string(\"\(desc)\")")
            }

            // Add type-specific properties
            let additionalProps = getJSONSchemaProperties(for: baseType)
            for (key, value) in additionalProps {
                propEntries.append("\"\(key)\": \(value)")
            }

            // Add constraints
            if let minLen = param.minLength {
                propEntries.append("\"minLength\": .int(\(minLen))")
            }
            if let maxLen = param.maxLength {
                propEntries.append("\"maxLength\": .int(\(maxLen))")
            }
            if let min = param.minimum {
                propEntries.append("\"minimum\": .double(\(min))")
            }
            if let max = param.maximum {
                propEntries.append("\"maximum\": .double(\(max))")
            }

            // Add default value if present
            if let defaultVal = param.defaultValue {
                let defaultExpr = convertToValueLiteral(defaultVal, type: baseType)
                propEntries.append("\"default\": \(defaultExpr)")
            }

            // Merge in runtime jsonSchemaProperties for enums and other custom types
            let propObject = ".object([\(propEntries.joined(separator: ", "))].merging(\(baseType).jsonSchemaProperties) { _, new in new })"
            propertiesEntries.append("\"\(param.jsonKey)\": \(propObject)")
        }

        let propertiesStr = propertiesEntries.joined(separator: ", ")

        // Required fields
        let requiredFields: [String] = if toolInfo.strictSchema {
            // Strict mode: all properties must be required (optionality expressed via nullable types)
            toolInfo.parameters.map { ".string(\"\($0.jsonKey)\")" }
        } else {
            toolInfo.parameters
                .filter { !$0.isOptional && !$0.hasDefault }
                .map { ".string(\"\($0.jsonKey)\")" }
        }
        let requiredStr = requiredFields.joined(separator: ", ")

        // Handle empty properties - use [:] for empty dictionary literal
        let propertiesLiteral = propertiesStr.isEmpty ? "[:]" : "[\n            \(propertiesStr)\n        ]"

        // Build schema entries
        var schemaEntries = [
            "\"type\": .string(\"object\")",
            "\"properties\": .object(\(propertiesLiteral))",
            "\"required\": .array([\(requiredStr)])",
        ]

        // Add additionalProperties: false if strictSchema is enabled
        if toolInfo.strictSchema {
            schemaEntries.append("\"additionalProperties\": .bool(false)")
        }

        let schemaLiteral = schemaEntries.joined(separator: ",\n                    ")

        return """
        \(raw: accessPrefix)static var toolDefinition: MCP.Tool {
            MCP.Tool(
                name: name,
                description: description,
                inputSchema: .object([
                    \(raw: schemaLiteral)
                ]),
                outputSchema: outputSchema(for: Output.self),
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
                // Optional: use flatMap with explicit type
                parseStatements.append(
                    "_instance.\(prop) = _args[\"\(key)\"].flatMap(\(type).init(parameterValue:))"
                )
            } else if param.hasDefault {
                // Has default: only use default if key is absent or null; throw if wrong type
                parseStatements.append(
                    "if let _value = _args[\"\(key)\"], !_value.isNull { guard let _parsed = \(type)(parameterValue: _value) else { throw MCPError.invalidParams(\"Invalid type for '\(key)': expected \(type)\") }; _instance.\(prop) = _parsed }"
                )
            } else {
                // Required: guard and throw - generate two separate statements
                parseStatements.append(
                    "guard let _\(prop)Value = _args[\"\(key)\"], let _\(prop) = \(type)(parameterValue: _\(prop)Value) else { throw MCPError.invalidParams(\"Invalid type for '\(key)': expected \(type)\") }"
                )
                parseStatements.append("_instance.\(prop) = _\(prop)")
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

    // MARK: - Type Mapping Helpers

    /// Checks if a type string represents a dictionary type `[Key: Value]` at the top level.
    /// This properly handles nested types like `[[String: String]]` (array of dictionaries).
    private static func isDictionaryType(_ inner: String) -> Bool {
        // Find colon that's at the top level (not inside nested brackets)
        var bracketDepth = 0
        for char in inner {
            switch char {
                case "[": bracketDepth += 1
                case "]": bracketDepth -= 1
                case ":":
                    // Only count as dictionary if colon is at top level
                    if bracketDepth == 0 {
                        return true
                    }
                default: break
            }
        }
        return false
    }

    /// Extracts the value type from a dictionary type string `[Key: Value]`.
    /// Returns nil if not a valid dictionary type.
    private static func extractDictionaryValueType(_ inner: String) -> String? {
        var bracketDepth = 0
        for (index, char) in inner.enumerated() {
            switch char {
                case "[": bracketDepth += 1
                case "]": bracketDepth -= 1
                case ":":
                    if bracketDepth == 0 {
                        let afterColon = inner.index(inner.startIndex, offsetBy: index + 1)
                        return String(inner[afterColon...]).trimmingCharacters(in: .whitespaces)
                    }
                default: break
            }
        }
        return nil
    }

    private static func getJSONSchemaType(for swiftType: String) -> String {
        switch swiftType {
            case "String": return "string"
            case "Int": return "integer"
            case "Double": return "number"
            case "Bool": return "boolean"
            case "Date": return "string"
            case "Data": return "string"
            default:
                // Check for collection types [T] or [K: V]
                if swiftType.hasPrefix("["), swiftType.hasSuffix("]") {
                    let inner = String(swiftType.dropFirst().dropLast())
                    // Dictionary type [String: T] - check for top-level colon only
                    if isDictionaryType(inner) {
                        return "object"
                    }
                    // Array type [T] (including nested arrays like [[String: String]])
                    return "array"
                }
                // Could be an enum or other type - default to string
                return "string"
        }
    }

    private static func getJSONSchemaProperties(for swiftType: String) -> [(String, String)] {
        switch swiftType {
            case "Date":
                return [("format", ".string(\"date-time\")")]
            case "Data":
                return [("contentEncoding", ".string(\"base64\")")]
            default:
                // Check for collection types [T] or [K: V]
                if swiftType.hasPrefix("["), swiftType.hasSuffix("]") {
                    let inner = String(swiftType.dropFirst().dropLast())
                    // Dictionary type [String: T] - check for top-level colon only
                    if let valueType = extractDictionaryValueType(inner) {
                        let valueSchema = generateSchemaObject(for: valueType)
                        return [("additionalProperties", valueSchema)]
                    }
                    // Array type [T] - use recursive schema generation for nested arrays
                    let elementSchema = generateSchemaObject(for: inner)
                    return [("items", elementSchema)]
                }
                return []
        }
    }

    /// Generates a complete schema object string for a Swift type, handling nested types recursively.
    private static func generateSchemaObject(for swiftType: String) -> String {
        let schemaType = getJSONSchemaType(for: swiftType)
        var parts = ["\"type\": .string(\"\(schemaType)\")"]

        // Add type-specific properties
        switch swiftType {
            case "Date":
                parts.append("\"format\": .string(\"date-time\")")
            case "Data":
                parts.append("\"contentEncoding\": .string(\"base64\")")
            default:
                if swiftType.hasPrefix("["), swiftType.hasSuffix("]") {
                    let inner = String(swiftType.dropFirst().dropLast())
                    // Dictionary type [String: T] - check for top-level colon only
                    if let valueType = extractDictionaryValueType(inner) {
                        let valueSchema = generateSchemaObject(for: valueType)
                        parts.append("\"additionalProperties\": \(valueSchema)")
                    } else {
                        // Array [T] (including nested arrays)
                        let elementSchema = generateSchemaObject(for: inner)
                        parts.append("\"items\": \(elementSchema)")
                    }
                }
        }

        return ".object([\(parts.joined(separator: ", "))])"
    }

    private static func convertToValueLiteral(_ value: String, type: String) -> String {
        // `nil` is accepted as a literal default for optional parameters — emit `.null`
        // so the generated schema uses a valid Value expression instead of `.string(nil)`.
        if value == "nil" {
            return ".null"
        }
        switch type {
            case "String":
                // Already a string literal
                return ".string(\(value))"
            case "Int":
                return ".int(\(value))"
            case "Double":
                return ".double(\(value))"
            case "Bool":
                return ".bool(\(value))"
            default:
                // Try to infer from value format
                if value == "true" || value == "false" {
                    return ".bool(\(value))"
                } else if value.contains(".") {
                    return ".double(\(value))"
                } else if let _ = Int(value) {
                    return ".int(\(value))"
                } else {
                    return ".string(\(value))"
                }
        }
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

/// Thrown after emitting a node-level diagnostic to silently abort macro expansion
/// without a second attribute-level error. Caught by the outer `expansion` function.
private struct AbortMacroExpansion: Error {}

// MARK: - Diagnostics

struct ToolMacroDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    static func warning(_ message: String) -> ToolMacroDiagnostic {
        ToolMacroDiagnostic(
            message: message,
            diagnosticID: MessageID(domain: "ToolMacro", id: "warning"),
            severity: .warning
        )
    }

    static func error(_ message: String) -> ToolMacroDiagnostic {
        ToolMacroDiagnostic(
            message: message,
            diagnosticID: MessageID(domain: "ToolMacro", id: "error"),
            severity: .error
        )
    }
}

// MARK: - Access Level Helpers

extension ToolMacro {
    /// Ranks Swift access levels from most to least restrictive.
    /// Missing modifier defaults to internal.
    static func accessLevelRank(of modifiers: DeclModifierListSyntax) -> Int {
        explicitAccessLevelRank(of: modifiers) ?? 2
    }

    /// Returns the explicit access level rank, or nil if no access modifier is present.
    static func explicitAccessLevelRank(of modifiers: DeclModifierListSyntax) -> Int? {
        for modifier in modifiers {
            switch modifier.name.text {
                case "private": return 0
                case "fileprivate": return 1
                case "internal": return 2
                case "package": return 3
                case "public": return 4
                case "open": return 5
                default: continue
            }
        }
        return nil
    }

    static func accessLevelName(_ rank: Int) -> String {
        switch rank {
            case 0: "private"
            case 1: "fileprivate"
            case 2: "internal"
            case 3: "package"
            case 4: "public"
            case 5: "open"
            default: "internal"
        }
    }
}

// MARK: - Duplicate Parameter Key Detection

extension ToolMacro {
    private static func duplicateParameterKeys(in parameters: [ParameterInfo]) -> [String] {
        var counts: [String: Int] = [:]
        for parameter in parameters {
            counts[parameter.jsonKey, default: 0] += 1
        }
        return counts
            .filter { $0.value > 1 }
            .map(\.key)
            .sorted()
    }
}

// MARK: - Tool Name Validation

extension ToolMacro {
    /// Valid characters for tool names: A-Z, a-z, 0-9, _, -, .
    private static let validToolNameCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-."
    )

    /// Validates a tool name and returns an error message if invalid, or nil if valid.
    static func validateToolName(_ name: String) -> String? {
        // Check length
        if name.isEmpty {
            return "Tool name cannot be empty"
        }
        if name.count > 128 {
            return "Tool name exceeds maximum length of 128 characters (got \(name.count))"
        }

        // Check for invalid characters
        let nameCharSet = CharacterSet(charactersIn: name)
        if !nameCharSet.isSubset(of: validToolNameCharacters) {
            let invalidChars = name.unicodeScalars.filter { !validToolNameCharacters.contains($0) }
            let invalidStr = String(String.UnicodeScalarView(invalidChars))
            return "Tool name contains invalid characters: '\(invalidStr)'. Only A-Z, a-z, 0-9, _, -, . are allowed"
        }

        return nil
    }

    /// Returns a warning message if the tool name has style issues, or nil if ok.
    static func toolNameStyleWarning(_ name: String) -> String? {
        if name.hasPrefix("-") || name.hasPrefix(".") {
            return "Tool name '\(name)' starts with '\(name.first!)' which may cause compatibility issues"
        }
        if name.hasSuffix("-") || name.hasSuffix(".") {
            return "Tool name '\(name)' ends with '\(name.last!)' which may cause compatibility issues"
        }
        return nil
    }
}

// MARK: - Attribute Matching

extension ToolMacro {
    /// Checks if an attribute is the `@Parameter` attribute.
    /// Recognizes both `@Parameter` and `@MCP.Parameter` forms for compatibility
    /// when MCP module is imported alongside other frameworks that also define Parameter.
    static func isParameterAttribute(_ attr: AttributeListSyntax.Element) -> Bool {
        guard case let .attribute(attrSyntax) = attr else { return false }

        // Check for simple `@Parameter`
        if let identifier = attrSyntax.attributeName.as(IdentifierTypeSyntax.self) {
            return identifier.name.text == "Parameter"
        }

        // Check for qualified `@MCP.Parameter`
        if let memberType = attrSyntax.attributeName.as(MemberTypeSyntax.self),
           let baseIdentifier = memberType.baseType.as(IdentifierTypeSyntax.self)
        {
            return baseIdentifier.name.text == "MCP" && memberType.name.text == "Parameter"
        }

        return false
    }

    /// Checks if a variable declaration has the `@Parameter` attribute.
    static func hasParameterAttribute(_ varDecl: VariableDeclSyntax) -> Bool {
        varDecl.attributes.contains { isParameterAttribute($0) }
    }
}

// MARK: - Default Value Validation

extension ToolMacro {
    /// Checks if an expression is a supported literal value.
    /// Returns true for: integer, float, string, boolean literals.
    /// Returns false for: function calls, member access, etc.
    static func isLiteralExpression(_ expr: ExprSyntax) -> Bool {
        // Integer literal: 42
        if expr.is(IntegerLiteralExprSyntax.self) {
            return true
        }
        // Float literal: 3.14
        if expr.is(FloatLiteralExprSyntax.self) {
            return true
        }
        // String literal: "hello"
        if expr.is(StringLiteralExprSyntax.self) {
            return true
        }
        // Boolean literal: true, false
        if expr.is(BooleanLiteralExprSyntax.self) {
            return true
        }
        // Nil literal
        if expr.is(NilLiteralExprSyntax.self) {
            return true
        }
        // Negative number: -42, -3.14
        if let prefixExpr = expr.as(PrefixOperatorExprSyntax.self),
           prefixExpr.operator.text == "-"
        {
            return isLiteralExpression(prefixExpr.expression)
        }
        return false
    }
}
