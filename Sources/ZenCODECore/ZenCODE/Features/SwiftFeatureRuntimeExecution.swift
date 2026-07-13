//
//  SwiftFeatureRuntimeExecution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

extension SwiftFeatureRuntime {
    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        excludingFeatureIDs: Set<String> = []
    ) async -> [DirectToolDescriptor] {
        var resolvedTools: [ToolDescriptor] = []
        for feature in features {
            guard !excludingFeatureIDs.contains(feature.id),
                  feature.isRelevant(allowedToolNames: allowedToolNames) else {
                continue
            }

            // Runtime discovery: invokes `--list-tools` subprocess and blocks
            // until completion (or user consent for xcode-tools). Results are
            // cached per-feature in `runtimeDiscoveredToolsByFeatureID`, so only
            // the first call for each feature incurs the cost. When the
            // SwiftFeatureRuntime is shared (parent → subagent), the cache is
            // reused across all sessions.
            if feature.discoversToolsAtRuntime {
                resolvedTools.append(contentsOf: await tools(for: feature))
            } else {
                resolvedTools.append(contentsOf: feature.tools)
            }
        }

        return ToolDescriptor.canonicalized(resolvedTools).map(DirectToolDescriptor.init)
    }

    public func featureToolIsAllowed(
        toolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let feature = features.first(where: { $0.contains(toolName: toolName) }) else {
            return false
        }
        return feature.isRelevant(allowedToolNames: allowedToolNames)
    }

    public func canExecute(toolName: String) -> Bool {
        features.contains { $0.contains(toolName: toolName) }
    }

    public func executeIfAvailable(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> String? {
        guard let feature = features.first(where: { $0.contains(toolName: toolCall.name) }) else {
            return nil
        }

        let result = try await AsyncProcessRunner.run(
            executableURL: feature.executableURL,
            arguments: [
                "--invoke",
                toolCall.name,
                "--working-directory",
                workingDirectory.path
            ],
            workingDirectory: workingDirectory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            stdinData: Data(toolCall.argumentsJSON.utf8),
            timeout: feature.invocationTimeoutSeconds ?? 60
        )
        return try Self.renderInvocationResult(result, feature: feature)
    }

    public func featureStatuses(
        includeTools: Bool = true,
        includeDisabled: Bool = true,
        discoverRuntimeTools: Bool = false
    ) async -> [SwiftFeatureStatus] {
        var statuses = explicitFeatures == nil
            ? Self.defaultFeatureRecords(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            ).map { Self.status(from: $0, tools: includeTools ? $0.tools.map(\.name) : []) }
            : features.map {
                Self.status(
                    from: $0,
                    enabled: true,
                    available: fileManager.isExecutableFile(atPath: $0.executableURL.path),
                    manifestPath: nil,
                    issue: nil,
                    tools: includeTools ? $0.tools.map(\.name) : []
                )
            }

        if includeTools && discoverRuntimeTools {
            for feature in features {
                let tools = await tools(for: feature).map(\.name)
                guard let index = statuses.firstIndex(where: { $0.id == feature.id }) else {
                    continue
                }
                let current = statuses[index]
                statuses[index] = SwiftFeatureStatus(
                    id: current.id,
                    displayName: current.displayName,
                    description: current.description,
                    source: current.source,
                    isCore: current.isCore,
                    adoptedFrom: current.adoptedFrom,
                    editable: current.editable,
                    adoptable: current.adoptable,
                    enabled: current.enabled,
                    available: current.available,
                    executablePath: current.executablePath,
                    manifestPath: current.manifestPath,
                    tools: tools,
                    toolNamePrefixes: current.toolNamePrefixes,
                    toolNameAliases: current.toolNameAliases,
                    discoversToolsAtRuntime: current.discoversToolsAtRuntime,
                    build: current.build,
                    generated: current.generated,
                    issue: current.issue
                )
            }
        }

        if !includeDisabled {
            statuses = statuses.filter(\.enabled)
        }
        return statuses.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}
