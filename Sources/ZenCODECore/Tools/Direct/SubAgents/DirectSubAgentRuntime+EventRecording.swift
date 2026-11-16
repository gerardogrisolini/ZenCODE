//
//  DirectSubAgentRuntime+EventRecording.swift
//  ZenCODE
//
//  Projection of streamed agent events onto the agent record, the streamed-
//  thought paragraph helpers, and the recording of a completed turn.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    public func recordEvent(
        _ event: DirectAgentEvent,
        agentID: String
    ) async {
        if case let .metrics(metrics) = event, metrics.isLiveProgress {
            // The overview does not render throughput: a live update must not
            // touch the agent or bump its activity timestamps.
            return
        }
        if case .toolCallPreview = event {
            // A fragment of a call still being written is live presentation
            // only, and arrives at the pace of the stream: like a live
            // metrics update it must not touch the agent or bump its activity
            // timestamps.
            return
        }

        // Nothing is recorded, and no lifecycle is forwarded, for an agent
        // that is gone or closed. `apply` reads nothing of the runtime, so the
        // record is mutated in place and the streamed buffers grow without
        // being copied first.
        let recorded = mutateAgentInPlace(agentID, where: { $0.status != .closed }) {
            Self.apply(event, to: &$0)
        }
        if let delegatedToolEvent = recorded ?? nil,
           let subAgentToolEventHandler {
            await subAgentToolEventHandler(delegatedToolEvent)
        }
    }

    /// Projects `event` onto the record of a live agent and returns the tool
    /// lifecycle to forward to the presentation sink, if any. Pure over the
    /// record: it reads nothing of the runtime.
    private static func apply(
        _ event: DirectAgentEvent,
        to agent: inout AgentRecord
    ) -> DirectSubAgentToolEvent? {
        var delegatedToolEvent: DirectSubAgentToolEvent?
        switch event {
        case .status, .diagnostic:
            // Backend status and diagnostic events are not model-authored chat
            // updates. Keeping them out of the overview prevents incidental
            // transport chatter from republishing the whole sub-agent section.
            break
        case let .thought(delta):
            // Reasoning arrives incrementally. Keep only the paragraph in
            // progress: each paragraph update replaces the overview's single
            // rewrite slot, rather than appending a growing private transcript.
            // The activity text is the bare paragraph and the kind marks it as
            // reasoning, so presentation never has to recognize a marker
            // prefix. A nil paragraph (nothing streamed yet, or the previous
            // paragraph just ended) leaves the thinking placeholder visible.
            agent.currentActivityKind = .thinking
            agent.currentActivity = Self.latestThoughtParagraph(
                appending: delta,
                to: &agent.pendingThoughtParagraph
            )
            // The live detail shows the whole reasoning of the phase growing,
            // not only its latest paragraph.
            agent.currentThought = Self.accumulatedThought(
                appending: delta,
                to: &agent.pendingThought
            )
            agent.currentToolName = nil
            agent.currentToolTarget = nil
            agent.currentToolIsRunning = false
            agent.latestContentPreview = nil
        case let .modelLoaded(modelID):
            agent.modelID = modelID.nilIfBlank ?? agent.modelID
        case let .content(delta):
            // A visible answer starts a new model phase; never let a later
            // thought delta continue the paragraph that preceded it.
            agent.pendingThoughtParagraph = nil
            // The reasoning stays visible while the message streams, as the
            // paragraph does; a later thought delta starts a new phase.
            agent.pendingThought = nil
            // Assistant content is also streamed as deltas. Buffer it without
            // touching snapshot-visible fields; it becomes visible only when a
            // tool boundary proves that the model's message is complete, or in
            // `recordCompletion` as the final response.
            if agent.pendingContentBuffer == nil {
                agent.pendingContentBuffer = delta
            } else {
                agent.pendingContentBuffer!.append(delta)
            }
        case let .toolCallStarted(toolCall):
            agent.pendingThoughtParagraph = nil
            // The backend recorded the message, its reasoning included, before
            // the call started: the transcript shows it from now on.
            agent.currentThought = nil
            agent.pendingThought = nil
            agent.currentActivity = Self.takeCompletedContent(
                from: &agent.pendingContentBuffer
            )
            agent.currentActivityKind = agent.currentActivity == nil ? nil : .content
            if agent.currentActivity != nil {
                agent.currentActivityRevision &+= 1
            }
            agent.currentToolName = toolCall.name
            agent.currentToolTarget = ToolCallPresentation.displayToolTarget(for: toolCall)
            agent.currentToolIsRunning = true
            agent.latestContentPreview = nil
            delegatedToolEvent = DirectSubAgentToolEvent(
                agentID: agent.id,
                agentName: agent.name,
                toolCall: toolCall,
                lifecycle: .started,
                rootSessionID: agent.rootSessionID
            )
        case let .toolCallCompleted(toolCall, result):
            // Keep the compatibility snapshot projection until the next model
            // state. Terminal presentation receives the lossless event below and
            // does not reconstruct a separate tool row from these fields. Only
            // `currentToolIsRunning` turns off: the name and the target name
            // the call that just completed, not one that runs.
            agent.currentToolName = toolCall.name
            agent.currentToolTarget = ToolCallPresentation.displayToolTarget(for: toolCall)
            agent.currentToolIsRunning = false
            // The call's time for the transcript, as the tool executor
            // measured it (``DirectAgentToolResult/elapsed``). A call without
            // an id cannot be matched to its row, and a result the executor
            // did not produce has no time: nothing is recorded.
            if !toolCall.id.isEmpty, let elapsed = result.elapsed {
                agent.toolCallDurations.record(elapsed, forCallID: toolCall.id)
            }
            delegatedToolEvent = DirectSubAgentToolEvent(
                agentID: agent.id,
                agentName: agent.name,
                toolCall: toolCall,
                lifecycle: .completed(result),
                rootSessionID: agent.rootSessionID
            )
        case let .sessionSnapshot(snapshot):
            agent.modelID = snapshot.modelID?.nilIfBlank ?? agent.modelID
        case let .metrics(metrics):
            // Providers emit partial updates (prefill first, generation later),
            // so fold them with the shared semantics instead of overwriting.
            // The first event of a new turn replaces the previous turn's
            // counters rather than accumulating on top of them.
            let current = agent.shouldReplaceMetricsOnNextUpdate
                ? nil
                : agent.latestMetrics
            agent.shouldReplaceMetricsOnNextUpdate = false
            agent.latestMetrics = DirectAgentGenerationMetrics.merging(
                current: current,
                update: metrics
            )
        case .contextWindow,
             .subscriptionUsage,
             .toolCallPreview,
             .turnEnded:
            break
        }

        agent.latestEventAt = .now
        agent.updatedAt = .now
        return delegatedToolEvent
    }

    /// Reduces the reasoning stream to the paragraph currently being written.
    ///
    /// The result depends only on the concatenation of every delta received so
    /// far, never on where the transport split it: the unfinished tail is kept
    /// in `buffer`, and a trailing CR is preserved verbatim because it may be
    /// the first half of a CRLF whose LF arrives in the next delta. Normalizing
    /// that CR eagerly would turn one line ending into two and fabricate a
    /// paragraph boundary. A delta that completes a paragraph (for example the
    /// single delta "A\n\n") leaves an empty tail and returns nil, exactly as
    /// the same text split across two deltas does.
    ///
    /// `buffer` holds the normalized tail, so each delta normalizes only
    /// itself and is scanned once for paragraph boundaries; the tail grows in
    /// place while no boundary arrives.
    static func latestThoughtParagraph(
        appending delta: String,
        to buffer: inout String?
    ) -> String? {
        // Take the buffer out so the tail is uniquely referenced and grows in
        // place.
        var tail = buffer ?? ""
        buffer = nil
        var chunk = delta
        if tail.utf8.last == ThoughtStreamByte.carriageReturn {
            tail.removeLast()
            chunk = "\r" + chunk
        }
        let endsWithUnresolvedCR = chunk.utf8.last == ThoughtStreamByte.carriageReturn
        if endsWithUnresolvedCR {
            chunk.removeLast()
        }
        let normalized = normalizedThoughtLineEndings(chunk)
        // A blank line (optionally padded with horizontal whitespace) ends a
        // paragraph. Only the text after the last boundary is still in
        // progress. The tail holds no complete boundary, so a new one ends in
        // this delta, possibly opened by a line the tail left open.
        if let paragraphStart = lastParagraphStart(
            in: normalized,
            afterOpenLine: endsWithOpenLine(tail)
        ) {
            tail = String(normalized[paragraphStart...])
        } else {
            tail += normalized
        }
        let paragraph = trimmedNonBlankThought(tail)
        if endsWithUnresolvedCR {
            tail.append("\r")
        }
        buffer = tail
        return paragraph
    }

    /// Accumulates the reasoning stream of one thinking phase, every
    /// paragraph included.
    ///
    /// As in ``latestThoughtParagraph(appending:to:)``, the result depends
    /// only on the concatenation of every delta received so far, never on
    /// where the transport split it: CRLF and lone CR become LF, and a
    /// trailing CR is kept verbatim in `buffer`, because it may be the first
    /// half of a CRLF whose LF arrives in the next delta. `buffer` holds the
    /// normalized text, so each delta normalizes only itself. Returns the
    /// text trimmed of leading and trailing whitespace, or nil while it is
    /// blank.
    static func accumulatedThought(
        appending delta: String,
        to buffer: inout String?
    ) -> String? {
        // Take the buffer out so the text is uniquely referenced and grows in
        // place.
        var accumulated = buffer ?? ""
        buffer = nil
        var chunk = delta
        if accumulated.utf8.last == ThoughtStreamByte.carriageReturn {
            accumulated.removeLast()
            chunk = "\r" + chunk
        }
        let endsWithUnresolvedCR = chunk.utf8.last == ThoughtStreamByte.carriageReturn
        if endsWithUnresolvedCR {
            chunk.removeLast()
        }
        accumulated += normalizedThoughtLineEndings(chunk)
        let thought = trimmedNonBlankThought(accumulated)
        if endsWithUnresolvedCR {
            accumulated.append("\r")
        }
        buffer = accumulated
        return thought
    }

    /// The bytes the thought reducers scan for. CR, LF, space and tab are
    /// ASCII, and UTF-8 never uses an ASCII byte inside a multi-byte scalar,
    /// so a byte scan finds exactly the scalars. A text whose last byte is CR
    /// ends with a lone CR character: a CR always starts its own grapheme,
    /// and only an LF after it could join it.
    private enum ThoughtStreamByte {
        static let carriageReturn = UInt8(ascii: "\r")
        static let lineFeed = UInt8(ascii: "\n")
        static let space = UInt8(ascii: " ")
        static let tab = UInt8(ascii: "\t")
    }

    /// CRLF and lone CR become LF, as the reducers have always normalized a
    /// whole text. A chunk without CR is returned as it is.
    private static func normalizedThoughtLineEndings(_ chunk: String) -> String {
        guard chunk.utf8.contains(ThoughtStreamByte.carriageReturn) else {
            return chunk
        }
        return chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// The text trimmed of leading and trailing whitespace, or nil while it
    /// is blank. Trimming is idempotent, so one pass gives what
    /// `trimmingCharacters(in:)` followed by `nilIfBlank` gives.
    private static func trimmedNonBlankThought(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when `text` ends with a line feed followed only by spaces and
    /// tabs: that line feed opens a paragraph boundary that the next line
    /// feed closes.
    private static func endsWithOpenLine(_ text: String) -> Bool {
        for byte in text.utf8.reversed() {
            switch byte {
            case ThoughtStreamByte.space, ThoughtStreamByte.tab:
                continue
            case ThoughtStreamByte.lineFeed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Where the text after the last paragraph boundary of `text` starts, or
    /// nil when `text` closes no boundary. A boundary is a line feed, any
    /// spaces and tabs, then a line feed, matched left to right without
    /// overlap, as repeated `\n[ \t]*\n` searches from the end of the
    /// previous match find them. `afterOpenLine` tells that the text before
    /// `text` left a boundary open (see ``endsWithOpenLine(_:)``).
    private static func lastParagraphStart(
        in text: String,
        afterOpenLine: Bool
    ) -> String.Index? {
        var isOpen = afterOpenLine
        var paragraphStart: String.Index?
        let bytes = text.utf8
        var index = bytes.startIndex
        while index != bytes.endIndex {
            let byte = bytes[index]
            bytes.formIndex(after: &index)
            switch byte {
            case ThoughtStreamByte.lineFeed:
                if isOpen {
                    // A line feed always ends its grapheme, so this index
                    // is a character boundary of `text`.
                    paragraphStart = index
                    isOpen = false
                } else {
                    isOpen = true
                }
            case ThoughtStreamByte.space, ThoughtStreamByte.tab:
                break
            default:
                isOpen = false
            }
        }
        return paragraphStart
    }

    private static func takeCompletedContent(
        from buffer: inout String?
    ) -> String? {
        defer { buffer = nil }
        return buffer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    func recordCompletion(
        _ response: DirectAgentResponse,
        agentID: String,
        authorization: TurnAuthorization
    ) async {
        // The turn is over, so the inline-delivery window closed: anything the
        // drain left in the mailbox has to be re-offered now. Deferred so every
        // exit — standby, task completion, orchestrator failure — re-arms once,
        // and harmless when the loop immediately starts the next queued prompt:
        // the drain simply observes `.running` again and holds back.
        defer { rearmSharedChatDrain(for: agentID) }
        let trimmedOutput = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let agent = mutateAgent(agentID, where: { $0.status != .closed }, { agent in
            let finalContent = Self.takeCompletedContent(
                from: &agent.pendingContentBuffer
            )
            agent.latestOutput = trimmedOutput
            agent.latestOutputRevision &+= 1
            agent.completedExecutionRevision = agent.executionRevision
            agent.latestError = nil
            agent.modelID = response.modelID.nilIfBlank ?? agent.modelID
            // The turn is over: drop the visible activity together with the private
            // thinking/content buffers so no partial paragraph leaks into the next
            // turn.
            agent.resetActivityState()
            // `response.text` may contain commentary from every prior tool round.
            // Preserve it for agent.get/wait, but let the TUI present only the final
            // completed content block when the backend emitted one.
            agent.latestContentPreview = finalContent
            agent.updatedAt = .now
            return agent
        }) else {
            return
        }

        // A direct operator message is a normal agent conversation, not a
        // coordinator turn. Models are instructed to answer with
        // `agent.message`, but a provider may still finish with ordinary output.
        // Preserve direct delivery in that case; a successful explicit chat
        // send marks the turn and suppresses this fallback.
        if agent.currentTurnRepliesToOperator,
           !agent.currentTurnSentOperatorMessage,
           !trimmedOutput.isEmpty {
            if (try? await sharedChat.send(
                roomID: agent.rootSessionID,
                senderID: agentID,
                destination: .operator,
                text: trimmedOutput
            )) != nil {
                sharedChatMessageAvailableHandler?(agent.rootSessionID)
            }
        }

        switch authorization {
        case .standby:
            // Standby turn: do NOT interact with the task orchestrator. The
            // attempt is already completed; this is a conversational follow-up.
            await recordStandbyTurnCompletion(agentID: agentID)
            return

        case .attempt:
            // Normal tracked turn: set status and interact with the orchestrator.
            break

        case .denied:
            // Unreachable: `runAgentLoop` discards the turn and returns before
            // any prompt is sent when the authorization is `.denied`, so no
            // response can ever be recorded for it. Handled as a normal turn
            // only to keep the switch exhaustive without a fatal error.
            break
        }

        // Re-read the agent under a distinct binding: the record was written
        // above and the `.standby` branch may have changed it.
        guard let completion = mutateAgent(agentID, { updatedAgent in
            updatedAgent.status = updatedAgent.pendingPrompts.isEmpty ? .idle : .queued
            let releasedReservation = updatedAgent.pendingPrompts.isEmpty
                ? takeTasklessDelegationReservation(from: &updatedAgent)
                : nil
            if releasedReservation != nil {
                // Keep the agent pending until the cross-actor lease release has
                // completed, so graph activation cannot race an apparently idle
                // taskless agent.
                updatedAgent.status = .running
            }
            return (agent: updatedAgent, releasedReservation: releasedReservation)
        }) else {
            return
        }
        let updatedAgent = completion.agent
        let releasedReservation = completion.releasedReservation

        if let taskID = updatedAgent.taskID,
           let attemptID = updatedAgent.taskAttemptID,
           let taskOrchestrator {
            do {
                let didComplete = try await taskOrchestrator.completeAttempt(
                    sessionID: updatedAgent.rootSessionID,
                    taskID: taskID,
                    attemptID: attemptID,
                    output: updatedAgent.latestOutput,
                    requiresValidation: false
                )
                if didComplete {
                    await concludeTaskBoundTurn(agentID: agentID)
                } else if let currentAgent = agents[agentID],
                          !(await hasActiveTaskAttempt(currentAgent)) {
                    discardInactiveTaskAttemptWork(for: agentID)
                }
            } catch {
                finishTaskBoundAttemptWork(
                    for: agentID,
                    error: "Unable to complete task attempt: \(error.localizedDescription)"
                )
            }
        }
        await releaseTasklessDelegationReservation(releasedReservation)
    }
}
