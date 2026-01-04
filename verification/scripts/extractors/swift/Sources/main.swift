// Copyright © Anthony DePasquale

import ArgumentParser
import Foundation
import SwiftParser
import SwiftSyntax

struct TypeInfo: Codable {
    let name: String
    let kind: String // struct, class, enum, protocol, typealias, actor, case, associatedtype
    let file: String
    let line: Int
}

/// Visitor that extracts type declarations from Swift source with fully qualified names
final class TypeExtractor: SyntaxVisitor {
    var types: [TypeInfo] = []
    let filePath: String
    let locationConverter: SourceLocationConverter

    /// Stack of parent type names for tracking nesting
    private var parentStack: [String] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        locationConverter = SourceLocationConverter(fileName: filePath, tree: Parser.parse(source: source))
        super.init(viewMode: .sourceAccurate)
    }

    private func lineNumber(for position: AbsolutePosition) -> Int {
        let location = locationConverter.location(for: position)
        return location.line
    }

    /// Build fully qualified name from parent stack and current name
    private func qualifiedName(_ name: String) -> String {
        if parentStack.isEmpty {
            return name
        }
        return (parentStack + [name]).joined(separator: ".")
    }

    private func addType(name: String, kind: String, position: AbsolutePosition) {
        types.append(TypeInfo(
            name: qualifiedName(name),
            kind: kind,
            file: filePath,
            line: lineNumber(for: position)
        ))
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        addType(name: name, kind: "struct", position: node.position)
        parentStack.append(name)
        return .visitChildren
    }

    override func visitPost(_: StructDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        addType(name: name, kind: "class", position: node.position)
        parentStack.append(name)
        return .visitChildren
    }

    override func visitPost(_: ClassDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        addType(name: name, kind: "enum", position: node.position)
        parentStack.append(name)
        return .visitChildren
    }

    override func visitPost(_: EnumDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        addType(name: node.name.text, kind: "case", position: node.position)
        return .skipChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        addType(name: name, kind: "protocol", position: node.position)
        parentStack.append(name)
        return .visitChildren
    }

    override func visitPost(_: ProtocolDeclSyntax) {
        parentStack.removeLast()
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        addType(name: node.name.text, kind: "associatedtype", position: node.position)
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        addType(name: node.name.text, kind: "typealias", position: node.position)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        addType(name: name, kind: "actor", position: node.position)
        parentStack.append(name)
        return .visitChildren
    }

    override func visitPost(_: ActorDeclSyntax) {
        parentStack.removeLast()
    }
}

func extractTypesFromFile(_ path: String) throws -> [TypeInfo] {
    let url = URL(fileURLWithPath: path)
    let content = try String(contentsOf: url, encoding: .utf8)
    let sourceFile = Parser.parse(source: content)
    let extractor = TypeExtractor(filePath: path, source: content)
    extractor.walk(sourceFile)
    return extractor.types
}

func extractTypesFromDirectory(_ path: String) throws -> [TypeInfo] {
    var types: [TypeInfo] = []
    let fileManager = FileManager.default
    let url = URL(fileURLWithPath: path)

    guard let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return types
    }

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "swift" else { continue }

        // Skip test files and build directories
        let pathComponents = fileURL.pathComponents
        if pathComponents.contains(".build") || pathComponents.contains("Tests") {
            continue
        }

        do {
            try types.append(contentsOf: extractTypesFromFile(fileURL.path))
        } catch {
            fputs("Warning: Could not parse \(fileURL.path): \(error)\n", stderr)
        }
    }

    return types
}

@main
struct ExtractSwiftTypes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Extract type definitions from Swift files using SwiftSyntax",
        discussion: """
        Outputs one type per line with fully qualified names (e.g., Resource.Content).

        Example:
            swift run extract-swift-types ./Sources/MCP
            swift run extract-swift-types ./Sources --json
        """
    )

    @Argument(help: "File or directory to analyze")
    var path: String

    @Flag(name: .long, help: "Output as JSON")
    var json = false

    @Option(name: .long, help: "Check if a specific type exists")
    var check: String?

    func run() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            fputs("Error: Path does not exist: \(path)\n", stderr)
            throw ExitCode.failure
        }

        let types: [TypeInfo] = if isDirectory.boolValue {
            try extractTypesFromDirectory(path)
        } else {
            try extractTypesFromFile(path)
        }

        if let typeName = check {
            let found = types.first { $0.name == typeName }
            if json {
                let result: [String: Any] = if let found {
                    [
                        "exists": true,
                        "name": found.name,
                        "kind": found.kind,
                        "file": found.file,
                        "line": found.line,
                    ]
                } else {
                    ["exists": false, "name": typeName]
                }
                let data = try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
                guard let output = String(data: data, encoding: .utf8) else {
                    fatalError("Internal error: JSON data could not be encoded as UTF-8")
                }
                print(output)
            } else {
                if let found {
                    print("Found: \(found.name) (\(found.kind))")
                } else {
                    print("Not found: \(typeName)")
                    throw ExitCode.failure
                }
            }
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(types)
            guard let output = String(data: data, encoding: .utf8) else {
                fatalError("Internal error: JSON data could not be encoded as UTF-8")
            }
            print(output)
        } else {
            for t in types {
                print("\(t.name):\(t.kind):\(t.file):\(t.line)")
            }
        }
    }
}
