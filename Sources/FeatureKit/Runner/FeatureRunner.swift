//
//  FeatureRunner.swift
//  ZenCODE
//

import Foundation

public enum FeatureRunner {
    public static func run(
        _ tools: [AnyFeatureTool],
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        let command = FeatureProcessProtocol.parse(arguments: Array(arguments.dropFirst()))
        do {
            switch command {
            case .listTools:
                try FeatureProcessProtocol.emitJSON(
                    FeatureListToolsResponse(
                        tools: FeatureToolDescriptor.canonicalized(tools.map(\.descriptor))
                    )
                )
            case let .invoke(toolName, workingDirectory):
                guard let tool = tools.first(where: { $0.descriptor.name == toolName }) else {
                    throw FeatureRunnerError.unknownTool(toolName)
                }
                let inputData = FileHandle.standardInput.readDataToEndOfFile()
                let context = FeatureContext(
                    workingDirectory: workingDirectory
                        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    environment: environment
                )
                let outputData = try await tool.invoke(
                    inputData: inputData,
                    context: context
                )
                FeatureProcessProtocol.emitSuccess(outputData: outputData)
            case .usage:
                try FeatureProcessProtocol.emitJSON(
                    FeatureErrorResponse(error: FeatureProcessProtocol.usageText)
                )
                FeatureProcessProtocol.terminate(code: 64)
            }
        } catch {
            try? FeatureProcessProtocol.emitJSON(
                FeatureErrorResponse(error: error.localizedDescription)
            )
            FeatureProcessProtocol.terminate(code: 1)
        }
    }
}

private enum FeatureRunnerError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(toolName):
            return "Unknown feature tool: \(toolName)"
        }
    }
}
