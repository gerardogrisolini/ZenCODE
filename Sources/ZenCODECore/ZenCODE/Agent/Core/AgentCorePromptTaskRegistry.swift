//
//  AgentCorePromptTaskRegistry.swift
//  ZenCODE
//
//  Extracted from AgentCoreSessionRunner to isolate prompt-task lifecycle
//  tracking so that the runner stays focused on orchestration.
//

import Foundation

/// Tracks in-flight prompt tasks keyed by prompt ID and session ID.
struct AgentCorePromptTaskRegistry {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var taskIDsBySessionID: [String: Set<UUID>] = [:]
    private var sessionIDsByTaskID: [UUID: String] = [:]

    var allTasks: [UUID: Task<Void, Never>] { tasks }
    var isEmpty: Bool { tasks.isEmpty }

    /// Registers a prompt task so it can be cancelled by session or cleared
    /// when it completes.
    mutating func register(
        _ task: Task<Void, Never>,
        id promptID: UUID,
        sessionID: String
    ) {
        tasks[promptID] = task
        sessionIDsByTaskID[promptID] = sessionID
        taskIDsBySessionID[sessionID, default: []].insert(promptID)
    }

    /// Cancels and removes every prompt task associated with a session.
    mutating func cancelAll(for sessionID: String) {
        guard let promptIDs = taskIDsBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        for promptID in promptIDs {
            tasks.removeValue(forKey: promptID)?.cancel()
            sessionIDsByTaskID.removeValue(forKey: promptID)
        }
    }

    /// Removes a single completed / finished prompt task.
    mutating func clear(id promptID: UUID) {
        tasks.removeValue(forKey: promptID)
        if let sessionID = sessionIDsByTaskID.removeValue(forKey: promptID) {
            taskIDsBySessionID[sessionID]?.remove(promptID)
            if taskIDsBySessionID[sessionID]?.isEmpty == true {
                taskIDsBySessionID.removeValue(forKey: sessionID)
            }
        }
    }

    /// Cancels all registered tasks and drops every mapping.
    mutating func cancelAllTasks() {
        for task in tasks.values {
            task.cancel()
        }
        removeAll()
    }

    mutating func removeAll() {
        tasks.removeAll()
        taskIDsBySessionID.removeAll()
        sessionIDsByTaskID.removeAll()
    }

    /// Returns `true` when at least one prompt task is active for the session.
    func hasActiveTasks(for sessionID: String) -> Bool {
        taskIDsBySessionID[sessionID]?.isEmpty == false
    }
}
