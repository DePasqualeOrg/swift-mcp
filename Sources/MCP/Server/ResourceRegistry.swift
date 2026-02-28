// Copyright © Anthony DePasquale

import Foundation

// MARK: - ResourceProvider Protocol

/// A resource that can be read.
public protocol ResourceProvider: Sendable {
    /// The resource definition for listings.
    var definition: Resource { get }

    /// Read the resource contents.
    func read() async throws -> Resource.Contents
}

// MARK: - Built-in Resource Types

/// A resource with static text content.
public struct TextResource: ResourceProvider {
    public let definition: Resource
    private let content: String

    public init(
        uri: String,
        name: String,
        content: String,
        description: String? = nil,
        mimeType: String = "text/plain"
    ) {
        definition = Resource(
            name: name,
            uri: uri,
            description: description,
            mimeType: mimeType
        )
        self.content = content
    }

    public func read() async throws -> Resource.Contents {
        .text(content, uri: definition.uri, mimeType: definition.mimeType)
    }
}

/// A resource with static binary content.
public struct BinaryResource: ResourceProvider {
    public let definition: Resource
    private let data: Data

    public init(
        uri: String,
        name: String,
        data: Data,
        description: String? = nil,
        mimeType: String = "application/octet-stream"
    ) {
        definition = Resource(
            name: name,
            uri: uri,
            description: description,
            mimeType: mimeType
        )
        self.data = data
    }

    public func read() async throws -> Resource.Contents {
        .binary(data, uri: definition.uri, mimeType: definition.mimeType)
    }
}

/// A resource that calls a function to generate content.
public struct FunctionResource: ResourceProvider {
    public let definition: Resource
    private let readHandler: @Sendable () async throws -> Resource.Contents

    public init(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        read: @escaping @Sendable () async throws -> Resource.Contents
    ) {
        definition = Resource(
            name: name,
            uri: uri,
            description: description,
            mimeType: mimeType
        )
        readHandler = read
    }

    public func read() async throws -> Resource.Contents {
        try await readHandler()
    }
}

/// A resource backed by a file on the filesystem.
public struct FileResource: ResourceProvider {
    public let definition: Resource
    private let path: String

    /// Creates a file resource.
    ///
    /// - Parameters:
    ///   - uri: The resource URI. If nil, defaults to "file://\(path)".
    ///   - name: The resource name. If nil, defaults to the filename.
    ///   - path: The filesystem path to the file.
    ///   - description: Optional description.
    ///   - mimeType: The MIME type. If nil, inferred from the file extension.
    public init(
        uri: String? = nil,
        name: String? = nil,
        path: String,
        description: String? = nil,
        mimeType: String? = nil
    ) {
        let resolvedUri = uri ?? "file://\(path)"
        let resolvedName = name ?? URL(fileURLWithPath: path).lastPathComponent
        let resolvedMimeType = mimeType ?? Self.inferMimeType(from: path)

        definition = Resource(
            name: resolvedName,
            uri: resolvedUri,
            description: description,
            mimeType: resolvedMimeType
        )
        self.path = path
    }

    public func read() async throws -> Resource.Contents {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        // Return as text if it's a text-based MIME type
        if let mimeType = definition.mimeType, Self.isTextMimeType(mimeType) {
            guard let text = String(data: data, encoding: .utf8) else {
                throw MCPError.internalError("Failed to decode file as UTF-8: \(path)")
            }
            return .text(text, uri: definition.uri, mimeType: mimeType)
        }

        return .binary(data, uri: definition.uri, mimeType: definition.mimeType)
    }

    private static func inferMimeType(from path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
            case "json": return "application/json"
            case "xml": return "application/xml"
            case "html", "htm": return "text/html"
            case "css": return "text/css"
            case "js": return "application/javascript"
            case "txt": return "text/plain"
            case "md": return "text/markdown"
            case "yaml", "yml": return "application/yaml"
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "pdf": return "application/pdf"
            case "swift": return "text/x-swift"
            case "py": return "text/x-python"
            case "ts": return "text/typescript"
            case "tsx": return "text/tsx"
            case "jsx": return "text/jsx"
            default: return "application/octet-stream"
        }
    }

    private static func isTextMimeType(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("text/") ||
            mimeType == "application/json" ||
            mimeType == "application/xml" ||
            mimeType == "application/javascript" ||
            mimeType == "application/yaml"
    }
}

/// A helper for exposing all files in a directory as resources.
///
/// This type is used with `ResourceRegistry.registerDirectory()` to expose
/// multiple files as individual resources with a common URI prefix.
///
/// Example:
/// ```swift
/// let directory = DirectoryResource(
///     path: "/path/to/docs",
///     uriPrefix: "docs://",
///     recursive: true,
///     allowedExtensions: ["md", "txt"]
/// )
///
/// for file in try directory.listResources() {
///     await registry.register(file)
/// }
/// ```
public struct DirectoryResource: Sendable {
    /// The directory path on the filesystem.
    public let path: String

