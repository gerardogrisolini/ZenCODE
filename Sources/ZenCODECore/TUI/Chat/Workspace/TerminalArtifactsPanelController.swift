//
//  TerminalArtifactsPanelController.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 08/11/26.
//

import Foundation
import ToolCore

/// Drives the `/artifacts` panel on the layout of the `/subagent` detail
/// (``TerminalSubAgentDetailPanel``, titled ``title``): it lets the operator
/// pick a changed file, shows the diff of the file picked, and presents the
/// framed panel through its ``Environment``.
///
/// The data is the session's ``ChatFileArtifactSnapshot`` (one ``Entry`` per
/// file of each turn, ``entries(_:)``), which the controller reads only when
/// it is asked to (``reload()``): the terminal asks after every live or
/// sealed artifact and at the end of a turn, never on a timer, since a read
/// of the turn in progress diffs every file it changed. The reads never
/// overlap and the requests coalesce: a request during a read, or within
/// ``Environment/reloadInterval`` after one, is served by one more read once
/// the interval elapsed. A read is applied only when no later read was, so an
/// earlier read never replaces a newer one.
///
/// A read keeps the list's focus on the entry it was on (by ``Entry/id``) and
/// a diff's scroll position. A file's diff opens at its first rows and never
/// follows its end, so a read that changes the diff leaves the rows the
/// operator reads in place. When a read no longer lists the file shown, the
/// panel keeps the last rows it drew of it. Nothing is saved.
///
/// Every frame is drawn for the viewport of the moment
/// (``Environment/viewport``), checked every
/// ``Environment/viewportPollInterval`` and at every resize signal; the check
/// closes the controller with ``CloseReason/layoutUnavailable`` once the
/// screen fell back to append-only output (``Environment/isCancelled``), as
/// the `/subagent` detail does.
///
/// After ``stop()`` the controller never calls ``Environment/present``,
/// ``Environment/onClosed`` or ``Environment/modeDidChange`` again, not even
/// from a read still in flight.
@ChatSessionActor
final class TerminalArtifactsPanelController {
    /// Why the panel closed: the reasons of the `/subagent` detail, since the
    /// terminal closes both panels in one teardown.
    typealias CloseReason = TerminalSubAgentDetailController.CloseReason

    /// One changed file of one turn, as the panel lists it.
    struct Entry: Sendable, Equatable {
        /// Unique in a snapshot and stable across reads: the turn number and
        /// the file's absolute path.
        let id: String
        let turnNumber: UInt64
        /// Whether the turn is the one in progress.
        let isInProgress: Bool
        let artifact: FileChangeArtifact
    }

    /// Everything the controller reads, waits for, and draws through.
    struct Environment {
        /// The session's file artifacts now
        /// (``ChatSessionController/fileArtifactSnapshot()``).
        var snapshot: @ChatSessionActor () async -> ChatFileArtifactSnapshot
        /// The rows and columns of the panel's frame, read at every frame.
        var viewport: @ChatSessionActor () -> (rows: Int, columns: Int)
        /// Shows a frame: exactly `viewport().rows` lines, each
        /// `viewport().columns` wide.
        var present: @ChatSessionActor (_ lines: [String]) -> Void
        /// Whether the screen fell back to append-only output.
        var isCancelled: @ChatSessionActor () -> Bool
        /// Called once when the controller closes itself (``close(reason:)``).
        var onClosed: @ChatSessionActor (CloseReason) async -> Void
        /// Called when the panel moves between the file list (`isChoosing`)
        /// and a file's diff.
        var modeDidChange: @ChatSessionActor (_ isChoosing: Bool) async -> Void
        /// Whether the rows carry ANSI styling.
        var standardErrorIsTerminal: Bool
        /// Waits for a duration; throws when its task is cancelled.
        var sleep: @Sendable (Duration) async throws -> Void
        /// The shortest time between the starts of two reads.
        var reloadInterval: Duration
        /// How often the viewport is compared with the last frame's.
        var viewportPollInterval: Duration
        /// Subscribes `observer` to the terminal resize signals and returns
        /// the cancellation of the subscription.
        var subscribeResize: (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)

