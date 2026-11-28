//
//  ACPResumableTaskGraphChoiceHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

/// ACP host used only for the startup offer of incomplete task graphs.
/// A form is requested only when explicitly advertised by the client; the
/// ordinary consent host does not expose general-purpose choice menus.
struct ACPResumableTaskGraphChoiceHost: ChatInteractionHost {
    private let writer: ACPWriter
    private let sessionID: String
    private let supportsForm: Bool

    init(writer: ACPWriter, sessionID: String, supportsForm: Bool) {
        self.writer = writer
        self.sessionID = sessionID
        self.supportsForm = supportsForm
    }

    var capabilities: ChatChannelCapabilities {
        supportsForm ? [.singleChoice] : []
    }

    func requestToolConsent(_ request: AgentToolAuthorizationRequest) async -> ChatConsentDecision? {
        nil
    }

    /// Only an accepted, explicitly listed choice can trigger an action.
    /// Decline, cancellation, invalid content and transport errors start fresh.
    func chooseOne(title: String, items: [ChatChoiceItem], selectedID: String?) async -> String? {
        guard supportsForm, !items.isEmpty, !Task.isCancelled else { return nil }
        let result: JSONValue?
        do {
            result = try await writer.request(
                method: "elicitation/create",
                params: Self.elicitationParams(sessionID: sessionID, title: title, items: items)
            )
        } catch {
            return nil
        }
        guard !Task.isCancelled,
              let response = result?.objectValue,
              response["action"]?.acpStringValue == "accept",
              let choice = response["content"]?.objectValue?["choice"]?.acpStringValue,
              items.contains(where: { $0.id == choice }) else { return nil }
        return choice
    }

    static func elicitationParams(sessionID: String, title: String, items: [ChatChoiceItem]) -> JSONValue {
        .object([
            "sessionId": .string(sessionID),
            "mode": .string("form"),
            "message": .string(title),
            "requestedSchema": .object([
                "type": .string("object"),
                "required": .array([.string("choice")]),
                "properties": .object([
                    "choice": .object([
                        "type": .string("string"),
                        "oneOf": .array(items.map { item in
                            .object(["const": .string(item.id), "title": .string(optionName(for: item))])
                        }),
                    ]),
                ]),
            ]),
        ])
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

    /// Every item but the deletion and Start fresh resumes a graph.
    private static func isResumeItem(_ item: ChatChoiceItem) -> Bool {
        item.id != ChatSessionController.resumableTaskGraphDeleteChoiceID
            && item.id != ChatSessionController.resumableTaskGraphStartFreshChoiceID
    }
}
