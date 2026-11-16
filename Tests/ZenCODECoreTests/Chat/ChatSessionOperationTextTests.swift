//
//  ChatSessionOperationTextTests.swift
//  ZenCODE
//
//  The tests of the texts of the session operation notices, as the terminal
//  wrote them before they moved to the shared notice channel.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Texts

/// The channel of the session notices, as the terminal wrote them.
@Suite("Chat session operation texts", .serialized)
struct ChatSessionOperationTextTests {
    private static let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static let summaries: [ChatSavedSessionSummary] = [
        ChatSavedSessionSummary(
            name: "alpha",
            modelID: "openrouter:auto",
            messageCount: 12,
            contextUsedTokens: 1_234,
            savedAt: savedAt
        ),
        ChatSavedSessionSummary(
            name: "beta",
            modelID: nil,
            messageCount: 0,
            contextUsedTokens: nil,
            savedAt: savedAt.addingTimeInterval(3_600)
        ),
        ChatSavedSessionSummary(
            name: "gamma",
            modelID: "chatgpt:gpt-5",
            messageCount: 3,
            contextUsedTokens: 2_500_000,
            savedAt: savedAt.addingTimeInterval(86_400)
        ),
    ]

    @Test
    func eachNoticeIsWrittenInTheToneTheTerminalWroteItIn() {
        let failures: [ChatSessionNotice] = [
            .operationFailed(description: "boom"),
            .savedSessionNotFound(name: "old"),
            .nothingToSave,
            .sessionUnavailableToSave,
            .noActiveSavedSession,
            .activeSavedSessionNotFound(name: "old"),
            .checkpointEntryUnknown(specifier: "ffffffff"),
            .checkpointEntryNotFound(entryID: "ffffffff", sessionName: "old"),
            .engineCheckpoint(.saveFailed(description: "boom")),
            .engineCheckpoint(.restoreFailed(reason: "boom")),
        ]
        let system: [ChatSessionNotice] = [
            .sessionStarted,
            .noSavedSessions,
            .sessionSelectionUsage,
            .savedSessions(Self.summaries, activeName: nil),
            .sessionDeleted(name: "old"),
            .sessionSaved(name: "old", messageCount: 1),
            .nothingToCompact,
            .turnMemoryBlock("<project-memory>\n- Entry\n</project-memory>"),
            .noTurnMemoryBlock,
            .sessionCompacted(originalTokenCount: 2, tokenCount: 1, keptRecentMessageCount: 1),
            .sessionLoaded(name: "old", messageCount: 1),
            .checkpointRestored(entryID: "a1b2c3d4", messageCount: 1),
            .engineCheckpoint(.saved),
            .engineCheckpoint(.skippedImages),
            .engineCheckpoint(.skippedNoLiveState),
            .engineCheckpoint(.status("Loading")),
            .engineCheckpoint(.restored),
            .engineCheckpoint(.incompatible),
            .requiresInteractiveHost(.savedSessionSelection(Self.summaries, activeName: nil)),
            .requiresInteractiveHost(.savedSessionDeletion(Self.summaries, activeName: nil)),
        ]

        #expect(failures.allSatisfy { $0.channel == .failure })
        #expect(system.allSatisfy { $0.channel == .system })
    }
}