        init(
            snapshot: @escaping @ChatSessionActor () async -> ChatFileArtifactSnapshot,
            viewport: @escaping @ChatSessionActor () -> (rows: Int, columns: Int),
            present: @escaping @ChatSessionActor (_ lines: [String]) -> Void,
            isCancelled: @escaping @ChatSessionActor () -> Bool,
            onClosed: @escaping @ChatSessionActor (CloseReason) async -> Void,
            modeDidChange: @escaping @ChatSessionActor (_ isChoosing: Bool) async -> Void = { _ in },
            standardErrorIsTerminal: Bool,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            reloadInterval: Duration = .milliseconds(500),
            viewportPollInterval: Duration = .milliseconds(200),
            subscribeResize: @escaping (_ observer: @escaping @Sendable () -> Void) -> (@Sendable () -> Void)
                = TerminalSubAgentDetailController.Environment.subscribeToTerminalResize
        ) {
            self.snapshot = snapshot
            self.viewport = viewport
            self.present = present
            self.isCancelled = isCancelled
            self.onClosed = onClosed
            self.modeDidChange = modeDidChange
            self.standardErrorIsTerminal = standardErrorIsTerminal
            self.sleep = sleep
            self.reloadInterval = reloadInterval
            self.viewportPollInterval = viewportPollInterval
            self.subscribeResize = subscribeResize
        }
    }

    /// The label of the panel's top border.
    nonisolated static let title = " 🪬 Artifacts "
    /// The body of a binary file's detail.
    nonisolated static let binaryRow = "Binary file: no diff to show."
    /// The body of the detail of a file without a diff to show.
    nonisolated static let noDiffRow = "No diff to show for this file."

    // MARK: State

    private let environment: Environment
    /// The panel as the last frame drew it.
    private(set) var panel = TerminalSubAgentDetailPanel(title: TerminalArtifactsPanelController.title)
    /// The entries of the latest snapshot applied.
    private(set) var entries: [Entry] = []
    /// The id of the file shown; `nil` while the operator chooses one.
    private(set) var entryID: String?
    /// The latest entry of the file shown. It stays when a read no longer
    /// lists the file.
    private(set) var entry: Entry?
    /// ``stop()`` ran: the controller calls nothing from now on.
    private(set) var isStopped = false
    /// The snapshot reads, for tests.
    private(set) var snapshotReadCount = 0
    /// The diff renderings (the cache missed), for tests.
    private(set) var diffRenderCount = 0

    /// A read was asked and not started yet.
    private var reloadRequested = false
    /// Serves the requested reads, one at a time; `nil` while none is asked.
    private var reloadTask: Task<Void, Never>?
    /// The reads started, and the one whose snapshot is applied.
    private var startedReadCount: UInt64 = 0
    private var appliedRead: UInt64 = 0
    private var viewportTask: Task<Void, Never>?
    private var cancelResizeSubscription: (@Sendable () -> Void)?
    /// The viewport of the last frame presented.
    private var lastViewport: Viewport?
    private var diffRows: DiffRows?

    init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Opening and closing

    /// Shows the list of the files of `snapshot` (``entries(_:)``), focused on
    /// the first. Does nothing after ``stop()``.
    func open(choosing snapshot: ChatFileArtifactSnapshot) {
        guard !isStopped else { return }
        entries = Self.entries(snapshot)
        entryID = nil
        entry = nil
        panel = TerminalSubAgentDetailPanel(
            mode: .choosing(
                entries: Self.choiceEntries(entries, standardErrorIsTerminal: environment.standardErrorIsTerminal),
                focusedIndex: 0
            ),
            availability: .available,
            title: Self.title
        )
        render()
        watchViewport()
    }

    /// Shows the diff of the file `entryID` of `snapshot`. Does nothing after
    /// ``stop()``.
    func open(entryID: String, in snapshot: ChatFileArtifactSnapshot) {
        guard !isStopped else { return }
        entries = Self.entries(snapshot)
        show(entryID: entryID)
        watchViewport()
    }

