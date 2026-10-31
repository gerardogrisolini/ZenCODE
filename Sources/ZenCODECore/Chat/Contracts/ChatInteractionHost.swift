//
//  ChatInteractionHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The operator's answer to a tool-consent request.
public enum ChatConsentDecision: Sendable, Equatable {
    /// Run this call only.
    case allowOnce
    /// Run this call and every later call with the same consent identity.
    case allowAlways
    /// Refuse this call only.
    case denyOnce
    /// Refuse this call and every later call with the same consent identity.
    case denyAlways
}

/// One entry of a host-presented choice menu.
public struct ChatChoiceItem: Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// Operator interactions a chat channel provides to the shared runtime.
///
/// Hosts are transport adapters: the terminal reads raw keys, ACP sends
/// `session/request_permission`, the headless runner offers nothing. Every
/// request returns `nil` when the host cannot answer or the operator cancelled;
/// callers must treat `nil` as a refusal, never as an approval.
public protocol ChatInteractionHost: Sendable {
    /// Interactions this host can actually perform.
    var capabilities: ChatChannelCapabilities { get }

    /// Asks the operator whether a gated tool call may run.
    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision?

    /// Presents a single-choice menu and returns the chosen item ID.
    func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String?

    /// Presents a multiple-choice menu and returns the chosen item IDs.
    func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>?

    /// Reads one line of free text from the operator.
    func readLine(prompt: String) async -> String?
}

extension ChatInteractionHost {
    public func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        nil
    }

    public func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>? {
        nil
    }

    public func readLine(prompt: String) async -> String? {
        nil
    }
}
