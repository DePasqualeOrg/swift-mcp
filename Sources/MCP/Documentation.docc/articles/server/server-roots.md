# Roots

Request filesystem roots from MCP clients

## Overview

Roots represent filesystem directories that clients make available to servers. Querying roots helps your server understand which locations it can access, enabling file-based operations within appropriate boundaries.

> Note: Roots is a client capability, not a server capability. Your server requests roots from clients that support it.

## Requesting Roots

Query the client's roots using ``Server/listRoots()``:

```swift
await server.withRequestHandler(CallTool.self) { [server] params, context in
    guard params.name == "list-files" else { ... }

    // Get roots from the client
    let roots = try await server.listRoots()

    var allFiles: [String] = []
    for root in roots {
        // root.uri is the filesystem location (e.g., "file:///Users/me/project")
        // root.name is the display name (e.g., "Project")
        let files = try listFilesIn(root.uri)
        allFiles.append(contentsOf: files)
    }

    return CallTool.Result(content: [.text("Found \(allFiles.count) files")])
}
```

## Root Properties

Each ``Root`` includes:

- `uri`: The filesystem location as a `file://` URI
- `name`: Optional human-readable name for display

```swift
let roots = try await server.listRoots()
for root in roots {
    print("Location: \(root.uri)")
    if let name = root.name {
        print("Name: \(name)")
    }
}
```

## Handling Unsupported Clients

Handle cases where clients don't support roots:

```swift
await server.withRequestHandler(CallTool.self) { [server] params, context in
    do {
        let roots = try await server.listRoots()
        // Process roots...
    } catch {
        return CallTool.Result(
            content: [.text("This tool requires roots capability")],
            isError: true
        )
    }
}
```

## Listening for Root Changes

If the client supports `roots.listChanged`, register for notifications:

```swift
await server.onNotification(RootsListChangedNotification.self) { [server] _ in
    // Client's roots have changed
    let newRoots = try await server.listRoots()
    print("Roots updated: \(newRoots.count) roots available")
}
```

## Working with Roots

### Validating Paths

Ensure operations stay within allowed roots:

```swift
func isPathWithinRoots(_ path: String, roots: [Root]) -> Bool {
    for root in roots {
        // Convert file:// URI to path
        let rootPath = root.uri.replacingOccurrences(of: "file://", with: "")
        if path.hasPrefix(rootPath) {
            return true
        }
    }
    return false
}
```

### Complete Example

```swift
await server.withRequestHandler(CallTool.self) { [server] params, context in
    guard params.name == "read-file" else { ... }

    let filePath = params.arguments?["path"]?.stringValue ?? ""

    // Get allowed roots
    let roots = try await server.listRoots()

    // Validate the path is within allowed roots
    guard isPathWithinRoots(filePath, roots: roots) else {
        return CallTool.Result(
            content: [.text("Access denied: path outside allowed roots")],
            isError: true
        )
    }

    // Read the file
    let content = try readFile(filePath)
    return CallTool.Result(content: [.text(content)])
}
```

## See Also

- <doc:server-setup>
- <doc:client-roots>
- ``Server``
- ``Root``
