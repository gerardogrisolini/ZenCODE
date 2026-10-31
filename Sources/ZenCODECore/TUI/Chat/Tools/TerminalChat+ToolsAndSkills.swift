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

        if Self.isToolLogsRequest(rawArguments) {
            await openToolExecutionLog()
            return
        }

        await writeSessionNotices(await chatSession.runToolsCommand(line: command).notices)
    }

    nonisolated static func isToolLogsRequest(_ rawArguments: String) -> Bool {
        ChatSessionController.isToolLogsRequest(rawArguments)
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

    /// Adapter of
    /// ``ChatSessionController/applyToolSelectionCommand(rawSelection:)``.
    public func applyToolSelection(_ rawSelection: String) async {
        await writeSessionNotices(
            await chatSession.applyToolSelectionCommand(rawSelection: rawSelection).notices
        )
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

    public nonisolated static func shouldDiscoverExternalTools(
        previousKeys: Set<String>,
        selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Bool {
        ChatSessionController.shouldDiscoverExternalTools(
            previousKeys: previousKeys,
            selectedKeys: selectedKeys,
            items: items
        )
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

    public nonisolated static func parseToolSelection(
        _ rawSelection: String,
        items: [TerminalToolSelectionItem]
    ) throws -> Set<String> {
        try TerminalToolSelectionCatalog.parseSelection(
            rawSelection,
            items: items
        )
    }

    public func toolSelectionItems(
        additionalDescriptors: [DirectToolDescriptor] = []
    ) async -> [TerminalToolSelectionItem] {
        await chatSession.toolSelectionItems(
            additionalDescriptors: additionalDescriptors
        )
    }

    public nonisolated static func toolSelectionItems(
        featureStatuses: [SwiftFeatureStatus],
        additionalDescriptors: [DirectToolDescriptor] = []
    ) -> [TerminalToolSelectionItem] {
        ChatSessionController.toolSelectionItems(
            featureStatuses: featureStatuses,
            additionalDescriptors: additionalDescriptors
        )
    }

    public func intrinsicAllowedToolNamesForSelectedAgent() -> Set<String> {
        chatSession.intrinsicAllowedToolNamesForSelectedAgent()
    }

    public nonisolated static func toolSelectionKeys(
        from rawValues: [String],
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        ChatSessionController.toolSelectionKeys(from: rawValues, items: items)
    }

    public func applyInitialAgentSelectionIfNeeded() async {
        await chatSession.applyInitialAgentSelectionIfNeeded()
    }

    public func applyInitialSkillSelectionIfNeeded() throws {
        try chatSession.applyInitialSkillSelectionIfNeeded()
    }

    /// `/skills`: adapter of ``ChatSessionController/runSkillsCommand(line:)``,
    /// which interprets the arguments and runs the matching operation:
    /// uninstall, install from a GitHub URL or a local path, the menu, or a
    /// selection. A changed selection refreshes the status bar
    /// (``selectionDidApply(_:command:)``).
    public func handleSkillsCommand(_ command: String) async {
        await writeSessionNotices(await chatSession.runSkillsCommand(line: command).notices)
    }

    public func installSkill(fromGitHubURL url: URL) async {
        await writeSessionNotices(
            await chatSession.installSkillCommand(from: .gitHub(url)).notices
        )
    }

    public func installSkill(fromLocalURL url: URL) async {
        await writeSessionNotices(
            await chatSession.installSkillCommand(from: .local(url)).notices
        )
    }

    /// Adapter of
    /// ``ChatSessionController/applySkillSelectionCommand(rawSelection:)``.
    public func applySkillSelection(_ rawSelection: String) async {
        await writeSessionNotices(
            await chatSession.applySkillSelectionCommand(rawSelection: rawSelection).notices
        )
    }

    /// Adapter of ``ChatSessionController/applySkillSelectionCommand(ids:)``.
    public func applySkillSelection(_ selectedSkillIDs: Set<String>) async {
        await writeSessionNotices(
            await chatSession.applySkillSelectionCommand(ids: selectedSkillIDs).notices
        )
    }

    public func printSkillSelectionStatus() async {
        await writeSessionNotice(.selectedSkills(selectedPromptSkills()))
    }

    public func skillCheckboxItems() -> [TerminalCheckboxMenuItem<String>] {
        chatSession.skillChoiceItems().map { item in
            TerminalCheckboxMenuItem(value: item.id, title: item.title, detail: item.detail)
        }
    }

    public func availableSkills() -> [PromptSkill] {
        chatSession.availableSkills()
    }

    public func selectedPromptSkills() -> [PromptSkill] {
        chatSession.selectedPromptSkills()
    }

    public nonisolated static func githubSkillInstallURL(from rawArguments: String) -> URL? {
        skillInstallValue(from: rawArguments).flatMap {
            ChatSessionController.gitHubSkillInstallURL(value: $0)
        }
    }

    public nonisolated static func localSkillInstallURL(
        from rawArguments: String,
        baseDirectory: URL
    ) -> URL? {
        skillInstallValue(from: rawArguments).flatMap {
            ChatSessionController.localSkillInstallURL(value: $0, baseDirectory: baseDirectory)
        }
    }

    public nonisolated static func isSkillInstallRequest(_ rawArguments: String) -> Bool {
        ChatSessionController.isSkillInstallRequest(rawArguments)
    }

    public nonisolated static func isSkillUninstallRequest(_ rawArguments: String) -> Bool {
        ChatSessionController.isSkillUninstallRequest(rawArguments)
    }

    public nonisolated static func skillInstallValue(from rawArguments: String) -> String? {
        ChatSessionController.skillInstallValue(from: rawArguments)
    }

    public nonisolated static func parseSkillSelection(
        _ rawSelection: String,
        availableSkills: [PromptSkill]
    ) throws -> Set<String> {
        try ChatSessionController.parseSkillSelection(
            rawSelection,
            availableSkills: availableSkills
        )
    }

    public nonisolated static func skill(
        matching rawToken: String,
        in availableSkills: [PromptSkill]
    ) -> PromptSkill? {
        ChatSessionController.skill(matching: rawToken, in: availableSkills)
    }

    public nonisolated static func selectionKey(_ value: String) -> String {
        ChatSessionController.selectionKey(value)
    }
}
