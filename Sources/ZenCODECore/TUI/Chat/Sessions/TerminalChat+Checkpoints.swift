//
//  TerminalChat+Checkpoints.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Checkpoint tree operations invoked via /sessions subcommands.
//

import Foundation

extension TerminalChat {
    /// `/sessions restore [entry-id]` — restores the active
    /// session in-place from a checkpoint entry, branching from that point.
    /// When the entry specifier is omitted, an interactive picker over the
    /// checkpoint tree lets the user choose the restore point. Adapter of
    /// ``ChatSessionController/chooseCheckpointEntry()`` and
    /// ``ChatSessionController/restoreFromCheckpoint(entryID:)``.
    func handleRestoreCommand(_ entrySpecifier: String) async {
        do {
            let outcome: ChatSessionOperationOutcome
            if entrySpecifier.isEmpty {
                // No entry specifier: pick the restore point interactively.
                outcome = try await chatSession.chooseCheckpointEntry()
            } else {
                outcome = try await chatSession.restoreFromCheckpoint(entryID: entrySpecifier)
            }
            await writeSessionNotices(outcome.notices)
        } catch {
            await writeSessionNotice(.operationFailed(description: error.localizedDescription))
        }
    }
}
