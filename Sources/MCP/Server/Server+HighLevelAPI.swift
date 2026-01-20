/// Server extensions for high-level API support.
///
/// These methods are primarily used by `MCPServer` but are public for
/// advanced use cases that need to set capabilities programmatically.
public extension Server {
    /// Sets the tools capability.
    ///
    /// - Parameter capability: The tools capability to set.
    func setToolsCapability(_ capability: Capabilities.Tools) {
        capabilities.tools = capability
    }

    /// Sets the resources capability.
    ///
    /// - Parameter capability: The resources capability to set.
    func setResourcesCapability(_ capability: Capabilities.Resources) {
        capabilities.resources = capability
    }

    /// Sets the prompts capability.
    ///
    /// - Parameter capability: The prompts capability to set.
    func setPromptsCapability(_ capability: Capabilities.Prompts) {
        capabilities.prompts = capability
    }

    /// Sets the logging capability.
    ///
    /// - Parameter capability: The logging capability to set.
    func setLoggingCapability(_ capability: Capabilities.Logging) {
        capabilities.logging = capability
    }
}
