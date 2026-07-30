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
    /// One selectable row of the Features step.
    ///
    /// Enabling a feature and reinstalling it from source are different intents
    /// for the same identity, so they are distinct menu values instead of one
    /// ambiguous checkbox: a checked "update" row rebuilds the package, while
    /// the feature's own row keeps expressing whether it should be enabled.
    enum FeatureMenuSelection: Hashable {
        case toggle(String)
        case install(String)
        case update(String)
    }

    /// Actions derived from one pass of the Features menu.
    ///
    /// The plan is computed as a pure value so the interaction between updates
    /// and enable/disable stays testable without a terminal.
    struct FeatureSelectionPlan: Equatable {
        var idsToUpdate: Set<String> = []
        var idsToInstall: Set<String> = []
        var idsToEnable: Set<String> = []
        var idsToDisable: Set<String> = []
        /// Enabled state requested for the features that are being reinstalled.
        var enabledAfterUpdate: Set<String> = []
    }

    /// Splits the menu result into the concrete actions the setup step performs.
    ///
    /// A reinstall rewrites the feature manifest, so it also decides the enabled
    /// state of what it installs. Updated identities are therefore removed from
    /// the enable/disable sets, leaving a single writer per feature.
    static func featureSelectionPlan(
        requested: Set<FeatureMenuSelection>,
        enabledIDs: Set<String>
    ) -> FeatureSelectionPlan {
        var requestedToggleIDs = Set<String>()
        var plan = FeatureSelectionPlan()

        for selection in requested {
            switch selection {
            case let .toggle(id):
                requestedToggleIDs.insert(id)
            case let .install(id):
                plan.idsToInstall.insert(id)
            case let .update(id):
                plan.idsToUpdate.insert(id)
            }
        }

        plan.enabledAfterUpdate = plan.idsToUpdate.intersection(requestedToggleIDs)
        plan.idsToEnable = requestedToggleIDs
            .subtracting(enabledIDs)
            .subtracting(plan.idsToUpdate)
        plan.idsToDisable = enabledIDs
            .subtracting(requestedToggleIDs)
            .subtracting(plan.idsToUpdate)
        return plan
    }

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
        let updatableOptionalFeatures = optionalFeatures
            .filter { $0.installed && $0.supportedOnCurrentPlatform }
            .sorted(by: optionalFeatureSortOrder)

        guard !sortedStatuses.isEmpty
                || !installableOptionalFeatures.isEmpty
                || !updatableOptionalFeatures.isEmpty else {
            AgentOutput.standardError.writeString("No Swift features found.\n")
            return
        }

        let enabledIDs = Set(sortedStatuses.filter(\.enabled).map(\.id))
        let menuItems = sortedStatuses.map(featureCheckboxItem)
            + installableOptionalFeatures.map(optionalFeatureCheckboxItem)
            + updatableOptionalFeatures.map(updatableFeatureCheckboxItem)
        guard let requestedSelections = TerminalCheckboxMenu.select(
            title: "Features",
            items: menuItems,
            selected: Set(enabledIDs.map(FeatureMenuSelection.toggle))
        ) else {
            return
        }

        let plan = featureSelectionPlan(
            requested: requestedSelections,
            enabledIDs: enabledIDs
        )

        var didChange = false
        for feature in updatableOptionalFeatures where plan.idsToUpdate.contains(feature.id) {
            AgentOutput.standardError.writeString(
                "Updating optional feature \(feature.id) from source…\n"
            )
            let didUpdate = await installOptionalFeature(
                id: feature.id,
                enable: plan.enabledAfterUpdate.contains(feature.id),
                isUpdate: true,
                runtime: runtime
            )
            didChange = didChange || didUpdate
        }
        for status in sortedStatuses where plan.idsToEnable.contains(status.id) {
            try await setFeature(status.id, enabled: true, runtime: runtime)
            didChange = true
        }
        let installableIDs = Set(installableOptionalFeatures.map(\.id))
        for id in plan.idsToInstall.intersection(installableIDs) {
            AgentOutput.standardError.writeString("Installing optional feature \(id)…\n")
            let didInstall = await installOptionalFeature(
                id: id,
                enable: true,
                isUpdate: false,
                runtime: runtime
            )
            didChange = didChange || didInstall
        }
        for status in sortedStatuses where plan.idsToDisable.contains(status.id) {
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

    /// Copies an optional feature package from the resolved ZenCODE checkout and
    /// rebuilds it. The same call installs a missing feature and updates an
    /// installed one, because the runtime always materializes the package with
    /// `overwrite` and rebuilds its release product.
    private static func installOptionalFeature(
        id: String,
        enable: Bool,
        isUpdate: Bool,
        runtime: SwiftFeatureRuntime
    ) async -> Bool {
        let verb = isUpdate ? "update" : "install"
        do {
            let report = try await runtime.installOptionalFeature(id: id, enable: enable)
            guard report.ok else {
                let details = report.errors.isEmpty
                    ? "The build or enable step did not complete."
                    : report.errors.joined(separator: " ")
                AgentOutput.standardError.writeString(
                    "Could not \(verb) optional feature \(id): \(details) " +
                    "Retry from a ZenCODE checkout or pass --zen-package-path to zen --install-features.\n"
                )
                // A failed materialization still replaced the package contents,
                // so report it as a change rather than claiming nothing moved.
                return report.copied
            }
            AgentOutput.standardError.writeString(
                enable
                    ? "\(isUpdate ? "Updated" : "Installed") and enabled \(report.productName).\n"
                    : "\(isUpdate ? "Updated" : "Installed") \(report.productName); it stays disabled.\n"
            )
            return true
        } catch {
            AgentOutput.standardError.writeString(
                "Could not \(verb) optional feature \(id): \(error.localizedDescription) " +
                "Retry from a ZenCODE checkout or pass --zen-package-path to zen --install-features.\n"
            )
            return false
        }
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

    private static func featureCheckboxItem(
        _ status: SwiftFeatureStatus
    ) -> TerminalCheckboxMenuItem<FeatureMenuSelection> {
        TerminalCheckboxMenuItem(
            value: .toggle(status.id),
            title: "\(featureDisplayName(status)) [\(status.id)]",
            detail: featureMenuDetail(status),
            groupTitle: status.source == .bundled ? "Bundled" : "Generated"
        )
    }

    private static func optionalFeatureCheckboxItem(
        _ feature: SwiftFeatureOptionalFeature
    ) -> TerminalCheckboxMenuItem<FeatureMenuSelection> {
        TerminalCheckboxMenuItem(
            value: .install(feature.id),
            title: "\(feature.displayName) [\(feature.id)]",
            detail: "\(feature.description) — not installed",
            groupTitle: "Installable"
        )
    }

    private static func updatableFeatureCheckboxItem(
        _ feature: SwiftFeatureOptionalFeature
    ) -> TerminalCheckboxMenuItem<FeatureMenuSelection> {
        TerminalCheckboxMenuItem(
            value: .update(feature.id),
            title: "\(feature.displayName) [\(feature.id)]",
            detail: "reinstall from the current ZenCODE source and rebuild — \(featureInstallationState(feature))",
            groupTitle: "Update installed"
        )
    }

    private static func featureInstallationState(
        _ feature: SwiftFeatureOptionalFeature
    ) -> String {
        if feature.enabled {
            return "installed and enabled"
        }
        if feature.built {
            return "installed; disabled"
        }
        return "installed; build required"
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
