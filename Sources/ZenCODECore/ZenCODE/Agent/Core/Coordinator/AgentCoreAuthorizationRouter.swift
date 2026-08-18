import Foundation

/// Routes authorization by exact turn/session identity and owns every retained
/// handler. The lifecycle API removes all entries for a session atomically,
/// preventing delegated authorization state from outliving session teardown.
struct AgentCoreAuthorizationRouter {
    private var promptHandlers: [UUID: AgentToolAuthorizationHandler] = [:]
    private var promptSessionIDs: [UUID: String] = [:]
    private var sessionHandlers: [String: AgentToolAuthorizationHandler] = [:]
    private(set) var localExecAccessMode: AgentLocalExecAccessMode = .standard

    mutating func toggleLocalExecAccessMode() -> AgentLocalExecAccessMode {
        localExecAccessMode = localExecAccessMode.next
        return localExecAccessMode
    }

    mutating func resetLocalExecAccessMode() {
        localExecAccessMode = .standard
    }

    mutating func register(
        promptID: UUID,
        sessionID: String,
        handler: @escaping AgentToolAuthorizationHandler
    ) {
        promptHandlers[promptID] = handler
        promptSessionIDs[promptID] = sessionID
        sessionHandlers[sessionID] = handler
    }

    mutating func clear(promptID: UUID) {
        promptHandlers.removeValue(forKey: promptID)
        promptSessionIDs.removeValue(forKey: promptID)
    }

    mutating func discard(sessionID: String) {
        let promptIDs = promptSessionIDs.compactMap { $0.value == sessionID ? $0.key : nil }
        for promptID in promptIDs { clear(promptID: promptID) }
        sessionHandlers.removeValue(forKey: sessionID)
    }

    mutating func discardAll() {
        promptHandlers.removeAll()
        promptSessionIDs.removeAll()
        sessionHandlers.removeAll()
    }

    func handler(forPromptID promptID: UUID, sessionID: String) -> AgentToolAuthorizationHandler? {
        guard promptSessionIDs[promptID] == sessionID else { return nil }
        return promptHandlers[promptID]
    }

    func handler(forSessionID sessionID: String) -> AgentToolAuthorizationHandler? {
        sessionHandlers[sessionID]
    }

    func knows(sessionID: String) -> Bool {
        sessionHandlers[sessionID] != nil
    }

    var retainedSessionCount: Int { sessionHandlers.count }
}
