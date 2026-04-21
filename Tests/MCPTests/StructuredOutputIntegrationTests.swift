// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCPCore
import MCPTool
import Testing

// MARK: - Test fixtures

/// A representative result type exercising:
/// - required string / int / array,
/// - optional string / int,
/// - `CodingKeys` renaming for wire compatibility.
@Schemable
@StructuredOutput
struct StructuredOutputFixture: Equatable {
    let stdout: String
    let exitCode: Int
    let items: [String]
    let note: String?
    let secondaryCount: Int?

    enum CodingKeys: String, CodingKey {
        case stdout
        case items
        case note
        case exitCode = "exit_code"
        case secondaryCount = "secondary_count"
    }
}

/// A result with a `Date` property, used to prove that the default encoder
/// emits ISO8601 strings (not floating-point timestamps).
@Schemable
@StructuredOutput
struct StructuredOutputDatedFixture: Equatable {
    let name: String
    let capturedAt: Date
}

/// A type that overrides `encoder` to use a custom `dateEncodingStrategy`.
/// Exercises the override path — confirming that consumers can replace the
/// default without touching the synthesized `encode(to:)`.
@Schemable
@StructuredOutput
struct StructuredOutputCustomEncoderFixture: Equatable {
    let name: String
    let capturedAt: Date

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

/// A hand-written encoder opt-out via `@ManualEncoding` — the macro must
/// skip synthesis, but still add `StructuredOutput` conformance and the
/// `outputJSONSchema` bridge.
@Schemable
@StructuredOutput
@ManualEncoding
struct StructuredOutputManualFixture: Equatable {
    let present: String
    let absent: String?

    enum CodingKeys: String, CodingKey {
        case present
        case absent
    }

    func encode(to encoder: Encoder) throws {
        // Intentionally uses `encodeIfPresent` so we can observe the difference
        // from the synthesized encoder's behavior at runtime. The author is
        // opting in to the stable-shape contract themselves.
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(present, forKey: .present)
        try container.encodeIfPresent(absent, forKey: .absent)
    }
}

/// Nested `@StructuredOutput` types. Proves that an outer struct can hold
/// an inner `@Schemable @StructuredOutput` value as a stored property —
/// each level's synthesized `encode(to:)` and `outputJSONSchema` compose
/// cleanly without the outer macro conflicting with the inner one.
@Schemable
@StructuredOutput
struct StructuredOutputNestedInner: Equatable {
    let label: String
    let count: Int?
}

@Schemable
@StructuredOutput
struct StructuredOutputNestedOuter: Equatable {
    let name: String
    let inner: StructuredOutputNestedInner
    // Decodable-friendly synthesis requires a matching init; we rely on
    // the compiler-synthesized memberwise init plus Codable's default
    // `init(from:)` (the macro only provides `encode(to:)`).
}

extension StructuredOutputNestedInner: Decodable {}
extension StructuredOutputNestedOuter: Decodable {}

/// Fixtures for enum / array / dictionary property coverage. The schema
/// must expose enums as a closed `enum` set (or `oneOf [null, enum]` for
/// optional), arrays as `items`-typed, and dictionaries as
/// `additionalProperties`-typed — and `required` at every nesting level
/// must include every stored property, including optional enum fields.
@Schemable
enum StructuredOutputKind: String, CaseIterable, Codable {
    case alpha
    case beta
}

@Schemable
@StructuredOutput
struct StructuredOutputWithEnum: Equatable {
    let kind: StructuredOutputKind
    let optionalKind: StructuredOutputKind?
    let innerList: [StructuredOutputNestedInner]
    let namedInner: [String: StructuredOutputNestedInner]
}

extension StructuredOutputWithEnum: Decodable {}

/// Fixture for the data-URI round-trip regression. `icon` is a plain
/// `String` that happens to hold a data URI — `Icon.src` is documented as
/// accepting this shape, so it's a realistic tool-metadata value. The
/// `structuredContent` round trip must preserve it as `.string`, not
/// auto-coerce to `.data`.
@Schemable
@StructuredOutput
struct StructuredOutputWithDataURI: Equatable {
    let icon: String
    let label: String
}

// MARK: - Tests

struct StructuredOutputIntegrationTests {
    // MARK: Schema shape

