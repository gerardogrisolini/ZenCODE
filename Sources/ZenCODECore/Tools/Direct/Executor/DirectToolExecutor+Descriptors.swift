//
//  DirectToolExecutor+Descriptors.swift
//  ZenCODE
//
//  The tool descriptors offered to a session and the static allowlist
//  filtering of tool names, including the core coordination aliases.
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore

extension DirectToolExecutor {
    /// The tool descriptors available to `sessionID`, filtered by
    /// `allowedToolNames`.
    ///
    /// With `discoversFeatureTools` (the default) a relevant feature that
    /// discovers its tools at runtime and has no successful discovery cached
    /// (not discovered yet, last discovery failed, or discovery cleared by a
    /// reload of the feature bundles) is discovered now (`--list-tools`, and
    /// the consent it can ask for).
    /// Without it the descriptors are only the ones already known
    /// (``SwiftFeatureRuntime/knownDescriptors(allowedToolNames:excludingFeatureIDs:sessionID:)``):
    /// nothing is discovered, so such a feature contributes only its declared
    /// tools.
    ///
    /// The features a Builder sub-agent delegated by `sessionID` built and
    /// that are loaded are listed even when `allowedToolNames` does not name
    /// them (``SwiftFeatureRuntime/exposedFeatureIDs(sessionID:)``); a
    /// sub-agent that inherits its delegating session's exposures reads that
    /// session's instead.
    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil,
        sessionID: String? = nil,
        discoversFeatureTools: Bool = true
    ) async -> [DirectToolDescriptor] {
        if MemoryConsolidationContext.isIsolated || allowedToolNames?.isEmpty == true {
            return []
        }
        let preferredWorkspaceRootURL = preferredWorkspaceRootURL
            ?? self.preferredWorkspaceRootURL

        let providerRegistry = toolProviderRegistry(forSessionID: sessionID)
        let providerDescriptors = providerRegistry.descriptors
        #if canImport(Darwin) || canImport(Glibc)
        let processDescriptors = DirectToolCatalog.coreProcessDescriptors
        #else
        let processDescriptors: [DirectToolDescriptor] = []
        #endif
        let protectedCoreDescriptors = Self.filtered(
            Self.canonicalized(
                DirectToolCatalog.coreLocalFileAndTextDescriptors + processDescriptors
            ),
            allowedToolNames: allowedToolNames
        )
        let providerPriorityDescriptors = Self.filtered(
            Self.canonicalized(
                providerDescriptors + DirectToolCatalog.skillToolDescriptors
            ),
            allowedToolNames: allowedToolNames
        )
        let providerToolNames = Set(providerDescriptors.map(\.name))
        let reservedSkillToolNames = PromptSkillToolProvider.toolNames
        // MCP servers installed by an ACP session are owned by that session
        // incarnation; sub-agents delegated from the same root session share
        // them through the root room id.
        let mcpScopeSessionID = sharedChatRootSessionID ?? sessionID
        let mcpDescriptors = await mcpRuntime.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            sessionID: mcpScopeSessionID
        )
        .filter { !providerToolNames.contains($0.name) }
        .filter { !reservedSkillToolNames.contains($0.name) }
        let featureExposureSessionID = featureExposureSessionID(for: sessionID)
        let resolvedFeatureDescriptors = if discoversFeatureTools {
            await swiftFeatureRuntime.descriptors(
                allowedToolNames: allowedToolNames,
                sessionID: featureExposureSessionID
            )
        } else {
            await swiftFeatureRuntime.knownDescriptors(
                allowedToolNames: allowedToolNames,
                sessionID: featureExposureSessionID
            )
        }
        let featureDescriptors = resolvedFeatureDescriptors
            .filter { !reservedSkillToolNames.contains($0.name) }

        let featureManagementDescriptors = Self.filtered(
            DirectToolCatalog.featureDescriptors,
            allowedToolNames: allowedToolNames
        )
        let lateCoreDescriptors = Self.filtered(
            DirectToolCatalog.subAgentDescriptors
                + DirectToolCatalog.todoTaskDescriptors
                + DirectToolCatalog.memoryDescriptors,
            allowedToolNames: allowedToolNames
        )
        let result = Self.canonicalized(
            protectedCoreDescriptors
                + providerPriorityDescriptors
                + mcpDescriptors
                + featureManagementDescriptors
                + featureDescriptors
                + lateCoreDescriptors
        ).map(Self.clientTextFileDescriptor)

        guard await taskToolAdapter.isTaskBound(sessionID: sessionID) else {
            return result
        }
        return result.map(Self.taskBoundDescriptor)
    }

    private static func taskBoundDescriptor(
        _ descriptor: DirectToolDescriptor
    ) -> DirectToolDescriptor {
        guard descriptor.name == "tasks.update" else { return descriptor }
        return DirectToolDescriptor(
            name: descriptor.name,
            description: "Reports progress for your assigned task attempt. As a task-bound "
                + "sub-agent, call this only with your task id and `output` (or `progress`); "
                + "you may also include `statusReason` and `expectedRevision`. Do not set "
                + "status, error, evidence, metadata, dependencies, or result fields. Your "
                + "final response is recorded automatically as the attempt result and lifecycle "
                + "completion is owned by the runtime.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"output":{"type":"string"},"progress":{"type":"string"},"statusReason":{"type":"string"},"status_reason":{"type":"string"},"expectedRevision":{"type":"integer"},"expected_revision":{"type":"integer"}},"required":["id"]}"#,
            title: descriptor.title,
            outputSchema: descriptor.outputSchema,
            presentation: descriptor.presentation
        )
    }

    public static func filtered(
        _ descriptors: [DirectToolDescriptor],
        allowedToolNames: Set<String>?
    ) -> [DirectToolDescriptor] {
        guard let allowedToolNames else {
            return descriptors
        }

        guard !allowedToolNames.isEmpty else {
            return []
        }

        return descriptors.filter {
            isAllowed($0.name, allowedToolNames: allowedToolNames)
        }
    }

    public static func isAllowed(
        _ toolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let allowedToolNames else {
            return true
        }

        guard !allowedToolNames.isEmpty else {
            return false
        }

        if ToolAllowlist.matches(toolName, in: allowedToolNames) {
            return true
        }

        if let canonicalCoordinationToolName = SubAgentToolRequestCompatibility.canonicalToolName(for: toolName),
           allowedToolNames.contains(canonicalCoordinationToolName) {
            return true
        }

        return false
    }

    /// Returns the catalog-owned coordination tool reached by a compatibility
    /// alias, if any. This intentionally recognizes only names that the direct
    /// executor can dispatch to its Todo, Task, or Sub-Agent runtimes.
    ///
    /// Provider, feature, and MCP dispatch retain precedence over this fallback
    /// path, so an externally registered raw tool name is never reclassified
    /// merely because it resembles a legacy coordination alias.
    static func canonicalCoreCoordinationToolName(
        for rawToolName: String
    ) -> String? {
        guard let canonicalName = SubAgentToolRequestCompatibility.canonicalToolName(
            for: rawToolName
        ), DirectToolCatalog.coreDescriptors.contains(where: { descriptor in
            descriptor.name == canonicalName
        }) else {
            return nil
        }
        return canonicalName
    }

    /// Authorization for a compatibility-dispatched coordination tool must be
    /// evaluated against its canonical catalog name, not the raw alias. A
    /// read-only profile may retain an external grant named like an alias, but
    /// that grant cannot unlock the core action reached by fallback dispatch.
    static func isCoreCoordinationToolAllowed(
        _ rawToolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let canonicalName = canonicalCoreCoordinationToolName(
            for: rawToolName
        ) else {
            return false
        }
        return isAllowed(canonicalName, allowedToolNames: allowedToolNames)
    }
}
