//
//  AnyFeatureTool.swift
//  ZenCODE
//

import Foundation

public struct AnyFeatureTool: Sendable {
    public let descriptor: FeatureToolDescriptor
    private let invokeBody: @Sendable (Data, FeatureContext) async throws -> Data

    public init<T: FeatureTool>(_ tool: T) {
        self.descriptor = FeatureToolDescriptor(
            name: T.name,
            description: T.description,
            inputSchema: T.inputSchema,
            outputSchema: T.outputSchema
        )
        self.invokeBody = { inputData, context in
            let normalizedInputData = inputData.isEmpty ? Data("{}".utf8) : inputData
            let input = try JSONDecoder().decode(T.Input.self, from: normalizedInputData)
            let output = try await tool.run(input, context: context)
            return try JSONEncoder().encode(output)
        }
    }

    public func invoke(
        inputData: Data,
        context: FeatureContext
    ) async throws -> Data {
        try await invokeBody(inputData, context)
    }
}
