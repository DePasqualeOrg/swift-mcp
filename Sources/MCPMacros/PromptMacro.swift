import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

/// The `@Prompt` macro generates `PromptSpec` protocol conformance.
///
/// It inspects the struct to find:
/// - `static let name: String` - The prompt name
/// - `static let description: String` - The prompt description
/// - `static let title: String` (optional) - Display title
/// - Properties with `@Argument` attribute - Prompt arguments
/// - `func render()` or `func render(context:)` - The render method
///
/// It generates:
/// - `static var promptDefinition: Prompt` - The prompt definition with arguments
/// - `static func parse(from:)` - Argument parsing
/// - `init()` - Empty initializer
/// - `func render(context:)` - Bridging method (only if you write `render()` without context)
public struct PromptMacro: MemberMacro, ExtensionMacro {
    // MARK: - MemberMacro

    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw PromptMacroError.notAStruct
        }

        let promptInfo = try extractPromptInfo(from: structDecl, context: context)

        var members: [DeclSyntax] = []

        // Generate init()
        members.append("""
        public init() {}
        """)

        // Generate bridging render(context:) if user wrote render() without context
        if !promptInfo.hasContextParameter {
            members.append("""
            public func render(context: HandlerContext) async throws -> \(raw: promptInfo.outputType) {
                try await render()
            }
            """)
        }

        // Generate promptDefinition
        let definitionDecl = generatePromptDefinition(promptInfo: promptInfo)
        members.append(definitionDecl)

        // Generate parse(from:)
        let parseDecl = generateParseMethod(promptInfo: promptInfo)
        members.append(parseDecl)

        return members
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            return []
        }

        // Check for required static properties
        var hasName = false
        var hasDescription = false

        for member in structDecl.memberBlock.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self),
               varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                for binding in varDecl.bindings {
                    if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) {
                        let propName = identifier.identifier.text
                        if propName == "name" { hasName = true }
                        if propName == "description" { hasDescription = true }
                    }
                }
            }
        }

        guard hasName, hasDescription else {
            return []
        }

        let extensionDecl: DeclSyntax = """
        extension \(type): PromptSpec {}
        """

        guard let ext = extensionDecl.as(ExtensionDeclSyntax.self) else {
            return []
        }

        return [ext]
    }

    // MARK: - Prompt Info Extraction

    private struct PromptInfo {
        var name: String
        var description: String
        var title: String?
        var arguments: [ArgumentInfo]
        var outputType: String // The return type of render()
        var hasContextParameter: Bool // Whether render() takes a context parameter
    }

    private struct ArgumentInfo {
        var propertyName: String
        var argumentKey: String
        var title: String?
        var description: String?
        var isOptional: Bool
        var requiredOverride: Bool?
    }

    private static func extractPromptInfo(
        from structDecl: StructDeclSyntax,
        context _: some MacroExpansionContext
    ) throws -> PromptInfo {
        var name: String?
        var description: String?
        var title: String?
        var arguments: [ArgumentInfo] = []
        var outputType = "[Prompt.Message]" // Default output type
        var hasContextParameter = true // Default to true for backwards compatibility

        for member in structDecl.memberBlock.members {
            let decl = member.decl

            // Look for static let name/description/title
            if let varDecl = decl.as(VariableDeclSyntax.self),
               varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
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
                    }

                    if propertyName == "description",
                       let initializer = binding.initializer,
                       let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                    {
                        description = segment.content.text
                    }

                    if propertyName == "title",
                       let initializer = binding.initializer,
                       let stringLiteral = initializer.value.as(StringLiteralExprSyntax.self),
                       let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                    {
                        title = segment.content.text
                    }
                }
            }

            // Look for @Argument properties
            if let varDecl = decl.as(VariableDeclSyntax.self),
               !varDecl.modifiers.contains(where: { $0.name.text == "static" })
            {
                let hasArgument = varDecl.attributes.contains { attr in
                    if case let .attribute(attrSyntax) = attr,
                       let identifier = attrSyntax.attributeName.as(IdentifierTypeSyntax.self)
                    {
                        return identifier.name.text == "Argument"
                    }
                    return false
                }

                if hasArgument {
                    for binding in varDecl.bindings {
                        if let argInfo = extractArgumentInfo(from: varDecl, binding: binding) {
                            arguments.append(argInfo)
                        }
                    }
                }
            }

            // Look for render method to get output type and check for context parameter
            if let funcDecl = decl.as(FunctionDeclSyntax.self),
               funcDecl.name.text == "render"
            {
                if let returnClause = funcDecl.signature.returnClause {
                    outputType = returnClause.type.trimmedDescription
                }
                // Check if the render method has a context parameter
                let parameterList = funcDecl.signature.parameterClause.parameters
                hasContextParameter = parameterList.contains { param in
                    param.firstName.text == "context" || param.secondName?.text == "context"
                }
            }
        }

        guard let promptName = name else {
            throw PromptMacroError.missingName
        }

        guard let promptDescription = description else {
            throw PromptMacroError.missingDescription
        }

        return PromptInfo(
            name: promptName,
            description: promptDescription,
            title: title,
            arguments: arguments,
            outputType: outputType,
            hasContextParameter: hasContextParameter
        )
    }

    private static func extractArgumentInfo(
        from varDecl: VariableDeclSyntax,
        binding: PatternBindingSyntax
    ) -> ArgumentInfo? {
        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return nil
        }

        let propertyName = identifier.identifier.text
        var argumentKey = propertyName
        var title: String?
        var argDescription: String?
        var isOptional = false
        var requiredOverride: Bool?

        // Get type annotation
        if let typeAnnotation = binding.typeAnnotation {
            let typeString = typeAnnotation.type.trimmedDescription
            if typeString.hasSuffix("?") || typeString.hasPrefix("Optional<") {
                isOptional = true
            }
        }

        // Extract @Argument arguments
        for attr in varDecl.attributes {
            if case let .attribute(attrSyntax) = attr,
               let attrIdentifier = attrSyntax.attributeName.as(IdentifierTypeSyntax.self),
               attrIdentifier.name.text == "Argument",
               let arguments = attrSyntax.arguments?.as(LabeledExprListSyntax.self)
            {
                for arg in arguments {
                    let label = arg.label?.text

                    switch label {
                        case "key":
                            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                argumentKey = segment.content.text
                            }
                        case "title":
                            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                title = segment.content.text
                            }
                        case "description":
                            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self),
                               let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
                            {
                                argDescription = segment.content.text
                            }
                        case "required":
                            if let boolLiteral = arg.expression.as(BooleanLiteralExprSyntax.self) {
                                requiredOverride = boolLiteral.literal.text == "true"
                            }
                        default:
                            break
                    }
                }
            }
        }

        return ArgumentInfo(
            propertyName: propertyName,
            argumentKey: argumentKey,
            title: title,
            description: argDescription,
            isOptional: isOptional,
            requiredOverride: requiredOverride
        )
    }

    // MARK: - Code Generation

    private static func generatePromptDefinition(promptInfo: PromptInfo) -> DeclSyntax {
        // Generate arguments array
        var argumentEntries: [String] = []

        for arg in promptInfo.arguments {
            var argParts = ["name: \"\(arg.argumentKey)\""]

            if let title = arg.title {
                argParts.append("title: \"\(title)\"")
            }

            if let desc = arg.description {
                argParts.append("description: \"\(desc)\"")
            }

            // Determine required status
            let isRequired: Bool = if let override = arg.requiredOverride {
                override
            } else {
                !arg.isOptional
            }
            argParts.append("required: \(isRequired)")

            argumentEntries.append("Prompt.Argument(\(argParts.joined(separator: ", ")))")
        }

        let argumentsLiteral = if argumentEntries.isEmpty {
            "nil"
        } else {
            "[\n            \(argumentEntries.joined(separator: ",\n            "))\n        ]"
        }

        let titleLiteral = promptInfo.title.map { "\"\($0)\"" } ?? "nil"

        return """
        public static var promptDefinition: Prompt {
            Prompt(
                name: name,
                title: \(raw: titleLiteral),
                description: description,
                arguments: \(raw: argumentsLiteral)
            )
        }
        """
    }

    private static func generateParseMethod(promptInfo: PromptInfo) -> DeclSyntax {
        var parseStatements: [String] = []

        for arg in promptInfo.arguments {
            let key = arg.argumentKey
            let prop = arg.propertyName

            // Determine if required
            let isRequired: Bool = if let override = arg.requiredOverride {
                override
            } else {
                !arg.isOptional
            }

            if arg.isOptional {
                parseStatements.append(
                    "_instance.\(prop) = _args[\"\(key)\"]"
                )
            } else if isRequired {
                parseStatements.append(
                    "guard let _\(prop) = _args[\"\(key)\"] else { throw MCPError.invalidParams(\"Missing required argument: '\(key)'\") }"
                )
                parseStatements.append("_instance.\(prop) = _\(prop)")
            } else {
                // Non-optional but not required - use empty string default
                parseStatements.append(
                    "_instance.\(prop) = _args[\"\(key)\"] ?? \"\""
                )
            }
        }

        let statements = parseStatements.isEmpty ? "" : parseStatements.joined(separator: "\n        ")

        return """
        public static func parse(from arguments: [String: String]?) throws -> Self {
            var _instance = Self()
            let _args = arguments ?? [:]
            \(raw: statements)
            return _instance
        }
        """
    }
}

// MARK: - Errors

enum PromptMacroError: Error, CustomStringConvertible {
    case notAStruct
    case missingName
    case missingDescription

    var description: String {
        switch self {
            case .notAStruct:
                "@Prompt can only be applied to structs"
            case .missingName:
                "@Prompt requires 'static let name: String' property"
            case .missingDescription:
                "@Prompt requires 'static let description: String' property"
        }
    }
}