    @Test
    func `outputJSONSchema lists every property in required`() throws {
        let schema = StructuredOutputFixture.outputJSONSchema
        let required = try #require(schema.objectValue?["required"]?.arrayValue)
        let names = Set(required.compactMap(\.stringValue))

        // CodingKeys-renamed keys are what the schema should reflect — the
        // wire keys, not the Swift property names.
        #expect(names == ["stdout", "exit_code", "items", "note", "secondary_count"])
    }

    @Test
    func `outputJSONSchema types optionals as union with null`() throws {
        let schema = StructuredOutputFixture.outputJSONSchema
        let properties = try #require(schema.objectValue?["properties"]?.objectValue)

        let noteType = properties["note"]?.objectValue?["type"]?.arrayValue?
            .compactMap(\.stringValue)
        #expect(noteType == ["string", "null"])

        let countType = properties["secondary_count"]?.objectValue?["type"]?.arrayValue?
            .compactMap(\.stringValue)
        #expect(countType == ["integer", "null"])

        // Non-optionals remain scalar types.
        #expect(properties["stdout"]?.objectValue?["type"]?.stringValue == "string")
        #expect(properties["exit_code"]?.objectValue?["type"]?.stringValue == "integer")
    }

    // MARK: Synthesized encoding

    @Test
    func `synthesized encoder emits null for nil optionals`() throws {
        let value = StructuredOutputFixture(
            stdout: "hello",
            exitCode: 0,
            items: ["a", "b"],
            note: nil,
            secondaryCount: nil,
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        let json = try #require(String(data: data, encoding: .utf8))

        // With `container.encode` (not `encodeIfPresent`), nil optionals
        // serialize as JSON `null` and the key is always present.
        #expect(json.contains("\"note\":null"))
        #expect(json.contains("\"secondary_count\":null"))
        // CodingKeys-rename honored.
        #expect(json.contains("\"exit_code\":0"))
        // `stdout` key present with its string value.
        #expect(json.contains("\"stdout\":\"hello\""))
    }

    @Test
    func `toCallToolResult emits stringified JSON matching structuredContent`() throws {
        let value = StructuredOutputFixture(
            stdout: "out",
            exitCode: 0,
            items: [],
            note: nil,
            secondaryCount: nil,
        )

        let result = try value.toCallToolResult()

        // `content[0]` is the stringified JSON. `structuredContent` is the
        // same value decoded back. The contract is that the text represents
        // the structured payload byte-for-byte under the chosen encoder.
        let text = try #require(result.content.first.flatMap { content -> String? in
            if case let .text(t, _, _) = content { return t } else { return nil }
        })
        let structured = try #require(result.structuredContent)
        let reencoded = try JSONEncoder().encode(structured)
        let roundTripped = try JSONDecoder().decode(Value.self, from: reencoded)
        let textAsValue = try JSONDecoder().decode(Value.self, from: Data(text.utf8))
        #expect(textAsValue == roundTripped)
    }

    // MARK: Nested @StructuredOutput

