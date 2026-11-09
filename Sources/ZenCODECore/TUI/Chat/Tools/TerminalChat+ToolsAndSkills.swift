//
//  TerminalChat+ToolsAndSkills.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension TerminalChat {
    /// `/tools`: `/tools logs` opens the system log viewer; everything else
    /// is an adapter of ``ChatSessionController/runToolsCommand(line:)``.
    public func handleToolsCommand(_ command: String) async {
        let rawArguments = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/tools"
        )

        if ChatSessionController.isToolLogsRequest(rawArguments) {
            await openToolExecutionLog()
            return
        }

        await writeSessionNotices(await chatSession.runToolsCommand(line: command).notices)
    }

    private func openToolExecutionLog() async {
        do {
            try await SystemLogViewerLauncher.open(timeout: 30)
            // TUI messages use stderr; ACP stdout remains reserved for protocol traffic.
            await writeSystemMessage(
                "Opened the system log viewer. Filter subsystem \"\(ToolExecutionLog.subsystem)\" "
                    + "and category \"\(ToolExecutionLog.category)\" for tool execution logs.\n"
            )
        } catch {
            await writeFailureMessage(
                "ZenCODE: unable to open the system log viewer: \(error.localizedDescription)\n"
            )
        }
    }

    /// Adapter of ``ChatSessionController/applyToolSelectionCommand(keys:)``;
    /// an applied selection has printed the active tools
    /// (``selectionDidApply(_:command:)``).
    public func applyToolSelection(_ selectedKeys: Set<String>) async {
        await writeSessionNotices(
            await chatSession.applyToolSelectionCommand(keys: selectedKeys).notices
        )
    }

    public func printToolSelectionStatus() async {
        await writeSessionNotice(.activeTools(await chatSession.activeToolsSummary()))
    }

    public nonisolated static func toolCheckboxItems(
        items: [TerminalToolSelectionItem]
    ) -> [TerminalCheckboxMenuItem<String>] {
        items.map { item in
            TerminalCheckboxMenuItem(
                value: item.key,
                title: item.title,
                detail: item.detail,
                groupTitle: item.groupTitle
            )
        }
    }

    public func toolSelectionItems(
        additionalDescriptors: [DirectToolDescriptor] = []
    ) async -> [TerminalToolSelectionItem] {
        await chatSession.toolSelectionItems(
            additionalDescriptors: additionalDescriptors
        )
    }

    public func applyInitialAgentSelectionIfNeeded() async {
        await chatSession.applyInitialAgentSelectionIfNeeded()
    }

    public func applyInitialSkillSelectionIfNeeded() throws {
        try chatSession.applyInitialSkillSelectionIfNeeded()
    }
}
