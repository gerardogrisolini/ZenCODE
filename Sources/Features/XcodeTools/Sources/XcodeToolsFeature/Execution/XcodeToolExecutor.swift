//
//  XcodeToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
public import FeatureMCPBridgeKit
import ToolCore

public actor XcodeToolExecutor {
    private let client: MCPClient

    public init(configuration: MCPServerConfiguration) {
        self.client = MCPClient(
            configuration: configuration,
            localTransportPolicy: XcodeMCPTransportPolicy.make()
        )
    }

    public func loadTools() async throws -> [ToolDescriptor] {
        try await client.connect()
        let toolList = try await client.listTools()
        return toolList.tools.map(ToolDescriptor.init(remoteTool:))
    }

    public func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
        let result = try await executeRequestRetryingIndentationMismatchIfNeeded(request)
        let renderedResult = MCPToolResultRenderer.stringify(result)

        return ToolExecutionOutput(
            text: renderedResult,
            rawResult: result
        )
    }

    private func executeRequestRetryingIndentationMismatchIfNeeded(
        _ request: ToolRequest
    ) async throws -> JSONValue {
        let initialResult = try await client.callTool(
            named: request.name,
            arguments: request.arguments
        )

        guard request.name == "XcodeUpdate",
              let retryRequest = retriedXcodeUpdateRequestForIndentationMismatch(
                  originalRequest: request,
                  failureResult: initialResult
              ) else {
            return initialResult
        }

        return try await client.callTool(
            named: retryRequest.name,
            arguments: retryRequest.arguments
        )
    }

    public func disconnect() async {
        await client.disconnect()
    }

}
