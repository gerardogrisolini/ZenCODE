//
//  ZenTranscriptProjection.swift
//  ZenApp
//
//  The projection of a session snapshot, the window's own rows, and the
//  prompts the window hid into the rows of a transcript, and the projection
//  of a sub-agent's transcript with the same row rules.
//

import Foundation
import ToolCore
import ZenCODECore

/// Projects a `ChatSessionSnapshot`, the window's local rows, and the prompts
/// the window hid into ``ZenTranscriptItem`` values (``items``).
///
/// Rules:
/// - one row per log entry, in log order, with the id
///   `<epoch>-log-<sequence>`; `.toolCallCompleted` fills the result of the
///   row of its start (by call id within the turn, FIFO within the turn for
///   calls without id) and adds no row; `.turnPhase` adds no row;
/// - a hidden prompt (``hidePrompt(after:epoch:)``) adds no row; every other
///   `.userPrompt` row starts a visible turn (``ZenTranscriptItem/startsTurn``),
///   a local one too (the echo of a reply the operator typed);
/// - the file-change summary of a turn (`fileChanges.turnSummary`, when it is
///   not empty) is remembered per turn and follows the last row of its turn,
///   as `<epoch>-summary-<turnID>`;
/// - each local row follows the log rows up to its anchor sequence; a row
///   the window moves (``moveLocal(id:to:content:)``, the task-graph card of
///   a turn) keeps its id;
/// - the block still streaming is not a row: its id is
///   ``liveBlockID(for:)``.
///
/// Everything belongs to one epoch: a snapshot of another epoch starts the
/// projection over, and drops the summaries, hidden prompts, and local rows
/// of the earlier epochs.
///
/// ``update(with:)`` keeps the rows of the log entries it already projected
/// and projects only the new entries while the epoch and the first retained
/// sequence of the log are unchanged (so no entry it holds was dropped and the
/// log did not start over); otherwise it rebuilds. It composes ``items`` again
/// only when an input changed (a row of the log, a summary, a hidden prompt,
/// a local row). Either way ``items`` equals
/// ``items(for:localItems:fileChangeSummaries:hiddenPromptSequences:)``.
public struct ZenTranscriptProjection: Sendable {
    /// The rows, as of the last composition.
    public private(set) var items: [ZenTranscriptItem] = []
    /// The epoch of the snapshots projected; `nil` before the first one.
    public private(set) var epoch: UInt64?
    /// The file-change summaries seen in the current epoch, by turn.
    public private(set) var fileChangeSummaries: [Int: TurnFileChangeSummary] = [:]
    /// The local rows of the current epoch and of later ones, ordered by
    /// epoch and anchor; rows with the same anchor keep their insertion order.
    public private(set) var localItems: [ZenLocalTranscriptItem] = []
    /// The sequences of the hidden prompts of the current epoch.
    public private(set) var hiddenPromptSequences: Set<Int> = []
    /// The title derived from the first visible prompt of the epoch, a log
    /// row or a local echo (``title(fromPrompt:)``); `nil` before one. It
    /// stays once found.
    public private(set) var firstVisiblePromptTitle: String?

    private struct HiddenPromptAnchor: Sendable {
        let epoch: UInt64
        let afterSequence: Int
    }

    /// The prompts to hide that the log does not show yet, oldest first.
    private var hiddenPromptAnchors: [HiddenPromptAnchor] = []
    private var base = LogRows(epoch: 0)
    private var firstRetainedSequence: Int?
    private var needsComposition = false
    /// The number of full rebuilds, for tests.
    private(set) var rebuildCount = 0
    /// The number of compositions, for tests.
    private(set) var compositionCount = 0

    public init() {}

    // MARK: - Inputs

    /// Hides the prompt of the next turn of `epoch`: the first `.userPrompt`
    /// entry after `sequence` (the last sequence of the log right before the
    /// turn started). Ignored for an earlier epoch than the current one.
    public mutating func hidePrompt(after sequence: Int, epoch: UInt64) {
        if let current = self.epoch, epoch < current {
            return
        }
        let anchor = HiddenPromptAnchor(epoch: epoch, afterSequence: sequence)
        let index = hiddenPromptAnchors.lastIndex {
            ($0.epoch, $0.afterSequence) <= (epoch, sequence)
        }.map { $0 + 1 } ?? 0
        hiddenPromptAnchors.insert(anchor, at: index)
    }

