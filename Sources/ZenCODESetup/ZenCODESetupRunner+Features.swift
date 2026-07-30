//
//  ZenCODESetupRunner+Features.swift
//  ZenCODE
//
//  Created by ZenCODE on 21/06/26.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenCODESetupRunner {
    static func configureFeatures() async throws {
        let runtime = SwiftFeatureRuntime()
        let statuses = await runtime.featureStatuses(
            includeTools: true,
            includeDisabled: true
        )
        let optionalFeatures = SwiftFeatureRuntime.optionalFeatures()
        let optionalFeaturesByID = Dictionary(
            uniqueKeysWithValues: optionalFeatures.map { ($0.id, $0) }
        )
        let optionalFeatureIDs = Set(optionalFeatures.map(\.id))
        let sortedStatuses = statuses
            .filter { status in
                guard optionalFeatureIDs.contains(status.id) else {
                    return true
                }
                return optionalFeaturesByID[status.id]?.installed == true
            }
            .sorted(by: featureStatusSortOrder)
        let installableOptionalFeatures = optionalFeatures
            .filter { !$0.installed && $0.supportedOnCurrentPlatform }
            .sorted(by: optionalFeatureSortOrder)

        guard !sortedStatuses.isEmpty || !installableOptionalFeatures.isEmpty else {
            AgentOutput.standardError.writeString("No Swift features found.\n")
            return
        }

        let selectedIDs = Set(sortedStatuses.filter(\.enabled).map(\.id))
        let menuItems = sortedStatuses.map(featureCheckboxItem)
            + installableOptionalFeatures.map(optionalFeatureCheckboxItem)
        guard let requestedIDs = TerminalCheckboxMenu.select(
            title: "Features",
            items: menuItems,
            selected: selectedIDs
        ) else {
            return
        }

        let enabledIDs = Set(sortedStatuses.filter(\.enabled).map(\.id))
        let idsToEnable = requestedIDs.subtracting(enabledIDs)
        let idsToDisable = enabledIDs.subtracting(requestedIDs)

        var didChange = false
        for status in sortedStatuses where idsToEnable.contains(status.id) {
            try await setFeature(status.id, enabled: true, runtime: runtime)
            didChange = true
        }
        let installableIDs = Set(installableOptionalFeatures.map(\.id))
        for id in requestedIDs.intersection(installableIDs) {
            AgentOutput.standardError.writeString("Installing optional feature \(id)…\n")
            do {
                let report = try await runtime.installOptionalFeature(id: id)
                if report.ok {
                    AgentOutput.standardError.writeString("Installed and enabled \(report.productName).\n")
                    didChange = true
                } else {
                    let details = report.errors.isEmpty
                        ? "The build or enable step did not complete."
                        : report.errors.joined(separator: " ")
                    AgentOutput.standardError.writeString(
                        "Could not install optional feature \(id): \(details) " +
                        "Retry from a ZenCODE checkout or pass --zen-package-path to zen --install-features.\n"
                    )
                }
            } catch {
                AgentOutput.standardError.writeString(
                    "Could not install optional feature \(id): \(error.localizedDescription) " +
                    "Retry from a ZenCODE checkout or pass --zen-package-path to zen --install-features.\n"
                )
            }
        }
        for status in sortedStatuses where idsToDisable.contains(status.id) {
            try await setFeature(status.id, enabled: false, runtime: runtime)
            didChange = true
        }

        if didChange {
            AgentOutput.standardError.writeString("Features updated. Changes will be available in new sessions.\n")
        } else {
            AgentOutput.standardError.writeString("Features unchanged.\n")
        }
    }

    static func featuresSetupDetail() -> String {
        let statuses = SwiftFeatureRuntime.defaultFeatureStatuses()
        guard !statuses.isEmpty else {
            return "none"
        }
        let enabledCount = statuses.filter(\.enabled).count
        let availableCount = statuses.filter(\.available).count
        return "\(enabledCount) enabled, \(availableCount) available"
    }

    static func featuresAreEnabled() -> Bool {
        SwiftFeatureRuntime.defaultFeatureStatuses().contains(where: \.enabled)
    }

    private static func setFeature(
        _ id: String,
        enabled: Bool,
        runtime: SwiftFeatureRuntime
    ) async throws {
        _ = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "setup-feature-\(enabled ? "enable" : "disable")-\(UUID().uuidString)",
                name: enabled ? "feature.enable" : "feature.disable",
                argumentsObject: ["id": id],
                argumentsJSON: "{\"id\":\"\(escapedJSONString(id))\"}"
            )
        )
    }

    private static func featureCheckboxItem(_ status: SwiftFeatureStatus) -> TerminalCheckboxMenuItem<String> {
        TerminalCheckboxMenuItem(
            value: status.id,
            title: "\(featureDisplayName(status)) [\(status.id)]",
            detail: featureMenuDetail(status),
            groupTitle: status.source == .bundled ? "Bundled" : "Generated"
        )
    }

    private static func optionalFeatureCheckboxItem(
        _ feature: SwiftFeatureOptionalFeature
    ) -> TerminalCheckboxMenuItem<String> {
        TerminalCheckboxMenuItem(
            value: feature.id,
            title: "\(feature.displayName) [\(feature.id)]",
            detail: "\(feature.description) — not installed",
            groupTitle: "Installable"
        )
    }

    private static func featureMenuDetail(_ status: SwiftFeatureStatus) -> String {
        TerminalToolSelectionCatalog.featureDetail(status)
    }

    private static func featureDisplayName(_ status: SwiftFeatureStatus) -> String {
        status.displayName?.nilIfBlank ?? status.id
    }

    private static func featureStatusSortOrder(
        _ lhs: SwiftFeatureStatus,
        _ rhs: SwiftFeatureStatus
    ) -> Bool {
        if lhs.source != rhs.source {
            return lhs.source == .bundled
        }
        return featureDisplayName(lhs).localizedCaseInsensitiveCompare(featureDisplayName(rhs)) == .orderedAscending
    }

    private static func optionalFeatureSortOrder(
        _ lhs: SwiftFeatureOptionalFeature,
        _ rhs: SwiftFeatureOptionalFeature
    ) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func escapedJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return value
        }
        return String(encoded.dropFirst().dropLast())
    }
}
