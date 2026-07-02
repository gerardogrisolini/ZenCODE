//
//  SwiftFeatureRuntimeToolDiscovery.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

extension SwiftFeatureRuntime {
    func tools(for feature: SwiftFeatureBundle) async -> [ToolDescriptor] {
        guard feature.discoversToolsAtRuntime else {
            return feature.tools
        }

        if let cachedTools = runtimeDiscoveredToolsByFeatureID[feature.id] {
            return cachedTools
        }

        let discoveredTools = (try? await Self.discoverRuntimeTools(feature: feature)) ?? []
        let canonicalTools = ToolDescriptor.canonicalized(feature.tools + discoveredTools)
        runtimeDiscoveredToolsByFeatureID[feature.id] = canonicalTools
        return canonicalTools
    }

    private static func discoverRuntimeTools(
        feature: SwiftFeatureBundle
    ) async throws -> [ToolDescriptor] {
        let result = try await AsyncProcessRunner.run(
            executableURL: feature.executableURL,
            arguments: ["--list-tools"],
            workingDirectory: feature.executableURL.deletingLastPathComponent(),
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 10
        )

        guard !result.timedOut,
              result.exitCode == 0 else {
            return []
        }

        let response = try JSONDecoder().decode(
            SwiftFeatureListToolsResponse.self,
            from: result.stdoutData
        )
        return response.tools
    }
}

private struct SwiftFeatureListToolsResponse: Decodable {
    let tools: [ToolDescriptor]
}
