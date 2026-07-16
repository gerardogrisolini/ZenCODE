//
//  TerminalChat+Checkpoints.swift
//  ZenCODE
//
//  Checkpoint tree operations invoked via /sessions subcommands.
//

import Foundation

extension TerminalChat {
    /// Parses and executes `/sessions fork <entry-id|index> [session-name] <entry-id> <new-name>`.
    func handleForkCommand(_ args: String) async {
        let parts = args
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)

        guard parts.count >= 2 else {
            await writeSystemMessage(Self.renderForkUsage())
            return
        }

        do {
            let sessions = try sessionRunner.savedSessions(
                for: configuration.workingDirectory
            )

            // Resolve which session to fork from.
            // If the first arg matches a session name, use it; otherwise fork
            // from the active session.
            var sourceSession: TerminalSavedSession?
            var remainingParts = parts

            if let match = sessions.first(where: {
                $0.name.caseInsensitiveCompare(parts[0]) == .orderedSame
            }) {
                sourceSession = match
                remainingParts = Array(parts.dropFirst())
            } else if let activeName = activeSavedSessionName,
                      let match = sessions.first(where: { $0.name == activeName }) {
                sourceSession = match
            }

            guard let session = sourceSession else {
                await writeFailureMessage(
                    "No active session to fork from. Save the session first with /sessions save.\n"
                )
                return
            }

            guard remainingParts.count >= 2 else {
                await writeFailureMessage(Self.renderForkUsage())
                return
            }

            let entrySpecifier = remainingParts[0]
            let newName = remainingParts[1...].joined(separator: " ")

            // Resolve the entry by ID or branch index.
            let tree = session.checkpointTree
            let entryID = resolveEntryID(specifier: entrySpecifier, in: tree)
            guard let entryID else {
                await writeFailureMessage(
                    "Entry '\(entrySpecifier)' not found. Use /sessions tree or /sessions branches to see available entry IDs and indices.\n"
                )
                return
            }

            _ = try await forkFromCheckpoint(session, entryID: entryID, newName: newName)
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    // MARK: - Helpers

    /// Resolves an entry specifier (8-char hex ID or 1-based branch index) to
    /// an entry ID in the tree.
    private func resolveEntryID(
        specifier: String,
        in tree: SessionCheckpointTree
    ) -> String? {
        // Direct ID match
        if tree.entry(id: specifier) != nil {
            return specifier
        }
        // Branch index (1-based)
        if let index = Int(specifier), index >= 1 {
            let branches = tree.branches
            if index <= branches.count {
                return branches[index - 1].leafID
            }
        }
        return nil
    }

    private static func renderForkUsage() -> String {
        """
        Usage: /sessions fork <entry-id|branch-index> <new-session-name>
               /sessions fork <session-name> <entry-id|branch-index> <new-session-name>

        Creates a new session file from a checkpoint entry.
        Use /sessions tree or /sessions branches to see entry IDs and branch indices.

        """
    }

    /// `/sessions restore <entry-id|branch-index>` — restores the active
    /// session in-place from a checkpoint entry, branching from that point.
    func handleRestoreCommand(_ entrySpecifier: String) async {
        guard !entrySpecifier.isEmpty else {
            await writeSystemMessage(
                "Usage: /sessions restore <entry-id|branch-index>\n"
                + "Use /sessions tree to see entry IDs.\n"
            )
            return
        }

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
            let entryID = resolveEntryID(specifier: entrySpecifier, in: tree)
            guard let entryID else {
                await writeFailureMessage(
                    "Entry '\(entrySpecifier)' not found. Use /sessions tree or /sessions branches to see available entry IDs and indices.\n"
                )
                return
            }

            try await restoreFromCheckpoint(session, entryID: entryID)
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }
}
