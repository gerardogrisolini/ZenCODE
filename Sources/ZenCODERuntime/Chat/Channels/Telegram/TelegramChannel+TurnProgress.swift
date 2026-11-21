//
//  TelegramChannel+TurnProgress.swift
//  ZenCODE
//
//  The progress of the turn in progress as the linked chat receives it: the
//  root response and reasoning blocks, the tool activity, the overviews, and
//  the ordered reporter that sends them.
//

import Foundation
import ToolCore

extension TelegramChannel {
    // MARK: - Root response

    /// Aggregates one visible root-response delta for the linked chat.
    ///
    /// The reporter buffers the deltas and publishes them as one message at
    /// the next tool boundary; nothing is sent while the response streams.
    func appendRootResponseDelta(_ delta: String) async {
        guard !delta.isEmpty else {
            return
        }
        guard turnBlocks.recordRootResponseContent(),
              let reporter = activeProgressReporter else {
            return
        }
        await reporter.appendAgentResponseDelta(delta)
    }

    /// Publishes the aggregated root response at a tool-call boundary, or
    /// at a reasoning block that assistant content closes
    /// (``closeThoughtBlockBeforeAssistantContent()``).
    ///
    /// The boundary proves the response complete: the model stopped writing
    /// and started a tool, or reasoned before it wrote again. A suppressed
    /// block ends here unsent; the next one is sent again.
    func publishRootResponseAtToolBoundary() async {
        let wasSuppressed = turnBlocks.endRootResponseBlock()
        guard let reporter = activeProgressReporter else {
            return
        }
        guard !wasSuppressed else {
            await reporter.discardPendingAgentResponse()
            return
        }
        guard await reporter.hasPendingAgentResponse else {
            return
        }
        if await reporter.publishPendingAgentResponseAtBoundary() {
            turnBlocks.didPublishIntermediateRootResponse = true
        }
    }

    /// The text to send as the turn's final response.
    ///
    /// A turn's response text accumulates every assistant block it produced,
    /// the intermediate responses already published at their tool boundaries
    /// included. Once one was published, the trailing block aggregated since
    /// the last boundary, the final response itself, is sent instead.
    func finalResponseText(fallback: String) async -> String {
        guard turnBlocks.didPublishIntermediateRootResponse,
              let reporter = activeProgressReporter else {
            return fallback
        }
        let trailing = await reporter.pendingAgentResponseText()
        return trailing.isEmpty ? fallback : trailing
    }

    /// Marks the streaming root response as unsendable, when one is in
    /// flight: a reporter is retired or replaced in the middle of it.
    func suppressRootResponseBlockIfStreaming() {
        turnBlocks.suppressRootResponseIfStreaming()
    }

    /// Resets the root-response state at a turn boundary.
    func resetRootResponseBlock() {
        turnBlocks.resetRootResponse()
    }

    // MARK: - Reasoning

    /// Aggregates one reasoning delta of the block streaming now, unless the
    /// block is suppressed. Nothing is queued here: the block is sent whole
    /// once the event that closes it arrives (``closeThoughtBlock()``). The
    /// buffer is bounded just above the message limit, so a long block cannot
    /// grow unbounded and its cut is still seen.
    func appendThoughtDelta(_ delta: String) {
        turnBlocks.appendThought(delta)
    }

    /// Closes the reasoning block streaming now: assistant content, a tool
    /// call, an automatic `/goal` continuation, or the end of the turn
    /// followed it. The block is queued as one thinking message, before what
    /// closed it, when a reporter sends the turn and the block is not blank;
    /// a suppressed block ends here and the next one is sent again.
    func closeThoughtBlock() async {
        let thought = turnBlocks.takeThought()
        guard thought.nilIfBlank != nil, let reporter = activeProgressReporter else { return }
        await reporter.enqueue(.thought(thought))
    }

    /// Closes the reasoning block that assistant content follows. A block
    /// that is sent (not blank, with a reporter) is a boundary of the root
    /// response written before it: that response is published first, as an
    /// intermediate one (``publishRootResponseAtToolBoundary()``), so the
    /// chat receives it, then the thought, then the content that follows,
    /// in the order they were written. A tool call and an automatic `/goal`
    /// continuation already publish the response before they close the
    /// block; the end of the turn closes it without a boundary, and the
    /// response before it stays the final response.
    func closeThoughtBlockBeforeAssistantContent() async {
        if turnBlocks.pendingThought.nilIfBlank != nil, activeProgressReporter != nil {
            await publishRootResponseAtToolBoundary()
        }
        await closeThoughtBlock()
    }

    /// Forgets the reasoning block at a turn boundary.
    func resetThoughtBlock() {
        turnBlocks.resetThought()
    }

    // MARK: - Tool activity

    /// Shows a root tool call that started in the turn's activity message:
    /// its title (``ToolCallPresentation/toolTitle(for:)``), never its
    /// arguments. A call the terminal does not show in its tool blocks
    /// (``ToolRenderingPolicy/shouldSuppressToolRendering(for:)``) is not shown
    /// either; nothing is shown without a reporter.
    func presentToolCallActivityStarted(_ toolCall: DirectAgentToolCall) async {
        guard !ToolRenderingPolicy.shouldSuppressToolRendering(for: toolCall.name),
              let reporter = activeProgressReporter else { return }
        await reporter.toolCallDidStart(
            id: toolCall.id, title: ToolCallPresentation.toolTitle(for: toolCall)
        )
    }

