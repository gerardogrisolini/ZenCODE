//
//  TelegramSessionCompanion+Presenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The presenter of a ``TelegramSessionCompanion`` in its session's
/// controller: the controller fans the turn's output out to it before the
/// primary channel's presenter (see ``ChatFanOutPresenter``).
///
/// It mirrors only what reaches the linked chat. A root-response delta is
/// buffered by the turn's reporter, and the tool call that follows publishes
/// it, after the channel's overview barrier. While a remote command runs, it
/// collects the text of the session and workflow notices the command
/// produces, so the command can answer with them in the linked chat.
///
/// The companion registers it in the controller once, when the companion is
/// created, and removes it in ``TelegramSessionCompanion/shutdown()``: a
/// `/telegram off` does not remove it and a `/telegram on` does not add it.
/// This departs on purpose from registering it at every attach and removing
/// it at every detach. A turn reads the controller's presenters once, when it
/// starts, so a presenter registered by `/telegram on` would miss the rest of
/// a turn already running, while the terminal mirrors that turn from its next
/// tool boundary on. Registered from the start, the presenter sees every turn;
/// while the companion is detached it sends nothing, because the turn then
/// has no reporter (``TelegramSessionCompanion/synchronizeTurnReporting()``),
/// and it only tracks the streaming response block, so a block that spans an
/// attach is suppressed instead of being mirrored from its middle.
///
/// The presenter holds the companion weakly. The companion holds the
/// controller, which holds the presenter, so a strong reference would form a
/// cycle; a presenter whose companion is gone does nothing.
@ChatSessionActor
final class TelegramCompanionPresenter: ChatCompanionPresenter {
    weak var companion: TelegramSessionCompanion?
    /// The notice texts collected since ``beginNoticeCapture()``, or `nil`
    /// when no remote command is collecting them.
    private var capturedNotices: [String]?

    init() {}

    // MARK: - Turn output

    func presentAssistantContent(_ content: String) async {
        await companion?.appendRootResponseDelta(content)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        // The tool call closes the root response that preceded it: publish
        // that response, never the call itself.
        await companion?.publishRootResponseAtToolBoundary()
    }

    // MARK: - Notices of a remote command

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
        capturedNotices?.append(ChatSessionNoticeText.text(for: notice))
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        capturedNotices?.append(ChatSessionNoticeText.text(for: notice))
    }
}
