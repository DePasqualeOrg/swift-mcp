// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.UUID
@testable import MCP
import Testing

struct IDTests {
    @Test
    func `String ID initialization and encoding`() throws {
        let id: RequestId = "test-id"
        #expect(id.description == "test-id")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(id)
        let decoded = try decoder.decode(RequestId.self, from: data)
        #expect(decoded == id)
    }

    @Test
    func `Number ID initialization and encoding`() throws {
        let id: RequestId = 42
        #expect(id.description == "42")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(id)
        let decoded = try decoder.decode(RequestId.self, from: data)
        #expect(decoded == id)
    }

    @Test
    func `Random ID generation`() {
        let id1 = RequestId.random
        let id2 = RequestId.random
        #expect(id1 != id2, "Random IDs should be unique")

        if case let .string(str) = id1 {
            #expect(!str.isEmpty)
            // Verify it's a valid UUID string
            #expect(UUID(uuidString: str) != nil)
        } else {
            #expect(Bool(false), "Random ID should be string type")
        }
    }
}
