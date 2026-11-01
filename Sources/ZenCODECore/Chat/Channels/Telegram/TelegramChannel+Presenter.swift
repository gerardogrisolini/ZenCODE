//
//  TelegramChannel+Presenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The presenter of a ``TelegramChannel``: the slot's presenter forwards the
/// session's output to it while the channel drives the slot (see
/// ``ChatSlotPresenter``), and tells it when a turn started on the primary
/// channel moves onto Telegram.
///
/// It sends the session's output to the linked chat: a root
/// response is buffered by the turn's reporter and published at the tool
/// call that follows it; the task-graph and sub-agent overviews the
/// controller publishes go through the reporter's ordered queue; the ending
/// of the turn (``presentTurnEnding(_:)``) retires the reporter with the
/// outcome and the file-change summary. While a remote command runs, it
/// collects the text of the session and workflow notices the command
/// produces, so the command can answer with them in the chat; outside a
/// command, a notice is sent to the chat as it comes.
///
/// The presenter holds the channel weakly: the channel holds it.
@ChatSessionActor
final class TelegramChannelPresenter: ChatSlotChannelPresenter {
    weak var channel: TelegramChannel?
    /// The notice texts collected since ``beginNoticeCapture()``, or `nil`
    /// when no remote command is collecting them.
    private var capturedNotices: [String]?
    /// The sub-agent responses already sent during the current turn, by
    /// their token, so a republished overview does not repeat them.
    private var sentSubAgentResponseTokens = Set<String>()

    init() {}

    // MARK: - Turn

    func turnWillStart(_ request: ChatTurnRequest) async {
        sentSubAgentResponseTokens = []
        await channel?.beginTurn(adoptingStreamingBlock: false)
    }

    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async {
        sentSubAgentResponseTokens = []
        // The block streaming now was sent as context by the handover; its
        // remaining deltas are suppressed until the next boundary.
        await channel?.beginTurn(adoptingStreamingBlock: !turn.liveAssistantText.isEmpty)
    }

    func presentAssistantContent(_ content: String) async {
        await channel?.appendRootResponseDelta(content)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        // The tool call closes the root response that preceded it: publish
        // that response, never the call itself.
        await channel?.publishRootResponseAtToolBoundary()
    }

    func turnWillContinueAutomatically() async {
        // An automatic `/goal` continuation closes the block like a boundary.
        await channel?.publishRootResponseAtToolBoundary()
    }

    func presentTurnEnding(_ ending: ChatTurnEnding) async {
        await channel?.finishTurn(ending: ending)
    }

    // MARK: - Overviews

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard let channel, let overview else { return }
        guard origin == .explicit || overview.isSignificant else { return }
        let plainText = TerminalANSIText.stripANSI(
            TerminalChat.taskGraphMarkdown(graph: overview.graph, tasks: overview.tasks, ansiEnabled: false)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else { return }
        await channel.enqueueOverview(
            .tasks("📋 Task graph\n\n\(plainText)"),
            taskGraphSignature: overview.signature
        )
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard let channel else { return }
        for response in TerminalChat.subAgentPartialResponses(overview.snapshots) {
            guard sentSubAgentResponseTokens.insert(response.token).inserted,
                  let payload = Self.subAgentResponsePayload(
                      heading: response.heading, markdown: response.markdown
                  ) else { continue }
            await channel.enqueueOverview(payload)
        }
        for response in TerminalChat.subAgentMarkdownResponses(overview.snapshots) {
            guard sentSubAgentResponseTokens.insert(response.token).inserted,
                  let payload = Self.subAgentResponsePayload(
                      heading: response.heading, markdown: response.markdown
                  ) else { continue }
            await channel.enqueueOverview(payload)
        }
    }

    /// The payload of a sub-agent response: its heading, without the
    /// terminal's decoration, over its Markdown; `nil` for an empty response.
    nonisolated static func subAgentResponsePayload(
        heading: String,
        markdown: String
    ) -> TerminalTelegramTurnPayload? {
        let heading = TerminalANSIText.stripANSI(heading)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else {
            return nil
        }
        let text = heading.isEmpty ? markdown : "\(heading)\n\n\(markdown)"
        return .subAgentResponse(text)
    }

    // MARK: - Notices

    /// Starts collecting the notices the session presents, for the remote
    /// command that is about to run. A capture already in progress starts
    /// over.
    func beginNoticeCapture() {
        capturedNotices = []
    }

    /// Stops collecting and returns the text of every session and workflow
    /// notice presented since ``beginNoticeCapture()``, in order, as
    /// ``ChatSessionNoticeText`` words them. Without a capture in progress it
    /// returns no text.
    func endNoticeCapture() -> [String] {
        let notices = capturedNotices ?? []
        capturedNotices = nil
        return notices
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        let text = ChatSessionNoticeText.text(for: notice)
        if capturedNotices != nil {
            capturedNotices?.append(text)
        } else {
            await channel?.sendSessionText(text)
        }
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        let text = ChatSessionNoticeText.text(for: notice)
        if capturedNotices != nil {
            capturedNotices?.append(text)
        } else {
            await channel?.sendSessionText(text)
        }
    }
}
