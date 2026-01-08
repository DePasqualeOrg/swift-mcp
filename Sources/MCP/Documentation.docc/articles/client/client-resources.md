# Resources

Read and subscribe to resources provided by MCP servers

## Overview

Resources represent data that servers expose to clients, such as files, database schemas, or application-specific information. Each resource is identified by a URI. This guide covers listing, reading, and subscribing to resources.

## Listing Resources

Use ``Client/listResources(cursor:)`` to discover available resources:

```swift
let result = try await client.listResources()
for resource in result.resources {
    print("\(resource.uri): \(resource.name)")
}
```

### Pagination

For servers with many resources, use the cursor:

```swift
var cursor: String? = nil
repeat {
    let result = try await client.listResources(cursor: cursor)
    for resource in result.resources {
        print(resource.name)
    }
    cursor = result.nextCursor
} while cursor != nil
```

## Reading Resources

Use ``Client/readResource(uri:)`` to retrieve resource contents:

```swift
let result = try await client.readResource(uri: "file:///path/to/file.txt")
for content in result.contents {
    if let text = content.text {
        print(text)
    } else if let blob = content.blob {
        // Binary data as base64
        print("Binary data: \(blob.count) chars")
    }
}
```

## Resource Templates

Resource templates define patterns for dynamic URIs. List available templates with ``Client/listResourceTemplates(cursor:)``:

```swift
let result = try await client.listResourceTemplates()
for template in result.templates {
    print("\(template.uriTemplate): \(template.name)")
    // Example: "users://{userId}/profile" - substitute userId to read
}
```

To use a template, construct a URI by substituting the template variables, then call `readResource`:

```swift
// If template is "users://{userId}/profile"
let uri = "users://123/profile"
let result = try await client.readResource(uri: uri)
```

## Subscribing to Resources

If the server supports subscriptions, you can receive notifications when resources change.

### Subscribe to a Resource

```swift
try await client.subscribeToResource(uri: "file:///config.json")
```

### Handle Update Notifications

```swift
await client.onNotification(ResourceUpdatedNotification.self) { message in
    print("Resource updated: \(message.params.uri)")

    // Fetch the updated content
    let updated = try await client.readResource(uri: message.params.uri)
    for content in updated.contents {
        if let text = content.text {
            print("New content: \(text)")
        }
    }
}
```

### Unsubscribe

```swift
try await client.unsubscribeFromResource(uri: "file:///config.json")
```

## Listening for Resource List Changes

Servers can notify clients when the list of available resources changes:

```swift
await client.onNotification(ResourceListChangedNotification.self) { _ in
    // Refresh the resource list
    let updated = try await client.listResources()
    print("Resources updated: \(updated.resources.count) resources available")
}
```

## See Also

- <doc:client-setup>
- <doc:server-resources>
- ``Client``
- ``Resource``
