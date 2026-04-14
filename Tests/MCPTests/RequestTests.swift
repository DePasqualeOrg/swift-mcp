// Copyright © Anthony DePasquale
// Copyright © Matt Zmuda

import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
@testable import MCP
import Testing

struct RequestTests {
    struct TestMethod: Method {
        struct Parameters: Codable, Hashable {
            let value: String
        }

        struct Result: Codable, Hashable {
            let success: Bool
        }

        static let name = "test.method"
    }

    struct EmptyMethod: Method {
        static let name = "empty.method"
    }

    @Test
    func `Request initialization with parameters`() {
        let id: RequestId = 1
        let params = CallTool.Parameters(name: "test-tool")
        let request = Request<CallTool>(id: id, method: CallTool.name, params: params)

        #expect(request.id == id)
        #expect(request.method == CallTool.name)
        #expect(request.params.name == "test-tool")
    }

    @Test
    func `Request encoding and decoding`() throws {
        let request = CallTool.request(id: 1, CallTool.Parameters(name: "test-tool"))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)
        let decoded = try decoder.decode(Request<CallTool>.self, from: data)

        #expect(decoded.id == request.id)
        #expect(decoded.method == request.method)
        #expect(decoded.params.name == request.params.name)
    }

    @Test
    func `Empty parameters request encoding`() throws {
        let request = EmptyMethod.request(id: 1)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(request)

        // Verify we can decode it back
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)
        #expect(decoded.id == request.id)
        #expect(decoded.method == request.method)
    }

    @Test
    func `Empty parameters request decoding`() throws {
        // Create a minimal JSON string
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"empty.method"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test
    func `NotRequired parameters request decoding - with params`() throws {
        // Test decoding when params field is present
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test
    func `NotRequired parameters request decoding - without params`() throws {
        // Test decoding when params field is missing
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"ping"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test
    func `NotRequired parameters request decoding - with null params`() throws {
        // Test decoding when params field is null
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"ping","params":null}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test
    func `Required parameters request decoding - missing params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<CallTool>.self, from: data)
        }
    }

    @Test
    func `Required parameters request decoding - null params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":null}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<CallTool>.self, from: data)
        }
    }

    @Test
    func `Empty parameters request decoding - with null params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"empty.method","params":null}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test
    func `Empty parameters request decoding - with empty object params`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"empty.method","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<EmptyMethod>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == EmptyMethod.name)
    }

    @Test
    func `Initialize request decoding - requires params`() throws {
        // Test missing params field
        let missingParams = """
        {"jsonrpc":"2.0","id":"test-id","method":"initialize"}
        """
        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(
                Request<Initialize>.self, from: #require(missingParams.data(using: .utf8)),
            )
        }

        // Test null params
        let nullParams = """
        {"jsonrpc":"2.0","id":"test-id","method":"initialize","params":null}
        """
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<Initialize>.self, from: #require(nullParams.data(using: .utf8)))
        }

        // Verify that empty object params works (since fields have defaults)
        let emptyParams = """
        {"jsonrpc":"2.0","id":"test-id","method":"initialize","params":{}}
        """
        let decoded = try decoder.decode(
            Request<Initialize>.self, from: #require(emptyParams.data(using: .utf8)),
        )
        #expect(decoded.params.protocolVersion == Version.latest)
        #expect(decoded.params.clientInfo.name == "unknown")
    }

    @Test
    func `Invalid parameters request decoding`() throws {
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"invalid":"value"}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(Request<CallTool>.self, from: data)
        }
    }

    @Test
    func `NotRequired parameters request decoding`() throws {
        // Test with missing params
        let missingParams = """
        {"jsonrpc":"2.0","id":1,"method":"tools/list"}
        """
        let decoder = JSONDecoder()
        let decodedMissing = try decoder.decode(
            Request<ListTools>.self,
            from: #require(missingParams.data(using: .utf8)),
        )
        #expect(decodedMissing.id == 1)
        #expect(decodedMissing.method == ListTools.name)
        #expect(decodedMissing.params.cursor == nil)

        // Test with null params
        let nullParams = """
        {"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}
        """
        let decodedNull = try decoder.decode(
            Request<ListTools>.self,
            from: #require(nullParams.data(using: .utf8)),
        )
        #expect(decodedNull.params.cursor == nil)

        // Test with empty object params
        let emptyParams = """
        {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
        """
        let decodedEmpty = try decoder.decode(
            Request<ListTools>.self,
            from: #require(emptyParams.data(using: .utf8)),
        )
        #expect(decodedEmpty.params.cursor == nil)

        // Test with provided cursor
        let withCursor = """
        {"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"cursor":"next-page"}}
        """
        let decodedWithCursor = try decoder.decode(
            Request<ListTools>.self,
            from: #require(withCursor.data(using: .utf8)),
        )
        #expect(decodedWithCursor.params.cursor == "next-page")
    }

    @Test
    func `AnyRequest parameters request decoding - without params`() throws {
        // Test decoding when params field is missing
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"ping"}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AnyRequest.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test
    func `AnyRequest parameters request decoding - with null params`() throws {
        // Test decoding when params field is null
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"ping","params":null}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }

    @Test
    func `AnyRequest parameters request decoding - with empty params`() throws {
        // Test decoding when params field is null
        let jsonString = """
        {"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
        """
        let data = try #require(jsonString.data(using: .utf8))

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Request<Ping>.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.method == Ping.name)
    }
}
