// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

/// The Model Context Protocol includes an optional ping mechanism that allows either party to verify that their counterpart is still responsive and the connection is alive.
/// - SeeAlso: https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/utilities/ping
public enum Ping: Method {
    public static let name: String = "ping"

    public struct Parameters: NotRequired, Hashable, Codable, Sendable {
        /// Request metadata including progress token.
        public let _meta: RequestMeta?

        public init() {
            _meta = nil
        }

        public init(_meta: RequestMeta?) {
            self._meta = _meta
        }
    }
}
