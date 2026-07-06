//
//  TerminalChat+ToolsAndSkills.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalChat {
    public func handleToolsCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/tools".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await printToolSelectionStatus()
                writeSystemMessage(Self.renderToolSelectionUsage())
                return
            }

            let items = await toolSelectionItems()
            let selectedKeys = TerminalCheckboxMenu.select(
                title: "Tools",
                items: Self.toolCheckboxItems(items: items),
                selected: TerminalToolSelectionCatalog.normalizedSelectionKeys(
                    selectedToolKeys,
                    items: items
                ),
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            )
            if let selectedKeys {
                await applyToolSelection(selectedKeys)
            } else {
                await printToolSelectionStatus()
            }
            return
        }

        await applyToolSelection(rawArguments)
    }

    public func applyToolSelection(_ rawSelection: String) async {
        do {
            let items = await toolSelectionItems()
            let selectedKeys = try Self.parseToolSelection(
                rawSelection,
                items: items
            )
            await applyToolSelection(selectedKeys)
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderToolSelectionUsage())
        }
    }

    public func applyToolSelection(_ selectedKeys: Set<String>) async {
        let previousKeys = selectedToolKeys
        let items = await toolSelectionItems()
        selectedToolKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedKeys,
            items: items
        )
        activeSessionSystemPromptOverride = nil
        await ensureWorkspaceAccessIfNeeded()
        let shouldDiscoverExternalTools = Self.shouldDiscoverExternalTools(
            previousKeys: previousKeys,
            selectedKeys: selectedToolKeys,
            items: items
        )
        let allowedToolNames = await updateCurrentSessionToolOptions(
            discoverExternalTools: shouldDiscoverExternalTools
        )
        let renderItems = await toolSelectionItems()
        writeSystemMessage(Self.renderActiveTools(Array(allowedToolNames), items: renderItems, selectedKeys: selectedToolKeys))
        didPrintActiveTools = true
    }

    public func printToolSelectionStatus() async {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        let items = await toolSelectionItems()
        writeSystemMessage(Self.renderActiveTools(Array(allowedToolNames), items: items, selectedKeys: selectedToolKeys))
    }

    public static func shouldDiscoverExternalTools(
        previousKeys: Set<String>,
        selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Bool {
        let previousPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: previousKeys,
            items: items
        )
        let selectedPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: selectedKeys,
            items: items
        )
        return !selectedPrefixes.subtracting(previousPrefixes).isEmpty
    }

    public static func toolCheckboxItems(
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

    public static func parseToolSelection(
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
        let knownMCPDescriptors = await sessionRunner.knownMCPToolDescriptors(
            preferredWorkspaceRootURL: configuration.workingDirectory
        )
        let featureStatuses = await featureRuntime.featureStatuses(
            includeTools: true,
            includeDisabled: true
        )
        return Self.toolSelectionItems(
            featureStatuses: featureStatuses,
            additionalDescriptors: DirectToolExecutor.canonicalized(
                knownMCPDescriptors + additionalDescriptors
            )
        )
    }

    public static func toolSelectionItems(
        featureStatuses: [SwiftFeatureStatus],
        additionalDescriptors: [DirectToolDescriptor] = []
    ) -> [TerminalToolSelectionItem] {
        TerminalToolSelectionCatalog.items(
            featureStatuses: featureStatuses,
            additionalDescriptors: additionalDescriptors
        )
    }

    public func intrinsicAllowedToolNamesForSelectedAgent() -> Set<String> {
        AgentProfileStore.isBuilderAgent(selectedAgent)
            ? AgentProfileStore.featureManagementToolNames
            : []
    }

    public static func toolSelectionKeys(
        from rawValues: [String],
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        var selectedKeys = Set<String>()
        for rawValue in rawValues {
            selectedKeys.formUnion(
                TerminalToolSelectionCatalog.selectionKeys(
                    for: rawValue,
                    items: items
                )
            )
        }
        return selectedKeys
    }

    public func applyInitialAgentSelectionIfNeeded() async {
        guard let selectedAgent else {
            return
        }
        await applyAgentProfile(selectedAgent)
    }

    public func applyInitialSkillSelectionIfNeeded() throws {
        guard let initialSkillSelection = configuration.initialSkillSelection else {
            return
        }

        selectedSkillIDs = try Self.parseSkillSelection(
            initialSkillSelection,
            availableSkills: availableSkills()
        )
    }

    public func handleSkillsCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/skills".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.isSkillInstallRequest(rawArguments),
           Self.githubSkillInstallURL(from: rawArguments) == nil,
           Self.localSkillInstallURL(
               from: rawArguments,
               baseDirectory: configuration.workingDirectory
           ) == nil {
            writeFailureMessage("ZenCODE: /skills install requires a GitHub URL or local path.\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
            return
        }

        if let installURL = Self.githubSkillInstallURL(from: rawArguments) {
            await installSkill(fromGitHubURL: installURL)
            return
        }

        if let localURL = Self.localSkillInstallURL(
            from: rawArguments,
            baseDirectory: configuration.workingDirectory
        ) {
            await installSkill(fromLocalURL: localURL)
            return
        }

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                printSkillSelectionStatus()
                writeSystemMessage(Self.renderSkillSelectionUsage())
                return
            }

            let skillItems = skillCheckboxItems()
            guard !skillItems.isEmpty else {
                writeSystemMessage("No prompt skills installed by the app.\n")
                printSkillSelectionStatus()
                return
            }
            let selectedSkillIDs = TerminalCheckboxMenu.select(
                title: "Prompt skills",
                items: skillItems,
                selected: selectedSkillIDs,
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            )
            if let selectedSkillIDs {
                await applySkillSelection(selectedSkillIDs)
            } else {
                printSkillSelectionStatus()
            }
            return
        }

        await applySkillSelection(rawArguments)
    }

    public func installSkill(fromGitHubURL url: URL) async {
        writeSystemMessage("Installing skill from \(url.absoluteString)...\n")
        do {
            let result = try await PromptSkillInstaller.install(fromGitHubURL: url)
            await finishInstalledSkill(result)
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
        }
    }

    public func installSkill(fromLocalURL url: URL) async {
        writeSystemMessage("Installing skill from \(url.path)...\n")
        do {
            let result = try PromptSkillInstaller.install(fromLocalURL: url)
            await finishInstalledSkill(result)
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
        }
    }

    private func finishInstalledSkill(_ result: PromptSkillInstallResult) async {
        availableSkillsCache = nil
        selectedSkillIDs.insert(result.skill.id)
        activeSessionSystemPromptOverride = nil
        do {
            try await createCurrentSession()
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
        statusBar.reset()
        refreshInitialStatusBarContextWindow()
        writeSystemMessage(
            "Installed and selected skill: \(result.skill.title)\n"
        )
    }

    public func applySkillSelection(_ rawSelection: String) async {
        do {
            let selectedSkillIDs = try Self.parseSkillSelection(
                rawSelection,
                availableSkills: availableSkills()
            )
            await applySkillSelection(selectedSkillIDs)
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            writeSystemMessage(Self.renderSkillSelectionUsage())
        }
    }

    public func applySkillSelection(_ selectedSkillIDs: Set<String>) async {
        self.selectedSkillIDs = selectedSkillIDs
        activeSessionSystemPromptOverride = nil
        do {
            try await createCurrentSession()
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
        statusBar.reset()
        refreshInitialStatusBarContextWindow()
        printSkillSelectionStatus()
    }

    public func printSkillSelectionStatus() {
        writeSystemMessage(Self.renderSelectedSkills(selectedPromptSkills()))
    }

    public func skillCheckboxItems() -> [TerminalCheckboxMenuItem<String>] {
        availableSkills().map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return TerminalCheckboxMenuItem(
                value: skill.id,
                title: "\(skill.title)\(canonicalName)",
                detail: Self.truncatedInline(skill.summary, limit: 96)
            )
        }
    }

    public func availableSkills() -> [PromptSkill] {
        if let availableSkillsCache {
            return availableSkillsCache
        }

        let skills = PromptSkillCatalog.discoverSkills(
            searchRoots: PromptSkillCatalog.appCatalogSearchRoots()
        )
        availableSkillsCache = skills
        return skills
    }

    public func selectedPromptSkills() -> [PromptSkill] {
        let skills = availableSkills()
        guard !selectedSkillIDs.isEmpty else {
            return []
        }

        return skills.filter { selectedSkillIDs.contains($0.id) }
    }

    public static func githubSkillInstallURL(from rawArguments: String) -> URL? {
        guard let rawValue = skillInstallValue(from: rawArguments),
              let urlToken = rawValue.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            return nil
        }

        guard let url = URL(string: urlToken),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        return url
    }

    public static func localSkillInstallURL(
        from rawArguments: String,
        baseDirectory: URL
    ) -> URL? {
        guard let rawValue = skillInstallValue(from: rawArguments) else {
            return nil
        }

        if rawValue.lowercased().hasPrefix("file://"),
           let url = URL(string: rawValue),
           url.isFileURL {
            return url.standardizedFileURL
        }

        if rawValue.hasPrefix("~/") {
            let expandedPath = NSString(string: rawValue).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: true)
                .standardizedFileURL
        }

        if rawValue.hasPrefix("/") {
            return URL(fileURLWithPath: rawValue, isDirectory: true)
                .standardizedFileURL
        }

        if rawValue == "."
            || rawValue == ".."
            || rawValue.hasPrefix("./")
            || rawValue.hasPrefix("../") {
            return baseDirectory
                .appendingPathComponent(rawValue, isDirectory: true)
                .standardizedFileURL
        }

        return nil
    }

    public static func isSkillInstallRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments
            .split { $0.isWhitespace }
        guard let command = tokens.first?.lowercased() else {
            return false
        }
        return ["install", "add"].contains(command)
    }

    public static func skillInstallValue(from rawArguments: String) -> String? {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArguments.isEmpty else {
            return nil
        }

        guard let commandEndIndex = trimmedArguments.firstIndex(where: \.isWhitespace) else {
            return isSkillInstallRequest(trimmedArguments) ? nil : trimmedArguments
        }

        let command = trimmedArguments[..<commandEndIndex].lowercased()
        guard ["install", "add"].contains(command) else {
            return trimmedArguments
        }

        let value = trimmedArguments[commandEndIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func parseSkillSelection(
        _ rawSelection: String,
        availableSkills: [PromptSkill]
    ) throws -> Set<String> {
        let tokens = rawSelection
            .replacingOccurrences(of: ",", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)

        guard !tokens.isEmpty else {
            return []
        }

        if tokens.count == 1 {
            let normalizedToken = tokens[0].lowercased()
            if normalizedToken == "all" {
                return Set(availableSkills.map(\.id))
            }
            if ["none", "off", "clear", "disabled"].contains(normalizedToken) {
                return []
            }
        }

        var selectedSkillIDs = Set<String>()
        for token in tokens {
            if let index = Int(token),
               availableSkills.indices.contains(index - 1) {
                selectedSkillIDs.insert(availableSkills[index - 1].id)
                continue
            }
            guard let skill = skill(matching: token, in: availableSkills) else {
                throw TerminalSkillSelectionError.unknownToken(token)
            }
            selectedSkillIDs.insert(skill.id)
        }
        return selectedSkillIDs
    }

    public static func skill(
        matching rawToken: String,
        in availableSkills: [PromptSkill]
    ) -> PromptSkill? {
        let token = selectionKey(rawToken)
        guard !token.isEmpty else {
            return nil
        }

        return availableSkills.first { skill in
            token == selectionKey(skill.canonicalName)
                || token == selectionKey(skill.title)
                || skill.sourceHash.hasPrefix(token)
                || skill.id.hasPrefix(token)
        }
    }

    public static func selectionKey(_ value: String) -> String {
        let foldedValue = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let characters = foldedValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(characters)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
