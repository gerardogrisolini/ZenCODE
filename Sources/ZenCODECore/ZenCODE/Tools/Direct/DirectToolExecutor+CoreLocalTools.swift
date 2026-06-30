//
//  DirectToolExecutor+CoreLocalTools.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import FeatureKit
import LocalToolsSupport

extension DirectToolExecutor {
    public static func isCoreLocalFileOrTextToolName(_ toolName: String) -> Bool {
        coreLocalFileAndTextTools.contains {
            $0.descriptor.name == toolName
        }
    }

    public func executeCoreLocalFileOrTextTool(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> String? {
        guard let tool = Self.coreLocalFileAndTextTools.first(where: {
            $0.descriptor.name == toolCall.name
        }) else {
            return nil
        }

        let outputData = try await tool.invoke(
            inputData: Data(toolCall.argumentsJSON.utf8),
            context: FeatureContext(
                workingDirectory: workingDirectory,
                environment: DeveloperToolEnvironment.processEnvironment()
            )
        )
        return try Self.renderCoreLocalOutput(outputData)
    }

    private static var coreLocalFileAndTextTools: [AnyFeatureTool] {
        LocalFeatureTools.fileTools() + LocalFeatureTools.textTools()
    }

    private static func renderCoreLocalOutput(_ data: Data) throws -> String {
        if let string = try? JSONDecoder().decode(String.self, from: data) {
            return string
        }

        let output = try JSONDecoder().decode(JSONValue.self, from: data)
        switch output {
        case let .string(value):
            return value
        case let .number(value):
            return "\(value)"
        case let .bool(value):
            return "\(value)"
        case .null:
            return "null"
        case .array, .object:
            return output.prettyPrinted()
        }
    }
}
