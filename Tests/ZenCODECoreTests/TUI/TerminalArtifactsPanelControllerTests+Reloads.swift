//
//  TerminalArtifactsPanelControllerTests+Reloads.swift
//  ZenCODE
//
//  Tests of the artifacts panel controller for reloads, closing and the
//  viewport.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalArtifactsPanelControllerTests {
    // MARK: Reloads

    @Test func aReloadKeepsTheFocusOnTheSameEntry() async {
        let initial = ChatFileArtifactSnapshot(
            turns: [turn(1, [artifact("A.swift")]), turn(2, [artifact("B.swift")])],
            activeTurnNumber: nil
        )
        let harness = ArtifactsHarness(initial)
        let controller = harness.makeController()
        controller.open(choosing: initial)
        await controller.handle(.focusNext)
        #expect(focusedIndex(controller) == 1)

        // A turn in progress lists its file first: the focus stays on A.
        harness.feed.setSnapshot(threeTurns)
        controller.reload()
        await waitUntil("the read is applied") { controller.entries.count == 3 }
        #expect(controller.entries.map(\.id) == ["3:/repo/C.swift", "2:/repo/B.swift", "1:/repo/A.swift"])
        #expect(focusedIndex(controller) == 2)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))
        #expect(listContents(harness.frames.last ?? [])[4] == "▸ turn 1                modified  +1 -1  A.swift")

        // The focused file leaves: the focus keeps its position, clamped.
        harness.feed.setSnapshot(ChatFileArtifactSnapshot(
            turns: [turn(2, [artifact("B.swift")]), turn(3, [artifact("C.swift")])],
            activeTurnNumber: 3
        ))
        controller.reload()
        await waitUntil("the reads wait the interval") {
            harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 1
        }
        #expect(harness.gate.release(ArtifactsHarness.reloadInterval))
        await waitUntil("the second read is applied") { controller.entries.count == 2 }
        #expect(focusedIndex(controller) == 1)
        #expect(harness.feed.reads == 2)
        controller.stop()
    }

    @Test func aReloadKeepsTheScrollPositionOfTheDiff() async throws {
        let id = "1:/repo/Long.swift"
        let snapshot = ChatFileArtifactSnapshot(turns: [turn(1, [longArtifact(40)])], activeTurnNumber: 1)
        let harness = ArtifactsHarness(snapshot)
        let controller = harness.makeController()
        controller.open(entryID: id, in: snapshot)
        for _ in 0..<3 {
            await controller.handle(.scrollDown)
        }
        #expect(controller.panel.scrollOffset == 3)

        // The turn goes on and changes more lines: the window stays.
        let longer = longArtifact(60)
        harness.feed.setSnapshot(ChatFileArtifactSnapshot(turns: [turn(1, [longer])], activeTurnNumber: 1))
        controller.reload()
        await waitUntil("the longer diff is applied") { controller.entry?.artifact == longer }
        #expect(controller.panel.scrollOffset == 3)
        #expect(!controller.panel.isFollowing)
        #expect(controller.panel.bodyRows == body(longer))
        #expect(controller.diffRenderCount == 2)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        // At the end of the diff a longer diff does not move the window
        // either, and the finished turn keeps the entry.
        await controller.handle(.bottom)
        let bottom = controller.panel.scrollOffset
        let final = longArtifact(80)
        harness.feed.setSnapshot(ChatFileArtifactSnapshot(turns: [turn(1, [final])], activeTurnNumber: nil))
        controller.reload()
        await waitUntil("the reads wait the interval") {
            harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 1
        }
        #expect(harness.gate.release(ArtifactsHarness.reloadInterval))
        await waitUntil("the final diff is applied") { controller.entry?.artifact == final }
        #expect(controller.entryID == id)
        #expect(controller.panel.scrollOffset == bottom)
        #expect(controller.panel.headerRows[1] == "turn 1")
        let entry = try #require(controller.entry)
        #expect(!entry.isInProgress)

        // A read that changes nothing renders nothing again.
        let renders = controller.diffRenderCount
        controller.reload()
        await waitUntil("the reads wait the interval") {
            harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 1
        }
        #expect(harness.gate.release(ArtifactsHarness.reloadInterval))
        await waitUntil("the read is done") { harness.feed.reads == 3 }
        await settle()
        #expect(controller.diffRenderCount == renders)
        #expect(controller.panel.scrollOffset == bottom)
        controller.stop()
    }

    @Test func aFileThatLeavesTheSnapshotKeepsItsLastRows() async {
        let snapshot = ChatFileArtifactSnapshot(
            turns: [turn(1, [artifact("A.swift")]), turn(3, [artifact("C.swift")])],
            activeTurnNumber: 3
        )
        let harness = ArtifactsHarness(snapshot)
        let controller = harness.makeController()
        controller.open(entryID: "3:/repo/C.swift", in: snapshot)
        let header = controller.panel.headerRows
        let rows = controller.panel.bodyRows
        #expect(header[1] == "turn 3 · in progress")

        // While the turn's summary is collected the turn is listed neither in
        // progress nor finished: the panel keeps what it showed.
        harness.feed.setSnapshot(ChatFileArtifactSnapshot(turns: [turn(1, [artifact("A.swift")])], activeTurnNumber: nil))
        controller.reload()
        await waitUntil("the read is applied") { controller.entries.count == 1 }
        #expect(controller.entryID == "3:/repo/C.swift")
        #expect(controller.entry?.isInProgress == true)
        #expect(controller.panel.headerRows == header)
        #expect(controller.panel.bodyRows == rows)

        // Back as a finished turn, the file shows its final evidence.
        let final = artifact("C.swift", additions: 2, deletions: 1, new: "let value = 3\nlet other = 4\n")
        harness.feed.setSnapshot(ChatFileArtifactSnapshot(
            turns: [turn(1, [artifact("A.swift")]), turn(3, [final])],
            activeTurnNumber: nil
        ))
        controller.reload()
        await waitUntil("the reads wait the interval") {
            harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 1
        }
        #expect(harness.gate.release(ArtifactsHarness.reloadInterval))
        await waitUntil("the final evidence is applied") { controller.entry?.artifact == final }
        #expect(controller.entry?.isInProgress == false)
        #expect(controller.panel.headerRows == ["modified C.swift  +2 -1", "turn 3"])
        #expect(controller.panel.bodyRows == body(final))
        controller.stop()
    }

    /// The reads never overlap: a read asked while one is in flight waits
    /// for it and for the interval, the requests coalesce into one read, and
    /// the panel ends with the latest read, never with an earlier one.
    @Test func readsCoalesceNeverOverlapAndEndWithTheLatestRead() async {
        let first = ChatFileArtifactSnapshot(turns: [turn(1, [artifact("A.swift")])], activeTurnNumber: nil)
        let second = ChatFileArtifactSnapshot(
            turns: [turn(1, [artifact("A.swift")]), turn(2, [artifact("B.swift")])],
            activeTurnNumber: nil
        )
        let harness = ArtifactsHarness(first)
        let controller = harness.makeController()
        controller.open(choosing: first)
        harness.feed.holdReads()
        harness.feed.setSnapshot(second)
        controller.reload()
        await waitUntil("the read is in flight") { harness.feed.heldReadCount == 1 }

        harness.feed.setSnapshot(threeTurns)
        controller.reload()
        controller.reload()
        await settle()
        #expect(harness.feed.reads == 1)
        #expect(controller.entries == Controller.entries(first))

        harness.feed.releaseReads()
        await waitUntil("the first read is applied") { controller.entries == Controller.entries(second) }
        await waitUntil("the reads wait the interval") {
            harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 1
        }
        #expect(harness.feed.reads == 1)
        #expect(harness.gate.release(ArtifactsHarness.reloadInterval))
        await waitUntil("the latest read is applied") { controller.entries == Controller.entries(threeTurns) }
        #expect(harness.feed.reads == 2)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        // Nothing more was asked: after the interval the reads end.
        await waitUntil("the reads wait the interval") {
            harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 1
        }
        #expect(harness.gate.release(ArtifactsHarness.reloadInterval))
        await settle()
        #expect(harness.feed.reads == 2)
        #expect(harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 0)
        #expect(controller.entries == Controller.entries(threeTurns))

        // A new request reads at once.
        controller.reload()
        await waitUntil("the new request reads") { harness.feed.reads == 3 }
        controller.stop()
    }

    // MARK: Closing

    @Test func closingIsIdempotentAndNothingFollowsIt() async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        #expect(harness.resize.isSubscribed)

        await controller.handle(.close)
        await controller.close(reason: .replaced)
        await controller.close(reason: .dismissed)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.resize.cancellationCount == 1)
        await waitUntil("the poll is cancelled") { harness.gate.pendingCount(ArtifactsHarness.pollInterval) == 0 }

        let frames = harness.frames.count
        await controller.handle(.scrollDown)
        await controller.handle(.confirm)
        controller.open(choosing: threeTurns)
        controller.open(entryID: "3:/repo/C.swift", in: threeTurns)
        controller.reload()
        controller.stop()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(harness.modeChanges.isEmpty)
        #expect(harness.feed.reads == 0)
        #expect(harness.closeReasons == [.dismissed])
    }

    @Test func nothingIsPresentedAfterStopNotEvenByAReadInFlight() async {
        let first = ChatFileArtifactSnapshot(turns: [turn(1, [artifact("A.swift")])], activeTurnNumber: nil)
        let harness = ArtifactsHarness(first)
        let controller = harness.makeController()
        controller.open(choosing: first)
        harness.feed.holdReads()
        harness.feed.setSnapshot(threeTurns)
        controller.reload()
        await waitUntil("the read is in flight") { harness.feed.heldReadCount == 1 }
        let frames = harness.frames.count

        controller.stop()
        controller.stop()
        harness.feed.releaseReads()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(controller.entries == Controller.entries(first))
        #expect(harness.gate.pendingCount(ArtifactsHarness.reloadInterval) == 0)
        #expect(harness.resize.cancellationCount == 1)

        // A close after a stop reports nothing.
        await controller.close(reason: .dismissed)
        #expect(harness.closeReasons.isEmpty)
    }

    // MARK: Viewport

    @Test(arguments: [false, true])
    func closesWhenTheScreenTurnsAppendOnly(throughResizeSignal: Bool) async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(entryID: "3:/repo/C.swift", in: threeTurns)
        await waitUntil("the poll waits") { harness.gate.pendingCount(ArtifactsHarness.pollInterval) == 1 }

        harness.isCancelled = true
        if throughResizeSignal {
            harness.resize.signal()
        } else {
            #expect(harness.gate.release(ArtifactsHarness.pollInterval))
        }
        await waitUntil("the controller closes") { !harness.closeReasons.isEmpty }
        #expect(harness.closeReasons == [.layoutUnavailable])
        // `onClosed` runs in a task that is not cancelled.
        #expect(harness.closedWhileCancelled == [false])
        #expect(controller.isStopped)
        #expect(harness.resize.cancellationCount == 1)

        let frames = harness.frames.count
        harness.isCancelled = false
        harness.viewport = (rows: 10, columns: 40)
        harness.resize.signal()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(harness.closeReasons == [.layoutUnavailable])
    }

    @Test func drawsAgainOnlyWhenTheViewportChanges() async {
        let long = longArtifact(30)
        let snapshot = ChatFileArtifactSnapshot(turns: [turn(1, [long])], activeTurnNumber: nil)
        let harness = ArtifactsHarness(snapshot)
        let controller = harness.makeController()
        controller.open(entryID: "1:/repo/Long.swift", in: snapshot)
        await waitUntil("the poll waits") { harness.gate.pendingCount(ArtifactsHarness.pollInterval) == 1 }

        // An unchanged viewport draws nothing.
        #expect(harness.gate.release(ArtifactsHarness.pollInterval))
        await waitUntil("the poll waits again") { harness.gate.pendingCount(ArtifactsHarness.pollInterval) == 1 }
        #expect(harness.frames.count == 1)

        harness.viewport = (rows: 12, columns: 40)
        #expect(harness.gate.release(ArtifactsHarness.pollInterval))
        await waitUntil("the new viewport is drawn") { harness.frames.count == 2 }
        #expect(harness.frames.last == controller.panel.frameLines(rows: 12, columns: 40))
        #expect(harness.frames.last?.count == 12)
        #expect(controller.panel.bodyRows == body(long, columns: 40))

        harness.viewport = (rows: 16, columns: 50)
        harness.resize.signal()
        await waitUntil("the resize is drawn") { harness.frames.count == 3 }
        #expect(harness.frames.last == controller.panel.frameLines(rows: 16, columns: 50))
        controller.stop()
    }
}
