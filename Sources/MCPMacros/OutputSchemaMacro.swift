import SwiftSyntax
import SwiftSyntaxMacros

/// The `@OutputSchema` macro generates `StructuredOutput` conformance.
///
/// It inspects the struct to find stored properties and generates:
/// - `static var schema: Value` - The JSON Schema for the output type
public struct OutputSchemaMacro: MemberMacro, ExtensionMacro {
    // MARK: - MemberMacro

    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Ensure we're applied to a struct
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            throw OutputSchemaMacroError.notAStruct
        }

        // Extract properties
        let properties = extractProperties(from: structDecl)

        // Generate schema
        let schemaDecl = generateSchema(properties: properties)

        return [schemaDecl]
    }

    // MARK: - ExtensionMacro

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Validate it's a struct
        guard declaration.as(StructDeclSyntax.self) != nil else {
            return []
        }

        // Add StructuredOutput conformance
        let extensionDecl: DeclSyntax = """
        extension \(type): StructuredOutput {}
        """

        guard let ext = extensionDecl.as(ExtensionDeclSyntax.self) else {
            return []
        }

        return [ext]
    }

    // MARK: - Property Extraction

    private struct PropertyInfo {
        var name: String
        var typeName: String
        var isOptional: Bool
    }

    private static func extractProperties(from structDecl: StructDeclSyntax) -> [PropertyInfo] {
        var properties: [PropertyInfo] = []

        for member in structDecl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  !varDecl.modifiers.contains(where: { $0.name.text == "static" })
            else {
                continue
            }

            for binding in varDecl.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                      let typeAnnotation = binding.typeAnnotation
                else {
                    continue
                }

                let name = identifier.identifier.text
                let typeString = typeAnnotation.type.trimmedDescription
                var typeName = typeString
                var isOptional = false

                // Check if optional
                if typeString.hasSuffix("?") {
                    isOptional = true
                    typeName = String(typeString.dropLast())
                } else if typeString.hasPrefix("Optional<") {
                    isOptional = true
                    typeName = String(typeString.dropFirst(9).dropLast())
                }

                properties.append(PropertyInfo(
                    name: name,
                    typeName: typeName,
                    isOptional: isOptional
                ))
            }
        }

        return properties
    }

    // MARK: - Schema Generation

    private static func generateSchema(properties: [PropertyInfo]) -> DeclSyntax {
        var propertyEntries: [String] = []
        var requiredFields: [String] = []

        for prop in properties {
            let schemaType = getJSONSchemaType(for: prop.typeName)
            var propEntries = ["\"type\": .string(\"\(schemaType)\")"]

            // Add items for arrays
            let additionalProps = getJSONSchemaProperties(for: prop.typeName)
            for (key, value) in additionalProps {
                propEntries.append("\"\(key)\": \(value)")
            }

            let propObject = ".object([\(propEntries.joined(separator: ", "))])"
            propertyEntries.append("\"\(prop.name)\": \(propObject)")

            // Non-optional properties are required
            if !prop.isOptional {
                requiredFields.append(".string(\"\(prop.name)\")")
            }
        }

        let propertiesStr = propertyEntries.joined(separator: ", ")
        let requiredStr = requiredFields.joined(separator: ", ")

        return """
        public static var schema: Value {
            .object([
                "type": .string("object"),
                "properties": .object([
                    \(raw: propertiesStr)
                ]),
                "required": .array([\(raw: requiredStr)])
            ])
        }
        """
    }

    // MARK: - Type Mapping

    private static func getJSONSchemaType(for swiftType: String) -> String {
        switch swiftType {
            case "String": return "string"
            case "Int": return "integer"
            case "Double": return "number"
            case "Bool": return "boolean"
            case "Date": return "string"
            case "Data": return "string"
            default:
                // Array types
                if swiftType.hasPrefix("["), swiftType.hasSuffix("]") {
                    return "array"
                }
                // Default to object for custom types
                return "object"
        }
    }

    private static func getJSONSchemaProperties(for swiftType: String) -> [(String, String)] {
        switch swiftType {
            case "Date":
                return [("format", ".string(\"date-time\")")]
            case "Data":
                return [("contentEncoding", ".string(\"base64\")")]
            default:
                // Check for array types
                if swiftType.hasPrefix("["), swiftType.hasSuffix("]") {
                    let elementType = String(swiftType.dropFirst().dropLast())
                    let itemSchemaType = getJSONSchemaType(for: elementType)
                    return [("items", ".object([\"type\": .string(\"\(itemSchemaType)\")])")]
                }
                return []
        }
    }
}

// MARK: - Errors

enum OutputSchemaMacroError: Error, CustomStringConvertible {
    case notAStruct

    var description: String {
        switch self {
            case .notAStruct:
                "@OutputSchema can only be applied to structs"
        }
    }
}
