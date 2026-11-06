//
//  ACPResumableTaskGraphChoiceHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// ACP host of the startup offer of the task graphs earlier sessions left
/// incomplete (``ChatSessionController/offerResumableTaskGraphs(choiceHost:)``),
/// used for that offer only.
///
/// ACP has no menus, so the session's own host (``ACPConsentHost``) declares
/// no ``ChatChannelCapabilities/singleChoice``: it would turn every controller
/// menu into a permission request. This host declares only that capability
/// and asks its menu with one `session/request_permission` on a synthetic
/// tool call: one option per item, its ID the item's, its kind mapped from
/// the stable choice IDs of the offer (`allow_once` resumes, `reject_always`
/// deletes every listed graph, `reject_once` starts fresh). Without
/// ``ChatChannelCapabilities/multipleChoice`` the offer's deletion deletes
/// every listed graph. Once answered, the tool call is completed with a
/// `tool_call_update`, so the client does not leave it pending.
struct ACPResumableTaskGraphChoiceHost: ChatInteractionHost {
    private let writer: ACPWriter
    /// The ACP session the offer runs for: the requests and the updates name it.
    private let sessionID: String

    init(writer: ACPWriter, sessionID: String) {
        self.writer = writer
        self.sessionID = sessionID
    }

    var capabilities: ChatChannelCapabilities {
        [.singleChoice]
    }

    /// Never asked: the offer asks no tool consent.
    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        nil
    }

    /// Asks `items` with `session/request_permission` and returns the ID of
    /// the option the client selected, only when it is one of `items`. A
    /// cancelled outcome, an unknown option, a failed request, and a
    /// cancellation (the session closed, the bridge shut down) return `nil`,
    /// which the offer treats as Start fresh. The synthetic tool call is
    /// completed after an answer or a client error, not after a cancellation.
    func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        let toolCallID = "zencode:resume-task-graphs:\(UUID().uuidString.lowercased())"
        let result: JSONValue?
        do {
            result = try await writer.request(
                method: "session/request_permission",
                params: Self.permissionParams(
                    sessionID: sessionID,
                    toolCallID: toolCallID,
                    title: title,
                    items: items
                )
            )
        } catch {
            if !(error is CancellationError) {
                await completeToolCall(toolCallID)
            }
            return nil
        }
        await completeToolCall(toolCallID)
        guard let optionID = ACPConsentHost.permissionOptionID(from: result),
              items.contains(where: { $0.id == optionID }) else {
            return nil
        }
        return optionID
    }

    /// Marks the synthetic tool call `completed`, unless the offer was
    /// cancelled meanwhile: its session is closing or the transport is.
    private func completeToolCall(_ toolCallID: String) async {
        guard !Task.isCancelled else {
            return
        }
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string(toolCallID),
                "status": .string("completed"),
            ])
        )
    }

    /// The params of the `session/request_permission` of `items`: the
    /// synthetic `toolCall` (`title`, its entries as one text block) and one
    /// option per item, in order.
    static func permissionParams(
        sessionID: String,
        toolCallID: String,
        title: String,
        items: [ChatChoiceItem]
    ) -> JSONValue {
        .object([
            "sessionId": .string(sessionID),
            "toolCall": .object([
                "toolCallId": .string(toolCallID),
                "status": .string("pending"),
                "title": .string(title),
                "kind": .string("other"),
                "content": .array([
                    .object([
                        "type": .string("content"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string(entriesText(items)),
                        ]),
                    ]),
                ]),
            ]),
            "options": .array(items.map { item in
                .object([
                    "optionId": .string(item.id),
                    "name": .string(optionName(for: item)),
                    "kind": .string(optionKind(for: item)),
                ])
            }),
        ])
    }

    /// The entries of the menu under their group headings, one
    /// `title — detail` line each (the title alone without a detail), the
    /// groups separated by blank lines.
    static func entriesText(_ items: [ChatChoiceItem]) -> String {
        var blocks: [[String]] = []
        var blockGroup: String?
        for item in items {
            if blocks.isEmpty || item.group != blockGroup {
                blocks.append(item.group.map { [$0] } ?? [])
                blockGroup = item.group
            }
            let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            blocks[blocks.count - 1].append(detail.isEmpty ? item.title : "\(item.title) — \(detail)")
        }
        return blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// The option name of `item`: `Resume <title> (<detail>)` for a graph,
    /// the plain title for the deletion and Start fresh.
    static func optionName(for item: ChatChoiceItem) -> String {
        guard isResumeItem(item) else {
            return item.title
        }
        let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? "Resume \(item.title)" : "Resume \(item.title) (\(detail))"
    }

    /// The ACP permission kind of `item`: `reject_always` for the deletion,
    /// `reject_once` for Start fresh, `allow_once` for a graph.
    static func optionKind(for item: ChatChoiceItem) -> String {
        switch item.id {
        case ChatSessionController.resumableTaskGraphDeleteChoiceID:
            return "reject_always"
        case ChatSessionController.resumableTaskGraphStartFreshChoiceID:
            return "reject_once"
        default:
            return "allow_once"
        }
    }

    /// Every item but the deletion and Start fresh resumes a graph.
    private static func isResumeItem(_ item: ChatChoiceItem) -> Bool {
        item.id != ChatSessionController.resumableTaskGraphDeleteChoiceID
            && item.id != ChatSessionController.resumableTaskGraphStartFreshChoiceID
    }
}
