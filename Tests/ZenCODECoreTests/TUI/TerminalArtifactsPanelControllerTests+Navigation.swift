//
//  TerminalArtifactsPanelControllerTests+Navigation.swift
//  ZenCODE
//
//  Tests of the artifacts panel controller for Esc in a file's diff: back to
//  the list when the panel opened on it, closed otherwise.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalArtifactsPanelControllerTests {
    // MARK: Bottom border

    /// The bottom border carries the keys of the mode (the list's, then the
    /// diff's `Esc back` once it was opened from the list) and the unread
    /// shared-chat badge, which ``TerminalArtifactsPanelController/redraw()``
    /// follows without reading the snapshot; a stopped controller draws
    /// nothing.
    @Test func theBottomBorderCarriesTheHelpOfTheModeAndTheUnreadBadge() async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        func bottom() -> String? {
            harness.frames.last?.last.map(TerminalANSIText.stripANSI)
        }
        controller.open(choosing: threeTurns)
        #expect(bottom()?.hasPrefix("╰─ ↑↓ choose · Enter open · Esc close ─") == true)

        harness.unreadSharedChatCount = 4
        let frames = harness.frames.count
        controller.redraw()
        #expect(harness.frames.count == frames + 1)
        #expect(bottom()?.hasPrefix("╰─ Chat: 4 new · ↑↓ choose · Enter open · Esc close ─") == true)
        #expect(harness.feed.reads == 0)

        await controller.handle(.confirm)
        #expect(bottom()?.hasPrefix("╰─ Chat: 4 new · ↑↓ PgUp PgDn Home End scroll · Esc back ─") == true)
        harness.unreadSharedChatCount = 0
        controller.redraw()
        #expect(bottom()?.hasPrefix("╰─ ↑↓ PgUp PgDn Home End scroll · Esc back ─") == true)

        controller.stop()
        let stopped = harness.frames.count
        controller.redraw()
        #expect(harness.frames.count == stopped)
    }

    // MARK: Esc in a file's diff

    @Test func escInTheDiffOfAFileFromTheListGoesBackToTheList() async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        #expect(controller.returnsToList)
        await controller.handle(.focusNext)
        await controller.handle(.confirm)
        #expect(controller.entryID == "2:/repo/B.swift")
        #expect(controller.panel.mode == .showing)
        #expect(harness.modeChanges == [false])

        // Esc leaves the diff, not the panel: the list is back, focused on
        // the file that was read, and the keys are routed to it again.
        await controller.handle(.close)
        #expect(!controller.isStopped)
        #expect(harness.closeReasons.isEmpty)
        #expect(harness.modeChanges == [false, true])
        #expect(controller.entryID == nil)
        #expect(controller.entry == nil)
        #expect(focusedIndex(controller) == 1)
        #expect(controller.panel.headerRows.isEmpty)
        #expect(controller.panel.bodyRows.isEmpty)
        #expect(controller.panel.title == Controller.title)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60, border: controller.border))
        #expect(Array(listContents(harness.frames.last ?? []).prefix(5)) == [
            "  turn 3 · in progress  modified  +1 -1  C.swift",
            "",
            "▸ turn 2                modified  +1 -1  B.swift",
            "",
            "  turn 1                modified  +1 -1  A.swift",
        ])
        #expect(harness.resize.isSubscribed)
        #expect(harness.feed.reads == 0)

        // The list works as before: it opens another file, which Esc leaves
        // again.
        await controller.handle(.focusPrevious)
        await controller.handle(.confirm)
        #expect(controller.entryID == "3:/repo/C.swift")
        #expect(harness.modeChanges == [false, true, false])
        await controller.handle(.close)
        #expect(focusedIndex(controller) == 0)
        #expect(harness.modeChanges == [false, true, false, true])
        #expect(harness.closeReasons.isEmpty)

        // Esc in the list closes the panel.
        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.modeChanges == [false, true, false, true])
    }

    @Test func escInTheDiffOfTheOnlyFileClosesThePanel() async {
        let snapshot = ChatFileArtifactSnapshot(turns: [turn(1, [artifact("Only.swift")])], activeTurnNumber: nil)
        let harness = ArtifactsHarness(snapshot)
        let controller = harness.makeController()
        controller.open(entryID: "1:/repo/Only.swift", in: snapshot)
        #expect(!controller.returnsToList)
        #expect(controller.panel.mode == .showing)

        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.modeChanges.isEmpty)
    }

    /// A file that a read no longer lists stays on screen, but the list Esc
    /// goes back to has only the files that are left.
    @Test func theListAfterEscHasOnlyTheFilesStillListed() async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        await controller.handle(.confirm)
        #expect(controller.entryID == "3:/repo/C.swift")

        harness.feed.setSnapshot(ChatFileArtifactSnapshot(
            turns: [turn(1, [artifact("A.swift")]), turn(2, [artifact("B.swift")])],
            activeTurnNumber: nil
        ))
        controller.reload()
        await waitUntil("the read is applied") { controller.entries.count == 2 }
        #expect(controller.entryID == "3:/repo/C.swift")
        #expect(controller.panel.mode == .showing)

        await controller.handle(.close)
        #expect(!controller.isStopped)
        #expect(harness.modeChanges == [false, true])
        #expect(focusedIndex(controller) == 0)
        #expect(Array(listContents(harness.frames.last ?? []).prefix(3)) == [
            "▸ turn 2  modified  +1 -1  B.swift",
            "",
            "  turn 1  modified  +1 -1  A.swift",
        ])
        controller.stop()
    }

    @Test func escInTheDiffClosesThePanelWhenNoFileIsListedAnyMore() async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        await controller.handle(.confirm)

        harness.feed.setSnapshot(ChatFileArtifactSnapshot(turns: [], activeTurnNumber: nil))
        controller.reload()
        await waitUntil("the read is applied") { controller.entries.isEmpty }

        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.modeChanges == [false])
    }

    @Test func aReadAfterTheReturnUpdatesTheListAndKeepsTheFocusOnTheFile() async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        await controller.handle(.focusNext)
        await controller.handle(.confirm)
        await controller.handle(.close)
        #expect(focusedIndex(controller) == 1)

        // A new turn lists its file first: the focus stays on B.
        harness.feed.setSnapshot(ChatFileArtifactSnapshot(
            turns: [
                turn(1, [artifact("A.swift")]), turn(2, [artifact("B.swift")]),
                turn(3, [artifact("C.swift")]), turn(4, [artifact("D.swift")]),
            ],
            activeTurnNumber: 4
        ))
        controller.reload()
        await waitUntil("the read is applied") { controller.entries.count == 4 }
        #expect(focusedIndex(controller) == 2)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60, border: controller.border))
        controller.stop()
    }
}
