//
//  ChatInteractionHost.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

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
    /// Heading the item is listed under, for hosts that group their menu
    /// (for example the provider of a model). `nil` for an ungrouped item.
    public let group: String?
    /// Marks the item that is in effect now (the active model, agent, or
    /// session), so a host can flag it independently of the selection.
    public let isCurrent: Bool

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        group: String? = nil,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.group = group
        self.isCurrent = isCurrent
    }
}

/// A menu the controller asks a host to present: its title, the items in
/// display order, and the items that start selected.
struct ChatChoiceList: Sendable, Equatable {
    let title: String
    let items: [ChatChoiceItem]
    let selectedIDs: Set<String>

    init(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String> = []
    ) {
        self.title = title
        self.items = items
        self.selectedIDs = selectedIDs
    }
}

/// The operator's answer to a multiple-choice menu with a focused item.
public struct ChatFocusedChoice: Sendable, Equatable {
    /// IDs of the items the operator left ticked.
    public let selectedIDs: Set<String>
    /// ID of the item the operator confirmed on.
    public let focusedID: String

    public init(selectedIDs: Set<String>, focusedID: String) {
        self.selectedIDs = selectedIDs
        self.focusedID = focusedID
    }
}

/// A request to let the session's tools reach the workspace folder, for hosts
/// whose platform gates folder access (a sandboxed app, the macOS terminal).
public struct ChatWorkspaceAccessRequest: Sendable, Equatable {
    /// The folder the tools need to read and write.
    public let workspaceURL: URL
    /// Titles of the tool groups that stay disabled if access is refused.
    public let toolTitles: [String]

    public init(workspaceURL: URL, toolTitles: [String]) {
        self.workspaceURL = workspaceURL
        self.toolTitles = toolTitles
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

    /// Presents a multiple-choice menu whose cursor rests on `focusedID` and
    /// returns the ticked item IDs together with the item the operator
    /// confirmed on. `toggleLabel` names what a tick selects and
    /// `confirmLabel` what confirming does, for hosts that print key help.
    func chooseManyWithFocus(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        focusedID: String?,
        toggleLabel: String,
        confirmLabel: String
    ) async -> ChatFocusedChoice?

    /// Reads one line of free text from the operator.
    func readLine(prompt: String) async -> String?

    /// Asks the platform to let the session's tools reach the workspace
    /// folder. Returns `false` when access is refused, which disables the
    /// tools that need it; a host without a folder gate grants it.
    func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool
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

    public func chooseManyWithFocus(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        focusedID: String?,
        toggleLabel: String,
        confirmLabel: String
    ) async -> ChatFocusedChoice? {
        nil
    }

    public func readLine(prompt: String) async -> String? {
        nil
    }

    public func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool {
        true
    }
}
