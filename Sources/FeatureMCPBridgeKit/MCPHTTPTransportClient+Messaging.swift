//
//  MCPHTTPTransportClient+Messaging.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

#if os(macOS)
extension MCPHTTPTransportClient {
    public func connect() async throws {
        guard !isInitialized else {
            return
        }

        if let connectTask {
            try await connectTask.value
            return
        }

        let connectTask = Task<Void, Error> {
            try await self.performConnect()
        }
        self.connectTask = connectTask

        do {
            try await connectTask.value
            self.connectTask = nil
        } catch {
            self.connectTask = nil
            throw error
        }
    }

    private func performConnect() async throws {
        let initializeParams = MCPInitializeParams(
            protocolVersion: preferredProtocolVersion,
            capabilities: MCPClientCapabilities(),
            clientInfo: MCPClientInfo(name: "Feature MCP client", version: "1.0")
        )

        _ = try await request(
            method: "initialize",
            params: initializeParams,
            includeSession: false
        )
        try await notify(method: "notifications/initialized", params: JSONValue.object([:]))
        isInitialized = true
    }

    public func disconnect() async {
        defer {
            sessionIdentifier = nil
            isInitialized = false
            connectTask?.cancel()
            connectTask = nil
            oauthAuthenticationTask?.cancel()
            oauthAuthenticationTask = nil
        }

        guard let sessionIdentifier else {
            return
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "DELETE"
        request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        applyCommonHeaders(to: &request, includeContentType: false)
        _ = try? await urlSession.data(for: request)
    }

    public func listTools() async throws -> MCPListToolsResult {
        try await connect()
        let result = try await request(method: "tools/list", params: JSONValue.object([:]))
        return try result.decode(MCPListToolsResult.self)
    }

    public func callTool(named name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        try await connect()
        return try await request(
            method: "tools/call",
            params: JSONValue.object([
                "name": .string(name),
                "arguments": .object(arguments)
            ])
        )
    }

    private func request<Params: Encodable>(
        method: String,
        params: Params,
        includeSession: Bool = true
    ) async throws -> JSONValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let payload = try JSONEncoder().encode(
            MCPRequest(
                jsonrpc: "2.0",
                id: .int(requestID),
                method: method,
                params: params
            )
        )

        let (message, _) = try await send(
            payload: payload,
            includeSession: includeSession
        )

        guard let message else {
            throw MCPClientError.invalidResponse
        }

        if let error = message.error {
            throw MCPClientError.serverError(code: error.code, message: error.message)
        }

        guard let result = message.result else {
            throw MCPClientError.invalidResponse
        }

        return result
    }

    private func notify<Params: Encodable>(
        method: String,
        params: Params
    ) async throws {
        let payload = try JSONEncoder().encode(
            MCPNotification(
                jsonrpc: "2.0",
                method: method,
                params: params
            )
        )

        _ = try await send(payload: payload, includeSession: true)
    }

    private func send(
        payload: Data,
        includeSession: Bool,
        allowAuthenticationRetry: Bool = true
    ) async throws -> (message: MCPIncomingMessage?, response: HTTPURLResponse?) {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = payload
        applyCommonHeaders(to: &request, includeContentType: true)

        if includeSession, let sessionIdentifier {
            request.setValue(sessionIdentifier, forHTTPHeaderField: "Mcp-Session-Id")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse
        }

        if let responseSessionID = headerValue(named: "Mcp-Session-Id", in: httpResponse),
           !responseSessionID.isEmpty {
            sessionIdentifier = responseSessionID
        }

        if httpResponse.statusCode == 401,
           allowAuthenticationRetry,
           shouldUseBrowserOAuth {
            let requiresFreshLogin = oauthAccessToken != nil
            _ = try await ensureOAuthAccessToken(requiringFreshLogin: requiresFreshLogin)
            return try await send(
                payload: payload,
                includeSession: includeSession,
                allowAuthenticationRetry: false
            )
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let errorMessage = decodeServerMessage(
                from: data,
                response: httpResponse
            ) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw MCPClientError.serverError(code: httpResponse.statusCode, message: errorMessage)
        }

        guard !data.isEmpty else {
            return (nil, httpResponse)
        }

        let messageData = try extractMessageData(from: data, response: httpResponse)
        let message = try JSONDecoder().decode(MCPIncomingMessage.self, from: messageData)
        return (message, httpResponse)
    }

    private func applyCommonHeaders(
        to request: inout URLRequest,
        includeContentType: Bool
    ) {
        if includeContentType {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(preferredProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")

        for (header, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if !hasStaticAuthorizationHeader,
           let oauthAccessToken {
            request.setValue(
                oauthAccessToken.authorizationHeaderValue,
                forHTTPHeaderField: "Authorization"
            )
        }
    }

    private func extractMessageData(
        from data: Data,
        response: HTTPURLResponse
    ) throws -> Data {
        let contentType = headerValue(named: "Content-Type", in: response)?.lowercased() ?? ""
        if contentType.contains("text/event-stream"),
           let ssePayload = Self.firstJSONEventPayload(in: data) {
            return ssePayload
        }

        return data
    }

    private func decodeServerMessage(
        from data: Data,
        response: HTTPURLResponse
    ) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        let messageData: Data
        if let decoded = try? extractMessageData(from: data, response: response) {
            messageData = decoded
        } else {
            messageData = data
        }

        if let incomingMessage = try? JSONDecoder().decode(MCPIncomingMessage.self, from: messageData),
           let error = incomingMessage.error {
            return error.message
        }

        return String(data: messageData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func headerValue(named name: String, in response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
#endif
