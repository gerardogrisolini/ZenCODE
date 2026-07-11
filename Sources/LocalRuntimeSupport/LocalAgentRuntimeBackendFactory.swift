import Foundation
import ZenCODECore

/// Retains a contextual sub-agent backend factory for local backends that
/// create sub-agents after their own initialization has completed.
package final class LocalAgentRuntimeContextualBackendFactory: @unchecked Sendable {
    private let makeBackendClosure: DirectSubAgentContextualBackendFactory

    package init(_ makeBackend: @escaping DirectSubAgentContextualBackendFactory) {
        makeBackendClosure = makeBackend
    }

    package var factory: DirectSubAgentContextualBackendFactory {
        makeBackendClosure
    }
}

/// Routes a local runtime's eligible configurations to its backend and all
/// other configurations to the standard remote backend.
package struct LocalAgentRuntimeBackendFactory<LocalConfiguration>: @unchecked Sendable {
    package typealias Eligibility = @Sendable (AgentRuntimeConfiguration) -> LocalConfiguration?
    package typealias LocalBackendBuilder = @Sendable (
        LocalConfiguration,
        AgentRuntimeConfiguration,
        DirectMCPToolRuntime,
        LocalAgentRuntimeContextualBackendFactory
    ) throws -> any AgentRuntimeBackend
    package typealias RemoteBackendBuilder = @Sendable (
        AgentRuntimeConfiguration,
        DirectMCPToolRuntime,
        String?
    ) throws -> any AgentRuntimeBackend
    package typealias ChatGPTConnectionScopeIDSupplier = @Sendable () -> String

    private let eligibility: Eligibility
    private let localBackendBuilder: LocalBackendBuilder
    private let remoteBackendBuilder: RemoteBackendBuilder
    private let chatGPTConnectionScopeIDSupplier: ChatGPTConnectionScopeIDSupplier

    package init(
        eligibility: @escaping Eligibility,
        localBackendBuilder: @escaping LocalBackendBuilder,
        remoteBackendBuilder: @escaping RemoteBackendBuilder = { configuration, mcpRuntime, scopeID in
            try AgentCoreBackend.makeRemoteBackend(
                configuration: configuration,
                mcpRuntime: mcpRuntime,
                chatGPTConnectionScopeID: scopeID
            )
        },
        chatGPTConnectionScopeIDSupplier: @escaping ChatGPTConnectionScopeIDSupplier = {
            UUID().uuidString
        }
    ) {
        self.eligibility = eligibility
        self.localBackendBuilder = localBackendBuilder
        self.remoteBackendBuilder = remoteBackendBuilder
        self.chatGPTConnectionScopeIDSupplier = chatGPTConnectionScopeIDSupplier
    }

    package func makeBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime,
        chatGPTConnectionScopeID: String? = nil
    ) throws -> any AgentRuntimeBackend {
        guard let localConfiguration = eligibility(configuration) else {
            return try remoteBackendBuilder(
                configuration,
                mcpRuntime,
                chatGPTConnectionScopeID
            )
        }

        let subAgentBackendFactory = LocalAgentRuntimeContextualBackendFactory {
            context in
            try makeBackend(
                configuration: configuration.applyingSubAgentBackendContext(context),
                mcpRuntime: mcpRuntime,
                chatGPTConnectionScopeID: chatGPTConnectionScopeIDSupplier()
            )
        }

        return try localBackendBuilder(
            localConfiguration,
            configuration,
            mcpRuntime,
            subAgentBackendFactory
        )
    }

    package var factory: AgentRuntimeBackendFactory {
        { configuration, mcpRuntime in
            try makeBackend(configuration: configuration, mcpRuntime: mcpRuntime)
        }
    }
}
