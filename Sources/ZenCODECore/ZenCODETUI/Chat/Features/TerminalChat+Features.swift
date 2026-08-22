//
//  TerminalChat+Features.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

enum TerminalFeatureCommandResult: Sendable {
    case none
    case runPrompt(String)
    case prefillPrompt(String)
}

extension TerminalChat {
    func handleFeatureCommand(_ command: String) async -> TerminalFeatureCommandResult {
        let rawArguments = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/feature"
        )

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await runFeatureManagementTool(
                    name: "feature.list",
                    arguments: ["includeTools": true]
                )
                await writeSystemMessage(Self.renderFeatureCommandUsage())
                return .none
            }
            return await runFeatureWizard()
        }

        var tokens = rawArguments.split(separator: " ").map(String.init)
        let action = tokens.removeFirst().lowercased()
        switch action {
        case "list", "ls":
            guard tokens.isEmpty else {
                await writeFailureMessage("ZenCODE: /feature \(action) does not accept arguments.\n")
                await writeSystemMessage(Self.renderFeatureCommandUsage())
                return .none
            }
            await openFeatureSelectionMenu()
            return .none
        case "status":
            await printFeatureList()
            return .none
        case "reload":
            await runFeatureManagementTool(
                name: "feature.reload",
                arguments: ["includeTools": true]
            )
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
            await printFeatureList()
            return .none
        case "edit", "modify", "update":
            guard let id = await resolveFeatureIDOrReport(action: action, rawID: tokens.first) else {
                return .none
            }
            let requirements = tokens.dropFirst().joined(separator: " ").nilIfBlank
            guard let output = await executeFeatureManagementTool(
                name: "feature.edit",
                arguments: ["id": id]
            ) else {
                return .none
            }
            await writeSystemMessage(Self.renderFeatureManagementToolOutput(name: "feature.edit", output: output))
            guard let report = Self.decodeFeatureOutput(
                SwiftFeatureEditReport.self,
                from: output.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                await writeFailureMessage("ZenCODE: could not decode the feature.edit report.\n")
                return .none
            }
            if report.adopt != nil {
                await updateCurrentSessionToolOptions(discoverExternalTools: false)
                await printFeatureList()
            }
            return Self.featurePromptResult(
                Self.featureModificationPrompt(
                    report: report,
                    requirements: requirements
                ),
                requirements: requirements
            )
        case "promote":
            guard let id = await resolveFeatureIDOrReport(action: action, rawID: tokens.first) else {
                return .none
            }
            var arguments: [String: Any] = ["id": id]
            let remainder = Array(tokens.dropFirst())
            var index = 0
            while index < remainder.count {
                let token = remainder[index]
                switch token {
                case "--repository", "--repository-path", "--checkout", "--checkout-path":
                    guard index + 1 < remainder.count else {
                        await writeFailureMessage("ZenCODE: /feature promote requires a path after \(token).\n")
                        return .none
                    }
                    arguments["repository"] = remainder[index + 1]
                    index += 2
                case "--overwrite", "--replace":
                    arguments["overwrite"] = true
                    index += 1
                case "--no-build":
                    arguments["build"] = false
                    index += 1
                case "--linux":
                    arguments["linux"] = true
                    index += 1
                case "--no-linux":
                    arguments["linux"] = false
                    index += 1
                default:
                    await writeFailureMessage("ZenCODE: unknown /feature promote option '\(token)'.\n")
                    return .none
                }
            }
            guard arguments["linux"] != nil else {
                await writeFailureMessage(
                    "ZenCODE: /feature promote requires an explicit --linux or --no-linux decision.\n"
                )
                return .none
            }
            if stdinIsTerminal {
                guard await promptFeatureYesNo(
                    "Promote '\(id)' into the ZenCODE Git checkout? This writes package and catalog files but never commits or pushes.",
                    defaultValue: false
                ) == true else {
                    await writeSystemMessage("Feature promotion cancelled.\n")
                    return .none
                }
            }
            let didSucceed = await runFeatureManagementTool(
                name: "feature.promote",
                arguments: arguments
            )
            if didSucceed {
                await updateCurrentSessionToolOptions(discoverExternalTools: false)
                await printFeatureList()
            }
            return .none
        case "enable", "disable", "delete", "build", "validate":
            guard let id = await resolveFeatureIDOrReport(action: action, rawID: tokens.first) else {
                return .none
            }
            if action == "delete", stdinIsTerminal {
                guard await promptFeatureYesNo(
                    "Delete generated feature '\(id)' permanently?",
                    defaultValue: false
                ) == true else {
                    await writeSystemMessage("Feature deletion cancelled.\n")
                    return .none
                }
            }
            let didSucceed: Bool
            switch action {
            case "enable", "disable":
                didSucceed = await setFeatureEnabled(id: id, enabled: action == "enable")
            default:
                didSucceed = await runFeatureManagementTool(
                    name: "feature.\(action)",
                    arguments: ["id": id]
                )
                if didSucceed, action == "delete" {
                    selectedToolKeys.remove(TerminalToolSelectionCatalog.featurePackageKey(id: id))
                }
            }
            if didSucceed, action != "validate" {
                await updateCurrentSessionToolOptions(discoverExternalTools: false)
                await printFeatureList()
            }
            return .none
        default:
            await writeFailureMessage("ZenCODE: unknown /feature command '\(action)'.\n")
            await writeSystemMessage(Self.renderFeatureCommandUsage())
            return .none
        }
    }

    nonisolated static func featurePromptResult(
        _ prompt: String,
        requirements: String?
    ) -> TerminalFeatureCommandResult {
        requirements != nil ? .runPrompt(prompt) : .prefillPrompt(prompt)
    }

    private func resolveFeatureIDOrReport(
        action: String,
        rawID: String?
    ) async -> String? {
        guard let rawID = rawID?.nilIfBlank else {
            await writeFailureMessage("ZenCODE: /feature \(action) requires a feature id, name, or list number.\n")
            await writeSystemMessage(Self.renderFeatureCommandUsage())
            return nil
        }
        do {
            return try await resolvedFeatureID(rawID)
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return nil
        }
    }

    private func printFeatureList() async {
        let statuses = await featureRuntime.featureStatuses(
            includeTools: true,
            includeDisabled: true
        )
        await writeSystemMessage(Self.renderFeatureStatusList(statuses))
    }

    private func openFeatureSelectionMenu() async {
        guard stdinIsTerminal else {
            await writeFailureMessage("ZenCODE: /feature list requires an interactive terminal.\n")
            return
        }

        let statuses = await featureRuntime.featureStatuses(
            includeTools: true,
            includeDisabled: true
        )
        let sortedStatuses = statuses.sorted(by: Self.featureStatusSortOrder)
        let selectedIDs = Set(sortedStatuses.filter(\.enabled).map(\.id))
        let requestedIDs = await TerminalCheckboxMenu.selectOffActor(
            title: "Features",
            items: sortedStatuses.map(Self.featureCheckboxItem),
            selected: selectedIDs,
            reservedBottomRows: await statusBar.reservedRowsForOverlay()
        )
        if let requestedIDs {
            await applyFeatureSelection(
                requestedIDs: requestedIDs,
                statuses: sortedStatuses
            )
        }
    }

    private func applyFeatureSelection(
        requestedIDs: Set<String>,
        statuses: [SwiftFeatureStatus]
    ) async {
        let enabledIDs = Set(statuses.filter(\.enabled).map(\.id))
        let idsToEnable = requestedIDs.subtracting(enabledIDs)
        let idsToDisable = enabledIDs.subtracting(requestedIDs)

        var changed = false
        for status in statuses where idsToEnable.contains(status.id) {
            changed = await setFeatureEnabled(
                id: status.id,
                enabled: true
            ) || changed
        }
        for status in statuses where idsToDisable.contains(status.id) {
            changed = await setFeatureEnabled(id: status.id, enabled: false) || changed
        }

        if changed {
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
        }
    }

    @discardableResult
    private func setFeatureEnabled(
        id: String,
        enabled: Bool
    ) async -> Bool {
        let didSucceed = await runFeatureManagementTool(
            name: enabled ? "feature.enable" : "feature.disable",
            arguments: ["id": id]
        )
        guard didSucceed else {
            return false
        }

        if !enabled {
            selectedToolKeys.remove(TerminalToolSelectionCatalog.featurePackageKey(id: id))
        }
        return true
    }

    private func resolvedFeatureID(_ rawValue: String) async throws -> String {
        let statuses = await featureRuntime.featureStatuses(
            includeTools: false,
            includeDisabled: true
        )
        return try Self.resolvedFeatureID(rawValue, statuses: statuses)
    }

}
