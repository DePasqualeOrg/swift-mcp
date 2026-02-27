// Copyright © Anthony DePasquale

import Logging

/// Helpers for building and validating server capabilities.
///
/// This enum namespace contains static functions for capability merging and validation.
/// Unlike `ClientCapabilityHelpers`, the Server's capability inference is simpler since
/// capabilities are typically set explicitly or auto-detected by MCPServer based on
/// registration flags.
enum ServerCapabilityHelpers {
    /// Merge auto-detected capabilities with explicit base capabilities.
    ///
    /// This performs two steps:
    /// 1. Creates capability objects (with `listChanged: true`) for registered
    ///    features that don't already have an explicit capability object.
    /// 2. Defaults any `nil` `listChanged` field to `true` within existing
    ///    capability objects, preserving explicit `false`.
    ///
    /// Explicit base capabilities take precedence where provided.
    ///
    /// - Parameters:
    ///   - base: Base capabilities (explicit overrides from initializer).
    ///   - hasTools: Whether tools have been registered.
    ///   - hasResources: Whether resources have been registered.
    ///   - hasPrompts: Whether prompts have been registered.
    /// - Returns: The merged capabilities.
    static func merge(
        base: Server.Capabilities,
        hasTools: Bool,
        hasResources: Bool,
        hasPrompts: Bool
    ) -> Server.Capabilities {
        var capabilities = base

        // Auto-detect: create capability objects for registered features
        if capabilities.tools == nil, hasTools {
            capabilities.tools = .init(listChanged: true)
        }
        if capabilities.resources == nil, hasResources {
            capabilities.resources = .init(subscribe: false, listChanged: true)
        }
        if capabilities.prompts == nil, hasPrompts {
            capabilities.prompts = .init(listChanged: true)
        }

        // Default nil listChanged to true, preserving explicit false.
        // Without this, a user providing e.g. Server.Capabilities(tools: .init())
        // would under-advertise: the client would receive {"tools": {}} instead
        // of {"tools": {"listChanged": true}}.
        if capabilities.tools?.listChanged == nil {
            capabilities.tools?.listChanged = true
        }
        if capabilities.resources?.listChanged == nil {
            capabilities.resources?.listChanged = true
        }
        if capabilities.prompts?.listChanged == nil {
            capabilities.prompts?.listChanged = true
        }

        return capabilities
    }

    /// Validate that advertised capabilities have handlers registered, and vice versa.
    ///
    /// This performs two-way validation:
    /// 1. Capabilities advertised without handlers (client may call methods that will fail)
    /// 2. Handlers registered without capabilities (client won't know the feature is available)
    ///
    /// These are intentionally warnings (not errors) to support legitimate edge cases:
    /// - Dynamic registration: capabilities advertised before handlers are registered
    /// - Testing: advertise capabilities to test client behavior
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities that will be advertised to the client.
    ///   - handlers: The registry of handlers.
    ///   - logger: Optional logger for warnings.
    static func validate(
        _ capabilities: Server.Capabilities,
        handlers: ServerHandlerRegistry,
        logger: Logger?
    ) {
        // Check for capabilities advertised without handlers
        if capabilities.tools != nil, handlers.methodHandlers[CallTool.name] == nil {
            logger?.warning(
                "Tools capability will be advertised but no tools/call handler is registered"
            )
        }
        if capabilities.resources != nil, handlers.methodHandlers[ReadResource.name] == nil {
            logger?.warning(
                "Resources capability will be advertised but no resources/read handler is registered"
            )
        }
        if capabilities.prompts != nil, handlers.methodHandlers[GetPrompt.name] == nil {
            logger?.warning(
                "Prompts capability will be advertised but no prompts/get handler is registered"
            )
        }

        // Check for handlers registered without capabilities (reverse validation)
        // These handlers exist but clients won't know the feature is available
        if handlers.methodHandlers[CallTool.name] != nil, capabilities.tools == nil {
            logger?.warning(
                "Tools handler registered but capability not advertised - clients won't discover tools"
            )
        }
        if handlers.methodHandlers[ReadResource.name] != nil, capabilities.resources == nil {
            logger?.warning(
                "Resources handler registered but capability not advertised - clients won't discover resources"
            )
        }
        if handlers.methodHandlers[GetPrompt.name] != nil, capabilities.prompts == nil {
            logger?.warning(
                "Prompts handler registered but capability not advertised - clients won't discover prompts"
            )
        }
    }
}
