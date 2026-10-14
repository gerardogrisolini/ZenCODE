import Synchronization
@testable import ZenCODECore

// Shared only by this suite's thematic files. Domain-specific fixtures remain
// private beside the scenarios that use them.
func builtInDirectSubAgentProfileResolver(
    _ payload: DirectSubAgentRuntime.RequestedAgentPayload
) -> AgentProfile? {
    DirectSubAgentRuntime.agentProfile(
        matching: payload,
        in: AgentProfileStore.defaultProfiles()
    )
}

func makeDirectSubAgentRuntime(backend: any AgentRuntimeBackend) -> DirectSubAgentRuntime {
    DirectSubAgentRuntime(
        contextualBackendFactory: { _ in backend },
        profileResolver: builtInDirectSubAgentProfileResolver
    )
}

final class SubAgentFactoryRecorder: Sendable {
    private let recordedContexts = Mutex<[DirectSubAgentRuntime.BackendContext]>([])

    var contexts: [DirectSubAgentRuntime.BackendContext] {
        recordedContexts.withLock { $0 }
    }

    func append(_ context: DirectSubAgentRuntime.BackendContext) {
        recordedContexts.withLock { $0.append(context) }
    }
}

extension DirectSubAgentRuntime {
    /// `createAgents`, `agent.message`, and shared-chat wake-ups install a
    /// single `runTask` synchronously. Await the captured tasks themselves so
    /// tests observe a completed turn rather than an arbitrary `agent.wait`
    /// polling deadline.
    func waitForDirectSubAgentTestWorkLoops(agentID: String? = nil) async {
        let tasks: [Task<Void, Never>]
        if let agentID, let task = agents[agentID]?.runTask {
            tasks = [task]
        } else if agentID != nil {
            tasks = []
        } else {
            tasks = agents.values.compactMap(\.runTask)
        }
        for task in tasks {
            await task.value
        }
    }
}
