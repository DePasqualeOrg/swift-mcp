// Copyright © Anthony DePasquale

/// Progress tracking for long-running operations.
///
/// Clients can include a `progressToken` in request metadata (`_meta.progressToken`)
/// to receive progress notifications during operation execution.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/progress/

/// Metadata that can be attached to any request via the `_meta` field.
///
/// This is used primarily for progress tracking, but can also carry
/// arbitrary additional metadata.
public struct RequestMeta: Hashable, Codable, Sendable {
    /// If specified, the caller is requesting out-of-band progress notifications
    /// for this request. The value is an opaque token that will be attached to
    /// any subsequent progress notifications.
    public var progressToken: ProgressToken?

    /// Additional metadata fields.
    public var additionalFields: [String: Value]?

    public init(
        progressToken: ProgressToken? = nil,
        additionalFields: [String: Value]? = nil,
    ) {
        self.progressToken = progressToken
        self.additionalFields = additionalFields
    }

    // MARK: - Convenience Accessors

    /// The related task ID, if present.
    ///
    /// Extracts the task ID from `_meta["io.modelcontextprotocol/related-task"].taskId`.
    /// This matches the TypeScript SDK's `_meta[RELATED_TASK_META_KEY]?.taskId`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let taskId = context._meta?.relatedTaskId {
    ///     print("Request is part of task: \(taskId)")
    /// }
    /// ```
    ///
    /// - Note: For the full `RelatedTaskMetadata` struct, use the experimental tasks API.
    public var relatedTaskId: String? {
        guard let metaValue = additionalFields?["io.modelcontextprotocol/related-task"],
              case let .object(dict) = metaValue,
              let taskIdValue = dict["taskId"],
              let taskId = taskIdValue.stringValue
        else {
            return nil
        }
        return taskId
    }

    private enum CodingKeys: String, CodingKey {
        case progressToken
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        progressToken = try container.decodeIfPresent(ProgressToken.self, forKey: .progressToken)

        // Decode additional fields
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var extra: [String: Value] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue == CodingKeys.progressToken.stringValue {
                continue
            }
            if let value = try? dynamicContainer.decode(Value.self, forKey: key) {
                extra[key.stringValue] = value
            }
        }
        additionalFields = extra.isEmpty ? nil : extra
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(progressToken, forKey: .progressToken)

        // Encode additional fields
        if let additional = additionalFields {
            var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in additional {
                if let codingKey = DynamicCodingKey(stringValue: key) {
                    try dynamicContainer.encode(value, forKey: codingKey)
                }
            }
        }
    }
}

/// A token used to associate progress notifications with a specific request.
///
/// Progress tokens can be either strings or integers.
public enum ProgressToken: Hashable, Sendable {
    case string(String)
    case integer(Int)
}

extension ProgressToken: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                ProgressToken.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string or integer for ProgressToken",
                ),
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case let .string(value):
                try container.encode(value)
            case let .integer(value):
                try container.encode(value)
        }
    }
}

extension ProgressToken: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension ProgressToken: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

/// Notification sent to report progress on a long-running operation.
///
/// Servers send progress notifications to inform clients about the status
/// of operations that may take significant time to complete.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2025-11-25/utilities/progress/
public struct ProgressNotification: Notification {
    public static let name: String = "notifications/progress"

    public struct Parameters: Hashable, Codable, Sendable {
        /// The progress token from the original request's `_meta.progressToken`.
        public let progressToken: ProgressToken

        /// The current progress value. Should increase monotonically.
        public let progress: Double

        /// The total progress value, if known.
        public let total: Double?

        /// An optional human-readable message describing the current progress.
        public let message: String?

        /// Reserved for additional metadata.
        public var _meta: [String: Value]?

        public init(
            progressToken: ProgressToken,
            progress: Double,
            total: Double? = nil,
            message: String? = nil,
            _meta: [String: Value]? = nil,
        ) {
            self.progressToken = progressToken
            self.progress = progress
            self.total = total
            self.message = message
            self._meta = _meta
        }
    }
}

// MARK: - Progress Callback

/// Progress information received during a long-running operation.
///
/// This struct is passed to progress callbacks when using `send(_:onProgress:)`.
public struct Progress: Sendable, Hashable {
    /// The current progress value. Increases monotonically.
    public let value: Double

    /// The total progress value, if known.
    public let total: Double?

    /// An optional human-readable message describing current progress.
    public let message: String?

    public init(value: Double, total: Double? = nil, message: String? = nil) {
        self.value = value
        self.total = total
        self.message = message
    }
}

/// A callback invoked when a progress notification is received.
///
/// This is used by the client to receive progress updates for specific requests
/// when using `send(_:onProgress:)`.
public typealias ProgressCallback = @Sendable (Progress) async -> Void
