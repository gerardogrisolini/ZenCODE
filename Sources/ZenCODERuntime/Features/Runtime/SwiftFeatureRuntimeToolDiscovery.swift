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

        // Only a successful discovery is cached (even an empty one: a valid
        // empty response is a success). A failed one (feature unavailable,
        // consent declined, process exited) is not remembered, so it is
        // retried on the next request until it succeeds.
        guard let discoveredTools = try? await discoverRuntimeTools(feature: feature) else {
            return ToolDescriptor.canonicalized(feature.tools)
        }
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

    /// The tools `feature` lists, or `nil` when its one-shot `--list-tools`
    /// exits with a failure status. Persistent-session errors, error frames
    /// and undecodable responses throw.
    private func discoverRuntimeTools(
        feature: SwiftFeatureBundle
    ) async throws -> [ToolDescriptor]? {
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
                return nil
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
