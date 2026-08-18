import Foundation

/// Authoritative in-memory session/snapshot cache for the runner. Session
/// incarnations are fenced here so teardown and late prompt finalization share
/// one invariant instead of manipulating parallel dictionaries independently.
struct AgentCoreSessionSnapshotStore {
    struct Generation: Hashable {
        let rawValue: UInt64
    }

    var configurations: [String: AgentCoreSessionConfiguration] = [:]
    var snapshots: [String: AgentRuntimeSessionSnapshot] = [:]
    private var generations: [String: Generation] = [:]
    private var nextGenerationValue: UInt64 = 1

    mutating func begin(_ configuration: AgentCoreSessionConfiguration) -> Generation {
        configurations[configuration.sessionID] = configuration
        let generation = Generation(rawValue: nextGenerationValue)
        nextGenerationValue &+= 1
        generations[configuration.sessionID] = generation
        return generation
    }

    mutating func update(_ configuration: AgentCoreSessionConfiguration) {
        configurations[configuration.sessionID] = configuration
    }

    mutating func cache(
        _ snapshot: AgentRuntimeSessionSnapshot,
        baseConfiguration: AgentCoreSessionConfiguration,
        generation: Generation?
    ) {
        guard isCurrent(generation, sessionID: snapshot.sessionID) else { return }
        snapshots[snapshot.sessionID] = snapshot
        configurations[snapshot.sessionID] = baseConfiguration.replacingRuntimeState(with: snapshot)
    }

    mutating func cacheCompacted(_ snapshot: AgentRuntimeSessionSnapshot) {
        snapshots[snapshot.sessionID] = snapshot
        if let configuration = configurations[snapshot.sessionID] {
            configurations[snapshot.sessionID] = configuration.replacingRuntimeState(with: snapshot)
        }
    }

    func currentGeneration(for sessionID: String) -> Generation? {
        generations[sessionID]
    }

    func isCurrent(_ generation: Generation?, sessionID: String) -> Bool {
        guard let generation else { return false }
        return generations[sessionID] == generation
    }

    mutating func discard(_ sessionID: String) {
        generations.removeValue(forKey: sessionID)
        configurations.removeValue(forKey: sessionID)
        snapshots.removeValue(forKey: sessionID)
    }

    mutating func discardAll() {
        generations.removeAll()
        configurations.removeAll()
        snapshots.removeAll()
    }

    var sessionIDs: Set<String> {
        Set(configurations.keys).union(snapshots.keys)
    }
}
