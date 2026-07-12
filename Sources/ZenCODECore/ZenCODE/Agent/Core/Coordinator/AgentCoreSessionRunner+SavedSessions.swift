//
//  AgentCoreSessionRunner+SavedSessions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/06/26.
//

import Foundation

public enum AgentCoreSessionRunnerError: LocalizedError, Equatable {
    case missingSessionSnapshot(String)
    case cannotCompactDuringActivePrompt(String)

    public var errorDescription: String? {
        switch self {
        case let .missingSessionSnapshot(sessionID):
            return "Session snapshot is not available for \(sessionID)."
        case let .cannotCompactDuringActivePrompt(sessionID):
            return "Cannot compact session \(sessionID) while a prompt is running."
        }
    }
}

public extension AgentCoreSessionRunner {
    nonisolated func savedSessions(
        for workingDirectory: URL,
        supportDirectoryURL: URL? = nil
    ) throws -> [TerminalSavedSession] {
        try TerminalSessionStore.savedSessions(
            for: workingDirectory,
            supportDirectoryURL: supportDirectoryURL
        )
    }

    @discardableResult
    func saveSession(
        id sessionID: String,
        named rawName: String,
        fallbackSnapshot: AgentRuntimeSessionSnapshot? = nil,
        fallbackCreatedAt: Date,
        modelID: String?,
        agentID: String?,
        agentName: String?,
        selectedTools: [String],
        selectedSkillIDs: [String],
        thinkingSelection: String?,
        contextWindow: TerminalSavedSessionContextWindow?,
        transcriptHistory: [AgentRuntimeMessage]?,
        activePlan: TerminalSessionPlan? = nil,
        supportDirectoryURL: URL? = nil
    ) async throws -> TerminalSavedSession {
        guard let snapshot = await snapshotSession(id: sessionID) ?? fallbackSnapshot else {
            throw AgentCoreSessionRunnerError.missingSessionSnapshot(sessionID)
        }

        let name = Self.normalizedSavedSessionName(rawName)
        let taskGraph = try? await taskGraphSnapshot(sessionID: sessionID)
        let workingDirectory = URL(fileURLWithPath: snapshot.workingDirectoryPath)
        let existingSession = try? TerminalSessionStore.load(
            name: name,
            workingDirectory: workingDirectory,
            supportDirectoryURL: supportDirectoryURL
        )
        let savedSession = TerminalSavedSession(
            name: name,
            sessionID: snapshot.sessionID,
            cacheKey: snapshot.cacheKey,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            createdAt: existingSession?.createdAt ?? fallbackCreatedAt,
            savedAt: Date(),
            modelID: modelID,
            agentID: agentID,
            agentName: agentName,
            selectedTools: selectedTools.compactMap(\.nilIfBlank).sorted(),
            selectedSkillIDs: selectedSkillIDs.compactMap(\.nilIfBlank).sorted(),
            thinkingSelection: thinkingSelection ?? snapshot.thinkingSelection?.rawValue,
            contextWindow: contextWindow,
            systemPrompt: snapshot.systemPrompt,
            history: snapshot.history,
            transcriptHistory: transcriptHistory,
            activePlan: activePlan,
            taskGraph: taskGraph
        )

        _ = try TerminalSessionStore.save(
            savedSession,
            supportDirectoryURL: supportDirectoryURL
        )
        return savedSession
    }

    @discardableResult
    nonisolated func deleteSavedSession(
        name: String,
        workingDirectory: URL,
        supportDirectoryURL: URL? = nil
    ) throws -> Bool {
        try TerminalSessionStore.delete(
            name: name,
            workingDirectory: workingDirectory,
            supportDirectoryURL: supportDirectoryURL
        )
    }

    private static func normalizedSavedSessionName(_ rawName: String) -> String {
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "Session" : trimmedName
    }
}