    /// Applies a key of the panel. In the file list ↑/↓ move the focus,
    /// Enter shows the focused file and Esc/`q` close; in a file's diff the
    /// scrolling keys scroll and Esc closes (the panel leaves `q` and Enter to
    /// the prompt there). The list's `q` (``TerminalSubAgentDetailAction/closeList``)
    /// that reaches a file's diff was typed ahead of the switch to it and is
    /// ignored. Every other key is ignored, and so is every key after
    /// ``stop()``.
    func handle(_ action: TerminalSubAgentDetailAction) async {
        guard !isStopped else { return }
        switch panel.mode {
        case let .choosing(choices, focusedIndex):
            switch action {
            case .scrollUp, .focusPrevious:
                panel.apply(.focusPrevious, frameRows: environment.viewport().rows)
                render()
            case .scrollDown, .focusNext:
                panel.apply(.focusNext, frameRows: environment.viewport().rows)
                render()
            case .confirm:
                guard !choices.isEmpty else { return }
                show(entryID: choices[min(max(0, focusedIndex), choices.count - 1)].id)
                await environment.modeDidChange(false)
            case .close, .closeList:
                await close(reason: .dismissed)
            case .pageUp, .pageDown, .top, .bottom:
                return
            }
        case .showing:
            switch action {
            case .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom:
                panel.apply(action, frameRows: environment.viewport().rows)
                // The diff keeps its position: it never follows its end.
                panel.isFollowing = false
                render()
            case .close:
                await close(reason: .dismissed)
            case .focusPrevious, .focusNext, .confirm, .closeList:
                return
            }
        }
    }

    /// Asks for a read of the snapshot, then draws it. Coalesced with the
    /// read in flight and the ones asked within
    /// ``Environment/reloadInterval`` (see the type). Does nothing after
    /// ``stop()``.
    func reload() {
        guard !isStopped else { return }
        reloadRequested = true
        guard reloadTask == nil else { return }
        let sleep = environment.sleep
        let interval = environment.reloadInterval
        reloadTask = Task { [weak self] in
            while await self?.readIfRequested() == true {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Stops the controller: cancels the reads, the viewport checks, and the
    /// resize subscription. The controller calls nothing from now on.
    /// Idempotent.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        reloadTask?.cancel()
        reloadTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        cancelResizeSubscription?()
        cancelResizeSubscription = nil
    }

    /// Stops the controller, then reports `reason` through
    /// ``Environment/onClosed``. Only the first call after the controller
    /// opened reports; a call after ``stop()`` does nothing.
    func close(reason: CloseReason) async {
        guard !isStopped else { return }
        stop()
        await environment.onClosed(reason)
    }

    // MARK: - Reads

    private func show(entryID: String) {
        self.entryID = entryID
        entry = entries.first { $0.id == entryID }
        panel = TerminalSubAgentDetailPanel(mode: .showing, availability: .available, title: Self.title)
        // A diff opens at its first rows.
        panel.isFollowing = false
        render()
    }

    /// Runs the read asked, if any. `false` ends the reads: none was asked
    /// (the reads are idle again), or the controller stopped.
    private func readIfRequested() async -> Bool {
        guard !isStopped else { return false }
        guard reloadRequested else {
            reloadTask = nil
            return false
        }
        reloadRequested = false
        await read()
        return !isStopped
    }

    /// Reads the snapshot and applies it, unless a later read was applied.
    private func read() async {
        startedReadCount &+= 1
        let read = startedReadCount
        snapshotReadCount += 1
        let snapshot = await environment.snapshot()
        guard !isStopped, !Task.isCancelled, read > appliedRead else { return }
        appliedRead = read
        apply(snapshot)
    }

    /// Replaces the entries with those of `snapshot` and draws them: the list
    /// keeps its focus on the same entry (on the same position when that
    /// entry is gone), a file's diff takes the file's new entry, if any.
    private func apply(_ snapshot: ChatFileArtifactSnapshot) {
        entries = Self.entries(snapshot)
        switch panel.mode {
        case let .choosing(choices, focusedIndex):
            let focusedID = choices.indices.contains(focusedIndex) ? choices[focusedIndex].id : nil
            let refreshed = Self.choiceEntries(entries, standardErrorIsTerminal: environment.standardErrorIsTerminal)
            let index = focusedID.flatMap { id in refreshed.firstIndex { $0.id == id } }
                ?? min(max(0, focusedIndex), max(0, refreshed.count - 1))
            panel.mode = .choosing(entries: refreshed, focusedIndex: index)
        case .showing:
            if let entryID, let refreshed = entries.first(where: { $0.id == entryID }) {
                entry = refreshed
            }
        }
        render()
    }

    // MARK: - Viewport

    /// Starts the viewport checks: a poll every
    /// ``Environment/viewportPollInterval`` and one at every resize signal.
    private func watchViewport() {
        guard !isStopped, viewportTask == nil, cancelResizeSubscription == nil else { return }
        cancelResizeSubscription = environment.subscribeResize { [weak self] in
            Task { @ChatSessionActor [weak self] in
                await self?.checkLayout()
            }
        }
        let sleep = environment.sleep
        let interval = environment.viewportPollInterval
        viewportTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self, !self.isStopped else { return }
                if self.environment.isCancelled() {
                    // This task closes the controller: keep it out of the
                    // cancellation of `stop()`, so `onClosed` runs uncancelled.
                    self.viewportTask = nil
                }
                await self.checkLayout()
                guard !self.isStopped else { return }
            }
        }
    }

