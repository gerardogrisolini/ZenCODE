//
//  TerminalChatSessionPresenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Renders the shared chat-turn pipeline in the terminal chat.
///
/// The presenter holds the chat weakly: the chat owns the session controller,
/// which owns this presenter, so a strong reference would form a cycle.
@TerminalChatActor
final class TerminalChatSessionPresenter: ChatSessionPresenter {
    weak var chat: TerminalChat?

    init() {}

    func presentThought(_ thought: String) async {
        await chat?.writeThought(thought)
    }

    func presentAssistantContent(_ content: String) async {
        guard let chat else { return }
        await chat.activeAssistantOutput?.append(content)
        await chat.appendTelegramRootResponseDelta(content)
    }

    func presentModelLoaded(_ modelID: String) async {
        await chat?.printModelIfNeeded(modelID)
    }

    func presentMetrics(_ metrics: DirectAgentGenerationMetrics) async {
        await chat?.writeMetricsStatus(metrics)
    }

    func presentContextWindow(_ status: DirectAgentContextWindowStatus) async {
        await chat?.writeContextWindowStatus(status)
    }

    func presentSubscriptionUsage(_ status: DirectAgentSubscriptionUsageStatus) async {
        await chat?.writeSubscriptionUsageStatus(status)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        guard let chat else { return }
        // The text written before a tool call is a comment on what is about
        // to happen: besides showing it, offer it to voice mode, which reads
        // it aloud when it can.
        let commentary = await chat.activeAssistantOutput?.takePending() ?? ""
        await chat.writeAssistantContent(commentary)
        chat.offerVoiceCommentary(commentary)
        await chat.writeToolCallStarted(toolCall)
        // The tool call closes the root response that preceded it: publish
        // that response, never the call itself.
        await chat.publishTelegramRootResponseAtToolBoundary()
        await chat.publishSubAgentOverviewIfChanged(relatedToolName: toolCall.name)
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            chat.startSubAgentOverviewRefreshIfNeeded()
        }
    }

    func presentToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        await chat?.writeToolCallCompleted(toolCall, result: result)
    }

    func presentToolCallSettled(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        guard let chat else { return }
        if TerminalChat.isFileMutationTool(toolCall.name) {
            await chat.refreshStatusBarGitStatusSummaryForFileMutation()
        }
        if await chat.shouldPublishDeferredTaskGraphOverview() {
            await chat.publishTaskGraphOverviewIfChanged(observedSessionID: chat.sessionID)
        }
        await chat.publishSubAgentOverviewIfChanged(relatedToolName: toolCall.name)
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            await chat.stopSubAgentOverviewRefresh()
        }
    }

    func presentLiveFileArtifacts(
        _ turns: [SessionFileArtifactHistory.Turn],
        agentID: String?
    ) async {
        guard let chat else { return }
        if agentID != nil {
            // A delegated artifact replaces the pending sub-agent overview, and
            // only while its recording turn is still the active one.
            guard let context = chat.chatSession.activeFileArtifactTurn else { return }
            await chat.writeFileArtifacts(
                turns,
                includeHistoryHeadings: false,
                preservingStreamingContext: true,
                replacingSubAgentOverviewFor: context
            )
        } else {
            await chat.writeFileArtifacts(
                turns,
                includeHistoryHeadings: false,
                preservingStreamingContext: true
            )
        }
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        await chat?.writeFileArtifacts([turn], includeHistoryHeadings: false)
    }

    func turnWillContinueAutomatically() async {
        guard let chat else { return }
        await chat.writeAssistantContent(await chat.activeAssistantOutput?.takePending() ?? "")
        await chat.finishStreamingOutput()
    }

    func turnWillFinish() async {
        guard let chat else { return }
        await chat.stopSubAgentOverviewRefresh()
        await chat.renderCoordinator.waitForOverviewMirrorsToDrain()
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        guard let chat else { return }
        switch notice {
        case let .openWithoutQuestion(graphID, pendingTaskCount):
            // Truthful notice: the graph survives, but nothing is waiting for
            // a reply, so the next message is an ordinary chat message.
            await chat.writeSystemMessage(
                TerminalChat.workflowOpenWithoutQuestionMessage(
                    graphID: graphID,
                    pendingTaskCount: pendingTaskCount
                )
            )
        case let .blocked(graphID, message):
            await chat.writeSystemMessage(
                "Workflow \"\(graphID)\" is blocked: \(message)\n"
                    + "Your next message resumes this same workflow; use /tasks clear to stop it.\n"
            )
        case let .awaitingReply(graphID, pendingTaskCount):
            await chat.writeSystemMessage(
                TerminalChat.workflowStillOpenMessage(
                    graphID: graphID,
                    pendingTaskCount: pendingTaskCount
                )
            )
        case let .recoverableFailure(graphID, pendingTaskCount):
            await chat.writeSystemMessage(
                TerminalChat.workflowRecoverableFailureMessage(
                    graphID: graphID,
                    pendingTaskCount: pendingTaskCount
                )
            )
        }
    }
}
