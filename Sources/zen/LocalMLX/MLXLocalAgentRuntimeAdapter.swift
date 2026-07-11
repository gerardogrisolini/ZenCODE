#if ZENCODE_LOCAL_MLX
import LocalRuntimeSupport
import ZenCODECore
import MLXServerCore

struct MLXLocalAgentRuntimeAdapter: @unchecked Sendable {
    private let backendFactory: LocalAgentRuntimeBackendFactory<MLXServerModelDescriptor>

    init(
        modelCatalog: MLXServerModelCatalog,
        initialModelID: String,
        runtime: MLXServerRuntime,
        kvCacheSettings: MLXServerKVCacheSettings
    ) {
        backendFactory = LocalAgentRuntimeBackendFactory(
            eligibility: { configuration in
                try? modelCatalog.resolve(id: configuration.modelID ?? initialModelID)
            },
            localBackendBuilder: { model, configuration, mcpRuntime, subAgentBackendFactory in
                MLXServerCoderBackend(
                    configuration: configuration,
                    runtime: runtime,
                    model: model,
                    kvCacheSettings: kvCacheSettings,
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
#endif