    @Test
    func `Nested @StructuredOutput round-trips through JSON`() throws {
        let original = StructuredOutputNestedOuter(
            name: "outer",
            inner: StructuredOutputNestedInner(label: "child", count: 7),
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StructuredOutputNestedOuter.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func `Nested @StructuredOutput outer encodes inner with null for nil optional`() throws {
        // The inner's synthesized encoder uses `container.encode` (not
        // `encodeIfPresent`), so a nil inner.count must surface as a JSON
        // `null` even when nested — proving the stable-shape contract
        // propagates through nesting.
        let value = StructuredOutputNestedOuter(
            name: "outer",
            inner: StructuredOutputNestedInner(label: "child", count: nil),
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"{"inner":{"count":null,"label":"child"},"name":"outer"}"#)
    }

    @Test
    func `Nested @StructuredOutput outer schema references inner properties`() throws {
        // The outer schema's `inner` property must be a fully-typed object
        // schema built from the inner's @Schemable component — not an
        // opaque `{}`.
        let schema = StructuredOutputNestedOuter.outputJSONSchema
        let properties = try #require(schema.objectValue?["properties"]?.objectValue)
        let innerSchema = try #require(properties["inner"]?.objectValue)
        #expect(innerSchema["type"]?.stringValue == "object")
        let innerProperties = try #require(innerSchema["properties"]?.objectValue)
        #expect(innerProperties["label"] != nil)
        #expect(innerProperties["count"] != nil)
    }

    @Test
    func `Enum property appears in required and emits closed raw-value set in schema`() throws {
        let schema = StructuredOutputWithEnum.outputJSONSchema
        let required = Set((schema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)) ?? [])
        #expect(required == ["kind", "optionalKind", "innerList", "namedInner"])

        let props = try #require(schema.objectValue?["properties"]?.objectValue)
        let kindSchema = try #require(props["kind"]?.objectValue)
        let kindEnum = kindSchema["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(Set(kindEnum ?? []) == ["alpha", "beta"])
    }

    @Test
    func `Nested @StructuredOutput inside array items inherits promoted required`() throws {
        // Regression guard for the recursion in `structuredOutputSchemaDictionary`
        // — array element schemas are nested objects and must also have
        // every property in `required`, not just the top-level.
        let schema = StructuredOutputWithEnum.outputJSONSchema
        let props = try #require(schema.objectValue?["properties"]?.objectValue)
        let innerList = try #require(props["innerList"]?.objectValue)
        let itemSchema = try #require(innerList["items"]?.objectValue)
        let itemRequired = Set((itemSchema["required"]?.arrayValue?.compactMap(\.stringValue)) ?? [])
        #expect(itemRequired == ["label", "count"])
    }

    @Test
    func `Nested @StructuredOutput inside dictionary values inherits promoted required`() throws {
        // Parallel to the array case — dictionary values land under
        // `additionalProperties` and are also subject to recursion.
        let schema = StructuredOutputWithEnum.outputJSONSchema
        let props = try #require(schema.objectValue?["properties"]?.objectValue)
        let namedInner = try #require(props["namedInner"]?.objectValue)
        let valueSchema = try #require(namedInner["additionalProperties"]?.objectValue)
        let valueRequired = Set((valueSchema["required"]?.arrayValue?.compactMap(\.stringValue)) ?? [])
        #expect(valueRequired == ["label", "count"])
    }

    @Test
    func `Nested @StructuredOutput inner required includes every stored property`() throws {
        // Stable-shape contract applies at every nesting level. Inner's
        // `count: Int?` encodes as `"count":null` (proven above), so it
        // must also appear in the inner schema's `required` list — not
        // just the outer's. Regression guard for the schema/payload drift
        // that existed when `required` was only promoted at the top level.
        let schema = StructuredOutputNestedOuter.outputJSONSchema
        let innerSchema = try #require(
            schema.objectValue?["properties"]?.objectValue?["inner"]?.objectValue,
        )
        let required = Set((innerSchema["required"]?.arrayValue?.compactMap(\.stringValue)) ?? [])
        #expect(required == ["label", "count"])
    }

    // MARK: @ManualEncoding opt-out

    @Test
    func `ManualEncoding preserves user-written encoder`() throws {
        let value = StructuredOutputManualFixture(present: "x", absent: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        let json = try #require(String(data: data, encoding: .utf8))

        // The user's `encodeIfPresent` path elides the absent key. This is
        // not the recommended shape — it's exactly why the synthesizer exists.
        // The `@ManualEncoding` user has opted in to taking responsibility.
        #expect(json == "{\"present\":\"x\"}")
    }

    @Test
    func `ManualEncoding still derives outputJSONSchema from Schemable`() throws {
        let schema = StructuredOutputManualFixture.outputJSONSchema
        let required = try #require(schema.objectValue?["required"]?.arrayValue)
        let names = Set(required.compactMap(\.stringValue))
        #expect(names == ["present", "absent"])
    }

    // MARK: Encoder default and override

    @Test
    func `Default encoder emits ISO8601 date strings`() throws {
        let value = StructuredOutputDatedFixture(
            name: "screenshot",
            // 2024-03-15T14:30:00Z — pinned epoch so the test isn't date-relative.
            capturedAt: Date(timeIntervalSince1970: 1_710_513_000),
        )

        let data = try StructuredOutputDatedFixture.encoder.encode(value)
        let json = try #require(String(data: data, encoding: .utf8))
        // `.iso8601` renders without fractional seconds; keys are sorted.
        #expect(json == "{\"capturedAt\":\"2024-03-15T14:30:00Z\",\"name\":\"screenshot\"}")
    }

    @Test
    func `Overriding encoder replaces only the chosen strategy`() throws {
        let value = StructuredOutputCustomEncoderFixture(
            name: "screenshot",
            capturedAt: Date(timeIntervalSince1970: 1_710_513_000),
        )

        let data = try StructuredOutputCustomEncoderFixture.encoder.encode(value)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "{\"capturedAt\":1710513000,\"name\":\"screenshot\"}")
    }

    @Test
    func `toCallToolResult routes through Self.encoder`() throws {
        // The custom encoder emits the date as a Unix timestamp. The
        // `structuredContent` and `content[0].text` must both reflect that
        // choice — proof that the default toCallToolResult uses `Self.encoder`.
        let value = StructuredOutputCustomEncoderFixture(
            name: "screenshot",
            capturedAt: Date(timeIntervalSince1970: 1_710_513_000),
        )
        let result = try value.toCallToolResult()
        let text = try #require(result.content.first.flatMap { content -> String? in
            if case let .text(t, _, _) = content { return t } else { return nil }
        })
        #expect(text.contains("\"capturedAt\":1710513000"))

        let structured = try #require(result.structuredContent)
        let capturedAt = structured.objectValue?["capturedAt"]
        // `Value` represents numbers as either .int or .double. `.secondsSince1970`
        // encodes whole seconds as an integer, so we expect `.int`.
        #expect(capturedAt == .int(1_710_513_000))
    }

