//
//  TerminalChat+Worktree.swift
//  ZenCODE
//
//  The end of a `zen --worktree NAME` chat: the terminal offers to merge the
//  worktree into the main branch, keep it, or remove it without merging, and
//  prints what was done.
//

import Foundation

extension TerminalChat {
    /// Asks how to close the worktree of a `--worktree` launch, then closes
    /// it with ``AgentWorktreeManager/perform(_:worktree:inspection:)`` and
    /// prints the outcome on standard output. Does nothing without a worktree.
    ///
    /// Runs once the chat has ended and its status bar has stopped: like the
    /// startup menus, the menus draw on their own temporary screen. The
    /// worktree is kept, and Git left untouched, without an interactive
    /// terminal, when the repository cannot be inspected, on Esc, and when
    /// the removal is not confirmed.
    func offerWorktreeClosureIfNeeded() async {
        guard let worktree = configuration.worktree else {
            return
        }
        guard stdinIsTerminal else {
            Self.writeWorktreeClosingLines(await Self.keptWorktreeLines(worktree))
            return
        }
        let inspection: AgentWorktreeManager.Inspection
        do {
            inspection = try await AgentWorktreeManager.inspect(worktree)
        } catch {
            Self.writeWorktreeClosingLines(
                ["Could not inspect the worktree \(worktree.name): \(error.localizedDescription)"]
                    + (await Self.keptWorktreeLines(worktree))
            )
            return
        }

        var action = await TerminalCheckboxMenu.selectOneOffActor(
            title: Self.worktreeClosingMenuTitle(worktree),
            items: Self.worktreeClosingMenuItems(mainBranch: inspection.mainBranch),
            selected: AgentWorktreeManager.ClosingAction.keep
        ) ?? .keep
        if action == .discard {
            let confirmed = await TerminalCheckboxMenu.selectOneOffActor(
                title: Self.worktreeDiscardConfirmationTitle(worktree),
                items: Self.worktreeDiscardConfirmationItems,
                selected: false
            ) ?? false
            if !confirmed {
                action = .keep
            }
        }
        let outcome = await AgentWorktreeManager.perform(
            action,
            worktree: worktree,
            inspection: inspection
        )
        Self.writeWorktreeClosingLines(outcome.lines)
    }

    /// The title of the closing menu: the worktree name and its directory,
    /// with the home folder abbreviated to `~`.
    nonisolated static func worktreeClosingMenuTitle(
        _ worktree: AgentWorktree,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let directory = LocalExecPermissionAuthorizer.abbreviatedHomePath(
            worktree.directory.path,
            homeDirectory: homeDirectory
        )
        return "Worktree \(worktree.name) (\(directory))"
    }

    /// The rows of the closing menu: merge, keep, discard.
    nonisolated static func worktreeClosingMenuItems(
        mainBranch: String
    ) -> [TerminalCheckboxMenuItem<AgentWorktreeManager.ClosingAction>] {
        [
            TerminalCheckboxMenuItem(
                value: .merge,
                title: "Merge into \(mainBranch) and remove the worktree",
                detail: nil
            ),
            TerminalCheckboxMenuItem(value: .keep, title: "Keep the worktree", detail: nil),
            TerminalCheckboxMenuItem(
                value: .discard,
                title: "Remove the worktree without merging",
                detail: nil
            )
        ]
    }

    /// The question that confirms a removal without merging; "No" is the
    /// default.
    nonisolated static func worktreeDiscardConfirmationTitle(_ worktree: AgentWorktree) -> String {
        "Remove the worktree \(worktree.name) and delete its branch without merging? Its changes are lost."
    }

    nonisolated static let worktreeDiscardConfirmationItems = [
        TerminalCheckboxMenuItem(value: true, title: "Yes", detail: nil),
        TerminalCheckboxMenuItem(value: false, title: "No", detail: nil)
    ]

    /// What keeping the worktree prints, from
    /// ``AgentWorktreeManager/perform(_:worktree:inspection:)`` so the text
    /// has one source. `.keep` reads neither Git nor the inspection, so a
    /// placeholder stands in when there is none.
    private nonisolated static func keptWorktreeLines(_ worktree: AgentWorktree) async -> [String] {
        await AgentWorktreeManager.perform(
            .keep,
            worktree: worktree,
            inspection: AgentWorktreeManager.Inspection(
                mainRoot: worktree.directory,
                mainBranch: worktree.name,
                hasUncommittedChanges: false
            )
        )
        .lines
    }

    private nonisolated static func writeWorktreeClosingLines(_ lines: [String]) {
        guard !lines.isEmpty else {
            return
        }
        AgentOutput.standardOutput.writeString(lines.joined(separator: "\n") + "\n")
    }
}
