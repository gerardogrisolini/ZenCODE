//
//  DirectSubAgentRuntime+SharedChat.swift
//  ZenCODE
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
        let roomID = sharedChatRootSessionID ?? rootSessionID.nilIfBlank ?? "default"
        let effectiveSenderID = senderIDOverride ?? sharedChatSenderID
        let senderID: String
        if let effectiveSenderID {
            senderID = effectiveSenderID
        } else {
            _ = try await sharedChat.registerCoordinator(roomID: roomID)
            senderID = AgentSharedChat.coordinatorID(for: roomID)
        }

        let destination = try sharedChatDestination(
            arguments: arguments,
            senderIDOverride: effectiveSenderID
        )
        // Keep the established reservation and workflow-attempt fence for a
        // coordinator's legacy direct follow-up, but apply the same message
        // bounds and transcript identity as the live bus route. The bus records
        // the delivery in the transient transcript with the coordinator's
        // qualified identity; the actual work (reservations, queuePrompt) still
        // goes through messageAgents.
        //
        // Recipients are split in two, because a message that only becomes
        // visible at the end of the turn is exactly the latency this route has
        // to avoid:
        // * a recipient with a turn in flight keeps its mailbox untouched. Its
        //   own executor delivers the message inline at the next tool boundary,
        //   so it is neither drained nor queued here.
        // * every other recipient keeps the previous behaviour: its mailbox is
        //   drained right after the bus send so the wake-up callback does not
        //   duplicate the prompt that messageAgents queues.
        if effectiveSenderID == nil,
           case .direct(let identifiers) = destination {
            let boundedText = AgentSharedChat.boundedMessageText(text)
            var transcriptDelivery: AgentSharedChat.Delivery?
            do {
                transcriptDelivery = try await sharedChat.send(
                    roomID: roomID,
                    senderID: senderID,
                    destination: destination,
                    text: boundedText
                )
            } catch {
                // Best-effort transcript recording: the agent may not yet be
                // registered in the bus. The message is still queued below.
            }
            // Inline delivery requires both halves: the bus actually accepted
            // the message for that recipient (so it is sitting in its mailbox)
            // and the agent has a turn in flight (so a tool boundary is still
            // coming). Anything else falls back to the queued route, which
            // cannot lose a message.
            let deliveredRecipientIDs = Set(transcriptDelivery?.recipients.map(\.id) ?? [])
            var seenAgentIDs = Set<String>()
            let requestedAgentIDs = identifiers
                .compactMap(agentID(matching:))
                .filter { seenAgentIDs.insert($0).inserted }
            let inlineAgentIDs = requestedAgentIDs.filter { agentID in
                deliveredRecipientIDs.contains(agentID)
                    && agents[agentID]?.status == .running
            }
            let inlineAgentIDSet = Set(inlineAgentIDs)
            for recipientID in deliveredRecipientIDs
            where !inlineAgentIDSet.contains(recipientID) {
                _ = await sharedChat.drain(
                    roomID: roomID,
                    participantID: recipientID,
                    limit: AgentSharedChat.maximumMailboxMessages
                )
            }
            // The terminal operator consumes live messages through the TUI
            // observation stream, not a mailbox or prompt queue. When the
            // coordinator addresses the operator directly (by id), the bus
            // transcript above is the only delivery channel needed: routing it
            // through the sub-agent work loop would fail because the operator is
            // not a delegated agent. Skip that loop when no identifier resolves
            // to a real agent, and surface the bus delivery instead.
            guard !requestedAgentIDs.isEmpty else {
                if let delivery = transcriptDelivery {
                    let recipients = AgentSharedChat.deliveryRecipientSummary(
                        for: delivery.recipients
                    )
                    return "Delivered live message to \(recipients)."
                }
                throw DirectSubAgentRuntimeError.agentNotFound(
                    identifiers.joined(separator: ", ")
                )
            }
            // Authorization is unchanged for the inline recipients: a stale or
            // standby-ineligible attempt must still be refused with the same
            // error it gets on the queued route. Only the delivery mechanism
            // differs, never the permission check.
            if !inlineAgentIDs.isEmpty {
                try await validateOpenMessageTargets(inlineAgentIDs)
            }
            let queuedAgentIDs = requestedAgentIDs.filter { !inlineAgentIDSet.contains($0) }
            var queueResult: String?
            if !queuedAgentIDs.isEmpty {
                var boundedArguments = arguments
                let messageKey = ["message", "prompt", "input"].first { arguments[$0] != nil }
                boundedArguments[messageKey ?? "message"] = .string(boundedText)
                // Restrict messageAgents to the queued subset only. A running
                // recipient must not reach queuePrompt — that is what would
                // defer its reply to the end of the turn — and it already owns
                // its taskless delegation reservation, so no new reservation
                // may be taken for it either.
                for key in Self.agentIdentifierArgumentKeys {
                    boundedArguments.removeValue(forKey: key)
                }
                boundedArguments["ids"] = .array(queuedAgentIDs.map(JSONValue.string))
                queueResult = try await messageAgents(
                    arguments: boundedArguments,
                    parentAllowedToolNames: parentAllowedToolNames
                )
            }
            var lines: [String] = []
            if let delivery = transcriptDelivery {
                let recipients = AgentSharedChat.deliveryRecipientSummary(
                    for: delivery.recipients
                )
                lines.append("Delivered live message to \(recipients).")
            }
            if !inlineAgentIDs.isEmpty {
                let inlineSummary = AgentSharedChat.deliveryRecipientSummary(
                    for: transcriptDelivery?.recipients.filter {
                        inlineAgentIDSet.contains($0.id)
                    } ?? []
                )
                lines.append(
                    "Busy right now, delivered live: \(inlineSummary). "
                        + "Each reads it at its next tool boundary, without "
                        + "interrupting the turn in flight; no prompt was queued."
                )
            }
            if let queueResult {
                lines.append(queueResult)
            }
            guard !lines.isEmpty else {
                throw DirectSubAgentRuntimeError.agentNotFound(
                    identifiers.joined(separator: ", ")
                )
            }
            return lines.joined(separator: "\n")
        }
        let delivery = try await withBroadcastClassification(destination: destination) {
            try await sharedChat.send(
                roomID: roomID,
                senderID: senderID,
                destination: destination,
                text: text
            )
        }
        // A display name is not an identity: any agent may be named
        // "operator" or "coordinator". Model-facing delivery output therefore
        // always includes the actor-owned kind and stable identifier, with the
        // display name only as an explicitly non-authoritative field.
        let recipients = AgentSharedChat.deliveryRecipientSummary(for: delivery.recipients)
        return "Delivered live message to \(recipients)."
    }

    /// Public bridge used exclusively by the terminal input surface. It gives
    /// human input its own trusted transcript identity instead of conflating it
    /// with the coordinator LLM or creating a mailbox-owning participant.
    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        let roomID = sharedChatRootSessionID ?? rootSessionID.nilIfBlank ?? "default"
        _ = try await sharedChat.registerCoordinator(roomID: roomID)
        return try await withBroadcastClassification(destination: destination) {
            try await sharedChat.sendFromOperator(
                roomID: roomID,
                destination: destination,
                text: text
            )
        }
    }

    // MARK: - Broadcast classification

    /// Standby agents keep receiving direct messages — the coordinator
    /// follow-up depends on it — but a `peers`/`all` broadcast must not enqueue
    /// an LLM turn on every standby agent in the room and burn its standby
    /// budget. Broadcasts are therefore identified as they are sent and dropped
    /// for standby residents when their mailbox is drained.
    ///
    /// The bus invokes the recipients' wake-up callbacks inside `send`, so a
    /// standby drain can reach the mailbox before the delivery is classified.
    /// `pendingBroadcastSends` closes that window: while it is non-zero a
    /// standby resident leaves its mailbox untouched, and this method re-arms
    /// the drain once the broadcast has been recorded.
    func withBroadcastClassification(
        destination: AgentSharedChat.Destination,
        send: () async throws -> AgentSharedChat.Delivery
    ) async rethrows -> AgentSharedChat.Delivery {
        guard Self.isBroadcastDestination(destination) else {
            return try await send()
        }
        pendingBroadcastSends += 1
        do {
            let delivery = try await send()
            noteBroadcastMessage(delivery.message.id)
            pendingBroadcastSends -= 1
            rearmStandbyDrains(for: delivery.recipients.map(\.id))
            return delivery
        } catch {
            pendingBroadcastSends -= 1
            rearmStandbyDrains(for: nil)
            throw error
        }
    }

    static func isBroadcastDestination(
        _ destination: AgentSharedChat.Destination
    ) -> Bool {
        switch destination {
        case .peers, .all:
            return true
        case .direct, .coordinator:
            return false
        }
    }

    /// Remembers a delivered broadcast, evicting the oldest tracked entries
    /// once the bounded window is full.
    func noteBroadcastMessage(_ id: UUID) {
        guard broadcastMessageIDs.insert(id).inserted else { return }
        broadcastMessageIDOrder.append(id)
        while broadcastMessageIDOrder.count > Self.maximumTrackedBroadcastMessages {
            broadcastMessageIDs.remove(broadcastMessageIDOrder.removeFirst())
        }
    }

    /// True when the message was delivered as a `peers`/`all` broadcast.
    func isBroadcastMessage(_ message: AgentSharedChat.Message) -> Bool {
        broadcastMessageIDs.contains(message.id)
    }

    /// Restarts the mailbox drain of the standby residents that skipped it
    /// while a broadcast was being classified, so a direct message parked
    /// behind the broadcast is still delivered.
    func rearmStandbyDrains(for recipientIDs: [String]?) {
        guard pendingBroadcastSends == 0 else { return }
        let targetIDs = agents.values
            .filter { record in
                isStandbyResident(record)
                    && (recipientIDs.map { $0.contains(record.id) } ?? true)
            }
            .map(\.id)
        guard !targetIDs.isEmpty else { return }
        let runtime = self
        Task(name: "ZenCODE.shared-chat.standby-drain-rearm") {
            for agentID in targetIDs {
                await runtime.drainSharedChatMailbox(for: agentID)
            }
        }
    }

    /// Restarts the mailbox drain of one agent after a turn ends.
    ///
    /// This is the fallback half of the inline-delivery contract: while a turn
    /// is running ``drainSharedChatMailbox(for:)`` deliberately leaves the
    /// mailbox alone so the executor can deliver inline, which means a turn
    /// that ends without any further tool call would otherwise leave messages
    /// parked. Re-arming here converts those leftovers into a queued prompt,
    /// exactly as before this optimisation.
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
        let roomID = sharedChatRootSessionID ?? rootSessionID.nilIfBlank ?? "default"
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
        let roomID = sharedChatRootSessionID ?? rootSessionID.nilIfBlank ?? "default"
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
        // A turn in flight gets its messages inline, at the first tool boundary
        // reached by `DirectToolExecutor` (which drains this very mailbox with
        // the agent's own participant id). Consuming the mailbox here instead
        // would turn a live message into a follow-up prompt that only runs
        // *after* the current turn — exactly the latency this hold-back exists
        // to remove.
        //
        // The status read and this early return happen in the same actor step,
        // with no `await` in between, so the decision cannot be taken against a
        // stale status. No message is lost either: whatever stays in the
        // mailbox is delivered inline at the next tool boundary, or by the
        // end-of-turn re-arm (`nextWork(for:)` when the queue drains, and the
        // work-loop exit path when prompts remain queued).
        guard agent.status != .running else {
            return
        }
        guard !agent.isDrainingSharedChatMailbox else {
            return
        }
        // A standby resident must not consume its mailbox while a broadcast is
        // still being classified: the message would be indistinguishable from a
        // direct message and would spend a standby turn. The sender re-arms
        // this drain as soon as the broadcast is recorded.
        guard !(isStandbyResident(agent) && pendingBroadcastSends > 0) else {
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
            // The prompt queued by the previous iteration may already have
            // started a turn. Leave the rest of the mailbox untouched so the
            // running turn receives it inline at its next tool boundary; the
            // end-of-turn re-arm covers the case where it makes no further
            // tool call.
            guard current.status != .running else { return }
            // Re-check the broadcast window too: a broadcast may have started
            // while this loop was awaiting the previous batch.
            guard !(isStandbyResident(current) && pendingBroadcastSends > 0) else {
                return
            }
            let messages = await sharedChat.drain(
                roomID: agent.rootSessionID,
                participantID: agentID,
                limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
            )
            var deliverable = messages.filter { $0.sender.id != agentID }
            guard !deliverable.isEmpty else { return }
            if isStandbyResident(current) {
                // A standby agent stays in the room and keeps its transcript,
                // but only an addressed message is worth an LLM turn: dropping
                // broadcasts here is what keeps `peers`/`all` from spending the
                // standby budget of every idle participant.
                deliverable = deliverable.filter { !isBroadcastMessage($0) }
                guard !deliverable.isEmpty else { continue }
            }
            // Backpressure: stop draining when the pending queue is full. The
            // mailbox retains the remaining messages; the drain is re-armed
            // from `nextWork` when the agent finishes a prompt and the queue
            // has capacity again.
            guard (agents[agentID]?.pendingPrompts.count ?? 0)
                    < Self.maximumPendingSharedChatPromptsPerAgent else {
                return
            }
            do {
                try queuePrompt(Self.sharedChatPrompt(deliverable), for: agentID)
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
        case "coordinator":
            return .coordinator
        case "peers", "peer":
            return .peers
        case "all", "broadcast":
            return .all
        default:
            throw DirectSubAgentRuntimeError.invalidArgument(
                "to must be direct, coordinator, peers, or all"
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
        Reply to the sender through this chat using the `agent.message` tool: address another agent by its `id`/`name`, or use `to: "coordinator"` to reach the coordinator and the human operator, who has no mailbox and is surfaced through the coordinator. Your ordinary output does not reach this chat, so any reply to a chat message must be sent via `agent.message`. Then continue the current work when appropriate.
        """
    }

    /// Block appended to a tool result when live messages arrive *during* a
    /// turn. It is the same serialization contract as ``sharedChatPrompt(_:)``
    /// — the Core serializer quotes every message body, so a hostile sender
    /// name or text cannot forge a second sender header or an operator
    /// instruction — but the framing differs: the work is still in flight, so
    /// the model is told to answer now and then resume, instead of treating the
    /// messages as a new task.
    static func inlineSharedChatDeliveryBlock(
        _ messages: [AgentSharedChat.Message]
    ) -> String {
        """
        [Live chat messages received while you were working]
        \(AgentSharedChat.promptTranscript(for: messages))

        \(AgentSharedChat.promptTrustBoundaryNote)
        These messages arrived during your current turn. Reply NOW with the `agent.message` tool before continuing: address the sender by its `id`/`name`, or use `to: "coordinator"` to reach the coordinator and the human operator, who has no mailbox and is surfaced through the coordinator. Your ordinary output does not reach this chat, so a reply that is not sent via `agent.message` is never delivered. After replying, resume the work you were doing.
        """
    }
}
