//
//  TerminalArtifactsPanelControllerTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Fakes

/// The session's file artifacts as the controller reads them: the snapshot
/// of the moment a read starts, and how many reads started. Reads can be held
/// until the test releases them.
private final class ArtifactsFeed: Sendable {
    private struct State {
        var snapshot: ChatFileArtifactSnapshot
        var reads = 0
        var holdsReads = false
        var heldReads: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(_ snapshot: ChatFileArtifactSnapshot) {
        state = Mutex(State(snapshot: snapshot))
    }

    var reads: Int { state.withLock { $0.reads } }
    var heldReadCount: Int { state.withLock { $0.heldReads.count } }

    func setSnapshot(_ snapshot: ChatFileArtifactSnapshot) {
        state.withLock { $0.snapshot = snapshot }
    }

    /// The next reads wait until ``releaseReads()``.
    func holdReads() {
        state.withLock { $0.holdsReads = true }
    }

    func releaseReads() {
        let held = state.withLock { state in
            state.holdsReads = false
            defer { state.heldReads = [] }
            return state.heldReads
        }
        held.forEach { $0.resume() }
    }

    func read() async -> ChatFileArtifactSnapshot {
        let (snapshot, holds) = state.withLock { state in
            state.reads += 1
            return (state.snapshot, state.holdsReads)
        }
        if holds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumesNow = state.withLock { state in
                    guard state.holdsReads else { return true }
                    state.heldReads.append(continuation)
                    return false
                }
                if resumesNow { continuation.resume() }
            }
        }
        return snapshot
    }
}