    /// The URI prefix for resources (e.g., "file:///docs").
    public let uriPrefix: String

    /// Whether to recursively include subdirectories.
    public let recursive: Bool

    /// Optional file extension filter (e.g., ["md", "txt"]).
    public let allowedExtensions: Set<String>?

    public init(
        path: String,
        uriPrefix: String,
        recursive: Bool = false,
        allowedExtensions: [String]? = nil
    ) {
        self.path = path
        self.uriPrefix = uriPrefix
        self.recursive = recursive
        self.allowedExtensions = allowedExtensions.map { Set($0.map { $0.lowercased() }) }
    }

    /// Lists all file resources in the directory.
    public func listResources() throws -> [FileResource] {
        let fileManager = FileManager.default
        let directoryURL = URL(fileURLWithPath: path)

        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive {
            options.insert(.skipsSubdirectoryDescendants)
        }

        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: options
        ) else {
            throw MCPError.internalError("Cannot enumerate directory: \(path)")
        }

        var resources: [FileResource] = []

        for case let fileURL as URL in enumerator {
            // Check if it's a regular file
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else {
                continue
            }

            // Check extension filter
            if let allowed = allowedExtensions {
                let ext = fileURL.pathExtension.lowercased()
                guard allowed.contains(ext) else { continue }
            }

            // Build URI from prefix and relative path
            let relativePath = fileURL.path.replacingOccurrences(of: path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let uri = "\(uriPrefix)/\(relativePath)"

            resources.append(FileResource(
                uri: uri,
                path: fileURL.path
            ))
        }

        return resources
    }
}

// MARK: - Resource Template

/// A template for dynamically generating resources from URI patterns.
///
/// Resource templates use a simplified URI pattern matching where `{variable}`
/// placeholders are extracted from URIs.
///
/// Example:
/// ```swift
/// let template = ManagedResourceTemplate(
///     uriTemplate: "file:///{path}",
///     name: "file",
///     description: "Read a file by path"
/// ) { uri, variables in
///     let path = variables["path"]!
///     let content = try String(contentsOfFile: "/" + path)
///     return .text(content, uri: uri)
/// }
///
/// // Matching "file:///etc/hosts" extracts path = "etc/hosts"
/// ```
public struct ManagedResourceTemplate: Sendable {
    /// The URI template pattern (e.g., "file:///{path}").
    public let uriTemplate: String

    /// The template definition for listings.
    public let definition: Resource.Template

    /// Handler to read the resource given extracted variables.
    private let readHandler: @Sendable (String, [String: String]) async throws -> Resource.Contents

    /// Optional handler to list resources matching this template.
    private let listHandler: (@Sendable () async throws -> [Resource])?

    /// Creates a new resource template.
    public init(
        uriTemplate: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        list: (@Sendable () async throws -> [Resource])? = nil,
        read: @escaping @Sendable (String, [String: String]) async throws -> Resource.Contents
    ) {
        self.uriTemplate = uriTemplate
        definition = Resource.Template(
            uriTemplate: uriTemplate,
            name: name,
            description: description,
            mimeType: mimeType
        )
        readHandler = read
        listHandler = list
    }

    /// Attempts to match a URI against this template.
    /// Returns extracted variables if successful, nil otherwise.
    public func match(_ uri: String) -> [String: String]? {
        // Convert template to regex pattern
        var pattern = NSRegularExpression.escapedPattern(for: uriTemplate)
        // Replace {variable} with named capture groups
        pattern = pattern.replacingOccurrences(
            of: "\\\\\\{([^}]+)\\\\\\}",
            with: "(?<$1>[^/]+)",
            options: .regularExpression
        )
        pattern = "^" + pattern + "$"

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: uri,
                  range: NSRange(uri.startIndex..., in: uri)
              )
        else {
            return nil
        }

        var variables: [String: String] = [:]
        for name in extractVariableNames() {
            if let range = Range(match.range(withName: name), in: uri) {
                let raw = String(uri[range])
                variables[name] = raw.removingPercentEncoding ?? raw
            }
        }
        return variables
    }

    /// Reads the resource at the given URI with extracted variables.
    public func read(uri: String, variables: [String: String]) async throws -> Resource.Contents {
        try await readHandler(uri, variables)
    }

    /// Lists resources matching this template (if list handler provided).
    public func list() async throws -> [Resource]? {
        try await listHandler?()
    }

    private func extractVariableNames() -> [String] {
        let pattern = "\\{([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(
            in: uriTemplate,
            range: NSRange(uriTemplate.startIndex..., in: uriTemplate)
        )
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: uriTemplate) else { return nil }
            return String(uriTemplate[range])
        }
    }
}

