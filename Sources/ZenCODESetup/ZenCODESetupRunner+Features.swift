//
//  ZenCODESetupRunner+Features.swift
//  ZenCODE
//
//  Created by ZenCODE on 21/06/26.
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func configureFeatures() async throws {
        let runtime = SwiftFeatureRuntime()
        let statuses = await runtime.featureStatuses(
            includeTools: true,
            includeDisabled: true
        )
        let sortedStatuses = statuses.sorted(by: featureStatusSortOrder)
        guard !sortedStatuses.isEmpty else {
            AgentOutput.standardError.writeString("No Swift features found.\n")
            return
        }

        let selectedIDs = Set(sortedStatuses.filter(\.enabled).map(\.id))
        guard let requestedIDs = TerminalCheckboxMenu.select(
            title: "Features",
            items: sortedStatuses.map(featureCheckboxItem),
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

    private static func featureMenuDetail(_ status: SwiftFeatureStatus) -> String {
        var parts = [status.enabled ? "enabled" : "disabled"]
        if !status.available {
            parts.append("unavailable")
        }
        if !status.tools.isEmpty {
            parts.append("tools: \(status.tools.sorted().joined(separator: ", "))")
        } else if status.discoversToolsAtRuntime {
            parts.append("tools discovered at runtime")
        } else {
            parts.append("no tools")
        }
        if let description = status.description?.nilIfBlank {
            parts.append(description)
        }
        return parts.joined(separator: " · ")
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

    private static func escapedJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return value
        }
        return String(encoded.dropFirst().dropLast())
    }
}
