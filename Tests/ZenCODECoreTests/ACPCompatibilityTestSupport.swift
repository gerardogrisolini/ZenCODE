//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//
import Foundation
@testable import ZenCODECore
import Testing

extension ACPCompatibilityTests {
    func makeBridge(
        models: [AgentSettingsModelManifest],
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles(),
        agentName: String? = nil,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        xcodeIsRunning: @escaping @Sendable () -> Bool = { false }
    ) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: models.first?.id ?? "model",
            agentName: agentName,
            availableAgents: availableAgents,
            availableModels: models,
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        return ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(),
            backendFactory: backendFactory,
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: xcodeIsRunning
        )
    }

    static func xcodeRuntime(workspacePath: String) -> DirectMCPToolRuntime {
        DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                DirectMCPToolRuntime.XcodeDiscovery(
                    executor: XcodeToolExecutor(
                        configuration: MCPServerConfiguration(
                            executablePath: "/usr/bin/false",
                            arguments: [],
                            environment: [:]
                        )
                    ),
                    tools: [
                        ToolDescriptor(
                            name: "BuildProject",
                            description: "Builds an Xcode project",
                            inputSchema: "{}"
                        )
                    ],
                    workspaceContexts: [
                        XcodeWorkspaceContext(
                            workspacePath: workspacePath,
                            defaultTabIdentifier: nil
                        )
                    ],
                    ownsExecutor: false
                )
            }
        )
    }

    static func thinkingModel(
        defaultThinkingSelection: AgentThinkingSelection
    ) -> AgentSettingsModelManifest {
        let provider = AgentRemoteProvider(
            name: "mlx-server",
            baseURL: "http://127.0.0.1",
            modelID: "local/thinking-model"
        )
        return AgentSettingsModelManifest(
            id: "thinking-model",
            kind: .remoteAPI,
            modelID: "local/thinking-model",
            provider: provider,
            thinkingOptions: [.off, .medium, .high],
            defaultThinkingSelection: defaultThinkingSelection
        )
    }
}

extension ZenCODEACPBridge {
    func sessionConfigurationsForTesting() -> [AgentCoreSessionConfiguration] {
        sessions.values.map(\.configuration)
    }

    func installTestSession(_ configuration: AgentCoreSessionConfiguration) {
        sessions[configuration.sessionID] = sessionState(configuration: configuration)
    }

    func testThinkingOptionValues(
        for modelID: String
    ) -> (currentValue: String?, optionValues: [String]?) {
        guard let thinking = configOptions(for: modelID).first(where: {
            $0["id"] as? String == "thinking"
        }) else {
            return (nil, nil)
        }
        let optionValues = (thinking["options"] as? [[String: Any]])?.compactMap { option in
            option["value"] as? String
        }
        return (thinking["currentValue"] as? String, optionValues)
    }

    func testHasThinkingOption(for modelID: String) -> Bool {
        configOptions(for: modelID).contains { option in
            option["id"] as? String == "thinking"
        }
    }

    func testLifecycleThinkingCurrentValue(sessionID: String) -> String? {
        let result = sessionLifecycleResult(sessionID: sessionID)
        let options = result["configOptions"] as? [[String: Any]]
        let thinking = options?.first { option in
            option["id"] as? String == "thinking"
        }
        return thinking?["currentValue"] as? String
    }
}

actor XcodeDiscoveryProbe {
    private var callCount = 0

    func discovery(workspacePath: String) -> DirectMCPToolRuntime.XcodeDiscovery {
        callCount += 1
        return DirectMCPToolRuntime.XcodeDiscovery(
            executor: XcodeToolExecutor(
                configuration: MCPServerConfiguration(
                    executablePath: "/usr/bin/false",
                    arguments: [],
                    environment: [:]
                )
            ),
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project",
                    inputSchema: "{}"
                )
            ],
            workspaceContexts: [
                XcodeWorkspaceContext(
                    workspacePath: workspacePath,
                    defaultTabIdentifier: nil
                )
            ],
            ownsExecutor: false
        )
    }

    func count() -> Int {
        callCount
    }
}

actor CapturingACPBackend: AgentRuntimeBackend {
    private var allowedToolNames: Set<String>?
    private var systemPrompt: String?

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        self.allowedToolNames = allowedToolNames
        self.systemPrompt = systemPrompt
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        self.allowedToolNames = allowedToolNames
        self.systemPrompt = systemPrompt
    }

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

        func createdAllowedToolNames() -> Set<String>? {
        allowedToolNames
    }

    func createdSystemPrompt() -> String? {
        systemPrompt
    }
}

actor RuntimeCacheRecordingACPBackend: AgentRuntimeBackend {
    private var savedIDs: [String] = []
    private var restoredIDs: [String] = []
    private var snapshots: [String: AgentRuntimeSessionSnapshot] = [:]

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        snapshots[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: "test-model",
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard snapshots[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        snapshots.removeValue(forKey: id)
    }

    func shutdown() async {}

    func saveSessionRuntimeCache(id: String) async {
        savedIDs.append(id)
    }

    func restoreSessionRuntimeCache(id: String) async {
        restoredIDs.append(id)
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        snapshots[id]
    }

    func saveCount() -> Int {
        savedIDs.count
    }

    func restoreCount() -> Int {
        restoredIDs.count
    }

    func savedSessionIDs() -> [String] {
        savedIDs
    }

    func restoredSessionIDs() -> [String] {
        restoredIDs
    }
}
