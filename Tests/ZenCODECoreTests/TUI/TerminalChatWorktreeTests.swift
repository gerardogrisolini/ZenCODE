//
//  TerminalChatWorktreeTests.swift
//  ZenCODECoreTests
//
//  What the terminal shows for a `zen --worktree NAME` chat: the worktree
//  line of the startup summary, and the menus offered when the chat ends.
//  The interactive menus themselves are not driven.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatWorktreeTests {
    private static let worktree = AgentWorktree(
        name: "feature",
        directory: URL(fileURLWithPath: "/Users/me/.zencode/worktrees/app-key/feature/app", isDirectory: true)
    )

    @Test
    func theStartupSummaryNamesTheWorktreeBeforeTheWorkingDirectory() {
        let directory = Self.worktree.directory
        #expect(TerminalChat.startupWorkspaceLines(workingDirectory: directory, worktree: Self.worktree) == [
            "Worktree: feature (branch feature)",
            "Working directory: \(directory.path)"
        ])
        #expect(TerminalChat.startupWorkspaceLines(workingDirectory: directory, worktree: nil) == [
            "Working directory: \(directory.path)"
        ])
    }

    @Test
    func theClosingMenuTitleAbbreviatesTheHomeFolder() {
        #expect(
            TerminalChat.worktreeClosingMenuTitle(Self.worktree, homeDirectory: "/Users/me")
                == "Worktree feature (~/.zencode/worktrees/app-key/feature/app)"
        )
        #expect(
            TerminalChat.worktreeClosingMenuTitle(Self.worktree, homeDirectory: "/Users/other")
                == "Worktree feature (/Users/me/.zencode/worktrees/app-key/feature/app)"
        )
    }

    @Test
    func theClosingMenuOffersMergeKeepAndDiscard() {
        let items = TerminalChat.worktreeClosingMenuItems(mainBranch: "main")
        #expect(items.map(\.value) == [.merge, .keep, .discard])
        #expect(items.map(\.title) == [
            "Merge into main and remove the worktree",
            "Keep the worktree",
            "Remove the worktree without merging"
        ])
        #expect(items.allSatisfy { $0.detail == nil && $0.groupTitle == nil })
    }

    @Test
    func discardingAsksForAConfirmation() {
        #expect(
            TerminalChat.worktreeDiscardConfirmationTitle(Self.worktree)
                == "Remove the worktree feature and delete its branch without merging? Its changes are lost."
        )
        let items = TerminalChat.worktreeDiscardConfirmationItems
        #expect(items.map(\.value) == [true, false])
        #expect(items.map(\.title) == ["Yes", "No"])
    }
}