// MARK: - ResourceRegistry Actor

/// Registry for managing resources and resource templates.
public actor ResourceRegistry {
    /// Internal storage for static resources.
    private struct ResourceEntry: Sendable {
        let provider: any ResourceProvider
        var enabled: Bool = true
    }

    /// Internal storage for resource templates.
    private struct TemplateEntry: Sendable {
        let template: ManagedResourceTemplate
        var enabled: Bool = true
    }

    /// Static resources keyed by URI.
    private var resources: [String: ResourceEntry] = [:]

    /// Resource templates keyed by template URI pattern.
    private var templates: [String: TemplateEntry] = [:]

    /// Creates an empty registry.
    public init() {}

    // MARK: - Static Resources

    /// Registers a static resource.
    ///
    /// - Parameters:
    ///   - resource: The resource provider to register.
    ///   - onListChanged: Optional callback for list change notifications.
    /// - Returns: A `RegisteredResource` for managing the resource.
    /// - Throws: `MCPError.invalidParams` if a resource with the same URI already exists.
    @discardableResult
    public func register(
        _ resource: any ResourceProvider,
        onListChanged: (@Sendable () async -> Void)? = nil
    ) throws -> RegisteredResource {
        let uri = resource.definition.uri
        guard resources[uri] == nil else {
            throw MCPError.invalidParams("Resource '\(uri)' is already registered")
        }
        resources[uri] = ResourceEntry(provider: resource)
        return RegisteredResource(uri: uri, registry: self, onListChanged: onListChanged)
    }

    /// Registers a resource with a closure handler.
    ///
    /// - Parameters:
    ///   - uri: The resource URI.
    ///   - name: The resource name.
    ///   - description: Optional description.
    ///   - mimeType: Optional MIME type.
    ///   - onListChanged: Optional callback for list change notifications.
    ///   - read: The handler to read the resource contents.
    /// - Returns: A `RegisteredResource` for managing the resource.
    /// - Throws: `MCPError.invalidParams` if a resource with the same URI already exists.
    @discardableResult
    public func register(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        onListChanged: (@Sendable () async -> Void)? = nil,
        read: @escaping @Sendable () async throws -> Resource.Contents
    ) throws -> RegisteredResource {
        let resource = FunctionResource(
            uri: uri,
            name: name,
            description: description,
            mimeType: mimeType,
            read: read
        )
        return try register(resource, onListChanged: onListChanged)
    }

    // MARK: - Templates

    /// Registers a resource template.
    ///
    /// - Parameters:
    ///   - template: The resource template to register.
    ///   - onListChanged: Optional callback for list change notifications.
    /// - Returns: A `RegisteredResourceTemplate` for managing the template.
    /// - Throws: `MCPError.invalidParams` if a template with the same URI pattern already exists.
    @discardableResult
    public func register(
        _ template: ManagedResourceTemplate,
        onListChanged: (@Sendable () async -> Void)? = nil
    ) throws -> RegisteredResourceTemplate {
        guard templates[template.uriTemplate] == nil else {
            throw MCPError.invalidParams("Resource template '\(template.uriTemplate)' is already registered")
        }
        templates[template.uriTemplate] = TemplateEntry(template: template)
        return RegisteredResourceTemplate(uriTemplate: template.uriTemplate, registry: self, onListChanged: onListChanged)
    }

    /// Registers a template with a closure handler.
    ///
    /// - Parameters:
    ///   - uriTemplate: The URI template pattern.
    ///   - name: The template name.
    ///   - description: Optional description.
    ///   - mimeType: Optional MIME type.
    ///   - list: Optional handler to list resources matching this template.
    ///   - onListChanged: Optional callback for list change notifications.
    ///   - read: The handler to read resources matching this template.
    /// - Returns: A `RegisteredResourceTemplate` for managing the template.
    /// - Throws: `MCPError.invalidParams` if a template with the same URI pattern already exists.
    @discardableResult
    public func registerTemplate(
        uriTemplate: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        list: (@Sendable () async throws -> [Resource])? = nil,
        onListChanged: (@Sendable () async -> Void)? = nil,
        read: @escaping @Sendable (String, [String: String]) async throws -> Resource.Contents
    ) throws -> RegisteredResourceTemplate {
        let template = ManagedResourceTemplate(
            uriTemplate: uriTemplate,
            name: name,
            description: description,
            mimeType: mimeType,
            list: list,
            read: read
        )
        return try register(template, onListChanged: onListChanged)
    }

    // MARK: - Lookup

    /// Lists all registered resources (static only).
    public func listResources() -> [Resource] {
        resources.values
            .filter { $0.enabled }
            .map { $0.provider.definition }
    }

    /// Lists all registered templates.
    public func listTemplates() -> [Resource.Template] {
        templates.values
            .filter { $0.enabled }
            .map { $0.template.definition }
    }

    /// Lists resources from templates that have list handlers.
    public func listTemplateResources() async throws -> [Resource] {
        var result: [Resource] = []
        for entry in templates.values where entry.enabled {
            if let listed = try await entry.template.list() {
                result.append(contentsOf: listed)
            }
        }
        return result
    }

    /// Reads a resource by URI.
    ///
    /// Checks static resources first, then templates.
    public func read(uri: String) async throws -> Resource.Contents {
        // Check static resources first
        if let entry = resources[uri] {
            guard entry.enabled else {
                throw MCPError.invalidParams("Resource '\(uri)' is disabled")
            }
            return try await entry.provider.read()
        }

        // Check templates
        for entry in templates.values where entry.enabled {
            if let variables = entry.template.match(uri) {
                return try await entry.template.read(uri: uri, variables: variables)
            }
        }

        throw MCPError.resourceNotFound(uri: uri)
    }

    /// Checks if a resource exists.
    public func hasResource(_ uri: String) -> Bool {
        if resources[uri] != nil { return true }
        for entry in templates.values {
            if entry.template.match(uri) != nil { return true }
        }
        return false
    }

    // MARK: - Resource Management (Internal)

    func isResourceEnabled(_ uri: String) -> Bool {
        resources[uri]?.enabled ?? false
    }

    func resourceDefinition(for uri: String) -> Resource? {
        resources[uri]?.provider.definition
    }

    func enableResource(_ uri: String) {
        resources[uri]?.enabled = true
    }

    func disableResource(_ uri: String) {
        resources[uri]?.enabled = false
    }

    func removeResource(_ uri: String) {
        resources.removeValue(forKey: uri)
    }

    // MARK: - Template Management (Internal)

    func isTemplateEnabled(_ uriTemplate: String) -> Bool {
        templates[uriTemplate]?.enabled ?? false
    }

    func templateDefinition(for uriTemplate: String) -> Resource.Template? {
        templates[uriTemplate]?.template.definition
    }

    func enableTemplate(_ uriTemplate: String) {
        templates[uriTemplate]?.enabled = true
    }

    func disableTemplate(_ uriTemplate: String) {
        templates[uriTemplate]?.enabled = false
    }

    func removeTemplate(_ uriTemplate: String) {
        templates.removeValue(forKey: uriTemplate)
    }
}

