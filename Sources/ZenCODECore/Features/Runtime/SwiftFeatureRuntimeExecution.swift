//
//  SwiftFeatureRuntimeExecution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import FeatureKit
import Foundation
import ToolCore

extension SwiftFeatureRuntime {
    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        excludingFeatureIDs: Set<String> = []
    ) async -> [DirectToolDescriptor] {
        var resolvedTools: [ToolDescriptor] = []
        var seenToolNames = Set<String>()
        for feature in features where isListed(
            feature,
            allowedToolNames: allowedToolNames,
            excludingFeatureIDs: excludingFeatureIDs
        ) {
            // Runtime discovery invokes the `--list-tools` subprocess and waits
            // for completion, including any feature-owned consent. Only a
            // successful discovery is cached per-feature in
            // `runtimeDiscoveredToolsByFeatureID`, so only the first successful
            // call for each feature incurs the cost; a failed discovery is
            // retried on the next call. When the SwiftFeatureRuntime is shared
            // (parent → subagent), the cache is reused across all sessions.
            let featureTools = feature.discoversToolsAtRuntime
                ? await tools(for: feature)
                : feature.tools
            appendOwnedTools(
                featureTools,
                of: feature,
                to: &resolvedTools,
                seenToolNames: &seenToolNames
            )
        }

        return ToolDescriptor.canonicalized(resolvedTools).map(DirectToolDescriptor.init)
    }

    /// The descriptors ``descriptors(allowedToolNames:excludingFeatureIDs:)``
    /// resolves, from the tools already known only: it never starts a
    /// feature's tool discovery (`--list-tools`) or the consent it can ask
    /// for. A feature that discovers its tools at runtime contributes the
    /// tools its last successful discovery cached, or only its declared tools
    /// when it has no successful discovery since the runtime was created or
    /// its bundles were reloaded (a failed discovery is not cached).
    public func knownDescriptors(
        allowedToolNames: Set<String>? = nil,
        excludingFeatureIDs: Set<String> = []
    ) -> [DirectToolDescriptor] {
        var resolvedTools: [ToolDescriptor] = []
        var seenToolNames = Set<String>()
        for feature in features where isListed(
            feature,
            allowedToolNames: allowedToolNames,
            excludingFeatureIDs: excludingFeatureIDs
        ) {
            appendOwnedTools(
                knownTools(for: feature),
                of: feature,
                to: &resolvedTools,
                seenToolNames: &seenToolNames
            )
        }

        return ToolDescriptor.canonicalized(resolvedTools).map(DirectToolDescriptor.init)
    }

    /// The IDs of the loaded features whose tools a session allowed
    /// `allowedToolNames` lists: the features
    /// ``descriptors(allowedToolNames:excludingFeatureIDs:)`` resolves, and
    /// discovers when they discover their tools at runtime. Never starts a
    /// feature's tool discovery.
    public func featureIDs(relevantTo allowedToolNames: Set<String>?) -> Set<String> {
        Set(
            features
                .filter { $0.isRelevant(allowedToolNames: allowedToolNames) }
                .map(\.id)
        )
    }

    private func isListed(
        _ feature: SwiftFeatureBundle,
        allowedToolNames: Set<String>?,
        excludingFeatureIDs: Set<String>
    ) -> Bool {
        !excludingFeatureIDs.contains(feature.id)
            && feature.isRelevant(allowedToolNames: allowedToolNames)
    }

    /// Appends the tools of `featureTools` whose name is not listed yet and
    /// that `feature` executes.
    private func appendOwnedTools(
        _ featureTools: [ToolDescriptor],
        of feature: SwiftFeatureBundle,
        to resolvedTools: inout [ToolDescriptor],
        seenToolNames: inout Set<String>
    ) {
        for tool in ToolDescriptor.canonicalized(featureTools)
        where seenToolNames.insert(tool.name).inserted
            && features.first(where: { $0.contains(toolName: tool.name) })?.id == feature.id {
            // Execution resolves the first feature containing a name, even
            // when only a later duplicate is relevant to the allowlist. Do
            // not publish that later descriptor with an owner that cannot
            // execute it.
            resolvedTools.append(tool)
        }
    }

    public func featureToolIsAllowed(
        toolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        // Kernel feature-management commands are never feature-owned, even if
        // an invalid manifest advertises the broad `feature.` prefix.
        guard !Self.isFeatureManagementToolName(toolName) else {
            return false
        }
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
        try await executeResultIfAvailable(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        )?.output
    }

    func executeResultIfAvailable(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> SwiftFeatureInvocationResult? {
        guard let feature = features.first(where: { $0.contains(toolName: toolCall.name) }) else {
            return nil
        }

        if feature.supportsPersistentSession {
            let responseData: Data
            do {
                responseData = try await persistentResponse(
                    for: feature,
                    request: FeaturePersistentRequest(
                        operation: .invoke,
                        toolName: toolCall.name,
                        workingDirectoryPath: workingDirectory.path,
                        inputData: Data(toolCall.argumentsJSON.utf8)
                    ),
                    timeout: feature.invocationTimeoutSeconds ?? 60
                )
            } catch let error as FeaturePersistentProcessError where error.kind == .timedOut {
                throw DirectToolError.timedOut(
                    "Swift feature '\(feature.id)' timed out.\n\(error.localizedDescription)"
                )
            }
            return try Self.invocationResult(responseData, feature: feature)
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
        return try Self.invocationResult(result, feature: feature)
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