/// A sleep that ends only when the test releases it, by duration; it throws
/// when its task is cancelled. Nothing sleeps for real.
private final class ArtifactsSleepGate: Sendable {
    private struct Waiter {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var nextID = 0
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await wait(duration) }
    }

    /// The sleeps of `duration` waiting for a release.
    func pendingCount(_ duration: Duration) -> Int {
        state.withLock { state in state.waiters.filter { waiter in waiter.duration == duration }.count }
    }

    /// Ends the oldest sleep of `duration` waiting; `false` when none waits.
    @discardableResult
    func release(_ duration: Duration) -> Bool {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.duration == duration }) else { return nil }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume()
        return waiter != nil
    }

    private func wait(_ duration: Duration) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let isCancelled = state.withLock { state in
                    guard !Task.isCancelled else { return true }
                    state.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if isCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// The terminal resize signal: one observer at a time, fired by the test.
private final class ArtifactsResizeSignal: Sendable {
    private struct State {
        var observer: (@Sendable () -> Void)?
        var cancellations = 0
    }

    private let state = Mutex(State())

    var isSubscribed: Bool { state.withLock { $0.observer != nil } }
    var cancellationCount: Int { state.withLock { $0.cancellations } }

    func subscribe(_ observer: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        state.withLock { $0.observer = observer }
        return { [self] in
            state.withLock { state in
                state.observer = nil
                state.cancellations += 1
            }
        }
    }

    func signal() {
        state.withLock { $0.observer }?()
    }
}

/// The screen and the caller around a controller: the frames presented, the
/// close reasons, and the mode changes.
@ChatSessionActor
private final class ArtifactsHarness {
    static let reloadInterval: Duration = .milliseconds(500)
    static let pollInterval: Duration = .milliseconds(200)

    let feed: ArtifactsFeed
    let gate = ArtifactsSleepGate()
    let resize = ArtifactsResizeSignal()
    var viewport: (rows: Int, columns: Int) = (rows: 20, columns: 60)
    var isCancelled = false
    private(set) var frames: [[String]] = []
    private(set) var closeReasons: [TerminalArtifactsPanelController.CloseReason] = []
    /// Whether the task that reported each close was cancelled.
    private(set) var closedWhileCancelled: [Bool] = []
    private(set) var modeChanges: [Bool] = []

    init(_ snapshot: ChatFileArtifactSnapshot) {
        feed = ArtifactsFeed(snapshot)
    }

    func makeController() -> TerminalArtifactsPanelController {
        let feed = feed
        let resize = resize
        return TerminalArtifactsPanelController(environment: .init(
            snapshot: { await feed.read() },
            viewport: { self.viewport },
            present: { self.frames.append($0) },
            isCancelled: { self.isCancelled },
            onClosed: { reason in
                self.closeReasons.append(reason)
                self.closedWhileCancelled.append(Task.isCancelled)
            },
            modeDidChange: { self.modeChanges.append($0) },
            standardErrorIsTerminal: false,
            sleep: gate.sleep,
            reloadInterval: Self.reloadInterval,
            viewportPollInterval: Self.pollInterval,
            subscribeResize: { resize.subscribe($0) }
        ))
    }
}

// MARK: - Tests

@ChatSessionActor
@Suite(.timeLimit(.minutes(1)))
struct TerminalArtifactsPanelControllerTests {
    private typealias Controller = TerminalArtifactsPanelController

    private func artifact(
        _ path: String,
        status: FileChangeArtifact.Status = .modified,
        additions: Int = 1,
        deletions: Int = 1,
        hasLineCounts: Bool = true,
        isBinary: Bool = false,
        old: String? = "let value = 1\n",
        new: String? = "let value = 2\n",
        explanation: String? = nil
    ) -> FileChangeArtifact {
        FileChangeArtifact(
            absolutePath: "/repo/\(path)",
            displayPath: path,
            status: status,
            additions: additions,
            deletions: deletions,
            hasLineCounts: hasLineCounts,
            isBinary: isBinary,
            oldText: old,
            newText: new,
            explanation: explanation
        )
    }

    /// A file whose `count` lines all changed.
    private func longArtifact(_ count: Int, path: String = "Long.swift") -> FileChangeArtifact {
        artifact(
            path,
            additions: count,
            deletions: count,
            old: (1...count).map { "old \($0)\n" }.joined(),
            new: (1...count).map { "new \($0)\n" }.joined()
        )
    }

    private func turn(_ number: UInt64, _ artifacts: [FileChangeArtifact]) -> SessionFileArtifactHistory.Turn {
        SessionFileArtifactHistory.Turn(number: number, artifacts: artifacts)
    }

    /// Turns 1 and 2 finished, turn 3 in progress, one file each.
    private var threeTurns: ChatFileArtifactSnapshot {
        ChatFileArtifactSnapshot(
            turns: [turn(1, [artifact("A.swift")]), turn(2, [artifact("B.swift")]), turn(3, [artifact("C.swift")])],
            activeTurnNumber: 3
        )
    }

    private func body(_ artifact: FileChangeArtifact, columns: Int = 60) -> [String] {
        Controller.bodyRows(artifact, width: columns - 4, standardErrorIsTerminal: false)
    }

    private func plain(_ lines: [String]) -> [String] {
        lines.map(TerminalANSIText.stripANSI)
    }

    /// The text between `│ ` and ` │`, without the right padding.
    private func content(_ line: String) -> String {
        var text = TerminalANSIText.stripANSI(line)
        guard text.hasPrefix("│ "), text.hasSuffix(" │") else { return text }
        text = String(text.dropFirst(2).dropLast(2))
        while text.last == " " {
            text.removeLast()
        }
        return text
    }

    /// The interior rows of a frame drawn without a header.
    private func listContents(_ frame: [String]) -> [String] {
        frame.dropFirst().dropLast().map(content)
    }

    /// The body rows of a frame drawn with a header of `headerCount` rows.
    private func diffContents(_ frame: [String], headerCount: Int = 2) -> [String] {
        frame.dropFirst(1 + headerCount + 1).dropLast().map(content)
    }

    private func trimmed(_ row: String) -> String {
        var row = row
        while row.last == " " {
            row.removeLast()
        }
        return row
    }

    private func focusedIndex(_ controller: Controller) -> Int? {
        guard case let .choosing(_, focusedIndex) = controller.panel.mode else { return nil }
        return focusedIndex
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets the controller's tasks run, for the checks that nothing happens.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    // MARK: Entries

    @Test func entriesPutTheTurnInProgressFirstThenTheMostRecentTurns() {
        let snapshot = ChatFileArtifactSnapshot(
            turns: [
                turn(1, [artifact("A.swift"), artifact("B.swift")]),
                turn(4, [artifact("C.swift")]),
                turn(5, [artifact("D.swift"), artifact("E.swift"), artifact("D.swift", status: .deleted)]),
            ],
            activeTurnNumber: 5
        )
        let listed = Controller.entries(snapshot)
        #expect(listed.map(\.id) == [
            "5:/repo/D.swift", "5:/repo/E.swift", "5:/repo/D.swift#2",
            "4:/repo/C.swift", "1:/repo/A.swift", "1:/repo/B.swift",
        ])
        #expect(listed.map(\.turnNumber) == [5, 5, 5, 4, 1, 1])
        #expect(listed.map(\.isInProgress) == [true, true, true, false, false, false])
        #expect(listed.map(\.artifact.displayPath) == ["D.swift", "E.swift", "D.swift", "C.swift", "A.swift", "B.swift"])

        // Without a turn in progress the most recent finished turn comes first.
        let finished = Controller.entries(ChatFileArtifactSnapshot(
            turns: [turn(2, [artifact("A.swift")]), turn(3, [artifact("B.swift")])],
            activeTurnNumber: nil
        ))
        #expect(finished.map(\.id) == ["3:/repo/B.swift", "2:/repo/A.swift"])
        #expect(finished.allSatisfy { !$0.isInProgress })
        #expect(Controller.entries(ChatFileArtifactSnapshot(turns: [], activeTurnNumber: nil)).isEmpty)
    }

    @Test func theEntriesShowTheFileItsTurnAndItsExplanation() {
        let explained = artifact(
            "Big.swift",
            additions: 12,
            deletions: 3,
            explanation: "The diff is\nlonger than the budget."
        )
        let binary = artifact("Logo.png", hasLineCounts: false, isBinary: true, old: nil, new: nil)
        let listed = Controller.entries(ChatFileArtifactSnapshot(
            turns: [turn(2, [binary]), turn(3, [explained])],
            activeTurnNumber: 3
        ))
        let plainEntries = Controller.choiceEntries(listed, standardErrorIsTerminal: false)
        #expect(plainEntries == [
            .init(
                id: "3:/repo/Big.swift",
                title: "modified Big.swift  +12 -3",
                details: ["turn 3 · in progress", "The diff is longer than the budget."]
            ),
            .init(id: "2:/repo/Logo.png", title: "modified Logo.png (binary)", details: ["turn 2"]),
        ])

        // On a terminal the counts take the colors of the chat's artifact
        // header; the text is the same.
        let styled = Controller.choiceEntries(listed, standardErrorIsTerminal: true)
        let palette = TerminalMarkdownPalette.detected
        let reset = TerminalStyle.reset
        #expect(styled[0].title.hasSuffix("  \(palette.diffAddition)+12\(reset) \(palette.diffRemoval)-3\(reset)"))
        #expect(styled.map { TerminalANSIText.stripANSI($0.title) } == plainEntries.map(\.title))
        #expect(styled.map { $0.details.map(TerminalANSIText.stripANSI) } == plainEntries.map(\.details))

        // The header of a file's diff: its title, its turn, then its
        // explanation wrapped at the width.
        #expect(Controller.headerRows(listed[0], width: 20, standardErrorIsTerminal: false) == [
            "modified Big.swift  +12 -3", "turn 3 · in progress", "The diff is longer", "than the budget.",
        ])
        #expect(Controller.headerRows(listed[1], width: 20, standardErrorIsTerminal: false) == [
            "modified Logo.png (binary)", "turn 2",
        ])
    }

    // MARK: List

    @Test func theListOpensFocusedOnTheFirstFileWithoutReading() {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        #expect(harness.frames.count == 1)
        #expect(focusedIndex(controller) == 0)
        #expect(controller.entryID == nil)
        #expect(controller.panel.title == Controller.title)
        #expect(harness.feed.reads == 0)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        let frame = harness.frames[0]
        #expect(frame.count == 20)
        #expect(plain(frame).first?.hasPrefix("╭─ 🪬 Artifacts ─") == true)
        #expect(Array(listContents(frame).prefix(9)) == [
            "▸ modified C.swift  +1 -1",
            "┃   turn 3 · in progress",
            "",
            "  modified B.swift  +1 -1",
            "    turn 2",
            "",
            "  modified A.swift  +1 -1",
            "    turn 1",
            "",
        ])
        controller.stop()
    }

    @Test func theListMovesTheFocusAndEnterOpensTheFocusedFile() async throws {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)

        // ↑/↓ move the focus cyclically; the page keys do nothing.
        await controller.handle(.scrollUp)
        #expect(focusedIndex(controller) == 2)
        await controller.handle(.focusNext)
        #expect(focusedIndex(controller) == 0)
        await controller.handle(.scrollDown)
        #expect(focusedIndex(controller) == 1)
        let frames = harness.frames.count
        await controller.handle(.pageDown)
        await controller.handle(.bottom)
        #expect(harness.frames.count == frames)
        #expect(focusedIndex(controller) == 1)

        // Enter opens the focused file, at the top of its diff.
        await controller.handle(.confirm)
        #expect(controller.entryID == "2:/repo/B.swift")
        #expect(controller.panel.mode == .showing)
        #expect(harness.modeChanges == [false])
        let entry = try #require(controller.entry)
        #expect(controller.panel.headerRows == Controller.headerRows(entry, width: 56, standardErrorIsTerminal: false))
        #expect(controller.panel.bodyRows == body(entry.artifact))
        #expect(controller.panel.scrollOffset == 0)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))
        #expect(harness.feed.reads == 0)

        // In the diff, Enter and the list's `q` belong to the prompt.
        await controller.handle(.confirm)
        await controller.handle(.closeList)
        await controller.handle(.focusNext)
        #expect(!controller.isStopped)
        #expect(controller.entryID == "2:/repo/B.swift")
        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
    }

    @Test(arguments: [TerminalSubAgentDetailAction.close, .closeList])
    func escAndQCloseTheList(_ action: TerminalSubAgentDetailAction) async {
        let harness = ArtifactsHarness(threeTurns)
        let controller = harness.makeController()
        controller.open(choosing: threeTurns)
        await controller.handle(action)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.modeChanges.isEmpty)
    }

    // MARK: Detail

    @Test func aFileOpensAtItsFirstRowsAndScrollsWithTheKeys() async {
        let long = longArtifact(40)
        let snapshot = ChatFileArtifactSnapshot(turns: [turn(1, [long])], activeTurnNumber: nil)
        let harness = ArtifactsHarness(snapshot)
        let controller = harness.makeController()
        controller.open(entryID: "1:/repo/Long.swift", in: snapshot)
        #expect(harness.frames.count == 1)
        #expect(controller.panel.mode == .showing)
        #expect(controller.panel.title == Controller.title)
        #expect(controller.panel.scrollOffset == 0)
        #expect(!controller.panel.isFollowing)
        #expect(harness.modeChanges.isEmpty)

        // The diff of the chat's artifacts: changed lines, numbered.
        let rows = body(long)
        #expect(rows == Controller.detailPanelRowsReference(long, width: 56))
        #expect(rows.contains { $0.contains("1 │ -old 1") })
        #expect(rows.contains { $0.contains("40 │ +new 40") })
        #expect(controller.panel.bodyRows == rows)
        let capacity = controller.panel.bodyCapacity(frameRows: 20)
        #expect(capacity == 15)
        #expect(rows.count > 2 * capacity)
        #expect(diffContents(harness.frames[0]) == rows.prefix(capacity).map(trimmed))
        #expect(plain(harness.frames[0]).last?.hasSuffix("─ rows 1–15/\(rows.count) ─╯") == true)

        await controller.handle(.scrollDown)
        #expect(controller.panel.scrollOffset == 1)
        await controller.handle(.pageDown)
        #expect(controller.panel.scrollOffset == 1 + capacity)
        await controller.handle(.bottom)
        #expect(controller.panel.scrollOffset == rows.count - capacity)
        #expect(!controller.panel.isFollowing)
        #expect(diffContents(harness.frames.last ?? []) == rows.suffix(capacity).map(trimmed))
        await controller.handle(.pageUp)
        #expect(controller.panel.scrollOffset == rows.count - 2 * capacity)
        await controller.handle(.top)
        #expect(controller.panel.scrollOffset == 0)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))
        // Scrolling never renders the diff again.
        #expect(controller.diffRenderCount == 1)
        controller.stop()
    }

    @Test func binaryFilesAndFilesWithoutADiffShowOneRow() {
        let binary = artifact("Logo.png", hasLineCounts: false, isBinary: true, old: nil, new: nil)
        let unknown = artifact(
            "Gone.swift",
            status: .unknown,
            hasLineCounts: false,
            old: nil,
            new: nil,
            explanation: "No evidence."
        )
        let unchanged = artifact("Same.swift", old: "same\n", new: "same\n")
        #expect(body(binary) == [Controller.binaryRow])
        #expect(body(unknown) == [Controller.noDiffRow])
        #expect(body(unchanged) == [Controller.noDiffRow])

        let snapshot = ChatFileArtifactSnapshot(turns: [turn(1, [binary, unknown])], activeTurnNumber: nil)
        let harness = ArtifactsHarness(snapshot)
        let controller = harness.makeController()
        controller.open(entryID: "1:/repo/Gone.swift", in: snapshot)
        #expect(controller.panel.headerRows == ["unknown Gone.swift", "turn 1", "No evidence."])
        #expect(controller.panel.bodyRows == [Controller.noDiffRow])
        #expect(diffContents(harness.frames[0], headerCount: 3).first == Controller.noDiffRow)
        controller.stop()
    }

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
        #expect(listContents(harness.frames.last ?? [])[6] == "▸ modified A.swift  +1 -1")

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

private extension TerminalArtifactsPanelController {
    /// The body of a file's diff built from the chat's pieces: the Markdown
    /// of the chat's artifact diff, in its changed-lines presentation,
    /// rendered as the rows of a detail panel.
    static func detailPanelRowsReference(_ artifact: FileChangeArtifact, width: Int) -> [String] {
        guard let markdown = TerminalChat.fileArtifactDiffMarkdown(artifact, presentation: .changedLines()) else {
            return []
        }
        return TerminalChat.detailPanelMarkdownRows(markdown, width: width, standardErrorIsTerminal: false)
    }
}
