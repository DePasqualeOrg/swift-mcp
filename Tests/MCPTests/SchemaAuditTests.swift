// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
@testable import MCPCore
import MCPTool
import Testing

// MARK: - Fixtures

@Schemable
@StructuredOutput
struct VerifyTestSearchResult: Equatable {
    let query: String
    let count: Int
}

@Schemable
@StructuredOutput
struct VerifyTestScreenshotMeta: Equatable {
    let width: Int
    let height: Int
}

/// Covered tool: typed `StructuredOutput`. Should produce a non-nil schema.
@Tool
struct VerifyTestStructuredTool {
    static let name = "verify_test_structured"
    static let description = "Test tool with StructuredOutput result"

    func perform() async throws -> VerifyTestSearchResult {
        VerifyTestSearchResult(query: "hi", count: 0)
    }
}

/// Covered tool: `MediaWithMetadata<Metadata>`. Should also produce a
/// non-nil schema, resolved through `StructuredMetadataCarrier`.
@Tool
struct VerifyTestMediaTool {
    static let name = "verify_test_media"
    static let description = "Test tool with MediaWithMetadata output"

    func perform() async throws -> MediaWithMetadata<VerifyTestScreenshotMeta> {
        MediaWithMetadata([], metadata: VerifyTestScreenshotMeta(width: 0, height: 0))
    }
}

/// Not covered: returns a custom `ToolOutput` conformer that publishes no
/// schema (the "advanced escape hatch" path). Should produce no schema.
///
/// Plain `String` — and every other built-in value return type — now
/// publishes a wrapped schema via `PrimitiveToolOutput`, so a tool has to
/// opt out by conforming its own type to `ToolOutput` directly to land in
/// the audit's `missingSchema` bucket.
struct VerifyTestEscapeHatchOutput: ToolOutput {
    func toCallToolResult() throws -> CallTool.Result {
        CallTool.Result(content: [.text("ok")])
    }
}

@Tool
struct VerifyTestUncoveredTool {
    static let name = "verify_test_uncovered"
    static let description = "Test tool with a custom ToolOutput conformer that declares no schema"

    func perform() async throws -> VerifyTestEscapeHatchOutput {
        VerifyTestEscapeHatchOutput()
    }
}

// MARK: - Tests

struct SchemaAuditTests {
    @Test
    func `StructuredOutput tool produces a schema`() async throws {
        let registry = ToolRegistry()
        try await registry.register(VerifyTestStructuredTool.self)
        let audit = await registry.schemaAudit(expected: ["verify_test_structured"])
        #expect(!audit.hasIssues)
    }

    @Test
    func `MediaWithMetadata tool produces a schema via StructuredMetadataCarrier`() async throws {
        let registry = ToolRegistry()
        try await registry.register(VerifyTestMediaTool.self)
        let audit = await registry.schemaAudit(expected: ["verify_test_media"])
        #expect(!audit.hasIssues)
    }

    @Test
    func `Uncovered tool shows up in missingSchema`() async throws {
        let registry = ToolRegistry()
        try await registry.register(VerifyTestUncoveredTool.self)
        let audit = await registry.schemaAudit(expected: ["verify_test_uncovered"])
        #expect(audit.missingSchema == ["verify_test_uncovered"])
        #expect(audit.missingRegistration.isEmpty)
    }

    @Test
    func `Mixed registry reports only uncovered tools`() async throws {
        let registry = ToolRegistry()
        try await registry.register(VerifyTestStructuredTool.self)
        try await registry.register(VerifyTestMediaTool.self)
        try await registry.register(VerifyTestUncoveredTool.self)

        let allowlist: Set = [
            "verify_test_structured",
            "verify_test_media",
            "verify_test_uncovered",
        ]
        let audit = await registry.schemaAudit(expected: allowlist)
        #expect(audit.missingSchema == ["verify_test_uncovered"])
        #expect(audit.missingRegistration.isEmpty)
    }

    @Test
    func `Expected tool not in registry shows up in missingRegistration`() async throws {
        let registry = ToolRegistry()
        try await registry.register(VerifyTestStructuredTool.self)
        let audit = await registry.schemaAudit(expected: [
            "verify_test_structured",
            "verify_test_unregistered",
        ])
        #expect(audit.missingSchema.isEmpty)
        #expect(audit.missingRegistration == ["verify_test_unregistered"])
    }

    @Test
    func `Both failure modes can be reported in the same audit`() async throws {
        let registry = ToolRegistry()
        try await registry.register(VerifyTestUncoveredTool.self)
        let audit = await registry.schemaAudit(expected: [
            "verify_test_uncovered",
            "verify_test_unregistered",
        ])
        #expect(audit.missingSchema == ["verify_test_uncovered"])
        #expect(audit.missingRegistration == ["verify_test_unregistered"])
        #expect(audit.hasIssues)
    }

    @Test
    func `Tools outside expected set are not checked`() async throws {
        // An uncovered tool registered outside the allowlist isn't flagged
        // — the helper is opt-in by design so unmigrated tools don't break
        // consumers during rollout.
        let registry = ToolRegistry()
        try await registry.register(VerifyTestStructuredTool.self)
        try await registry.register(VerifyTestUncoveredTool.self)
        let audit = await registry.schemaAudit(expected: ["verify_test_structured"])
        #expect(!audit.hasIssues)
    }
}