    /// Adds a local row in anchor order. A row of an earlier epoch than the
    /// current one is dropped.
    public mutating func insertLocal(_ item: ZenLocalTranscriptItem) {
        if let epoch, item.epoch < epoch {
            return
        }
        let index = localItems.lastIndex {
            ($0.epoch, $0.anchorSequence) <= (item.epoch, item.anchorSequence)
        }.map { $0 + 1 } ?? 0
        localItems.insert(item, at: index)
        if item.epoch == epoch {
            needsComposition = true
        }
    }

    /// Moves the local row `id` after the log rows up to `anchorSequence`,
    /// with `content`, keeping its id and its epoch: it leaves its place and
    /// goes where ``insertLocal(_:)`` puts a row inserted now, after every
    /// local row with an anchor up to the new one. A row that does not move
    /// and keeps its content changes nothing in ``items``. `false`, and
    /// nothing changes, when no local row has that id (its epoch ended).
    @discardableResult
    public mutating func moveLocal(
        id: UUID,
        to anchorSequence: Int,
        content: ZenTranscriptItem.Content
    ) -> Bool {
        guard let index = localItems.firstIndex(where: { $0.id == id }) else { return false }
        let item = localItems.remove(at: index)
        insertLocal(ZenLocalTranscriptItem(
            id: id,
            epoch: item.epoch,
            anchorSequence: anchorSequence,
            content: content
        ))
        return true
    }

    /// Projects `snapshot`; `true` when ``items`` changed.
    @discardableResult
    public mutating func update(with snapshot: ChatSessionSnapshot) -> Bool {
        if epoch != snapshot.epoch {
            startEpoch(snapshot.epoch)
        }
        if Self.remember(snapshot, in: &fileChangeSummaries) {
            needsComposition = true
        }
        resolveHiddenPrompts(in: snapshot)

        let lastSequence = snapshot.log.last?.sequence
        let canCatchUp = firstRetainedSequence == snapshot.firstRetainedSequence
            && base.lastSequence + 1 >= snapshot.firstRetainedSequence
            && (lastSequence ?? base.lastSequence) >= base.lastSequence
        if canCatchUp {
            if let lastSequence, lastSequence > base.lastSequence {
                let start = Self.firstIndex(after: base.lastSequence, in: snapshot.log)
                for entry in snapshot.log[start...] where base.apply(entry) {
                    needsComposition = true
                }
            }
        } else {
            base = LogRows(
                epoch: snapshot.epoch,
                entries: snapshot.log,
                firstRetainedSequence: snapshot.firstRetainedSequence
            )
            rebuildCount += 1
            needsComposition = true
        }
        firstRetainedSequence = snapshot.firstRetainedSequence
        return composeIfNeeded()
    }

    /// Composes ``items`` again when an input changed since the last
    /// composition; `true` when ``items`` changed.
    @discardableResult
    public mutating func composeIfNeeded() -> Bool {
        guard needsComposition, let epoch else { return false }
        needsComposition = false
        compositionCount += 1
        let composition = Self.compose(
            base,
            epoch: epoch,
            localItems: localItems,
            fileChangeSummaries: fileChangeSummaries,
            hiddenPromptSequences: hiddenPromptSequences
        )
        if firstVisiblePromptTitle == nil, let prompt = composition.firstVisiblePrompt {
            firstVisiblePromptTitle = Self.title(fromPrompt: prompt)
        }
        guard composition.items != items else { return false }
        items = composition.items
        return true
    }

    /// The id of the block `snapshot` is streaming, unique across the blocks
    /// and the epochs of a window: `<epoch>-live-<turnID>-<n>`, where `n`
    /// counts the closed assistant and reasoning blocks of the turn; `nil`
    /// when nothing streams. Call it after ``update(with:)`` with the same
    /// snapshot.
    public func liveBlockID(for snapshot: ChatSessionSnapshot) -> String? {
        let turn = snapshot.turn
        guard !turn.liveThought.isEmpty || !turn.liveAssistantText.isEmpty else { return nil }
        guard let turnID = turn.turnID else {
            return "\(snapshot.epoch)-live-none-0"
        }
        return "\(snapshot.epoch)-live-\(turnID)-\(base.closedBlockCount(inTurn: turnID))"
    }

    // MARK: - Full rebuild

