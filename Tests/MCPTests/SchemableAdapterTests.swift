// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
@testable import MCPCore
import Testing

@Schemable
struct SchemableAdapterTestsSearchQuery {
    let text: String
    let limit: Int
}

@Schemable
enum SchemableAdapterTestsPriority {
    case low
    case medium
    case high
}

@Schemable
enum SchemableAdapterTestsLineEdit {
    case insert(line: Int, lines: [String])
    case delete(startLine: Int, endLine: Int)
    case replace(startLine: Int, endLine: Int, lines: [String])
}

struct SchemableAdapterTests {
    @Test
    func `Schemable struct round-trips into Value dictionary`() throws {
        let dict = try SchemableAdapter.valueDictionary(from: SchemableAdapterTestsSearchQuery.schema)

        #expect(dict["type"] == .string("object"))
        let properties = try #require(dict["properties"]?.objectValue)
        #expect(properties["text"]?.objectValue?["type"] == .string("string"))
        #expect(properties["limit"]?.objectValue?["type"] == .string("integer"))

        let required = try #require(dict["required"]?.arrayValue)
        #expect(Set(required.compactMap(\.stringValue)) == ["text", "limit"])
    }

    @Test
    func `Schemable plain enum produces string schema with enum values`() throws {
        let dict = try SchemableAdapter.valueDictionary(from: SchemableAdapterTestsPriority.schema)

        #expect(dict["type"] == .string("string"))
        let enumValues = try #require(dict["enum"]?.arrayValue)
        #expect(Set(enumValues.compactMap(\.stringValue)) == ["low", "medium", "high"])
    }

    @Test
    func `Schemable associated-value enum produces oneOf composition`() throws {
        let dict = try SchemableAdapter.valueDictionary(from: SchemableAdapterTestsLineEdit.schema)

        let oneOf = try #require(dict["oneOf"]?.arrayValue)
        #expect(oneOf.count == 3)

        let caseKeys = oneOf.compactMap { variant -> String? in
            guard let props = variant.objectValue?["properties"]?.objectValue else { return nil }
            return props.keys.first
        }
        #expect(Set(caseKeys) == ["insert", "delete", "replace"])
    }

    // MARK: - promoteRequired recursion

    /// Builds an object schema with the given properties. Leaves `required`
    /// unset so the helper drives `promoteRequired`'s behavior, not the
    /// pre-existing value.
    private static func objectSchema(_ properties: [String: Value]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
    }

