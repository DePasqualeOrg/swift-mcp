// Copyright © Anthony DePasquale

import Foundation
import JSONSchemaBuilder
@testable import MCP
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
}
