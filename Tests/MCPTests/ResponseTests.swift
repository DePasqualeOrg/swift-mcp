// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import Testing

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

@testable import MCP

@Suite("Response Tests")
struct ResponseTests {
    struct TestMethod: Method {
        struct Parameters: Codable, Hashable, Sendable {
            let value: String
        }

        struct Result: Codable, Hashable, Sendable {
            let success: Bool
        }

        static let name = "test.method"
    }

    struct EmptyMethod: Method {
        static let name = "empty.method"
    }

    @Test("Success response initialization and encoding")
    func testSuccessResponse() throws {
        let id: RequestId = "test-id"
        let result = TestMethod.Result(success: true)
        let response = Response<TestMethod>(id: id, result: result)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        if case let .success(decodedResult) = decoded.result {
            #expect(decodedResult.success == true)
        } else {
            #expect(Bool(false), "Expected success result")
        }
    }

    @Test("Error response initialization and encoding")
    func testErrorResponse() throws {
        let id: RequestId = "test-id"
        let error = MCPError.parseError(nil)
        let response = Response<TestMethod>(id: id, error: error)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        if case let .failure(decodedError) = decoded.result {
            #expect(decodedError.code == ErrorCode.parseError)
            // Roundtrip preserves the error: parseError(nil) encodes as "Invalid JSON",
            // which decodes back to parseError(nil) since it matches the default message
            #expect(decodedError.localizedDescription == "Parse error: Invalid JSON")
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }

    @Test("Error response with detail")
    func testErrorResponseWithDetail() throws {
        let id: RequestId = "test-id"
        let error = MCPError.parseError("Invalid syntax")
        let response = Response<TestMethod>(id: id, error: error)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        if case let .failure(decodedError) = decoded.result {
            #expect(decodedError.code == ErrorCode.parseError)
            #expect(
                decodedError.localizedDescription
                    == "Parse error: Invalid JSON: Invalid syntax")
        } else {
            #expect(Bool(false), "Expected error result")
        }
    }

    @Test("Empty result response encoding")
    func testEmptyResultResponseEncoding() throws {
        let response = EmptyMethod.response(id: "test-id")

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)

        // Verify we can decode it back
        let decoded = try decoder.decode(Response<EmptyMethod>.self, from: data)
        #expect(decoded.id == response.id)
    }

    @Test("Empty result response decoding")
    func testEmptyResultResponseDecoding() throws {
        // Create a minimal JSON string
        let jsonString = """
        {"jsonrpc":"2.0","id":"test-id","result":{}}
        """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Response<EmptyMethod>.self, from: data)

        #expect(decoded.id == "test-id")
        if case .success = decoded.result {
            // Success
        } else {
            #expect(Bool(false), "Expected success result")
        }
    }

    // MARK: - Null/Missing ID Tests

    @Test("Error response with null id decodes successfully")
    func errorResponseWithNullId() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid request"}}
        """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        #expect(decoded.id == nil)
        if case let .failure(error) = decoded.result {
            #expect(error.code == ErrorCode.invalidRequest)
        } else {
            Issue.record("Expected error result")
        }
    }

    @Test("Error response with missing id decodes successfully")
    func errorResponseWithMissingId() throws {
        let jsonString = """
        {"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}
        """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        #expect(decoded.id == nil)
        if case let .failure(error) = decoded.result {
            #expect(error.code == ErrorCode.parseError)
        } else {
            Issue.record("Expected error result")
        }
    }

    @Test("Response with nil id roundtrips through encode/decode")
    func nilIdResponseRoundtrip() throws {
        let error = MCPError.internalError("Something went wrong")
        let response = Response<TestMethod>(id: nil, error: error)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(response)
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        #expect(decoded.id == nil)
        if case let .failure(decodedError) = decoded.result {
            #expect(decodedError.code == ErrorCode.internalError)
        } else {
            Issue.record("Expected error result")
        }

        // Verify the encoded JSON omits the id field entirely
        let json = try decoder.decode([String: Value].self, from: data)
        #expect(json["id"] == nil)
    }

    @Test("Normal error response with valid id is unchanged")
    func normalErrorResponseWithValidId() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":"req-123","error":{"code":-32601,"message":"Method not found"}}
        """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Response<TestMethod>.self, from: data)

        #expect(decoded.id == .string("req-123"))
        if case let .failure(error) = decoded.result {
            #expect(error.code == ErrorCode.methodNotFound)
        } else {
            Issue.record("Expected error result")
        }
    }

    @Test("RequestId no longer decodes null values")
    func requestIdRejectsNull() throws {
        let jsonString = "null"
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(RequestId.self, from: data)
        }
    }
}
