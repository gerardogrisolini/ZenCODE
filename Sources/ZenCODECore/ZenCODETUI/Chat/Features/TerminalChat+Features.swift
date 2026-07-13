//
//  TerminalChat+Features.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

enum TerminalFeatureCommandResult: Sendable {
    case none
    case runPrompt(String)
    case prefillPrompt(String)
}

extension TerminalChat {
    func handleFeatureCommand(_ command: String) async -> TerminalFeatureCommandResult {
        let rawArguments = String(command.dropFirst("/feature".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

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
        case "enable", "disable", "delete", "build", "validate":
            guard let id = await resolveFeatureIDOrReport(action: action, rawID: tokens.first) else {
                return .none
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

    static func featurePromptResult(
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
        let requestedIDs = TerminalCheckboxMenu.select(
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