    /// Closes the controller once the screen fell back to append-only output;
    /// otherwise draws the panel again when the viewport changed since the
    /// last frame.
    private func checkLayout() async {
        guard !isStopped else { return }
        guard !environment.isCancelled() else {
            await close(reason: .layoutUnavailable)
            return
        }
        guard Viewport(environment.viewport()) != lastViewport else { return }
        render()
    }

    // MARK: - Rendering

    /// Draws the panel for the current viewport and presents it.
    private func render() {
        guard !isStopped else { return }
        let viewport = Viewport(environment.viewport())
        lastViewport = viewport
        var headerRows: [String] = []
        var bodyRows: [String] = []
        if case .showing = panel.mode, let entry {
            // The interior width of `TerminalSubAgentDetailPanel.frameLines`.
            let width = max(1, viewport.columns - 4)
            headerRows = Self.headerRows(
                entry,
                width: width,
                standardErrorIsTerminal: environment.standardErrorIsTerminal
            )
            bodyRows = renderedDiff(entry.artifact, width: width)
        }
        panel.replace(headerRows: headerRows, bodyRows: bodyRows, frameRows: viewport.rows)
        environment.present(panel.frameLines(rows: viewport.rows, columns: viewport.columns))
    }

    /// The rows of the diff of `artifact` at `width`, rendered again only when
    /// the artifact or the width changed.
    private func renderedDiff(_ artifact: FileChangeArtifact, width: Int) -> [String] {
        if let diffRows, diffRows.artifact == artifact, diffRows.width == width {
            return diffRows.rows
        }
        diffRenderCount += 1
        let rows = Self.bodyRows(
            artifact,
            width: width,
            standardErrorIsTerminal: environment.standardErrorIsTerminal
        )
        diffRows = DiffRows(artifact: artifact, width: width, rows: rows)
        return rows
    }

    // MARK: - Entries and rows

    /// One entry per file of each turn of `snapshot`: the turn in progress
    /// first, then the finished turns, the most recent first; within a turn,
    /// the files in the order of the snapshot. An entry's id joins the turn
    /// number and the file's absolute path, with `#2`, `#3`… on a path a turn
    /// lists more than once.
    nonisolated static func entries(_ snapshot: ChatFileArtifactSnapshot) -> [Entry] {
        let turns = snapshot.turns.enumerated().sorted { lhs, rhs in
            let lhsInProgress = lhs.element.number == snapshot.activeTurnNumber
            let rhsInProgress = rhs.element.number == snapshot.activeTurnNumber
            if lhsInProgress != rhsInProgress { return lhsInProgress }
            if lhs.element.number != rhs.element.number { return lhs.element.number > rhs.element.number }
            return lhs.offset > rhs.offset
        }.map(\.element)
        var occurrences: [String: Int] = [:]
        var entries: [Entry] = []
        for turn in turns {
            for artifact in turn.artifacts {
                let base = "\(turn.number):\(artifact.absolutePath)"
                let occurrence = occurrences[base, default: 0] + 1
                occurrences[base] = occurrence
                entries.append(Entry(
                    id: occurrence == 1 ? base : "\(base)#\(occurrence)",
                    turnNumber: turn.number,
                    isInProgress: turn.number == snapshot.activeTurnNumber,
                    artifact: artifact
                ))
            }
        }
        return entries
    }

    /// The list's entries, one block per entry: the file's title
    /// (``titleText(_:standardErrorIsTerminal:)``), then, indented, its turn
    /// (``turnText(_:standardErrorIsTerminal:)``) and, when the artifact
    /// explains itself, the explanation on one row.
    nonisolated static func choiceEntries(
        _ entries: [Entry],
        standardErrorIsTerminal: Bool
    ) -> [TerminalSubAgentDetailPanel.ChoiceEntry] {
        entries.map { entry in
            var details = [turnText(entry, standardErrorIsTerminal: standardErrorIsTerminal)]
            if let explanation = explanationText(entry.artifact) {
                details.append(muted(explanation, standardErrorIsTerminal: standardErrorIsTerminal))
            }
            return TerminalSubAgentDetailPanel.ChoiceEntry(
                id: entry.id,
                title: titleText(entry.artifact, standardErrorIsTerminal: standardErrorIsTerminal),
                details: details
            )
        }
    }

