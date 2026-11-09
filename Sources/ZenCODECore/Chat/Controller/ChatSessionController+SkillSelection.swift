//
//  ChatSessionController+SkillSelection.swift
//  ZenCODE
//
//  Prompt-skill selection: the skill menu, `/skills`, install and uninstall,
//  and the install sources.
//

import Foundation

extension ChatSessionController {
    // MARK: - Skills

    /// The menu entries of the installed prompt skills.
    func skillChoiceItems() -> [ChatChoiceItem] {
        availableSkills().map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return ChatChoiceItem(
                id: skill.id,
                title: "\(skill.title)\(canonicalName)",
                detail: InlineTextTruncation.truncatedInline(skill.summary, limit: 96)
            )
        }
    }

    /// The skill menu: every installed prompt skill, the selected ones
    /// ticked.
    func skillChoices() -> ChatChoiceList {
        ChatChoiceList(
            title: "Prompt skills",
            items: skillChoiceItems(),
            selectedIDs: selection.skillIDs
        )
    }

    /// `/skills`: asks the host for the prompt skills and applies them.
    public func chooseSkills() async -> ChatSelectionOutcome {
        guard host.capabilities.contains(.multipleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.skillSelection(selected: selectedPromptSkills())),
            ])
        }

        let choices = skillChoices()
        guard !choices.items.isEmpty else {
            return ChatSelectionOutcome(notices: [
                .noPromptSkillsInstalled,
                .selectedSkills(selectedPromptSkills()),
            ])
        }
        guard let selectedSkillIDs = await host.chooseMany(
            title: choices.title,
            items: choices.items,
            selectedIDs: choices.selectedIDs
        ) else {
            return ChatSelectionOutcome(notices: [.selectedSkills(selectedPromptSkills())])
        }
        return await selectSkills(ids: selectedSkillIDs)
    }

    /// Selects the prompt skills `rawSelection` names (`all`, `none`, names,
    /// numbers).
    public func selectSkills(rawSelection: String) async throws -> ChatSelectionOutcome {
        let selectedSkillIDs = try Self.parseSkillSelection(
            rawSelection,
            availableSkills: availableSkills()
        )
        return await selectSkills(ids: selectedSkillIDs)
    }

    /// Selects the prompt skills `ids`.
    public func selectSkills(ids: Set<String>) async -> ChatSelectionOutcome {
        selection.skillIDs = ids
        await presentSessionStateChanged()
        await updateRuntimePromptSkills()
        return ChatSelectionOutcome(
            change: .sessionUpdated,
            notices: [.selectedSkills(selectedPromptSkills())]
        )
    }

    /// Hands the selected prompt skills to the session. Selection is
    /// session-scoped, mutable state: updating it must not touch the system
    /// prompt, allowlist, cache key, or history, so the remote continuation
    /// and KV-cache prefix stay valid.
    private func updateRuntimePromptSkills() async {
        await managementRuntime?.updatePromptSkillSelection(
            selectedPromptSkills(),
            sessionID: sessionID
        )
    }

    /// Where a skill is installed from.
    enum SkillInstallSource: Sendable, Equatable {
        /// A GitHub repository or folder URL.
        case gitHub(URL)
        /// A local skill folder or `SKILL.md` file.
        case local(URL)
    }

    /// Installs the skill at `source` (a GitHub URL, or a local path that a
    /// relative form resolves against ``workingDirectory``) and selects it.
    public func installSkill(source: String) async -> ChatSelectionOutcome {
        guard let installSource = Self.skillInstallSource(
            source,
            workingDirectory: workingDirectory
        ) else {
            return ChatSelectionOutcome(notices: [
                .skillInstallSourceRequired,
                .skillSelectionUsage,
            ])
        }
        return await installSkill(from: installSource)
    }

    func installSkill(from source: SkillInstallSource) async -> ChatSelectionOutcome {
        let result: PromptSkillInstallResult
        do {
            switch source {
            case let .gitHub(url):
                await effectivePresenter(for: nil).presentSessionNotice(
                    .skillInstallStarted(source: url.absoluteString)
                )
                result = try await PromptSkillInstaller.install(fromGitHubURL: url)
            case let .local(url):
                await effectivePresenter(for: nil).presentSessionNotice(.skillInstallStarted(source: url.path))
                result = try PromptSkillInstaller.install(fromLocalURL: url)
            }
        } catch {
            return ChatSelectionOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
                .skillSelectionUsage,
            ])
        }

        availableSkillsCache = nil
        selection.skillIDs.insert(result.skill.id)
        await presentSessionStateChanged()
        await updateRuntimePromptSkills()
        return ChatSelectionOutcome(
            change: .sessionUpdated,
            notices: [.skillInstalled(result.skill)]
        )
    }

    /// `/skills uninstall`: asks the host which installed skills to remove
    /// and uninstalls them. A cancelled menu presents nothing.
    public func chooseSkillsToUninstall() async -> ChatSelectionOutcome {
        guard host.capabilities.contains(.multipleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.skillUninstall),
                .skillSelectionUsage,
            ])
        }

        guard !availableSkills().isEmpty else {
            return ChatSelectionOutcome(notices: [.noPromptSkillsInstalled])
        }
        guard let selectedSkillIDs = await host.chooseMany(
            title: "Uninstall prompt skills",
            items: skillChoiceItems(),
            selectedIDs: []
        ) else {
            return ChatSelectionOutcome()
        }
        return await uninstallSkills(ids: selectedSkillIDs)
    }

    /// Uninstalls the installed skills `ids` and deselects them.
    public func uninstallSkills(ids: Set<String>) async -> ChatSelectionOutcome {
        let selectedSkills = availableSkills().filter { ids.contains($0.id) }
        guard !selectedSkills.isEmpty else {
            return ChatSelectionOutcome(notices: [.noSkillsSelectedForUninstall])
        }

        do {
            try PromptSkillInstaller.uninstall(skills: selectedSkills)
        } catch {
            return ChatSelectionOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
                .skillSelectionUsage,
            ])
        }
        availableSkillsCache = nil
        selection.skillIDs.subtract(ids)
        await presentSessionStateChanged()
        await updateRuntimePromptSkills()
        return ChatSelectionOutcome(
            change: .sessionUpdated,
            notices: [.skillsUninstalled(selectedSkills)]
        )
    }

    // MARK: - Skill install sources

    /// The install source `value` names: a GitHub URL, else a local path
    /// (absolute, `~/`, `file://`, or relative to `workingDirectory` when it
    /// starts with `.` or `..`).
    nonisolated static func skillInstallSource(
        _ value: String,
        workingDirectory: URL
    ) -> SkillInstallSource? {
        if let url = gitHubSkillInstallURL(value: value) {
            return .gitHub(url)
        }
        if let url = localSkillInstallURL(value: value, baseDirectory: workingDirectory) {
            return .local(url)
        }
        return nil
    }

    nonisolated static func gitHubSkillInstallURL(value: String) -> URL? {
        guard let urlToken = value.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            return nil
        }

        guard let url = URL(string: urlToken),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        return url
    }

    nonisolated static func localSkillInstallURL(
        value: String,
        baseDirectory: URL
    ) -> URL? {
        if value.lowercased().hasPrefix("file://"),
           let url = URL(string: value),
           url.isFileURL {
            return url.standardizedFileURL
        }

        if value.hasPrefix("~/") {
            let expandedPath = NSString(string: value).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: true)
                .standardizedFileURL
        }

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
                .standardizedFileURL
        }

        if value == "."
            || value == ".."
            || value.hasPrefix("./")
            || value.hasPrefix("../") {
            return baseDirectory
                .appendingPathComponent(value, isDirectory: true)
                .standardizedFileURL
        }

        return nil
    }

    /// The install value of `/skills` arguments: what follows `install` or
    /// `add`, or the whole argument without that keyword. `nil` when there
    /// is none.
    nonisolated static func skillInstallValue(from rawArguments: String) -> String? {
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

    nonisolated static func isSkillInstallRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments
            .split { $0.isWhitespace }
        guard let command = tokens.first?.lowercased() else {
            return false
        }
        return ["install", "add"].contains(command)
    }

    nonisolated static func isSkillUninstallRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments
            .split { $0.isWhitespace }
        return tokens.count == 1 && tokens[0].lowercased() == "uninstall"
    }
}
