//
//  AnyFeatureTool.swift
//  ZenCODE
//

import Foundation

public struct AnyFeatureTool: Sendable {
    public let descriptor: FeatureToolDescriptor
    private let invokeBody: @Sendable (
        Data,
        FeatureContext
    ) async throws -> AnyFeatureToolInvocationResult

    public init<T: FeatureTool>(_ tool: T) {
        self.descriptor = FeatureToolDescriptor(
            name: T.name,
            description: T.description,
            inputSchema: T.inputSchema,
            outputSchema: T.outputSchema,
            presentation: T.presentation
        )
        self.invokeBody = { inputData, context in
            let normalizedInputData = inputData.isEmpty ? Data("{}".utf8) : inputData
            let input = try JSONDecoder().decode(T.Input.self, from: normalizedInputData)
            let output = try await tool.run(input, context: context)
            let attachments = (output as? any FeatureInvocationAttachmentProviding)?
                .featureInvocationAttachments ?? []
            return AnyFeatureToolInvocationResult(
                outputData: try JSONEncoder().encode(output),
                attachments: attachments
            )
        }
    }

    public func invoke(
        inputData: Data,
        context: FeatureContext
    ) async throws -> Data {
        try await invokeResult(inputData: inputData, context: context).outputData
    }

    public func invokeResult(
        inputData: Data,
        context: FeatureContext
    ) async throws -> AnyFeatureToolInvocationResult {
        try await invokeBody(inputData, context)
    }
}
