// Copyright © Anthony DePasquale

import Foundation

// MARK: - Server Capabilities

public extension Server.Capabilities {
    /// Tasks capabilities for servers.
    ///
    /// Servers advertise these capabilities during initialization to indicate
    /// what task-related features they support.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let capabilities = Server.Capabilities(
    ///     tasks: .init(
    ///         list: .init(),
    ///         cancel: .init(),
    ///         requests: .init(tools: .init(call: .init()))
    ///     )
    /// )
    /// ```
    struct Tasks: Hashable, Codable, Sendable {
        /// Capability marker for list operations.
        public struct List: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Capability marker for cancel operations.
        public struct Cancel: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Task-augmented request capabilities.
        public struct Requests: Hashable, Codable, Sendable {
            /// Tools request capabilities.
            public struct Tools: Hashable, Codable, Sendable {
                /// Capability marker for task-augmented tools/call.
                public struct Call: Hashable, Codable, Sendable {
                    public init() {}
                }

                /// Whether task-augmented tools/call is supported.
                public var call: Call?

                public init(call: Call? = nil) {
                    self.call = call
                }
            }

            /// Whether task-augmented tools requests are supported.
            public var tools: Tools?

            public init(tools: Tools? = nil) {
                self.tools = tools
            }
        }

        /// Whether the server supports tasks/list.
        public var list: List?
        /// Whether the server supports tasks/cancel.
        public var cancel: Cancel?
        /// Task-augmented request capabilities.
        public var requests: Requests?

        public init(
            list: List? = nil,
            cancel: Cancel? = nil,
            requests: Requests? = nil,
        ) {
            self.list = list
            self.cancel = cancel
            self.requests = requests
        }

        /// Convenience initializer for full task support.
        ///
        /// Creates a capability declaration with list, cancel, and task-augmented tools/call.
        public static func full() -> Tasks {
            Tasks(
                list: List(),
                cancel: Cancel(),
                requests: Requests(tools: .init(call: .init())),
            )
        }
    }
}

// MARK: - Client Capabilities

public extension Client.Capabilities {
    /// Tasks capabilities for clients.
    ///
    /// Clients advertise these capabilities during initialization to indicate
    /// what task-related features they support. This is for bidirectional task
    /// support where servers can initiate tasks on clients.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let capabilities = Client.Capabilities(
    ///     tasks: .init(
    ///         list: .init(),
    ///         cancel: .init(),
    ///         requests: .init(
    ///             sampling: .init(createMessage: .init()),
    ///             elicitation: .init(create: .init())
    ///         )
    ///     )
    /// )
    /// ```
    struct Tasks: Hashable, Codable, Sendable {
        /// Capability marker for list operations.
        public struct List: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Capability marker for cancel operations.
        public struct Cancel: Hashable, Codable, Sendable {
            public init() {}
        }

        /// Task-augmented request capabilities for client.
        public struct Requests: Hashable, Codable, Sendable {
            /// Sampling request capabilities.
            public struct Sampling: Hashable, Codable, Sendable {
                /// Capability marker for task-augmented sampling/createMessage.
                public struct CreateMessage: Hashable, Codable, Sendable {
                    public init() {}
                }

                /// Whether task-augmented sampling/createMessage is supported.
                public var createMessage: CreateMessage?

                public init(createMessage: CreateMessage? = nil) {
                    self.createMessage = createMessage
                }
            }

            /// Elicitation request capabilities.
            public struct Elicitation: Hashable, Codable, Sendable {
                /// Capability marker for task-augmented elicitation/create.
                public struct Create: Hashable, Codable, Sendable {
                    public init() {}
                }

                /// Whether task-augmented elicitation/create is supported.
                public var create: Create?

                public init(create: Create? = nil) {
                    self.create = create
                }
            }

            /// Whether task-augmented sampling requests are supported.
            public var sampling: Sampling?
            /// Whether task-augmented elicitation requests are supported.
            public var elicitation: Elicitation?

            public init(
                sampling: Sampling? = nil,
                elicitation: Elicitation? = nil,
            ) {
                self.sampling = sampling
                self.elicitation = elicitation
            }
        }

        /// Whether the client supports tasks/list.
        public var list: List?
        /// Whether the client supports tasks/cancel.
        public var cancel: Cancel?
        /// Task-augmented request capabilities.
        public var requests: Requests?

        public init(
            list: List? = nil,
            cancel: Cancel? = nil,
            requests: Requests? = nil,
        ) {
            self.list = list
            self.cancel = cancel
            self.requests = requests
        }

        /// Convenience initializer for full task support.
        ///
        /// Creates a capability declaration with list, cancel, and all task-augmented requests.
        public static func full() -> Tasks {
            Tasks(
                list: List(),
                cancel: Cancel(),
                requests: Requests(
                    sampling: .init(createMessage: .init()),
                    elicitation: .init(create: .init()),
                ),
            )
        }
    }
}

// MARK: - Capability Checking Helpers

/// Check if server capabilities include task-augmented tools/call support.
///
/// - Parameter caps: The server capabilities
/// - Returns: True if task-augmented tools/call is supported
public func hasTaskAugmentedToolsCall(_ caps: Server.Capabilities?) -> Bool {
    caps?.tasks?.requests?.tools?.call != nil
}

/// Check if client capabilities include task-augmented elicitation support.
///
/// - Parameter caps: The client capabilities
/// - Returns: True if task-augmented elicitation/create is supported
public func hasTaskAugmentedElicitation(_ caps: Client.Capabilities?) -> Bool {
    caps?.tasks?.requests?.elicitation?.create != nil
}

/// Check if client capabilities include task-augmented sampling support.
///
/// - Parameter caps: The client capabilities
/// - Returns: True if task-augmented sampling/createMessage is supported
public func hasTaskAugmentedSampling(_ caps: Client.Capabilities?) -> Bool {
    caps?.tasks?.requests?.sampling?.createMessage != nil
}

/// Require task-augmented elicitation support from client.
///
/// - Parameter caps: The client capabilities
/// - Throws: MCPError if client doesn't support task-augmented elicitation
public func requireTaskAugmentedElicitation(_ caps: Client.Capabilities?) throws {
    if !hasTaskAugmentedElicitation(caps) {
        throw MCPError.invalidRequest("Client does not support task-augmented elicitation")
    }
}

/// Require task-augmented sampling support from client.
///
/// - Parameter caps: The client capabilities
/// - Throws: MCPError if client doesn't support task-augmented sampling
public func requireTaskAugmentedSampling(_ caps: Client.Capabilities?) throws {
    if !hasTaskAugmentedSampling(caps) {
        throw MCPError.invalidRequest("Client does not support task-augmented sampling")
    }
}

/// Require task-augmented tools/call support from server.
///
/// - Parameter caps: The server capabilities
/// - Throws: MCPError if server doesn't support task-augmented tools/call
public func requireTaskAugmentedToolsCall(_ caps: Server.Capabilities?) throws {
    if !hasTaskAugmentedToolsCall(caps) {
        throw MCPError.invalidRequest("Server does not support task-augmented tools/call")
    }
}
