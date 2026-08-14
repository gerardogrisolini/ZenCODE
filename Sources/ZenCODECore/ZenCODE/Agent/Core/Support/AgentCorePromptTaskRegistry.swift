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

    /// Cancels every prompt task associated with a session.
    ///
    /// A cancelled task remains registered until its operation actually exits
    /// and calls ``clear(id:)``. Treating `Task.cancel()` as completion lets a
    /// compaction/reset race a still-running prompt.
    mutating func cancelAll(for sessionID: String) {
        guard let promptIDs = taskIDsBySessionID[sessionID] else {
            return
        }
        for promptID in promptIDs {
            tasks[promptID]?.cancel()
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

    /// Cancels all registered tasks. Mappings are retained until each task
    /// finishes so active-prompt checks remain truthful during teardown.
    mutating func cancelAllTasks() {
        for task in tasks.values {
            task.cancel()
        }
    }

    func tasks(for sessionID: String) -> [Task<Void, Never>] {
        (taskIDsBySessionID[sessionID] ?? []).compactMap { tasks[$0] }
    }

    var activeTasks: [Task<Void, Never>] {
        Array(tasks.values)
    }

    /// Returns `true` when at least one prompt task is active for the session.
    func hasActiveTasks(for sessionID: String) -> Bool {
        taskIDsBySessionID[sessionID]?.isEmpty == false
    }
}
