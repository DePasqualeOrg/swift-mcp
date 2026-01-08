# Roots

Share filesystem locations with MCP servers

## Overview

Roots allow clients to inform servers about which filesystem directories are available for operations. When a server needs to understand the scope of files it can work with, it requests the list of roots from the client.

## Declaring Roots Capability

Before providing roots, declare the capability when setting up your client:

```swift
let client = Client(name: "MyApp", version: "1.0.0")

await client.setCapabilities(Client.Capabilities(
    roots: .init(listChanged: true)  // Enable roots with change notifications
))
```

Setting `listChanged: true` indicates that your client will notify the server when roots change.

## Registering a Roots Handler

Use ``Client/withRootsHandler(_:)`` to register a handler that returns available roots:

```swift
client.withRootsHandler { context in
    [
        Root(uri: "file:///Users/john/projects", name: "Projects"),
        Root(uri: "file:///Users/john/documents", name: "Documents")
    ]
}
```

### Dynamic Roots

Return different roots based on application state:

```swift
client.withRootsHandler { context in
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
Root(uri: "/path/to/directory", name: "Missing scheme")      // No scheme
Root(uri: "https://example.com", name: "Wrong scheme")       // Wrong scheme
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
- ``Root``
