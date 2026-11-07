//
//  ZenTranscriptRows.swift
//  ZenApp
//
//  The rows of the conversation: which transcript items show, where the turn
//  separators go, the closed rows and the block still streaming, and the
//  view of each item.
//

import Foundation
import Observation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

/// One row of the conversation list.
struct ZenConversationRow: Identifiable, Equatable {
    let item: ZenTranscriptItem
    /// A turn separator precedes the row: it starts a visible turn after the
    /// first one.
    let showsSeparator: Bool

    var id: String { item.id }

    /// The rows of `transcript`: hidden tool calls (`agent.message`) and the
    /// file artifacts (they show in the artifacts sidebar) are left out, and
    /// every row that starts a visible turn (``ZenTranscriptItem/startsTurn``)
    /// after the first one starts with a separator. A prompt a command built
    /// is not a row, so no separator marks it.
    static func rows(for transcript: [ZenTranscriptItem]) -> [ZenConversationRow] {
        var rows: [ZenConversationRow] = []
        rows.reserveCapacity(transcript.count)
        var hasSeenTurnStart = false
        for item in transcript {
            switch item.content {
            case let .toolCall(call, _) where ZenToolCallFormatting.isHidden(toolName: call.name):
                continue
            case .fileArtifacts:
                continue
            default:
                break
            }
            rows.append(ZenConversationRow(item: item, showsSeparator: item.startsTurn && hasSeenTurnStart))
            if item.startsTurn {
                hasSeenTurnStart = true
            }
        }
        return rows
    }
}

/// The rows of the latest transcript, computed again only when the
/// transcript changes. The session reassigns its transcript only when a
/// closed row changes, so the comparison of an unchanged transcript is one
/// buffer identity check, and a body that runs again (a scroll, the content
/// growing while a block streams) does no work per row.
@MainActor
final class ZenConversationRowCache {
    private var transcript: [ZenTranscriptItem] = []
    private var rows: [ZenConversationRow] = []

    init() {}

    /// The rows of `transcript` (``ZenConversationRow/rows(for:)``).
    func rows(for transcript: [ZenTranscriptItem]) -> [ZenConversationRow] {
        if transcript != self.transcript {
            self.transcript = transcript
            rows = ZenConversationRow.rows(for: transcript)
        }
        return rows
    }
}

/// The closed rows of the conversation. Equal values (the same rows, the
/// same durations) do not run the body again, so the list re-runs its own
/// body without diffing the rows.
struct ZenTranscriptRowList: View, Equatable {
    let rows: [ZenConversationRow]
    let durations: ZenToolDurations

    var body: some View {
        ForEach(rows) { row in
            ZenConversationRowView(row: row, durations: durations)
        }
    }

    nonisolated static func == (lhs: ZenTranscriptRowList, rhs: ZenTranscriptRowList) -> Bool {
        lhs.durations === rhs.durations && lhs.rows == rhs.rows
    }
}

/// The block still streaming (``ZenWindowSession/liveItems``), after the
/// closed rows. It is the only view that reads the live text, so a streamed
/// token runs this body alone; the list follows the content growing through
/// its scroll geometry.
struct ZenLiveRows: View {
    let session: ZenWindowSession

    var body: some View {
        ForEach(session.liveItems) { item in
            ZenTranscriptItemView(content: item.content, toolDuration: nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The view of one conversation row: the turn separator, then the item.
struct ZenConversationRowView: View {
    let row: ZenConversationRow
    let durations: ZenToolDurations

    @Environment(\.zenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if row.showsSeparator {
                Rectangle()
                    .fill(palette.turnSeparator)
                    .frame(height: 1)
                    .padding(.vertical, 6)
                    .accessibilityHidden(true)
            }
            // Only a completed tool call reads the durations.
            ZenTranscriptItemView(content: row.item.content, toolDuration: durations.duration(for: row.item))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The view of a transcript item's content. The content is an enum of this
/// package (`ZenAppSession`), so the switch stays exhaustive: a new case is a
/// build error here, not a silent blank row.
struct ZenTranscriptItemView: View {
    let content: ZenTranscriptItem.Content
    let toolDuration: Duration?

    var body: some View {
        switch content {
        case let .userPrompt(text, attachments, origin):
            ZenUserPromptView(text: text, attachments: attachments, origin: origin)
        case let .commandLine(text):
            ZenCommandLineView(text: text)
        case let .assistantText(text, isStreaming):
            ZenAssistantTextView(text: text, isStreaming: isStreaming)
        case let .thought(text, isStreaming):
            ZenThoughtView(text: text, isStreaming: isStreaming)
        case let .toolCall(call, result):
            ZenToolCallView(call: call, result: result, duration: toolDuration)
        case let .fileArtifacts(turn, agentID, _):
            // Not a row of the conversation (see `ZenConversationRow`): the
            // artifacts show in the sidebar.
            ZenFileArtifactsView(turn: turn, agentID: agentID)
        case let .notice(notice):
            ZenNoticeView(notice: notice)
        case let .workflowNotice(notice):
            ZenWorkflowNoticeView(notice: notice)
        case let .fileChangeSummary(summary):
            ZenFileChangeSummaryView(summary: summary, includesDiff: false)
        case let .local(text, isFailure):
            ZenLocalMessageView(text: text, isFailure: isFailure)
        case let .taskGraph(overview):
            ZenTaskGraphCard(overview: overview)
        }
    }
}

/// The durations of the completed tool calls, as the Core measured them: the
/// time a call's result carries (`DirectAgentToolResult.elapsed`), measured
/// once by the tool executor. A result the executor did not produce (a call
/// cancelled before its dispatch, a restored session) has none, and the row
/// shows no time.
///
/// A sub-agent tab rebuilds its rows from the agent's history, whose results
/// carry no time: it shows the durations the Core kept for the agent instead
/// (``replace(with:)``, by row id, from
/// `ZenSubAgentTranscriptModel.toolDurations`), which win over the result's.
@MainActor
@Observable
final class ZenToolDurations {
    /// The durations given by ``replace(with:)``, by row id.
    private(set) var durations: [String: Duration] = [:]

    init() {}

    /// The duration of the call of `item` once it completed: the one given
    /// for its row by ``replace(with:)``, else the one its result carries.
    func duration(for item: ZenTranscriptItem) -> Duration? {
        guard case let .toolCall(_, result) = item.content, let result else { return nil }
        return durations[item.id] ?? result.elapsed
    }

    /// Shows `durations` (by row id), measured elsewhere, instead of the
    /// ones held; assigned only when they differ.
    func replace(with durations: [String: Duration]) {
        if self.durations != durations {
            self.durations = durations
        }
    }
}