    /// The rows of `snapshot` with `localItems`, projected from scratch.
    /// `fileChangeSummaries` are the summaries remembered for earlier turns of
    /// the epoch; the snapshot's current summary is added to them.
    /// `hiddenPromptSequences` are the prompts that add no row.
    public static func items(
        for snapshot: ChatSessionSnapshot,
        localItems: [ZenLocalTranscriptItem],
        fileChangeSummaries: [Int: TurnFileChangeSummary] = [:],
        hiddenPromptSequences: Set<Int> = []
    ) -> [ZenTranscriptItem] {
        var summaries = fileChangeSummaries
        remember(snapshot, in: &summaries)
        // A stable sort: rows with the same anchor keep their order.
        let locals = localItems
            .enumerated()
            .filter { $0.element.epoch == snapshot.epoch }
            .sorted { ($0.element.anchorSequence, $0.offset) < ($1.element.anchorSequence, $1.offset) }
            .map(\.element)
        return compose(
            LogRows(epoch: snapshot.epoch, entries: snapshot.log, firstRetainedSequence: snapshot.firstRetainedSequence),
            epoch: snapshot.epoch,
            localItems: locals,
            fileChangeSummaries: summaries,
            hiddenPromptSequences: hiddenPromptSequences
        ).items
    }

    /// A concise single-line title from a prompt, as the Core derives a
    /// session name from its first prompt: whitespace collapsed, at most
    /// `limit` characters, cut at a word boundary; `nil` for a blank prompt.
    public static func title(fromPrompt prompt: String, limit: Int = 40) -> String? {
        let singleLine = prompt
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        guard singleLine.count > limit else { return singleLine }
        let truncated = String(singleLine.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " ") {
            let wordBounded = String(truncated[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !wordBounded.isEmpty {
                return wordBounded
            }
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Epoch

    private mutating func startEpoch(_ newEpoch: UInt64) {
        epoch = newEpoch
        fileChangeSummaries = [:]
        hiddenPromptSequences = []
        hiddenPromptAnchors.removeAll { $0.epoch < newEpoch }
        localItems.removeAll { $0.epoch < newEpoch }
        firstVisiblePromptTitle = nil
        firstRetainedSequence = nil
        base = LogRows(epoch: newEpoch)
        // `items` keeps the rows of the earlier epoch until the composition
        // replaces them, so the change is reported even when the new epoch
        // has no row yet.
        needsComposition = true
    }

    /// Hides, for each anchor of the snapshot's epoch, the first prompt after
    /// it that the log shows; the anchors whose prompt has not come yet wait.
    private mutating func resolveHiddenPrompts(in snapshot: ChatSessionSnapshot) {
        guard !hiddenPromptAnchors.isEmpty else { return }
        var waiting: [HiddenPromptAnchor] = []
        for anchor in hiddenPromptAnchors {
            guard anchor.epoch == snapshot.epoch else {
                waiting.append(anchor)
                continue
            }
            let start = Self.firstIndex(after: anchor.afterSequence, in: snapshot.log)
            let prompt = snapshot.log[start...].first { entry in
                if case .userPrompt = entry.kind {
                    return !hiddenPromptSequences.contains(entry.sequence)
                }
                return false
            }
            if let prompt {
                hiddenPromptSequences.insert(prompt.sequence)
                needsComposition = true
            } else {
                waiting.append(anchor)
            }
        }
        hiddenPromptAnchors = waiting
    }

    // MARK: - Composition

    /// Remembers the snapshot's current summary; `true` when it changed what
    /// `summaries` holds.
    @discardableResult
    private static func remember(
        _ snapshot: ChatSessionSnapshot,
        in summaries: inout [Int: TurnFileChangeSummary]
    ) -> Bool {
        guard let turnID = snapshot.turn.turnID,
              let summary = snapshot.fileChanges.turnSummary,
              !summary.entries.isEmpty,
              summaries[turnID] != summary else {
            return false
        }
        summaries[turnID] = summary
        return true
    }

    /// The index of the first entry of `log` with a sequence above
    /// `sequence` (the log's sequences strictly increase).
    private static func firstIndex(after sequence: Int, in log: [ChatTurnEntry]) -> Int {
        var low = 0
        var high = log.count
        while low < high {
            let middle = (low + high) / 2
            if log[middle].sequence <= sequence {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private struct Composition {
        let items: [ZenTranscriptItem]
        /// The text of the first visible prompt.
        let firstVisiblePrompt: String?
    }

    /// `localItems` are in anchor order; the ones of another epoch are left
    /// out.
    private static func compose(
        _ base: LogRows,
        epoch: UInt64,
        localItems: [ZenLocalTranscriptItem],
        fileChangeSummaries: [Int: TurnFileChangeSummary],
        hiddenPromptSequences: Set<Int>
    ) -> Composition {
        let locals = localItems.filter { $0.epoch == epoch }
        var items: [ZenTranscriptItem] = []
        items.reserveCapacity(base.rows.count + locals.count + fileChangeSummaries.count)
        var firstVisiblePrompt: String?
        func append(_ item: ZenTranscriptItem) {
            if firstVisiblePrompt == nil, case let .userPrompt(text, _, _) = item.content {
                firstVisiblePrompt = text
            }
            items.append(item)
        }
        var localIndex = 0
        for (index, row) in base.rows.enumerated() {
            while localIndex < locals.count, locals[localIndex].anchorSequence < row.sequence {
                append(locals[localIndex].transcriptItem)
                localIndex += 1
            }
            if !hiddenPromptSequences.contains(row.sequence) {
                append(row.item)
            }
            if let turnID = row.item.turnID,
               base.lastRowIndexByTurn[turnID] == index,
               let summary = fileChangeSummaries[turnID] {
                items.append(ZenTranscriptItem(
                    id: "\(epoch)-summary-\(turnID)",
                    turnID: turnID,
                    content: .fileChangeSummary(summary)
                ))
            }
        }
        while localIndex < locals.count {
            append(locals[localIndex].transcriptItem)
            localIndex += 1
        }
        return Composition(items: items, firstVisiblePrompt: firstVisiblePrompt)
    }
}

// MARK: - Sub-agent transcripts

/// Projects the conversation of one delegated sub-agent
/// (`ChatSubAgentTranscript.kinds`, oldest first) into ``ZenTranscriptItem``
/// values, with the row rules of the session log (``ZenTranscriptProjection``):
///
/// - one row per kind, in order, with the id `subagent-<agentID>-<n>`, where
///   `n` is the index of the kind in `kinds`, so a transcript that grows keeps
///   the ids of its rows;
/// - `.toolCallCompleted` fills the result of the row of its start (by call
///   id, the latest call with that id; oldest first for calls without id) and
///   adds no row; a call that has not completed stays a row without result;
/// - every `.userPrompt` (the brief, a message the agent received) starts a
///   visible turn (``ZenTranscriptItem/startsTurn``), so a separator goes
///   before every prompt after the first;
/// - reasoning and assistant text are closed blocks (`isStreaming == false`);
/// - `.turnPhase`, and any kind a later release adds, adds no row.
///
/// A sub-agent transcript has no turn numbers: every row has a `nil`
/// ``ZenTranscriptItem/turnID``.
public enum ZenSubAgentTranscriptProjection {
    /// The rows of `kinds`, the transcript of the sub-agent `agentID`.
    public static func items(for kinds: [ChatTurnEntry.Kind], agentID: String) -> [ZenTranscriptItem] {
        var rows = LogRows(idPrefix: rowIDPrefix(agentID: agentID))
        for (index, kind) in kinds.enumerated() {
            rows.apply(kind, sequence: index, turnID: nil)
        }
        return rows.rows.map(\.item)
    }

    /// `subagent-<agentID>-`, the prefix of the ids of the rows of `agentID`.
    public static func rowIDPrefix(agentID: String) -> String {
        "subagent-\(agentID)-"
    }

    /// The durations of the completed tool calls of `items`, by row id: each
    /// tool-call row with a result whose call id has a duration in
    /// `callDurations` (`ChatSubAgentTranscript.toolDurations`, by call id).
    /// A running call, a call without an id, and a call without a duration
    /// have none; every other row has none either.
    public static func toolDurations(
        for items: [ZenTranscriptItem],
        callDurations: [String: Duration]
    ) -> [String: Duration] {
        guard !callDurations.isEmpty else { return [:] }
        var durations: [String: Duration] = [:]
        for item in items {
            guard case let .toolCall(call, result) = item.content,
                  result != nil,
                  !call.id.isEmpty,
                  let duration = callDurations[call.id] else { continue }
            durations[item.id] = duration
        }
        return durations
    }
}

// MARK: - Log rows

/// The rows of the log entries of one epoch (or of the kinds of a sub-agent
/// transcript), with what merging the tool results needs.
private struct LogRows: Sendable {
    struct Row: Sendable {
        let sequence: Int
        var item: ZenTranscriptItem
    }

    private struct CallKey: Hashable, Sendable {
        let turnID: Int?
        let callID: String
    }

    /// The prefix of the row ids, followed by the sequence: `<epoch>-log-`
    /// for the log of a session.
    let idPrefix: String
    private(set) var rows: [Row] = []
    /// The index of the last row of each turn.
    private(set) var lastRowIndexByTurn: [Int: Int] = [:]
    /// The last sequence applied.
    private(set) var lastSequence: Int
    /// Open tool calls with an id, by turn and id.
    private var openCalls: [CallKey: Int] = [:]
    /// Open tool calls without an id, oldest first, by turn.
    private var openCallsWithoutID: [Int?: [Int]] = [:]
    /// The closed assistant and reasoning blocks of each turn.
    private var closedBlockCountByTurn: [Int: Int] = [:]

    init(epoch: UInt64) {
        self.init(idPrefix: Self.logIDPrefix(epoch: epoch))
    }

    init(idPrefix: String) {
        self.idPrefix = idPrefix
        lastSequence = 0
    }

    init(epoch: UInt64, entries: [ChatTurnEntry], firstRetainedSequence: Int) {
        idPrefix = Self.logIDPrefix(epoch: epoch)
        lastSequence = firstRetainedSequence - 1
        for entry in entries {
            apply(entry)
        }
    }

    /// `<epoch>-log-`, the prefix of the rows of a session log.
    private static func logIDPrefix(epoch: UInt64) -> String {
        "\(epoch)-log-"
    }

    func closedBlockCount(inTurn turnID: Int) -> Int {
        closedBlockCountByTurn[turnID] ?? 0
    }

    /// Applies `entry`; `true` when it added or changed a row.
    @discardableResult
    mutating func apply(_ entry: ChatTurnEntry) -> Bool {
        apply(entry.kind, sequence: entry.sequence, turnID: entry.turnID)
    }

    /// Applies an entry of `kind` at `sequence` in `turnID`; `true` when it
    /// added or changed a row.
    @discardableResult
    mutating func apply(_ kind: ChatTurnEntry.Kind, sequence: Int, turnID: Int?) -> Bool {
        lastSequence = max(lastSequence, sequence)
        let content: ZenTranscriptItem.Content
        var startsTurn = false
        switch kind {
        case let .userPrompt(text, attachments, origin):
            content = .userPrompt(text: text, attachments: attachments, origin: origin)
            startsTurn = true
        case let .assistantText(text):
            content = .assistantText(text, isStreaming: false)
            countClosedBlock(in: turnID)
        case let .thought(text):
            content = .thought(text, isStreaming: false)
            countClosedBlock(in: turnID)
        case let .toolCallStarted(call):
            let index = rows.count
            if call.id.isEmpty {
                openCallsWithoutID[turnID, default: []].append(index)
            } else {
                openCalls[CallKey(turnID: turnID, callID: call.id)] = index
            }
            content = .toolCall(call: call, result: nil)
        case let .toolCallCompleted(call, result):
            return complete(call, result: result, turnID: turnID)
        case let .fileArtifacts(turn, agentID, isSealed):
            content = .fileArtifacts(turn, agentID: agentID, isSealed: isSealed)
        case let .notice(notice):
            content = .notice(notice)
        case let .workflowNotice(notice):
            content = .workflowNotice(notice)
        default:
            // `.turnPhase` adds no row, nor does a kind a later release adds.
            return false
        }
        if let turnID {
            lastRowIndexByTurn[turnID] = rows.count
        }
        rows.append(Row(
            sequence: sequence,
            item: ZenTranscriptItem(
                id: "\(idPrefix)\(sequence)",
                turnID: turnID,
                startsTurn: startsTurn,
                content: content
            )
        ))
        return true
    }

    private mutating func countClosedBlock(in turnID: Int?) {
        guard let turnID else { return }
        closedBlockCountByTurn[turnID, default: 0] += 1
    }

    private mutating func complete(_ call: DirectAgentToolCall, result: DirectAgentToolResult, turnID: Int?) -> Bool {
        let index: Int?
        if call.id.isEmpty {
            if var queue = openCallsWithoutID[turnID], !queue.isEmpty {
                index = queue.removeFirst()
                openCallsWithoutID[turnID] = queue
            } else {
                index = nil
            }
        } else {
            index = openCalls.removeValue(forKey: CallKey(turnID: turnID, callID: call.id))
        }
        guard let index, case let .toolCall(startedCall, _) = rows[index].item.content else {
            return false
        }
        rows[index].item = ZenTranscriptItem(
            id: rows[index].item.id,
            turnID: rows[index].item.turnID,
            content: .toolCall(call: startedCall, result: result)
        )
        return true
    }
}
