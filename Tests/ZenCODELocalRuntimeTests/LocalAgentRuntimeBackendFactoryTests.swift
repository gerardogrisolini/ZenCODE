import Foundation
import Testing
@testable import LocalRuntimeSupport
import ZenCODECore

@Suite("Local agent runtime backend factory")
struct LocalAgentRuntimeBackendFactoryTests {
    @Test("routes eligible configurations locally and other configurations remotely")
    func routesLocalAndRemoteConfigurations() async throws {
        let factory = makeFactory()
        let mcpRuntime = DirectMCPToolRuntime()

        let local = try factory.makeBackend(
            configuration: configuration(modelID: "local"),
            mcpRuntime: mcpRuntime
        ) as! FakeBackend
        let remote = try factory.factory(
            configuration(modelID: "remote"),
            mcpRuntime
        ) as! FakeBackend

        let localKind = local.kind
        let remoteKind = remote.kind
        let remoteModelID = remote.configuration.modelID
        let remoteScopeID = remote.chatGPTConnectionScopeID
        #expect(localKind == .local)
        #expect(remoteKind == .remote)
        #expect(remoteModelID == "remote")
        #expect(remoteScopeID == nil)
    }

    @Test("contextual sub-agents re-route their configuration with a fresh scope ID")
    func contextualSubAgentsUseContextAndScopeID() async throws {
        let factory = makeFactory()
        let parent = try factory.makeBackend(
            configuration: configuration(modelID: "local"),
            mcpRuntime: DirectMCPToolRuntime()
        ) as! FakeBackend
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "remote-agent",
            requestedRole: "worker",
            isolationMode: .report,
            profile: AgentProfile(id: "remote-agent", name: "Remote", modelID: "remote")
        )

        let child = try await parent.makeContextualBackend(context) as! FakeBackend
        let childKind = child.kind
        let childModelID = child.configuration.modelID
        let childScopeID = child.chatGPTConnectionScopeID

        #expect(childKind == .remote)
        #expect(childModelID == "remote")
        #expect(childScopeID == "test-fresh-scope")
    }

    @Test("contextual sub-agents inherit the parent's swiftFeatureRuntime")
    func contextualSubAgentsInheritSwiftFeatureRuntime() async throws {
        let parentRuntime = SwiftFeatureRuntime()
        let factory = makeFactory()
        let parent = try factory.makeBackend(
            configuration: configuration(modelID: "local"),
            mcpRuntime: DirectMCPToolRuntime(),
            swiftFeatureRuntime: parentRuntime
        ) as! FakeBackend

        // Parent backend should have received the runtime.
        let parentReceivedRuntime = await parent.swiftFeatureRuntime
        #expect(parentReceivedRuntime === parentRuntime)

        // Sub-agent created via contextual factory should inherit the same instance.
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "child-agent",
            requestedRole: "worker",
            isolationMode: .report,
            profile: AgentProfile(id: "child-agent", name: "Child", modelID: "local")
        )
        let child = try await parent.makeContextualBackend(context) as! FakeBackend
        let childReceivedRuntime = await child.swiftFeatureRuntime
        #expect(childReceivedRuntime === parentRuntime)
    }

    private func makeFactory() -> LocalAgentRuntimeBackendFactory<String> {
        LocalAgentRuntimeBackendFactory(
            eligibility: { $0.modelID == "local" ? "local" : nil },
            localBackendBuilder: { _, configuration, _, swiftFeatureRuntime, contextualBackendFactory in
                FakeBackend(
                    kind: .local,
                    configuration: configuration,
                    swiftFeatureRuntime: swiftFeatureRuntime,
                    contextualBackendFactory: contextualBackendFactory.factory
                )
            },
            remoteBackendBuilder: { configuration, _, scopeID, swiftFeatureRuntime in
                FakeBackend(
                    kind: .remote,
                    configuration: configuration,
                    chatGPTConnectionScopeID: scopeID,
                    swiftFeatureRuntime: swiftFeatureRuntime
                )
            },
            chatGPTConnectionScopeIDSupplier: { "test-fresh-scope" }
        )
    }

    private func configuration(modelID: String) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            maxToolRounds: 1,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
    }
}

private actor FakeBackend: AgentRuntimeBackend {
    enum Kind: Sendable, Equatable {
        case local
        case remote
    }

    let kind: Kind
    let configuration: AgentRuntimeConfiguration
    let chatGPTConnectionScopeID: String?
    let swiftFeatureRuntime: SwiftFeatureRuntime?
    private let contextualBackendFactory: DirectSubAgentContextualBackendFactory?

    init(
        kind: Kind,
        configuration: AgentRuntimeConfiguration,
        chatGPTConnectionScopeID: String? = nil,
        swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
        contextualBackendFactory: DirectSubAgentContextualBackendFactory? = nil
    ) {
        self.kind = kind
        self.configuration = configuration
        self.chatGPTConnectionScopeID = chatGPTConnectionScopeID
        self.swiftFeatureRuntime = swiftFeatureRuntime
        self.contextualBackendFactory = contextualBackendFactory
    }

    func makeContextualBackend(
        _ context: DirectSubAgentRuntime.BackendContext
    ) throws -> any AgentRuntimeBackend {
        guard let contextualBackendFactory else {
            fatalError("No contextual backend factory")
        }
        return try contextualBackendFactory(context)
    }

    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) async {}
    func shutdown() async {}
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { fatalError("Unused in this test") }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { fatalError("Unused in this test") }
    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment], onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse { fatalError("Unused in this test") }
}
