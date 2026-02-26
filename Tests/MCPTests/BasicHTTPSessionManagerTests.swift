// Copyright © Anthony DePasquale

import Foundation
import Testing

@testable import MCP

@Suite("Basic HTTP Session Manager Tests")
struct BasicHTTPSessionManagerTests {
    @Test("Non-initialize request without session ID returns 400 JSON-RPC invalid request")
    func missingSessionIdReturns400() async throws {
        try await withSessionManager { manager in
            let request = TestPayloads.postRequest(body: TestPayloads.listToolsRequest(id: "req-1"))
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 400,
                code: ErrorCode.invalidRequest,
                message: "Bad Request: Mcp-Session-Id header required"
            )
        }
    }

    @Test("Unknown session ID returns 404 JSON-RPC invalid request")
    func unknownSessionReturns404() async throws {
        try await withSessionManager { manager in
            let request = TestPayloads.postRequest(
                body: TestPayloads.listToolsRequest(id: "req-2"),
                sessionId: "missing-session"
            )
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 404,
                code: ErrorCode.invalidRequest,
                message: "Session not found"
            )
        }
    }

    @Test("GET request with unknown session ID returns 404 JSON-RPC invalid request")
    func getWithUnknownSessionIdReturns404() async throws {
        try await withSessionManager { manager in
            let request = HTTPRequest(
                method: "GET",
                headers: [
                    HTTPHeader.accept: "text/event-stream",
                    HTTPHeader.sessionId: "missing-session",
                    HTTPHeader.protocolVersion: TestPayloads.defaultVersion,
                ],
                body: nil
            )
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 404,
                code: ErrorCode.invalidRequest,
                message: "Session not found"
            )
        }
    }

    @Test("DELETE request with unknown session ID returns 404 JSON-RPC invalid request")
    func deleteWithUnknownSessionIdReturns404() async throws {
        try await withSessionManager { manager in
            let request = HTTPRequest(
                method: "DELETE",
                headers: [
                    HTTPHeader.sessionId: "missing-session",
                    HTTPHeader.protocolVersion: TestPayloads.defaultVersion,
                ],
                body: nil
            )
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 404,
                code: ErrorCode.invalidRequest,
                message: "Session not found"
            )
        }
    }

    @Test("GET request without session ID returns 400 JSON-RPC invalid request")
    func getWithoutSessionIdReturns400() async throws {
        try await withSessionManager { manager in
            let request = HTTPRequest(
                method: "GET",
                headers: [
                    HTTPHeader.accept: "text/event-stream",
                    HTTPHeader.protocolVersion: TestPayloads.defaultVersion,
                ],
                body: nil
            )
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 400,
                code: ErrorCode.invalidRequest,
                message: "Bad Request: Mcp-Session-Id header required"
            )
        }
    }

    @Test("DELETE request without session ID returns 400 JSON-RPC invalid request")
    func deleteWithoutSessionIdReturns400() async throws {
        try await withSessionManager { manager in
            let request = HTTPRequest(
                method: "DELETE",
                headers: [
                    HTTPHeader.protocolVersion: TestPayloads.defaultVersion,
                ],
                body: nil
            )
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 400,
                code: ErrorCode.invalidRequest,
                message: "Bad Request: Mcp-Session-Id header required"
            )
        }
    }

    @Test("Capacity limit returns 503 JSON-RPC internal error")
    func capacityLimitReturns503() async throws {
        try await withSessionManager(maxSessions: 1) { manager in
            let init1 = TestPayloads.postRequest(body: TestPayloads.initializeRequest(id: "init-1"))
            let init1Response = await manager.handleRequest(init1)
            #expect(init1Response.statusCode == 200)
            #expect(await manager.sessionCount == 1)

            let init2 = TestPayloads.postRequest(body: TestPayloads.initializeRequest(id: "init-2"))
            let init2Response = await manager.handleRequest(init2)
            #expect(init2Response.headers["retry-after"] == "60")
            try assertJSONRPCError(
                init2Response,
                statusCode: 503,
                code: ErrorCode.internalError,
                message: "Service Unavailable: Maximum sessions reached"
            )
        }
    }

    @Test("Initialize creates session and routes subsequent request")
    func initializeAndRouteSubsequentRequest() async throws {
        try await withSessionManager(sessionIdGenerator: { "session-fixed" }) { manager in
            let initRequest = TestPayloads.postRequest(body: TestPayloads.initializeRequest(id: "init-route"))
            let initResponse = await manager.handleRequest(initRequest)

            #expect(initResponse.statusCode == 200)
            #expect(initResponse.headers[HTTPHeader.sessionId] == "session-fixed")
            #expect(await manager.sessionCount == 1)

            let notificationRequest = TestPayloads.postRequest(
                body: TestPayloads.initializedNotification(),
                sessionId: "session-fixed"
            )
            let notificationResponse = await manager.handleRequest(notificationRequest)
            #expect(notificationResponse.statusCode == 202)
        }
    }

    @Test("Removing a session rejects subsequent requests with 404 invalid request")
    func removeSessionRejectsSubsequentRequests() async throws {
        try await withSessionManager(sessionIdGenerator: { "session-fixed" }) { manager in
            let initRequest = TestPayloads.postRequest(body: TestPayloads.initializeRequest(id: "init-remove"))
            let initResponse = await manager.handleRequest(initRequest)
            #expect(initResponse.statusCode == 200)
            #expect(await manager.sessionCount == 1)

            let removed = await manager.removeSession("session-fixed")
            #expect(removed)
            #expect(await manager.sessionCount == 0)

            let request = TestPayloads.postRequest(
                body: TestPayloads.listToolsRequest(id: "req-after-remove"),
                sessionId: "session-fixed"
            )
            let response = await manager.handleRequest(request)
            try assertJSONRPCError(
                response,
                statusCode: 404,
                code: ErrorCode.invalidRequest,
                message: "Session not found"
            )
        }
    }

    @Test("closeAll removes all active sessions")
    func closeAllRemovesAllSessions() async throws {
        let manager = makeSessionManager()
        let init1 = TestPayloads.postRequest(body: TestPayloads.initializeRequest(id: "init-a"))
        let init2 = TestPayloads.postRequest(body: TestPayloads.initializeRequest(id: "init-b"))

        _ = await manager.handleRequest(init1)
        _ = await manager.handleRequest(init2)
        #expect(await manager.sessionCount == 2)

        await manager.closeAll()
        #expect(await manager.sessionCount == 0)
    }
}

