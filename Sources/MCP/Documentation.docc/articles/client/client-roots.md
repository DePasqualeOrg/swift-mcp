# Roots

Share filesystem locations with MCP servers

## Overview

Roots allow clients to inform servers about which filesystem directories are available for operations. When a server needs to understand the scope of files it can work with, it requests the list of roots from the client.

## Security Considerations

Client implementations should:

- Prompt users for consent before exposing roots to servers
- Provide clear UI for managing which directories are shared
- Validate root accessibility before exposing them
- Only expose roots with appropriate permissions

## Registering a Roots Handler

Use ``Client/withRootsHandler(listChanged:handler:)`` to register a handler that returns available roots. The roots capability is automatically advertised when you register a handler:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

// Enable roots with change notifications
await client.withRootsHandler(listChanged: true) { context in
    [
        Root(uri: "file:///Users/john/projects", name: "Projects"),
        Root(uri: "file:///Users/john/documents", name: "Documents")
    ]
}

try await client.connect(transport: transport)
```

> Important: Register handlers before calling `connect()`. Attempting to register handlers after connecting will result in an error.

Setting `listChanged: true` indicates that your client will notify the server when roots change.

## Static Roots

For clients with a fixed set of roots, use ``Client/withStaticRoots(_:)`` for a simpler API:

```swift
await client.withStaticRoots([
    Root(uri: "file:///Users/john/projects", name: "Projects"),
    Root(uri: "file:///Users/john/documents", name: "Documents")
])
```

This registers the roots capability without change notifications.

### Dynamic Roots

Return different roots based on application state:

```swift
await client.withRootsHandler { context in
    var roots: [Root] = []

    // Add the current workspace
    if let workspace = currentWorkspace {
        roots.append(Root(
            uri: "file://\(workspace.path)",
            name: workspace.name
        ))
    }

    // Add any open folders
    for folder in openFolders {
        roots.append(Root(
            uri: "file://\(folder.path)",
            name: folder.displayName
        ))
    }

    return roots
}
```

## Root Requirements

All root URIs must use the `file://` scheme:

```swift
// Valid
Root(uri: "file:///path/to/directory", name: "My Directory")

// Invalid - will fail
Root(uri: "/path/to/directory", name: "Missing scheme")  // No scheme
Root(uri: "https://example.com", name: "Wrong scheme")   // Wrong scheme
```

## Notifying Root Changes

When your available roots change, notify the server:

```swift
// After roots change (e.g., user opens a new folder)
try await client.sendRootsChanged()
```

The server will then request the updated list of roots.

> Important: Only call `sendRootsChanged()` if you declared `listChanged: true` in your roots capability.

## See Also

- <doc:client-setup>
- <doc:server-roots>
- ``Client``
- ``/MCPCore/Root``
