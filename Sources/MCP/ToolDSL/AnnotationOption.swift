// Copyright © Anthony DePasquale

/// Options for annotating MCP tool behavior.
///
/// Annotations provide hints about a tool's characteristics. They are used by MCP clients
/// to make decisions about tool execution (e.g., showing confirmation dialogs for
/// destructive tools).
///
/// When the `annotations` array is empty (the default), MCP implicit defaults apply:
/// - `readOnlyHint: false` – tool may modify state
/// - `destructiveHint: true` – tool may destroy data
/// - `idempotentHint: false` – repeated calls may have different effects
/// - `openWorldHint: true` – tool interacts with external systems
///
/// Example:
/// ```swift
/// @Tool
/// struct GetCalendars {
///     static let name = "get_calendars"
///     static let description = "Get all available calendars"
///     static let annotations: [AnnotationOption] = [.readOnly]
///     // ...
/// }
///
/// @Tool
/// struct DeleteEvent {
///     static let name = "delete_event"
///     static let description = "Delete a calendar event"
///     static let annotations: [AnnotationOption] = [.idempotent, .title("Delete Event")]
///     // No .readOnly → destructive is the implicit default
///     // ...
/// }
/// ```
public enum AnnotationOption: Sendable, Equatable {
    /// Tool only reads data, has no side effects.
    /// Automatically implies non-destructive and idempotent.
    case readOnly

    /// Tool can be safely called multiple times with the same result.
    case idempotent

    /// Tool does not interact with external systems (closed world).
    case closedWorld

    /// Human-readable title for UI display.
    case title(String)
}

public extension AnnotationOption {
    /// Converts an array of `AnnotationOption` to `Tool.Annotations`.
    ///
    /// - Parameter options: The array of annotation options.
    /// - Returns: A configured `Tool.Annotations` instance.
    static func buildAnnotations(from options: [AnnotationOption]) -> Tool.Annotations {
        var annotations = Tool.Annotations()

        for option in options {
            switch option {
                case .readOnly:
                    annotations.readOnlyHint = true
                    annotations.destructiveHint = false
                    annotations.idempotentHint = true
                case .idempotent:
                    annotations.idempotentHint = true
                case .closedWorld:
                    annotations.openWorldHint = false
                case let .title(t):
                    annotations.title = t
            }
        }

        return annotations
    }
}
