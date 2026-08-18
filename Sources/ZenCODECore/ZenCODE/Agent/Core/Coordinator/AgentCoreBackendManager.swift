import Foundation

/// Runner-owned backend lifecycle state. The runner remains the public facade
/// and coordinates suspension points; this seam centralizes generation fencing
/// and single-flight ownership so stale backends cannot be installed ad hoc.
struct AgentCoreBackendManager {
    struct InvalidatedError: Error {}

    var backend: AgentCoreBackend?
    var preparation: Task<AgentCoreBackend, Error>?
    private(set) var generation: UInt64 = 0
    private(set) var shutdownGeneration: UInt64 = 0
    var activeConfiguration: AgentCoreSessionConfiguration?

    mutating func invalidateBackend() -> AgentCoreBackend? {
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        activeConfiguration = nil
        let retired = backend
        backend = nil
        return retired
    }

    mutating func latchShutdown() {
        shutdownGeneration &+= 1
    }

    func verify(generation expected: UInt64) throws {
        guard expected == generation else { throw InvalidatedError() }
    }

    func isCurrent(generation expected: UInt64) -> Bool {
        expected == generation
    }

    func verifyShutdown(generation expected: UInt64) throws {
        guard expected == shutdownGeneration else { throw InvalidatedError() }
    }
}
