import DS4RuntimeShim
import Foundation
import LocalRuntimeSupport
import ZenCODECore

struct DS4LocalAgentRuntimeAdapter: @unchecked Sendable {
    private let backendFactory: LocalAgentRuntimeBackendFactory<Void>

    init(runtimeOptions: DS4RuntimeOptions) {
        backendFactory = LocalAgentRuntimeBackendFactory(
            eligibility: { configuration in
                guard let modelID = configuration.modelID?.nilIfBlank,
                      modelID.caseInsensitiveCompare(runtimeOptions.modelID) != .orderedSame else {
                    return ()
                }
                return nil
            },
            localBackendBuilder: { _, configuration, mcpRuntime, subAgentBackendFactory in
                DS4CoderBackend(
                    configuration: configuration,
                    options: runtimeOptions,
                    mcpRuntime: mcpRuntime,
                    subAgentContextualBackendFactory: subAgentBackendFactory.factory
                )
            }
        )
    }

    func makeBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime
    ) throws -> any AgentRuntimeBackend {
        try backendFactory.makeBackend(configuration: configuration, mcpRuntime: mcpRuntime)
    }

    var factory: AgentRuntimeBackendFactory {
        backendFactory.factory
    }
}
