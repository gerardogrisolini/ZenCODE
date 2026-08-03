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
        let featureArguments = Array(arguments.dropFirst())
        if FeatureProcessProtocol.isPersistentService(arguments: featureArguments) {
            await runPersistentService(tools: tools, environment: environment)
            return
        }
        let command = FeatureProcessProtocol.parse(arguments: featureArguments)
        do {
            switch command {
            case .listTools:
                try FeatureProcessProtocol.emitJSON(
                    FeatureListToolsResponse(
                        tools: FeatureToolDescriptor.canonicalized(tools.map(\.descriptor))
                    )
                )
            case let .invoke(toolName, workingDirectory):
                let response = try await invokeResponse(
                    tools: tools,
                    toolName: toolName,
                    workingDirectory: workingDirectory,
                    inputData: FileHandle.standardInput.readDataToEndOfFile(),
                    environment: environment
                )
                FileHandle.standardOutput.write(response)
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

    private static func invokeResponse(
        tools: [AnyFeatureTool],
        toolName: String,
        workingDirectory: URL?,
        inputData: Data,
        environment: [String: String]
    ) async throws -> Data {
        guard let tool = tools.first(where: { $0.descriptor.name == toolName }) else {
            throw FeatureRunnerError.unknownTool(toolName)
        }
        let context = FeatureContext(
            workingDirectory: workingDirectory
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: environment
        )
        let invocationResult = try await tool.invokeResult(
            inputData: inputData,
            context: context
        )
        return try FeatureProcessProtocol.renderSuccess(
            outputData: invocationResult.outputData,
            attachments: invocationResult.attachments
        )
    }

    private static func runPersistentService(
        tools: [AnyFeatureTool],
        environment: [String: String]
    ) async {
        await FeaturePersistentService.run { request in
            switch request.operation {
            case .listTools:
                return try FeatureProcessProtocol.renderJSON(
                    FeatureListToolsResponse(
                        tools: FeatureToolDescriptor.canonicalized(tools.map(\.descriptor))
                    )
                )
            case .invoke:
                guard let toolName = request.toolName else {
                    throw FeatureRunnerError.unknownTool("")
                }
                return try await invokeResponse(
                    tools: tools,
                    toolName: toolName,
                    workingDirectory: request.workingDirectoryPath.map(URL.init(fileURLWithPath:)),
                    inputData: request.inputData ?? Data(),
                    environment: environment
                )
            case .shutdown:
                return Data()
            }
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
