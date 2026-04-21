// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Foundation

/// The Model Context Protocol (MCP) provides a standardized way
/// for servers to expose prompt templates to clients.
/// Prompts allow servers to provide structured messages and instructions
/// for interacting with language models.
/// Clients can discover available prompts, retrieve their contents,
/// and provide arguments to customize them.
///
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/server/prompts/
public struct Prompt: Hashable, Codable, Sendable {
    /// The prompt name (intended for programmatic or logical use)
    public let name: String
    /// A human-readable title for the prompt, intended for UI display.
    /// If not provided, the `name` should be used for display.
    public let title: String?
    /// The prompt description
    public let description: String?
    /// The prompt arguments
    public let arguments: [Argument]?
    /// Reserved for clients and servers to attach additional metadata.
    public var _meta: [String: Value]?
    /// Optional icons representing this prompt.
    public var icons: [Icon]?

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        arguments: [Argument]? = nil,
        _meta: [String: Value]? = nil,
        icons: [Icon]? = nil,
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
        self._meta = _meta
        self.icons = icons
    }

    /// An argument for a prompt
    public struct Argument: Hashable, Codable, Sendable {
        /// The argument name (intended for programmatic or logical use)
        public let name: String
        /// A human-readable title for the argument, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public let title: String?
        /// The argument description
        public let description: String?
        /// Whether the argument is required
        public let required: Bool?

        public init(
            name: String,
            title: String? = nil,
            description: String? = nil,
            required: Bool? = nil,
        ) {
            self.name = name
            self.title = title
            self.description = description
            self.required = required
        }
    }

    /// A message in a prompt
    public struct Message: Hashable, Codable, Sendable {
        /// The message role
        public let role: Role
        /// The message content
        public let content: ContentBlock

        private init(role: Role, content: ContentBlock) {
            self.role = role
            self.content = content
        }

        /// Creates a user message with the specified content
        public static func user(_ content: ContentBlock) -> Message {
            Message(role: .user, content: content)
        }

        /// Creates an assistant message with the specified content
        public static func assistant(_ content: ContentBlock) -> Message {
            Message(role: .assistant, content: content)
        }
    }

    /// Reference type for prompts
    public struct Reference: Hashable, Codable, Sendable {
        /// The prompt reference name
        public let name: String
        /// A human-readable title for the prompt, intended for UI display.
        /// If not provided, the `name` should be used for display.
        public let title: String?

        public init(name: String, title: String? = nil) {
            self.name = name
            self.title = title
        }

        private enum CodingKeys: String, CodingKey {
            case type, name, title
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("ref/prompt", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(title, forKey: .title)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            _ = try container.decode(String.self, forKey: .type)
            name = try container.decode(String.self, forKey: .name)
            title = try container.decodeIfPresent(String.self, forKey: .title)
        }
    }
}

// MARK: -

/// To retrieve available prompts, clients send a `prompts/list` request.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#listing-prompts
public enum ListPrompts: Method {
    public static let name: String = "prompts/list"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        public let cursor: String?
        /// Request metadata including progress token.
        public let _meta: RequestMeta?

        public init() {
            cursor = nil
            _meta = nil
        }

        public init(cursor: String? = nil, _meta: RequestMeta? = nil) {
            self.cursor = cursor
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let prompts: [Prompt]
        public let nextCursor: String?
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            prompts: [Prompt],
            nextCursor: String? = nil,
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil,
        ) {
            self.prompts = prompts
            self.nextCursor = nextCursor
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case prompts, nextCursor, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            prompts = try container.decode([Prompt].self, forKey: .prompts)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(prompts, forKey: .prompts)
            try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// To retrieve a specific prompt, clients send a `prompts/get` request.
/// Arguments may be auto-completed through the completion API.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#getting-a-prompt
public enum GetPrompt: Method {
    public static let name: String = "prompts/get"

    public struct Parameters: Hashable, Codable, Sendable {
        public let name: String
        /// Arguments to use for templating the prompt.
        /// Per the MCP spec, argument values must be strings.
        public let arguments: [String: String]?
        /// Request metadata including progress token.
        public let _meta: RequestMeta?

        public init(name: String, arguments: [String: String]? = nil, _meta: RequestMeta? = nil) {
            self.name = name
            self.arguments = arguments
            self._meta = _meta
        }
    }

    public struct Result: ResultWithExtraFields {
        public typealias ResultCodingKeys = CodingKeys

        public let description: String?
        public let messages: [Prompt.Message]
        /// Reserved for clients and servers to attach additional metadata.
        public var _meta: [String: Value]?
        /// Additional fields not defined in the schema (for forward compatibility).
        public var extraFields: [String: Value]?

        public init(
            description: String?,
            messages: [Prompt.Message],
            _meta: [String: Value]? = nil,
            extraFields: [String: Value]? = nil,
        ) {
            self.description = description
            self.messages = messages
            self._meta = _meta
            self.extraFields = extraFields
        }

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case description, messages, _meta
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            messages = try container.decode([Prompt.Message].self, forKey: .messages)
            _meta = try container.decodeIfPresent([String: Value].self, forKey: ._meta)
            extraFields = try Self.decodeExtraFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(_meta, forKey: ._meta)
            try encodeExtraFields(to: encoder)
        }
    }
}

/// When the list of available prompts changes, servers that declared the listChanged capability SHOULD send a notification.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/server/prompts/#list-changed-notification
public struct PromptListChangedNotification: Notification {
    public static let name: String = "notifications/prompts/list_changed"

    public typealias Parameters = NotificationParams

    public init() {}
}