    @Test
    func `promoteRequired fills required on a top-level object`() throws {
        let input = Self.objectSchema([
            "name": .object(["type": .string("string")]),
            "age": .object(["type": .string("integer")]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let required = try #require(result.objectValue?["required"]?.arrayValue)
        #expect(Set(required.compactMap(\.stringValue)) == ["name", "age"])
    }

    @Test
    func `promoteRequired recurses into nested properties`() throws {
        let input = Self.objectSchema([
            "inner": Self.objectSchema([
                "a": .object(["type": .string("string")]),
                "b": .object(["type": .string("integer")]),
            ]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let inner = try #require(result.objectValue?["properties"]?.objectValue?["inner"]?.objectValue)
        let innerRequired = try #require(inner["required"]?.arrayValue)
        #expect(Set(innerRequired.compactMap(\.stringValue)) == ["a", "b"])
    }

    @Test
    func `promoteRequired recurses into items schema`() throws {
        let input = Self.objectSchema([
            "list": .object([
                "type": .string("array"),
                "items": Self.objectSchema([
                    "id": .object(["type": .string("string")]),
                ]),
            ]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let items = try #require(
            result.objectValue?["properties"]?.objectValue?["list"]?.objectValue?["items"]?.objectValue,
        )
        let required = try #require(items["required"]?.arrayValue)
        #expect(required.compactMap(\.stringValue) == ["id"])
    }

    @Test
    func `promoteRequired recurses into prefixItems tuple schemas`() throws {
        let input = Self.objectSchema([
            "pair": .object([
                "type": .string("array"),
                "prefixItems": .array([
                    Self.objectSchema(["first": .object(["type": .string("string")])]),
                    Self.objectSchema(["second": .object(["type": .string("integer")])]),
                ]),
            ]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let prefix = try #require(
            result.objectValue?["properties"]?.objectValue?["pair"]?.objectValue?["prefixItems"]?.arrayValue,
        )
        #expect(prefix.count == 2)

        let first = try #require(prefix[0].objectValue?["required"]?.arrayValue)
        let second = try #require(prefix[1].objectValue?["required"]?.arrayValue)
        #expect(first.compactMap(\.stringValue) == ["first"])
        #expect(second.compactMap(\.stringValue) == ["second"])
    }

    @Test
    func `promoteRequired recurses into additionalProperties object schema`() throws {
        let input = Self.objectSchema([
            "map": .object([
                "type": .string("object"),
                "additionalProperties": Self.objectSchema([
                    "value": .object(["type": .string("string")]),
                ]),
            ]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let additional = try #require(
            result.objectValue?["properties"]?.objectValue?["map"]?.objectValue?["additionalProperties"]?.objectValue,
        )
        let required = try #require(additional["required"]?.arrayValue)
        #expect(required.compactMap(\.stringValue) == ["value"])
    }

    @Test
    func `promoteRequired recurses into patternProperties values`() throws {
        let input: Value = .object([
            "type": .string("object"),
            "patternProperties": .object([
                "^name_": Self.objectSchema([
                    "display": .object(["type": .string("string")]),
                ]),
            ]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let pattern = try #require(
            result.objectValue?["patternProperties"]?.objectValue?["^name_"]?.objectValue,
        )
        let required = try #require(pattern["required"]?.arrayValue)
        #expect(required.compactMap(\.stringValue) == ["display"])
    }

    @Test
    func `promoteRequired recurses into oneOf anyOf allOf composition`() throws {
        let input: Value = .object([
            "oneOf": .array([Self.objectSchema(["a": .object(["type": .string("string")])])]),
            "anyOf": .array([Self.objectSchema(["b": .object(["type": .string("string")])])]),
            "allOf": .array([Self.objectSchema(["c": .object(["type": .string("string")])])]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        for (key, propName) in [("oneOf", "a"), ("anyOf", "b"), ("allOf", "c")] {
            let variants = try #require(result.objectValue?[key]?.arrayValue)
            let required = try #require(variants.first?.objectValue?["required"]?.arrayValue)
            #expect(required.compactMap(\.stringValue) == [propName])
        }
    }

    @Test
    func `promoteRequired recurses into $defs and definitions`() throws {
        let input: Value = .object([
            "$defs": .object([
                "User": Self.objectSchema([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                ]),
            ]),
            "definitions": .object([
                "Legacy": Self.objectSchema([
                    "x": .object(["type": .string("integer")]),
                ]),
            ]),
        ])

        let result = SchemableAdapter.promoteRequired(input)

        let user = try #require(result.objectValue?["$defs"]?.objectValue?["User"]?.objectValue)
        let userRequired = try #require(user["required"]?.arrayValue)
        #expect(Set(userRequired.compactMap(\.stringValue)) == ["id", "name"])

        let legacy = try #require(result.objectValue?["definitions"]?.objectValue?["Legacy"]?.objectValue)
        let legacyRequired = try #require(legacy["required"]?.arrayValue)
        #expect(legacyRequired.compactMap(\.stringValue) == ["x"])
    }

    @Test
    func `promoteRequired does not recurse into validation-constraint keywords`() throws {
        // `not`/`if`/`then`/`else`/`dependentSchemas`/`contains`/`propertyNames`/
        // `unevaluatedProperties` describe what an instance must (or must not)
        // satisfy, not the output's shape. Promoting `required` inside them
        // would change the user's validation rule — e.g. a `not` subschema
        // that rejects `{has a}` would start rejecting only `{has a, b}`.
        let inner = Self.objectSchema([
            "a": .object(["type": .string("string")]),
            "b": .object(["type": .string("string")]),
        ])
        let input: Value = .object([
            "not": inner,
            "if": inner,
            "then": inner,
            "else": inner,
            "dependentSchemas": .object(["x": inner]),
            "contains": inner,
            "propertyNames": inner,
            "unevaluatedProperties": inner,
            "unevaluatedItems": inner,
        ])

        let result = SchemableAdapter.promoteRequired(input)

        // Every constraint-keyword subschema should still be the original
        // `inner` value — unmodified, no `required` added.
        for key in ["not", "if", "then", "else", "contains", "propertyNames",
                    "unevaluatedProperties", "unevaluatedItems"]
        {
            let sub = try #require(result.objectValue?[key]?.objectValue)
            #expect(sub["required"] == nil, "\(key) should not have a promoted required")
        }
        let dep = try #require(
            result.objectValue?["dependentSchemas"]?.objectValue?["x"]?.objectValue,
        )
        #expect(dep["required"] == nil, "dependentSchemas values should not have a promoted required")
    }
}
