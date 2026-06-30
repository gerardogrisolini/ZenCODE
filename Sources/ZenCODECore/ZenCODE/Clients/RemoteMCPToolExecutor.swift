//
//  RemoteMCPToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public actor RemoteMCPToolExecutor {
    private let client: MCPClient
    private let toolNamePrefix: String

    public init(configuration: MCPServerConfiguration, toolNamePrefix: String) {
        self.client = MCPClient(configuration: configuration)
        self.toolNamePrefix = toolNamePrefix
    }

    public func loadTools() async throws -> [ToolDescriptor] {
        try await client.connect()
        let toolList = try await client.listTools()
        return toolList.tools
            .map(ToolDescriptor.init(remoteTool:))
            .map { $0.prefixed(with: toolNamePrefix) }
    }

    public func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
        let rawToolName: String
        if request.name.hasPrefix(toolNamePrefix) {
            rawToolName = String(request.name.dropFirst(toolNamePrefix.count))
        } else {
            rawToolName = request.name
        }

        let result = try await client.callTool(named: rawToolName, arguments: request.arguments)
        return ToolExecutionOutput(
            text: MCPToolResultRenderer.stringify(result),
            rawResult: result
        )
    }

    public func disconnect() async {
        await client.disconnect()
    }
}

public nonisolated enum MCPToolResultRenderer {
    public static func stringify(_ result: JSONValue) -> String {
        guard case let .object(rootObject) = result else {
            return result.prettyPrinted()
        }

        if let structuredContent = rootObject["structuredContent"],
           let renderedStructuredContent = renderStructuredToolResult(structuredContent) {
            if isErrorResult(rootObject) {
                return "Tool error:\n\(renderedStructuredContent)"
            }
            return renderedStructuredContent
        }

        if let renderedRootMessage = renderRootObjectMessage(rootObject) {
            return renderedRootMessage
        }

        guard let contentValue = rootObject["content"],
              case let .array(contentItems) = contentValue else {
            return result.prettyPrinted()
        }

        let renderedItems = contentItems.compactMap { item -> String? in
            guard case let .object(itemObject) = item else {
                return item.prettyPrinted()
            }

            if let text = itemObject["text"]?.stringValue,
               containsVisibleContent(text) {
                return text
            }

            if let dataValue = itemObject["data"] {
                return dataValue.prettyPrinted()
            }

            return item.prettyPrinted()
        }

        let renderedText = renderedItems
            .joined(separator: "\n\n")

        guard containsVisibleContent(renderedText) else {
            return result.prettyPrinted()
        }

        if rootObject["isError"]?.boolValue == true || rootObject["success"]?.boolValue == false {
            return "Tool error:\n\(renderedText)"
        }

        return renderedText
    }

    private static func renderRootObjectMessage(
        _ rootObject: [String: JSONValue]
    ) -> String? {
        let preferredText = rootObject["message"]?.stringValue
            ?? rootObject["content"]?.stringValue
            ?? rootObject["text"]?.stringValue
        guard let message = preferredText,
              containsVisibleContent(message) else {
            return nil
        }

        if isErrorResult(rootObject) {
            return "Tool error:\n\(message)"
        }

        if effectiveSuccessFlag(in: rootObject) == true {
            return message
        }

        return nil
    }

    private static func containsVisibleContent(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func renderStructuredToolResult(_ structuredContent: JSONValue) -> String? {
        if case let .object(structuredObject) = structuredContent {
            let preferredText = structuredObject["message"]?.stringValue
                ?? structuredObject["content"]?.stringValue
                ?? structuredObject["text"]?.stringValue
            if let preferredText,
               containsVisibleContent(preferredText) {
                return preferredText
            }

            let renderedStructuredContent = structuredContent.prettyPrinted()
            return renderedStructuredContent == "{}" ? nil : renderedStructuredContent
        }

        let renderedStructuredContent = structuredContent.prettyPrinted()
        return renderedStructuredContent == "{}" ? nil : renderedStructuredContent
    }

    private static func effectiveSuccessFlag(
        in rootObject: [String: JSONValue]
    ) -> Bool? {
        if let success = rootObject["success"]?.boolValue {
            return success
        }

        guard case let .object(structuredObject) = rootObject["structuredContent"] else {
            return nil
        }

        return structuredObject["success"]?.boolValue
    }

    private static func isErrorResult(
        _ rootObject: [String: JSONValue]
    ) -> Bool {
        let structuredIsError: Bool
        if case let .object(structuredObject) = rootObject["structuredContent"] {
            structuredIsError = structuredObject["isError"]?.boolValue == true
        } else {
            structuredIsError = false
        }

        return rootObject["isError"]?.boolValue == true
            || structuredIsError
            || effectiveSuccessFlag(in: rootObject) == false
    }
}
