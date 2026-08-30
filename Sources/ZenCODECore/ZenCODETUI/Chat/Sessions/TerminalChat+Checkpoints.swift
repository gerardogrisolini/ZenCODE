//
//  TerminalChat+Checkpoints.swift
//  ZenCODE
//
//  Checkpoint tree operations invoked via /sessions subcommands.
//

import Foundation

extension TerminalChat {
    /// `/sessions restore [entry-id]` — restores the active
    /// session in-place from a checkpoint entry, branching from that point.
    /// When the entry specifier is omitted, an interactive picker over the
    /// checkpoint tree lets the user choose the restore point.
    func handleRestoreCommand(_ entrySpecifier: String) async {
        guard let activeName = activeSavedSessionName else {
            await writeFailureMessage(
                "No active saved session. Save first with /sessions save.\n"
            )
            return
        }

        do {
            let sessions = try sessionRunner.savedSessions(
                for: configuration.workingDirectory
            )
            guard let session = sessions.first(where: { $0.name == activeName }) else {
                await writeFailureMessage(
                    "Active session '\(activeName)' not found. Try /sessions save first.\n"
                )
                return
            }

            let tree = session.checkpointTree
            let entryID: String?
            if entrySpecifier.isEmpty {
                // No entry specifier: pick the restore point interactively.
                entryID = await selectCheckpointEntry(
                    in: tree,
                    title: "Restore '\(session.name)' from checkpoint entry"
                )
                guard entryID != nil else { return }
            } else {
                entryID = resolveEntryID(specifier: entrySpecifier, in: tree)
                guard entryID != nil else {
                    await writeFailureMessage(
                        "Entry '\(entrySpecifier)' not found. Use /sessions restore to choose an entry.\n"
                    )
                    return
                }
            }

            guard let entryID else { return }
            try await restoreFromCheckpoint(session, entryID: entryID)
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    // MARK: - Helpers

    /// Presents an interactive single-selection menu over all checkpoint
    /// entries of `tree` and returns the chosen entry ID, or `nil` when the
    /// user cancels.
    func selectCheckpointEntry(
        in tree: SessionCheckpointTree,
        title: String
    ) async -> String? {
        let items = tree.entries.map { entry in
            TerminalCheckboxMenuItem(
                value: entry.id,
                title: "\(entry.id) \(tree.entryLabel(entry))",
                detail: entry.id == tree.activeLeafID ? "active" : nil
            )
        }
        return await TerminalCheckboxMenu.selectOneOffActor(
            title: title,
            items: items,
            selected: tree.activeLeafID,
            reservedBottomRows: await statusBar.reservedRowsForOverlay()
        )
    }

    /// Resolves an entry ID in the tree.
    private func resolveEntryID(
        specifier: String,
        in tree: SessionCheckpointTree
    ) -> String? {
        tree.entry(id: specifier).map { _ in specifier }
    }
}
