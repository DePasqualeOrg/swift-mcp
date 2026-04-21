# Resources

Register resources that clients can read and subscribe to.

## Overview

Resources represent data that your server exposes to clients. Each resource has a URI and content. Clients can list resources, read their contents, and optionally subscribe to updates.

## Registering Resources

Use ``MCPServer`` to register resources with a closure that returns the content:

```swift
let server = MCPServer(name: "MyServer", version: "1.0.0")

let resource = try await server.registerResource(
    uri: "config://app",
    name: "Configuration",
    description: "Application configuration",
    mimeType: "application/json"
) {
    let config = loadConfiguration()
    return .text(config.jsonString, uri: "config://app", mimeType: "application/json")
}
```

The closure is called each time a client reads the resource, so content is always fresh.

## Resource Content Types

### Text Content

```swift
try await server.registerResource(
    uri: "logs://recent",
    name: "Recent Logs"
) {
    .text(recentLogs, uri: "logs://recent", mimeType: "text/plain")
}
```

### Binary Content

```swift
try await server.registerResource(
    uri: "chart://sales",
    name: "Sales Chart",
    mimeType: "image/png"
) {
    let chartData = generateChart()
    return .binary(chartData, uri: "chart://sales", mimeType: "image/png")
}
```

## File Resources

For file-backed resources, you can register with a closure that reads the file:

```swift
try await server.registerResource(
    uri: "file:///etc/config.json",
    name: "config.json",
    mimeType: "application/json"
) {
    let data = try Data(contentsOf: URL(fileURLWithPath: "/etc/config.json"))
    let content = String(data: data, encoding: .utf8) ?? ""
    return .text(content, uri: "file:///etc/config.json", mimeType: "application/json")
}
```

For lower-level file handling with automatic MIME type inference, use ``FileResource`` via the resource registry. See <doc:server-advanced>.

## Resource Templates

For dynamic resources where the URI contains variables, register a template:

```swift
let template = try await server.registerResourceTemplate(
    uriTemplate: "user://{userId}/profile",
    name: "User Profile",
    description: "User profile data"
) { uri, variables in
    let userId = variables["userId"]!
    let profile = await loadUserProfile(userId)
    return .text(profile.json, uri: uri, mimeType: "application/json")
}
```

Clients see the template in `listResourceTemplates` and substitute variables to construct URIs for reading.

### Template Variables

Template URIs use `{variableName}` placeholders that are extracted when matching:

```swift
// Template: "file:///{path}"
// URI: "file:///documents/report.pdf"
// variables["path"] == "documents/report.pdf"
```

## Resource Lifecycle

Registered resources return a handle for lifecycle management:

```swift
let resource = try await server.registerResource(...)

// Temporarily hide from clients
await resource.disable()

// Make available again
await resource.enable()

// Permanently remove
await resource.remove()
```

Disabled resources don't appear in `listResources` responses and reject read attempts.

## Resource Metadata

Resources support optional metadata:

```swift
try await server.registerResource(
    uri: "file:///docs/report.pdf",
    name: "Monthly Report",
    description: "Monthly sales report",
    mimeType: "application/pdf"
) { ... }
```

## Resource Annotations

Resources can include annotations to indicate audience (`user`, `assistant`, or both), priority (0.0 to 1.0), and last modified timestamp. For setting annotations, use the low-level API with the ``/MCPCore/Resource`` type directly. See <doc:server-advanced>.

## Notifying Changes

``MCPServer`` automatically sends list change notifications when resources are registered, enabled, disabled, or removed. To send manually:

```swift
// From within a request handler
try await context.sendResourceListChanged()

// From outside a handler (low-level Server)
try await server.sendResourceListChanged()
```

## Resource Subscriptions

Resource subscriptions allow clients to be notified when content changes. This requires implementing subscription handlers on the low-level ``Server``. See <doc:server-advanced> for details.

## Complete Example

```swift
let server = MCPServer(name: "FileServer", version: "1.0.0")

// Static configuration resource
try await server.registerResource(
    uri: "config://app",
    name: "App Config",
    mimeType: "application/json"
) {
    .text(appConfig.json, uri: "config://app", mimeType: "application/json")
}

// File-backed resource
try await server.registerResource(
    uri: "file:///project/README.md",
    name: "README",
    mimeType: "text/markdown"
) {
    let content = try String(contentsOfFile: "/project/README.md")
    return .text(content, uri: "file:///project/README.md", mimeType: "text/markdown")
}

// Dynamic user data via template
try await server.registerResourceTemplate(
    uriTemplate: "user://{userId}/settings",
    name: "User Settings"
) { uri, variables in
    let settings = await loadSettings(for: variables["userId"]!)
    return .text(settings.json, uri: uri)
}

// Connect and run
try await server.run(transport: .stdio)
```

## Low-Level API

For advanced use cases like resource subscriptions or custom request handling, see <doc:server-advanced> for the manual `withRequestHandler` approach.

## See Also

- <doc:server-setup>
- <doc:client-resources>
- ``MCPServer``
- ``/MCPCore/Resource``
- ``FileResource``