    /// Writes the outcome of a root tool call in its activity row: ✅, or ❌
    /// when it failed as the terminal judges it
    /// (``ToolRenderingPolicy/toolResultIsFailure(for:result:)``), with the time the
    /// tool executor measured for it (``DirectAgentToolResult/elapsed``),
    /// when the result has one. Its result is never sent.
    func presentToolCallActivityCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        guard !ToolRenderingPolicy.shouldSuppressToolRendering(for: toolCall.name),
              let reporter = activeProgressReporter else { return }
        await reporter.toolCallDidComplete(
            id: toolCall.id,
            failed: ToolRenderingPolicy.toolResultIsFailure(for: toolCall, result: result),
            elapsed: result.elapsed
        )
    }

    // MARK: - Overviews

    /// Queues an overview section the controller published for the turn in
    /// progress: a task graph (`.tasks`), a sub-agent response
    /// (`.subAgentResponse`), or the sub-agent status (`.subAgentStatus`).
    ///
    /// The section is dropped when no reporter sends the turn: outside a
    /// turn there is no remote audience. A task graph whose
    /// `taskGraphSignature` was already sent during the turn is dropped too,
    /// so republished identical content does not repeat in the chat.
    /// Sections go through the reporter's queue, so they cannot overtake the
    /// tool activity that produced them.
    func enqueueOverview(
        _ payload: TerminalTelegramTurnPayload,
        taskGraphSignature: String? = nil
    ) async {
        guard activeProgressReporter != nil else {
            return
        }
        if let taskGraphSignature {
            guard publishedTaskGraphOverviewSignature != taskGraphSignature else {
                return
            }
            publishedTaskGraphOverviewSignature = taskGraphSignature
        }
        await activeProgressReporter?.enqueue(payload)
    }

    // MARK: - Reporter

    /// The ordered reporter of a turn on `lease`, or `nil` when the turn does
    /// not reach the linked chat or the link has no wire lifecycle. Every
    /// send and every edit, the progress card's, the activity and status
    /// messages', and the thinking messages' included, is fenced by the route
    /// lease and the lifecycle epoch, and validated again before it leaves.
    func makeTurnProgressReporter(
        for lease: TerminalTelegramRouteLease
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let chatID = outgoingChatID(for: lease),
              let lifecycleEpoch = controlState.wireLifecycleEpoch else {
            return nil
        }

        let service = controlService
        let wireFence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [router] lease in
                try await router.validate(lease)
            }
        )
        let topicID = lease.effectiveMessageThreadID
        let cards = TerminalTelegramProgressCardLedger(
            chatID: chatID,
            send: { [weak self] text, chatID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                return try await service.sendPlainMessageWithReceipt(
                    text, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            editText: { [weak self] text, chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.editMessageText(
                    text, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            editMarkup: { [weak self] markup, chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.editMessageReplyMarkup(
                    markup, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            delete: { [weak self] chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.deleteMessage(
                    chatID: chatID, messageID: messageID, fence: wireFence
                )
            }
        )
        let activity = TerminalTelegramTurnActivityWire(
            sendPlainMessage: { [weak self] text, chatID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                return try await service.sendPlainMessageWithReceipt(
                    text, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            editPlainMessage: { [weak self] text, chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.editMessageText(
                    text, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            sendThought: { [weak self] thought, chatID in
                guard let self, await self.validateLease(lease) else { return false }
                return await self.sendThoughtMessage(
                    thought, to: chatID, topicID: topicID, fence: wireFence
                )
            }
        )
        return TerminalTelegramTurnProgressReporter(
            chatID: chatID,
            sendMessage: { [weak self] message, chatID in
                guard let self, await self.validateLease(lease) else { return false }
                return await self.sendProgressMessage(
                    message, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            sendDraft: { [weak self] text, chatID, draftID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.sendRichMessageDraftWithFallback(
                    text, to: chatID, draftID: draftID, canStop: true, fence: wireFence
                )
            },
            progressCards: cards,
            activityWire: activity,
            wireFence: wireFence,
            waitForWireQuiescence: { fence in
                await service.waitForWireQuiescence(fence: fence)
            }
        )
    }

    /// Sends one reporter message as a rich message, reporting whether it
    /// was delivered. Failures are silent: the reporter owns the outcome.
    @discardableResult
    private func sendProgressMessage(
        _ message: String, to chatID: Int64, topicID: Int? = nil,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        guard controlState.isActive else {
            return false
        }
        do {
            _ = try await controlService.sendRichMessageWithFallback(
                message, to: chatID, topicID: topicID, fence: fence
            )
            return true
        } catch {
            return false
        }
    }

    /// Sends one reasoning block as a thinking message, reporting whether it
    /// was delivered. Failures are silent, as for the other reporter
    /// messages.
    private func sendThoughtMessage(
        _ thought: String, to chatID: Int64, topicID: Int?,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        guard controlState.isActive else {
            return false
        }
        do {
            _ = try await controlService.sendThoughtMessage(
                thought, to: chatID, topicID: topicID, fence: fence
            )
            return true
        } catch {
            return false
        }
    }
}