    @Test
    func `MCPEncoding.defaultEncoder returns a fresh encoder each call`() {
        let a = MCPEncoding.defaultEncoder()
        let b = MCPEncoding.defaultEncoder()
        // Proves callers can mutate without side-effects on later calls.
        a.outputFormatting = []
        #expect(b.outputFormatting == .sortedKeys)
    }

    // MARK: Registry path

    @Test
    func `MCPSchema.outputSchema(for:) resolves StructuredOutput types`() {
        let schema = MCPSchema.outputSchema(for: StructuredOutputFixture.self)
        #expect(schema != nil)
        #expect(schema?.objectValue?["type"]?.stringValue == "object")
    }

    @Test
    func `MCPSchema.outputSchema(for:) returns nil for non-StructuredOutput types`() {
        struct NotStructured: Encodable { let x: Int }
        #expect(MCPSchema.outputSchema(for: NotStructured.self) == nil)
    }

    // MARK: Data-URI round trip

    /// Regression test: a `String` field carrying a data URI must survive
    /// the `toCallToolResult()` round trip (`encode` → `JSONDecoder` →
    /// `Value`) as `Value.string`, not `Value.data`. `Icon.src` is
    /// documented as "HTTP/HTTPS URL or data URI" — a consumer
    /// pattern-matching `.string` would silently miss data-URI values
    /// if `Value.init(from:)` auto-coerced `data:` strings to `.data`.
    @Test
    func `String field carrying a data URI round-trips as string not data`() throws {
        let dataURI = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let value = StructuredOutputWithDataURI(icon: dataURI, label: "pixel")

        let result = try value.toCallToolResult()
        let structured = try #require(result.structuredContent)
        let iconValue = try #require(structured.objectValue?["icon"])

        #expect(iconValue.stringValue == dataURI)
        #expect(iconValue.dataValue == nil)
    }
}
