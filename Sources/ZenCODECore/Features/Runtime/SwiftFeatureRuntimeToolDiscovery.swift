//
//  SwiftFeatureRuntimeToolDiscovery.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import FeatureKit
import ToolCore

extension SwiftFeatureRuntime {
    func tools(for feature: SwiftFeatureBundle) async -> [ToolDescriptor] {
        guard feature.discoversToolsAtRuntime else {
            return feature.tools
        }

        if let cachedTools = runtimeDiscoveredToolsByFeatureID[feature.id] {
            return cachedTools
        }

        let discoveredTools = (try? await discoverRuntimeTools(feature: feature)) ?? []
        let canonicalTools = ToolDescriptor.canonicalized(feature.tools + discoveredTools)
        runtimeDiscoveredToolsByFeatureID[feature.id] = canonicalTools
        return canonicalTools
    }

    /// The tools of `feature` already known, without discovering them: its
    /// cached discovery when it discovers its tools at runtime and has one,
    /// otherwise its declared tools. Never starts a process.
    func knownTools(for feature: SwiftFeatureBundle) -> [ToolDescriptor] {
        guard feature.discoversToolsAtRuntime else {
            return feature.tools
        }
        return runtimeDiscoveredToolsByFeatureID[feature.id] ?? feature.tools
    }

    private func discoverRuntimeTools(
        feature: SwiftFeatureBundle
    ) async throws -> [ToolDescriptor] {
        // No timeout: a feature may trigger a user-consent dialog while listing
        // tools, and the process must wait until the user responds.
        let responseData: Data
        if feature.supportsPersistentSession {
            responseData = try await persistentResponse(
                for: feature,
                request: FeaturePersistentRequest(operation: .listTools)
            )
        } else {
            let result = try await AsyncProcessRunner.run(
                executableURL: feature.executableURL,
                arguments: ["--list-tools"],
                workingDirectory: feature.executableURL.deletingLastPathComponent(),
                environment: DeveloperToolEnvironment.processEnvironment()
            )
            guard result.exitCode == 0 else {
                return []
            }
            responseData = result.stdoutData
        }

        let response = try JSONDecoder().decode(
            FeatureListToolsResponse.self,
            from: responseData
        )
        return response.tools.map(\.toolDescriptor)
    }
}