private func withSessionManager<T>(
    maxSessions: Int = 100,
    sessionIdGenerator: (@Sendable () -> String)? = nil,
    _ testBody: (BasicHTTPSessionManager) async throws -> T
) async throws -> T {
    let manager = makeSessionManager(maxSessions: maxSessions, sessionIdGenerator: sessionIdGenerator)
    do {
        let result = try await testBody(manager)
        await manager.closeAll()
        return result
    } catch {
        await manager.closeAll()
        throw error
    }
}

private func assertJSONRPCError(
    _ response: HTTPResponse,
    statusCode: Int,
    code: Int,
    message: String
) throws {
    #expect(response.statusCode == statusCode)
    #expect(response.headers[HTTPHeader.contentType] == "application/json")

    guard let body = response.body else {
        Issue.record("Expected JSON error body")
        return
    }

    let json = try JSONDecoder().decode([String: Value].self, from: body)
    #expect(json["jsonrpc"] == .string("2.0"))
    #expect(json["id"] == .null)

    let error = json["error"]?.objectValue
    #expect(error?["code"] == .int(code))
    #expect(error?["message"] == .string(message))
}

private func makeSessionManager(
    maxSessions: Int = 100,
    sessionIdGenerator: (@Sendable () -> String)? = nil
) -> BasicHTTPSessionManager {
    let server = MCPServer(name: "basic-http-session-manager-tests", version: "1.0.0")
    return BasicHTTPSessionManager(
        server: server,
        host: "0.0.0.0",
        port: 8080,
        maxSessions: maxSessions,
        sessionIdGenerator: sessionIdGenerator
    )
}