// MARK: - Registered Resource Types

/// A registered resource providing enable/disable/remove operations.
public struct RegisteredResource: Sendable {
    /// The resource URI.
    public let uri: String

    /// Reference to the registry for mutations.
    private let registry: ResourceRegistry

    /// Optional callback to notify when the resource list changes.
    private let onListChanged: (@Sendable () async -> Void)?

    init(uri: String, registry: ResourceRegistry, onListChanged: (@Sendable () async -> Void)? = nil) {
        self.uri = uri
        self.registry = registry
        self.onListChanged = onListChanged
    }

    /// Whether the resource is currently enabled.
    public var isEnabled: Bool {
        get async { await registry.isResourceEnabled(uri) }
    }

    /// The resource definition.
    public var definition: Resource? {
        get async { await registry.resourceDefinition(for: uri) }
    }

    /// Enables the resource.
    public func enable() async {
        await registry.enableResource(uri)
        await onListChanged?()
    }

    /// Disables the resource.
    public func disable() async {
        await registry.disableResource(uri)
        await onListChanged?()
    }

    /// Removes the resource from the registry.
    public func remove() async {
        await registry.removeResource(uri)
        await onListChanged?()
    }
}

/// A registered resource template providing enable/disable/remove operations.
public struct RegisteredResourceTemplate: Sendable {
    /// The template URI pattern.
    public let uriTemplate: String

    /// Reference to the registry for mutations.
    private let registry: ResourceRegistry

    /// Optional callback to notify when the resource list changes.
    private let onListChanged: (@Sendable () async -> Void)?

    init(uriTemplate: String, registry: ResourceRegistry, onListChanged: (@Sendable () async -> Void)? = nil) {
        self.uriTemplate = uriTemplate
        self.registry = registry
        self.onListChanged = onListChanged
    }

    /// Whether the template is currently enabled.
    public var isEnabled: Bool {
        get async { await registry.isTemplateEnabled(uriTemplate) }
    }

    /// The template definition.
    public var definition: Resource.Template? {
        get async { await registry.templateDefinition(for: uriTemplate) }
    }

    /// Enables the template.
    public func enable() async {
        await registry.enableTemplate(uriTemplate)
        await onListChanged?()
    }

    /// Disables the template.
    public func disable() async {
        await registry.disableTemplate(uriTemplate)
        await onListChanged?()
    }

    /// Removes the template from the registry.
    public func remove() async {
        await registry.removeTemplate(uriTemplate)
        await onListChanged?()
    }
}