    /// The header of a file's diff: the file's title, its turn, then its
    /// explanation, if any, wrapped at `width`.
    nonisolated static func headerRows(
        _ entry: Entry,
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        var rows = [
            titleText(entry.artifact, standardErrorIsTerminal: standardErrorIsTerminal),
            turnText(entry, standardErrorIsTerminal: standardErrorIsTerminal),
        ]
        if let explanation = explanationText(entry.artifact) {
            rows += TerminalChat.wrapInline(explanation, width: max(1, width)).map {
                muted($0, standardErrorIsTerminal: standardErrorIsTerminal)
            }
        }
        return rows
    }

    /// The body of a file's diff: the changed lines with their context,
    /// numbered and rendered as the chat renders a file artifact
    /// (``TerminalChat/fileArtifactDiffMarkdown(_:presentation:)``, drawn with
    /// ``TerminalChat/detailPanelMarkdownRows(_:width:standardErrorIsTerminal:)``);
    /// ``binaryRow`` for a binary file, ``noDiffRow`` without a diff.
    nonisolated static func bodyRows(
        _ artifact: FileChangeArtifact,
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        guard !artifact.isBinary else { return [binaryRow] }
        guard let markdown = TerminalChat.fileArtifactDiffMarkdown(artifact, presentation: .changedLines()) else {
            return [noDiffRow]
        }
        return TerminalChat.detailPanelMarkdownRows(
            markdown,
            width: width,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
    }

    /// The status of the file, its displayed path, and the counts as the
    /// header of a chat artifact shows them (`+n` green, `-n` red, left out
    /// when the evidence has no counts), then ` (binary)` for a binary file.
    nonisolated static func titleText(
        _ artifact: FileChangeArtifact,
        standardErrorIsTerminal: Bool
    ) -> String {
        let path = InlineTextTruncation.inlineText(artifact.displayPath.nilIfBlank ?? artifact.absolutePath)
        var text = "\(artifact.status.rawValue) \(path.nilIfBlank ?? "(unknown path)")"
        if artifact.hasLineCounts {
            let additions = "+\(artifact.additions)"
            let deletions = "-\(artifact.deletions)"
            if standardErrorIsTerminal {
                let palette = TerminalMarkdownPalette.detected
                let reset = TerminalStyle.reset
                text += "  \(palette.diffAddition)\(additions)\(reset) \(palette.diffRemoval)\(deletions)\(reset)"
            } else {
                text += "  \(additions) \(deletions)"
            }
        }
        if artifact.isBinary {
            text += " (binary)"
        }
        return text
    }

    /// `turn N`, muted, followed by `· in progress` for the turn in progress.
    nonisolated static func turnText(_ entry: Entry, standardErrorIsTerminal: Bool) -> String {
        let turn = "turn \(entry.turnNumber)"
        guard entry.isInProgress else {
            return muted(turn, standardErrorIsTerminal: standardErrorIsTerminal)
        }
        guard standardErrorIsTerminal else { return "\(turn) · in progress" }
        return muted("\(turn) ·", standardErrorIsTerminal: true)
            + " \(TerminalStyle.Status.active)in progress\(TerminalStyle.reset)"
    }

    /// The artifact's explanation on one line; `nil` when it has none.
    private nonisolated static func explanationText(_ artifact: FileChangeArtifact) -> String? {
        artifact.explanation.map(InlineTextTruncation.inlineText)?.nilIfBlank
    }

    private nonisolated static func muted(_ text: String, standardErrorIsTerminal: Bool) -> String {
        standardErrorIsTerminal ? "\(TerminalStyle.Text.muted)\(text)\(TerminalStyle.reset)" : text
    }

    private struct Viewport: Equatable {
        let rows: Int
        let columns: Int

        init(_ viewport: (rows: Int, columns: Int)) {
            rows = viewport.rows
            columns = viewport.columns
        }
    }

    private struct DiffRows {
        let artifact: FileChangeArtifact
        let width: Int
        let rows: [String]
    }
}
