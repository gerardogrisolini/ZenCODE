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
        guard let text = Self.firstString(["message", "prompt", "input"], in: arguments)?.nilIfBlank else {
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
        // coordinator's legacy direct follow-up. Peer/coordinator/broadcast
        // routes use the shared bus below; direct coordinator delivery still
        // enters the same immediately-started work loop as before.
        if effectiveSenderID == nil,
           case .direct = destination {
            return try await messageAgents(
                arguments: arguments,
                parentAllowedToolNames: parentAllowedToolNames
            )
        }
        let delivery = try await sharedChat.send(
            roomID: roomID,
            senderID: senderID,
            destination: destination,
            text: text
        )
        let names = delivery.recipients.map { "@\($0.name)" }.joined(separator: ", ")
        return "Delivered live message to \(names)."
    }

    /// Public bridge used by the terminal input surface. This uses the same
    /// actor and destination semantics as tool-driven `agent.message` calls.
    public func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        let roomID = sharedChatRootSessionID ?? rootSessionID.nilIfBlank ?? "default"
        _ = try await sharedChat.registerCoordinator(roomID: roomID)
        return try await sharedChat.send(
            roomID: roomID,
            senderID: sharedChatSenderID ?? AgentSharedChat.coordinatorID(for: roomID),
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
    func drainSharedChatMailbox(for agentID: String) async {
        guard let agent = agents[agentID], agent.status != .closed else {
            return
        }
        while true {
            let messages = await sharedChat.drain(
                roomID: agent.rootSessionID,
                participantID: agentID,
                limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
            )
            let deliverable = messages.filter { $0.sender.id != agentID }
            guard !deliverable.isEmpty else { return }
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

    static func sharedChatPrompt(_ messages: [AgentSharedChat.Message]) -> String {
        let body = messages.map {
            "[@\($0.sender.name)] \($0.text)"
        }.joined(separator: "\n")
        return """
        [Live shared-chat messages from your team]
        \(body)

        Respond directly to these messages and continue your assigned work when appropriate.
        """
    }
}
