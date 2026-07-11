//
//  XcodeToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public actor XcodeToolExecutor {
    private let client: MCPClient

    public init(configuration: MCPServerConfiguration) {
        self.client = MCPClient(configuration: configuration)
    }

    public func loadTools() async throws -> [ToolDescriptor] {
        try await client.connect()
        let toolList = try await client.listTools()
        return toolList.tools.map(ToolDescriptor.init(remoteTool:))
    }

    public func loadWorkspaceContext() async throws -> XcodeWorkspaceContext? {
        try await loadWorkspaceContexts().first
    }

    public func loadWorkspaceContexts() async throws -> [XcodeWorkspaceContext] {
        try await client.connect()
        let result = try await client.callTool(named: "XcodeListWindows", arguments: [:])
        return XcodeWorkspaceContext.contexts(fromListWindowsResult: result)
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

    private func summarizedMutationResult(from result: JSONValue) -> String? {
        let rootObject = objectValue(from: result)
        let object = rootObject.flatMap { rootObject in
            objectValue(from: rootObject["structuredContent"]) ?? rootObject
        }
        guard let object else {
            return nil
        }

        var parts: [String] = []
        if let success = object["success"]?.boolValue {
            parts.append("success=\(success)")
        }
        if let editsApplied = object["editsApplied"]?.numberValue {
            parts.append("editsApplied=\(Int(editsApplied))")
        }
        if let filePath = object["filePath"]?.stringValue,
           !filePath.isEmpty {
            parts.append("filePath=\(filePath)")
        }
        if let message = object["message"]?.stringValue,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("message=\(message)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func objectValue(from value: JSONValue?) -> [String: JSONValue]? {
        guard let value,
              case let .object(object) = value else {
            return nil
        }
        return object
    }
}
