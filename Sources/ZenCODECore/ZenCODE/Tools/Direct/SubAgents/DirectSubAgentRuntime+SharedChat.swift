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
        // goes through messageAgents. The target mailboxes are drained right
        // after the bus send so the wake-up callback does not duplicate the
        // prompt that messageAgents queues.
        if effectiveSenderID == nil,
           case .direct = destination {
            let boundedText = AgentSharedChat.boundedMessageText(text)
            var transcriptDelivery: AgentSharedChat.Delivery?
            do {
                transcriptDelivery = try await sharedChat.send(
                    roomID: roomID,
                    senderID: senderID,
                    destination: destination,
                    text: boundedText
                )
                for recipientID in transcriptDelivery!.recipients.map(\.id) {
                    _ = await sharedChat.drain(
                        roomID: roomID,
                        participantID: recipientID,
                        limit: AgentSharedChat.maximumMailboxMessages
                    )
                }
            } catch {
                // Best-effort transcript recording: the agent may not yet be
                // registered in the bus. The message is still queued below.
            }
            var boundedArguments = arguments
            let messageKey = ["message", "prompt", "input"].first { arguments[$0] != nil }
            boundedArguments[messageKey ?? "message"] = .string(boundedText)
            let queueResult = try await messageAgents(
                arguments: boundedArguments,
                parentAllowedToolNames: parentAllowedToolNames
            )
            if let delivery = transcriptDelivery {
                let recipients = AgentSharedChat.deliveryRecipientSummary(
                    for: delivery.recipients
                )
                return "Delivered live message to \(recipients).\n" + queueResult
            }
            return queueResult
        }
        let delivery = try await sharedChat.send(
            roomID: roomID,
            senderID: senderID,
            destination: destination,
            text: text
        )
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
        return try await sharedChat.sendFromOperator(
            roomID: roomID,
            destination: destination,
            text: text
        )
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
            guard agents[agentID]?.status != .closed else { return }
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
        [Live shared-chat messages]
        \(AgentSharedChat.promptTranscript(for: messages))

        \(AgentSharedChat.promptTrustBoundaryNote)
        Respond directly to these messages and continue the current work when appropriate.
        """
    }
}
