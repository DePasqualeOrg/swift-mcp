// Copyright © Anthony DePasquale

import Logging

/// Helpers for building and validating client capabilities.
///
/// This enum namespace contains static functions for capability merging and validation.
/// These are pure functions with explicit inputs, making them easy to test in isolation.
enum ClientCapabilityHelpers {
    /// Merge inferred capabilities with explicit overrides.
    ///
    /// Explicit overrides (from initializer) take precedence where provided.
    /// Only non-nil explicit capabilities override; others use auto-detected values.
    ///
    /// - Parameters:
    ///   - inferred: Capabilities inferred from registered handlers.
    ///   - explicit: Optional explicit capability overrides from initializer.
    /// - Returns: The merged capabilities.
    static func merge(
        inferred: Client.Capabilities,
        explicit: Client.Capabilities?,
    ) -> Client.Capabilities {
        guard let explicit else { return inferred }

        var capabilities = inferred

        // Explicit overrides win
        if explicit.sampling != nil {
            capabilities.sampling = explicit.sampling
        }
        if explicit.elicitation != nil {
            capabilities.elicitation = explicit.elicitation
        }
        if explicit.roots != nil {
            capabilities.roots = explicit.roots
        }
        if explicit.tasks != nil {
            capabilities.tasks = explicit.tasks
        }

        // Experimental: always from explicit (cannot auto-detect arbitrary capabilities)
        capabilities.experimental = explicit.experimental

        return capabilities
    }

    /// Validate that advertised capabilities have handlers registered, and vice versa.
    ///
    /// This performs two-way validation:
    /// 1. Capabilities advertised without handlers (handler won't be invoked by server)
    /// 2. Handlers registered without capabilities (handler won't be invoked because
    ///    capability isn't advertised)
    ///
    /// These are intentionally warnings (not errors) to support legitimate edge cases:
    /// - Testing: advertise capabilities to test server behavior without implementing handlers
    /// - Forward compatibility: explicit overrides may advertise capabilities not yet supported
    /// - Gradual migration: configure capabilities before handlers are fully implemented
    ///
    /// - Parameters:
    ///   - capabilities: The capabilities that will be advertised to the server.
    ///   - handlers: The registry of handlers.
    ///   - logger: Optional logger for warnings.
    static func validate(
        _ capabilities: Client.Capabilities,
        handlers: ClientHandlerRegistry,
        logger: Logger?,
    ) {
        // Check for capabilities advertised without handlers
        if capabilities.sampling != nil, handlers.requestHandlers[ClientSamplingRequest.name] == nil {
            logger?.warning(
                "Sampling capability will be advertised but no handler is registered",
            )
        }
        if capabilities.elicitation != nil, handlers.requestHandlers[Elicit.name] == nil {
            logger?.warning(
                "Elicitation capability will be advertised but no handler is registered",
            )
        }
        if capabilities.roots != nil, handlers.requestHandlers[ListRoots.name] == nil {
            logger?.warning(
                "Roots capability will be advertised but no handler is registered",
            )
        }

        // Check for handlers registered without capabilities (reverse validation)
        // These handlers will never be invoked because the capability isn't advertised
        if handlers.requestHandlers[ClientSamplingRequest.name] != nil, capabilities.sampling == nil {
            logger?.warning(
                "Sampling handler registered but capability not advertised - handler won't be invoked",
            )
        }
        if handlers.requestHandlers[Elicit.name] != nil, capabilities.elicitation == nil {
            logger?.warning(
                "Elicitation handler registered but capability not advertised - handler won't be invoked",
            )
        }
        if handlers.requestHandlers[ListRoots.name] != nil, capabilities.roots == nil {
            logger?.warning(
                "Roots handler registered but capability not advertised - handler won't be invoked",
            )
        }
    }
}
