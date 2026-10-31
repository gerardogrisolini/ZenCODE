//
//  ChatSessionNoticePayloads.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The tool groups currently active, with the number of tools each exposes.
struct ChatActiveToolsSummary: Sendable, Equatable {
    struct Group: Sendable, Equatable {
        let title: String
        let toolCount: Int

        init(title: String, toolCount: Int) {
            self.title = title
            self.toolCount = toolCount
        }
    }

    /// The groups in display order; empty when no tool is active.
    let groups: [Group]

    init(groups: [Group]) {
        self.groups = groups
    }

    /// Groups the active tool names under the selected tool items, followed by
    /// the prompt-skill tools. Feature-management tools are never listed.
    init(
        toolNames: [String],
        items: [TerminalToolSelectionItem],
        selectedKeys: Set<String>
    ) {
        let uniqueToolNames = Set(toolNames).subtracting(AgentProfileStore.featureManagementToolNames)
        guard !uniqueToolNames.isEmpty else {
            self.init(groups: [])
            return
        }

        var groups: [Group] = []
        let normalizedKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedKeys,
            items: items
        )
        for item in items where normalizedKeys.contains(item.key) {
            let itemToolNames = uniqueToolNames.filter { item.allows(toolName: $0) }
            guard !itemToolNames.isEmpty else {
                continue
            }
            let concreteToolNames = itemToolNames.filter { toolName in
                !toolName.hasSuffix(".")
            }
            groups.append(Group(title: item.title, toolCount: concreteToolNames.count))
        }

        let skillToolNames = uniqueToolNames.intersection(PromptSkillToolProvider.toolNames)
        if !skillToolNames.isEmpty {
            groups.append(Group(title: "Skills", toolCount: skillToolNames.count))
        }
        self.init(groups: groups)
    }
}

/// What the saved-session list shows about one saved session.
struct ChatSavedSessionSummary: Sendable, Equatable {
    let name: String
    let modelID: String?
    /// Messages of the display history, system messages excluded.
    let messageCount: Int
    /// Context-window tokens in use when the session was saved.
    let contextUsedTokens: Int?
    let savedAt: Date

    init(
        name: String,
        modelID: String?,
        messageCount: Int,
        contextUsedTokens: Int?,
        savedAt: Date
    ) {
        self.name = name
        self.modelID = modelID
        self.messageCount = messageCount
        self.contextUsedTokens = contextUsedTokens
        self.savedAt = savedAt
    }

    init(_ session: TerminalSavedSession) {
        self.init(
            name: session.name,
            modelID: session.modelID,
            messageCount: session.messageCount,
            contextUsedTokens: session.contextWindow?.usedTokens,
            savedAt: session.savedAt
        )
    }
}

/// A file or URL the conversation mentions that `/open` can hand to the
/// platform, with the label the selection list shows for it.
struct ChatOpenCandidate: Sendable, Equatable {
    /// The value the platform opens: an absolute file path or a URL string.
    let target: String
    /// The human-readable label of the selection list.
    let display: String
    let kind: ChatOpenTarget.Kind

    init(target: String, display: String, kind: ChatOpenTarget.Kind) {
        self.target = target
        self.display = display
        self.kind = kind
    }

    /// What an interaction host is asked to open for this candidate.
    var openTarget: ChatOpenTarget {
        ChatOpenTarget(target: target, kind: kind)
    }
}
