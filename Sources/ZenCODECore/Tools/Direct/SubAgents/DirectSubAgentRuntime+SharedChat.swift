//
//  DirectSubAgentRuntime+SharedChat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    /// Delivers an `agent.message` request through the shared transient bus.
    /// The sender is derived from the executor that issued the tool call, not
    /// from a mutable request field, so child agents cannot impersonate peers.
    func messageSharedChat(
        arguments: [String: JSONValue],
        rootSessionID: String,
        parentAllowedToolNames: Set<String>?,
        senderIDOverride: String? = nil
    ) async throws -> String {
        // Do not trim a model-provided String before the shared-chat actor has
        // applied its scalar/UTF-8 bound. `nilIfBlank` materialises a trimmed
        // copy and a single combining grapheme can be arbitrarily large.
        guard let text = Self.firstString(["message", "prompt", "input"], in: arguments) else {
            throw DirectSubAgentRuntimeError.missingArgument("message")
        }
        let roomID = AgentSharedChat.resolvedRoomID(
            sharedChatRootSessionID: sharedChatRootSessionID,
            sessionID: rootSessionID
        )
        let effectiveSenderID = senderIDOverride ?? sharedChatSenderID
        let awaitsReply = Self.firstBool(["awaitReply", "await_reply"], in: arguments) ?? false
        // Validate before sending so a rejected request never delivers.
        if awaitsReply, effectiveSenderID == nil {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "awaitReply is only available to delegated sub-agents; the coordinator "
                    + "receives replies through agent.wait and inline live-chat delivery"
            )
        }
        let requestedReplyTimeout = Self.firstNumber(
            ["replyTimeoutSeconds", "reply_timeout_seconds"],
            in: arguments
        ) ?? Self.defaultSharedChatReplyTimeoutSeconds
        // Clamp before converting: a finite value such as 1e100 would trap in
        // `Int(_)`, while the bounded value is always representable.
        let replyTimeoutSeconds = Int(min(
            max(requestedReplyTimeout, 1),
            Self.maximumSharedChatReplyTimeoutSeconds
        ))
        if effectiveSenderID == nil {
            _ = try await sharedChat.registerCoordinator(roomID: roomID)
        }
        let senderID = AgentSharedChat.mailboxParticipantID(
            senderID: effectiveSenderID,
            roomID: roomID
        )

        let destination = try sharedChatDestination(
            arguments: arguments,
            senderIDOverride: effectiveSenderID
        )
        let boundedText = AgentSharedChat.boundedMessageText(text)
        // Coordinator→direct follow-up: authorise the resolved agent targets up
        // front. The actual prompt queuing is handled by each recipient's
        // mailbox drain (its shared-chat wake-up callback), so there is a single
        // delivery channel and no inline/queued split: every recipient — idle,
        // running or standby — receives the message as a serial turn in its own
        // work loop, independent of any future tool call.
        if effectiveSenderID == nil, case .direct(let identifiers) = destination {
            var seenAgentIDs = Set<String>()
            let requestedAgentIDs = identifiers
                .compactMap(agentID(matching:))
                .filter { seenAgentIDs.insert($0).inserted }
            if !requestedAgentIDs.isEmpty {
                try await validateOpenMessageTargets(requestedAgentIDs)
            }
        }
        let delivery = try await sharedChat.send(
            roomID: roomID,
            senderID: senderID,
            destination: destination,
            text: boundedText
        )
        sharedChatMessageAvailableHandler?(roomID)
        if let effectiveSenderID,
           delivery.recipients.contains(where: { $0.kind == .operator }),
           var sender = agents[effectiveSenderID] {
            sender.currentTurnSentOperatorMessage = true
            agents[effectiveSenderID] = sender
        }
        // A display name is not an identity: any agent may be named
        // "operator" or "coordinator". Model-facing delivery output therefore
        // always includes the actor-owned kind and stable identifier, with the
        // display name only as an explicitly non-authoritative field.
        let recipients = AgentSharedChat.deliveryRecipientSummary(for: delivery.recipients)
        let deliveredText = "Delivered live message to \(recipients)."
        guard awaitsReply, let effectiveSenderID else {
            return deliveredText
        }
        let outcome = await awaitSharedChatReply(
            senderID: effectiveSenderID,
            roomID: roomID,
            timeoutSeconds: replyTimeoutSeconds
        )
        return deliveredText + "\n\n" + outcome
    }

    static let defaultSharedChatReplyTimeoutSeconds: Double = 600
    static let maximumSharedChatReplyTimeoutSeconds: Double = 900
    static let sharedChatReplyPollInterval: Duration = .milliseconds(500)

    /// Keeps a delegated agent's `agent.message` tool call open until a live
    /// reply reaches its mailbox, so the agent's turn (a task attempt or a
    /// standby follow-up) stays open while it waits instead of ending.
    ///
    /// Draining here is the single destructive owner of the sender's mailbox:
    /// the sender is `.running` for the whole tool call, so
    /// ``drainSharedChatMailbox(for:)`` leaves the mailbox untouched, and the
    /// executor's inline delivery only runs after this result is returned.
    /// Messages left beyond one batch stay queued for that inline delivery.
    ///
    /// Liveness is evaluated once per iteration by
    /// ``sharedChatReplyLiveness(senderID:)``, whose final `.running` check is
    /// synchronous and is followed directly by the drain: no other await sits
    /// between them, so the mailbox is never drained for an agent whose turn
    /// was already finished (for example set `.idle` by
    /// `finishTaskBoundAttemptWork`).
    ///
    /// The wait never consumes standby turns: the budget is charged once, when
    /// the standby turn itself completes.
    func awaitSharedChatReply(
        senderID: String,
        roomID: String,
        timeoutSeconds: Int
    ) async -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeoutSeconds)
        while true {
            if Task.isCancelled {
                return Self.sharedChatReplyCancelledText
            }
            switch await sharedChatReplyLiveness(senderID: senderID) {
            case .live:
                break
            case .senderStopped:
                return Self.sharedChatReplySenderStoppedText
            case .attemptClosed:
                return Self.sharedChatReplyAttemptInactiveText
            case .standbyEnded:
                return Self.sharedChatReplyStandbyEndedText
            }
            // Keep this drain immediately after the liveness check above.
            let messages = await sharedChat.drain(
                roomID: roomID,
                participantID: senderID,
                limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
            )
            let replies = messages.filter { $0.sender.id != senderID }
            if !replies.isEmpty {
                return Self.awaitedSharedChatReplyBlock(replies)
            }
            let now = clock.now
            guard now < deadline else {
                return Self.sharedChatReplyTimeoutText(seconds: timeoutSeconds)
            }
            do {
                try await Task.sleep(
                    for: min(Self.sharedChatReplyPollInterval, now.duration(to: deadline))
                )
            } catch {
                // Cancellation during the sleep only: nothing was drained in
                // this iteration, so pending messages stay in the mailbox for
                // the end-of-turn drain. A drain that already returned replies
                // is handed back to the turn above and never reaches this path.
                return Self.sharedChatReplyCancelledText
            }
        }
    }

    enum SharedChatReplyLiveness: Equatable {
        case live
        /// The agent is closed or failed.
        case senderStopped
        /// The task attempt is no longer active and the agent is not on a
        /// standby turn, or its turn already finished.
        case attemptClosed
        /// A standby turn whose standby eligibility ended (terminal graph,
        /// superseded attempt, pending release, failed/cancelled task, or
        /// exhausted budget).
        case standbyEnded
    }

    /// Single per-iteration liveness rule for an `awaitReply` wait: the sender
    /// is not closed/failed, its turn is still `.running`, and it either owns
    /// an active task attempt or is a standby resident that is still standby
    /// eligible. The standby idle timeout is ignored: an in-flight turn is not
    /// idle, the reaper never touches pending agents, and `standbySince` is
    /// refreshed when the standby turn completes.
    ///
    /// Agent state is re-read after every await. The returned `.live` is
    /// decided by a final synchronous read, so callers can drain right after.
    func sharedChatReplyLiveness(senderID: String) async -> SharedChatReplyLiveness {
        guard let sender = agents[senderID], Self.canAwaitSharedChatReply(sender) else {
            return .senderStopped
        }
        let isStandbyTurn: Bool
        if await hasActiveTaskAttempt(sender) {
            isStandbyTurn = false
        } else if let resident = agents[senderID], isStandbyResident(resident) {
            guard await isStandbyEligible(resident, ignoringIdleTimeout: true) else {
                return .standbyEnded
            }
            isStandbyTurn = true
        } else {
            return .attemptClosed
        }
        guard let current = agents[senderID], Self.canAwaitSharedChatReply(current) else {
            return .senderStopped
        }
        guard current.status == .running else {
            return isStandbyTurn ? .standbyEnded : .attemptClosed
        }
        if isStandbyTurn, current.pendingRelease || current.supersededByAttemptID != nil {
            return .standbyEnded
        }
        return .live
    }

    private static func canAwaitSharedChatReply(_ agent: AgentRecord) -> Bool {
        agent.status != .closed && agent.status != .failed
    }

    static let sharedChatReplyCancelledText =
        "Stopped waiting for a live reply: the wait was cancelled."
    static let sharedChatReplySenderStoppedText =
        "Stopped waiting for a live reply: this agent is closed or has failed."
    static let sharedChatReplyAttemptInactiveText =
        "Stopped waiting for a live reply: this task attempt closed and standby is not "
            + "available. Do not resume implementation; end your turn and report what is "
            + "still open."
    static let sharedChatReplyStandbyEndedText =
        "Stopped waiting for a live reply: this agent's standby ended (the task graph may be "
            + "terminal, the attempt superseded or released, or the standby budget exhausted). "
            + "End your turn; new work needs a new task attempt."

    static func sharedChatReplyTimeoutText(seconds: Int) -> String {
        "No live reply arrived within \(seconds) seconds. Do not proceed on assumptions: "
            + "call agent.message with awaitReply again to send a short reminder or, "
            + "if the blocker persists, end your attempt and report it as a blocker."
    }

    /// Public bridge used exclusively by the terminal input surface. It gives
    /// human input its own trusted transcript identity instead of conflating it
    /// with the coordinator LLM or creating a mailbox-owning participant.
    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String,
        messageID: UUID = UUID()
    ) async throws -> AgentSharedChat.Delivery {
        let roomID = AgentSharedChat.resolvedRoomID(
            sharedChatRootSessionID: sharedChatRootSessionID,
            sessionID: rootSessionID
        )
        _ = try await sharedChat.registerCoordinator(roomID: roomID)
        let delivery = try await sharedChat.sendFromOperator(
            roomID: roomID,
            destination: destination,
            text: text,
            messageID: messageID
        )
        // Operator-originated terminal messages use the same room-wide wake-up
        // as agent.message deliveries. Without it the transcript can render in
        // the TUI while the coordinator mailbox remains asleep until the safety
        // poll, so an @coordinator message appears sent but starts no turn.
        sharedChatMessageAvailableHandler?(roomID)
        return delivery
    }

    public func updateSharedChatMessageAvailableHandler(
        _ handler: (@Sendable (String) -> Void)?
    ) {
        sharedChatMessageAvailableHandler = handler
    }

    // MARK: - Broadcast classification

    // Removed: there is no longer a broadcast classification path. Every
    // participant the bus includes in a delivery receives its serialized prompt
    // through the mailbox/work loop, or is excluded from the delivery before
    // `send`. Standby residents are therefore no longer filtered after
    // `sharedChat.send` has already declared a message delivered.

    /// Restarts the mailbox drain of one agent after a turn ends or the work
    /// loop exits.
    ///
    /// The mailbox is drained even while a turn is running. This re-arm is the
    /// safety net that guarantees no message is stranded: a wake-up callback that
    /// raced the status transition is delivered as a queued prompt the instant
    /// the agent is free to consume it again.
    ///
    /// It is safe to call this more than once per turn: the drain is
    /// single-flight per agent (``AgentRecord/isDrainingSharedChatMailbox``),
    /// returns immediately on an empty mailbox, and never re-arms itself, so no
    /// pair of re-arms can build a drain loop.
    func rearmSharedChatDrain(for agentID: String) {
        let runtime = self
        Task(name: "ZenCODE.shared-chat.agent-drain-rearm") {
            await runtime.drainSharedChatMailbox(for: agentID)
        }
    }

    public func sharedChatParticipants(
        rootSessionID: String
    ) async -> [AgentSharedChat.Participant] {
        await sharedChat.participants(roomID: sharedChatRootSessionID ?? rootSessionID)
    }

    /// Non-blocking mailbox drain for the coordinator. The TUI owns deciding
    /// whether the result starts a turn now or joins its queued prompt list.
    public func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        let roomID = AgentSharedChat.resolvedRoomID(
            sharedChatRootSessionID: sharedChatRootSessionID,
            sessionID: rootSessionID
        )
        return await sharedChat.drain(
            roomID: roomID,
            participantID: AgentSharedChat.coordinatorID(for: roomID),
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
    }

    /// Read-only access to the full bounded room transcript. Unlike
    /// ``drainCoordinatorSharedChatMessages(rootSessionID:)`` this never removes
    /// messages from any mailbox: it returns every retained message so the
    /// coordinator can display agent-to-agent traffic that never enters its own
    /// mailbox.
    public func sharedChatTranscriptMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] {
        let roomID = AgentSharedChat.resolvedRoomID(
            sharedChatRootSessionID: sharedChatRootSessionID,
            sessionID: rootSessionID
        )
        return await sharedChat.messages(roomID: roomID)
    }

    func registerSharedChatAgent(_ agent: AgentRecord) async throws {
        let runtime = self
        _ = try await sharedChat.registerAgent(
            id: agent.id,
            name: agent.name,
            roomID: agent.rootSessionID,
            onMessageAvailable: {
                Task(name: "ZenCODE.shared-chat.agent-drain") {
                    await runtime.drainSharedChatMailbox(for: agent.id)
                }
            }
        )
    }

    /// Pulls the mailbox and uses the existing serialized work loop. `queuePrompt`
    /// starts an idle agent immediately, while a running agent simply receives a
    /// follow-up in FIFO order; no chat sender waits for model generation.
    ///
    /// Single-flight and backpressure are encoded here:
    /// * exactly one drain loop may be active per agent (``AgentRecord/isDrainingSharedChatMailbox``);
    /// * the pending-prompt queue is bounded by
    ///   ``DirectSubAgentRuntime/maximumPendingSharedChatPromptsPerAgent``, so a
    ///   fast producer cannot grow memory without limit. Undelivered messages
    ///   stay in the bounded mailbox and are drained when the queue has capacity
    ///   again (re-armed from ``nextWork(for:)`` when the agent goes idle).
    func drainSharedChatMailbox(for agentID: String) async {
        guard var agent = agents[agentID], agent.status != .closed else {
            return
        }
        // A running turn owns its mailbox through DirectToolExecutor. Leaving
        // the batch untouched lets the next tool result inject it immediately
        // into that same model turn. When no further tool call occurs, the work
        // loop's existing end-of-turn re-arm drains it into a queued prompt as
        // the lossless fallback.
        guard agent.status != .running else {
            return
        }
        guard !agent.isDrainingSharedChatMailbox else {
            return
        }
        agent.isDrainingSharedChatMailbox = true
        agents[agentID] = agent
        defer {
            if var current = agents[agentID] {
                current.isDrainingSharedChatMailbox = false
                agents[agentID] = current
            }
        }
        while true {
            // Re-check liveness on every iteration: the agent may have been
            // closed between two drain calls.
            guard let current = agents[agentID], current.status != .closed else { return }
            // Queueing the previous batch may already have started the agent.
            // Preserve any remaining mailbox entries for that active turn's
            // next tool boundary rather than creating a delayed second turn.
            guard current.status != .running else { return }
            let messages = await sharedChat.drain(
                roomID: agent.rootSessionID,
                participantID: agentID,
                limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
            )
            let deliverable = messages.filter { $0.sender.id != agentID }
            guard !deliverable.isEmpty else { return }
            // Backpressure: stop draining when the pending queue is full. The
            // mailbox retains the remaining messages; the drain is re-armed
            // from `nextWork` when the agent finishes a prompt and the queue
            // has capacity again.
            guard (agents[agentID]?.pendingPrompts.count ?? 0)
                    < Self.maximumPendingSharedChatPromptsPerAgent else {
                return
            }
            do {
                try queuePrompt(
                    Self.sharedChatPrompt(deliverable),
                    for: agentID,
                    repliesToOperator: deliverable.contains { $0.sender.kind == .operator }
                )
            } catch {
                guard var current = agents[agentID] else { return }
                current.latestError = "Unable to deliver shared-chat message: \(error.localizedDescription)"
                current.updatedAt = .now
                agents[agentID] = current
                return
            }
        }
    }

    func sharedChatDestination(
        arguments: [String: JSONValue],
        senderIDOverride: String? = nil
    ) throws -> AgentSharedChat.Destination {
        let explicitTarget = Self.firstString(
            ["to", "target", "destination", "recipient", "scope"],
            in: arguments
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let identifiers = Self.requestedAgentIdentifiers(from: arguments)

        switch explicitTarget {
        case nil, "", "direct":
            if !identifiers.isEmpty {
                return .direct(identifiers)
            }
            // Preserve the established coordinator ergonomics: an unspecified
            // message targets idle agents (or the single active one). Child
            // agents instead get a clear error rather than guessing a peer.
            if sharedChatSenderID == nil, senderIDOverride == nil {
                return .direct(try resolveMessageTargetIDs(arguments: arguments))
            }
            throw DirectSubAgentRuntimeError.missingArgument("id or to")
        case "operator":
            return .operator
        case "coordinator":
            return .coordinator
        case "peers", "peer":
            return .peers
        case "all", "broadcast":
            return .all
        default:
            throw DirectSubAgentRuntimeError.invalidArgument(
                "to must be direct, operator, coordinator, peers, or all"
            )
        }
    }

    /// Executes the root runtime's coordination surface on behalf of a child.
    /// The captured sender identifier supplies message identity, while list/get
    /// observe the parent's single agent graph instead of the child's empty one.
    func executeBorrowedSubAgentTool(
        senderID: String,
        rootSessionID: String,
        toolCall: AgentBorrowedToolCall
    ) async throws -> String {
        guard let data = toolCall.argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(
                  [String: JSONValue].self,
                  from: data
              ) else {
            throw DirectSubAgentRuntimeError.invalidArgument(
                "argumentsJSON must encode an object"
            )
        }
        let directToolCall = DirectAgentToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsObject: arguments.mapValues(\.jsonObject),
            argumentsJSON: toolCall.argumentsJSON
        )
        let request = Self.normalizedToolRequest(for: directToolCall)
        switch request.name {
        case "agent.list":
            return listAgents(arguments: request.arguments)
        case "agent.get":
            return getAgents(arguments: request.arguments)
        case "agent.message":
            return try await messageSharedChat(
                arguments: request.arguments,
                rootSessionID: rootSessionID,
                parentAllowedToolNames: nil,
                senderIDOverride: senderID
            )
        default:
            throw DirectSubAgentRuntimeError.unknownTool(toolCall.name)
        }
    }

    /// Prompt injected into a delegated agent for its inbound live messages.
    /// It uses the Core serializer, so a hostile sender name or message body
    /// cannot forge a second sender header or a fake operator instruction.
    static func sharedChatPrompt(_ messages: [AgentSharedChat.Message]) -> String {
        """
        [Live chat messages]
        \(AgentSharedChat.promptTranscript(for: messages))

        \(AgentSharedChat.promptTrustBoundaryNote)
        Reply to the sender through this chat using the `agent.message` tool: address another agent by its `id`/`name`, use `to: "operator"` to reply directly to the human operator, or use `to: "coordinator"` to reach only the coordinator. Your ordinary output does not reach this chat, so any reply to a chat message must be sent via `agent.message`. Then continue the current work when appropriate.
        """
    }

    /// Model-facing reply returned by `agent.message` with `awaitReply`. Every
    /// drained message counts as the reply, whoever sent it, so none is lost.
    static func awaitedSharedChatReplyBlock(
        _ messages: [AgentSharedChat.Message]
    ) -> String {
        """
        [Live chat reply received while you were waiting]
        \(AgentSharedChat.promptTranscript(for: messages))

        \(AgentSharedChat.promptTrustBoundaryNote)
        Act on this reply, then resume your assigned work. If this does not answer your question, call agent.message with awaitReply again.
        """
    }

    /// Model-facing delivery used when the coordinator is already inside a
    /// turn. The message is appended to the next tool result, so the model can
    /// reply immediately and then resume the work already in progress.
    static func inlineSharedChatDeliveryBlock(
        _ messages: [AgentSharedChat.Message]
    ) -> String {
        """
        [Live chat messages received while you were working]
        \(AgentSharedChat.promptTranscript(for: messages))

        \(AgentSharedChat.promptTrustBoundaryNote)
        These messages arrived during your current turn. Reply NOW through this chat using the `agent.message` tool: address a delegated agent by its `id`/`name`, use `to: "operator"` for the human operator, or use `to: "coordinator"` for the coordinator. Your ordinary output does not reach this chat, so a reply not sent via `agent.message` is never delivered. After replying, resume the work you were doing.
        """
    }
}
