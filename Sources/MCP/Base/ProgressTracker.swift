// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation

// MARK: - Progress Tracker (Server-Side)

/// An actor for tracking and sending cumulative progress during a request.
///
/// This follows the Python SDK's `ProgressContext` pattern, providing a convenient
/// way to track cumulative progress and send notifications without manually
/// tracking the current value.
///
/// ## Example
///
/// ```swift
/// server.withRequestHandler(CallTool.self) { request, context in
///     guard let token = request._meta?.progressToken else {
///         return CallTool.Result(content: [.text("Done")])
///     }
///
///     let tracker = ProgressTracker(token: token, total: 100, context: context)
///
///     try await tracker.advance(by: 25, message: "Loading...")
///     try await tracker.advance(by: 50, message: "Processing...")
///     try await tracker.advance(by: 25, message: "Completing...")
///
///     return CallTool.Result(content: [.text("Done")])
/// }
/// ```
public actor ProgressTracker {
    /// The progress token from the request.
    public let token: ProgressToken

    /// The total progress value, if known.
    public let total: Double?

    /// The request handler context for sending notifications.
    private let context: RequestHandlerContext

    /// The current cumulative progress value.
    public private(set) var current: Double = 0

    /// Creates a new progress tracker.
    ///
    /// - Parameters:
    ///   - token: The progress token from the request's `_meta.progressToken`
    ///   - total: The total progress value, if known
    ///   - context: The request handler context for sending notifications
    public init(
        token: ProgressToken,
        total: Double? = nil,
        context: RequestHandlerContext,
    ) {
        self.token = token
        self.total = total
        self.context = context
    }

    /// Advance progress by the given amount and send a notification.
    ///
    /// - Parameters:
    ///   - amount: The amount to add to the current progress
    ///   - message: An optional human-readable message describing current progress
    public func advance(by amount: Double, message: String? = nil) async throws {
        current += amount
        try await context.sendProgress(
            token: token,
            progress: current,
            total: total,
            message: message,
        )
    }

    /// Set progress to a specific value and send a notification.
    ///
    /// Use this when you want to set progress to an absolute value rather than
    /// incrementing. The progress value should still increase monotonically.
    ///
    /// - Parameters:
    ///   - value: The new progress value
    ///   - message: An optional human-readable message describing current progress
    public func set(to value: Double, message: String? = nil) async throws {
        current = value
        try await context.sendProgress(
            token: token,
            progress: current,
            total: total,
            message: message,
        )
    }

    /// Send a progress notification without changing the current value.
    ///
    /// Use this to update the message without changing the progress value.
    ///
    /// - Parameter message: A human-readable message describing current progress
    public func update(message: String) async throws {
        try await context.sendProgress(
            token: token,
            progress: current,
            total: total,
            message: message,
        )
    }
}
