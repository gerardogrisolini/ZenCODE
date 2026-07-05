//
//  TerminalChat+FeatureRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public static func renderFeatureCommandUsage() -> String {
        "Usage: /feature [list|status|reload|enable <id|name|#>|disable <id|name|#>|edit <id|name|#> [requirements]|delete <id|name|#>|build <id|name|#>|validate <id|name|#>]\n"
    }

    public static func renderFeatureBuilderInactiveWarning() -> String {
        renderFeatureCommandUnavailableForAgent()
    }

    public static func renderFeatureCommandUnavailableForAgent() -> String {
        "ZenCODE: /feature is only available with the Builder agent. Switch with /agents Builder.\n"
    }

    public static func renderFeatureWizardCompletion(
        id: String,
        built: Bool,
        enabled: Bool,
        selected: Bool
    ) -> String {
        var actions = ["created", "validated"]
        if built {
            actions.append("built")
        }
        if enabled {
            actions.append("enabled")
        }
        if selected {
            actions.append("selected")
        }

        var lines = ["Feature '\(id)' \(actions.joined(separator: ", "))."]
        if !enabled {
            lines.append("It is not active yet. Enable it from /feature list, then select it from /tools.")
        } else if !selected {
            lines.append("It is enabled. Select it from /tools to expose its tools in this session.")
        } else {
            lines.append("It is active in this session.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func featureImplementationPrompt(
        id: String,
        displayName: String,
        directoryPath: String,
        manifestPath: String,
        sourcePath: String,
        toolName: String,
        requirements: String?
    ) -> String {
        var sections = [
            """
            Implement the Swift feature "\(displayName)" (`\(id)`).

            Feature directory:
            \(directoryPath)

            Main files:
            - Manifest: \(manifestPath)
            - Source: \(sourcePath)
            - Tool: \(toolName)

            Work on the existing Swift package using the available file/text tools.
            Keep Swift tools 6.3, update the tool description and JSON schema if needed, then run `feature.validate` and `feature.build` for `\(id)`.
            If everything passes, enable the feature with `feature.enable` and tell me whether I should select it from `/tools` to try it in the current session.
            """
        ]

        if let requirements {
            sections.append(
                """

                Goal / requirements:
                \(requirements)
                """
            )
        } else {
            sections.append(
                """

                Goal / requirements:
                """
            )
        }

        return sections.joined()
    }

    public static func featureModificationPrompt(
        report: SwiftFeatureEditReport,
        requirements: String?
    ) -> String {
        let sourceList = report.sourcePaths.isEmpty
            ? "- Source files: inspect the package under \(report.directoryPath)"
            : report.sourcePaths.map { "- \($0)" }.joined(separator: "\n")
        let packageLine = report.packagePath.map { "- Package: \($0)" } ?? "- Package: not found; inspect the feature directory"
        let adoptedLine = report.adoptedFrom.map {
            "\nThis is a local editable copy of bundled feature `\($0)`. Do not edit bundled sources directly."
        } ?? ""

        var sections = [
            """
            Modify the Swift feature `\(report.id)`.

            Feature directory:
            \(report.directoryPath)

            Main files:
            - Manifest: \(report.manifestPath)
            \(packageLine)
            - Executable: \(report.executablePath)

            Source files:
            \(sourceList)
            \(adoptedLine)

            Work on the existing package using the available file/text tools. Preserve the feature id and existing tool names unless I explicitly ask to rename them. After edits, run `feature.validate` and `feature.build` for `\(report.id)`, then `feature.reload` if the build passes.
            """
        ]

        if let requirements {
            sections.append(
                """

                Goal / requirements:
                \(requirements)
                """
            )
        } else {
            sections.append(
                """

                Goal / requirements:
                """
            )
        }
        return sections.joined()
    }

    public static func renderFeatureManagementToolOutput(
        name: String,
        output: String
    ) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return ""
        }

        switch name {
        case "feature.scaffold":
            if let report = decodeFeatureOutput(SwiftFeatureScaffoldReport.self, from: trimmedOutput) {
                return """
                Created Swift feature '\(report.id)'.
                  Source: \(report.directoryPath)
                  Tool: \(report.toolName)

                """
            }
        case "feature.validate":
            if let report = decodeFeatureOutput(SwiftFeatureValidationReport.self, from: trimmedOutput) {
                return renderFeatureValidationReport(report)
            }
        case "feature.build":
            if let report = decodeFeatureOutput(SwiftFeatureBuildReport.self, from: trimmedOutput) {
                return renderFeatureBuildReport(report)
            }
        case "feature.install":
            if let report = decodeFeatureOutput(SwiftFeatureInstallReport.self, from: trimmedOutput) {
                return renderFeatureInstallReport(report)
            }
        case "feature.edit", "feature.update":
            if let report = decodeFeatureOutput(SwiftFeatureEditReport.self, from: trimmedOutput) {
                return renderFeatureEditReport(report)
            }
        case "feature.delete":
            if let report = decodeFeatureOutput(SwiftFeatureDeleteReport.self, from: trimmedOutput) {
                return renderFeatureDeleteReport(report)
            }
        case "feature.list", "feature.reload":
            return renderFeatureListToolOutput(name: name, output: trimmedOutput)
        case "feature.enable", "feature.disable":
            return renderFeatureMutationToolOutput(output: trimmedOutput)
        default:
            break
        }

        return trimmedOutput + "\n"
    }

    public static func featureManagementToolSucceeded(
        name: String,
        output: String
    ) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "feature.validate":
            return decodeFeatureOutput(SwiftFeatureValidationReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.build":
            return decodeFeatureOutput(SwiftFeatureBuildReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.install":
            return decodeFeatureOutput(SwiftFeatureInstallReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.edit", "feature.update":
            return decodeFeatureOutput(SwiftFeatureEditReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.delete":
            return decodeFeatureOutput(SwiftFeatureDeleteReport.self, from: trimmedOutput)?.ok ?? true
        default:
            return true
        }
    }

    public static func featureCommandRequiresActiveBuilder(rawArguments _: String) -> Bool {
        true
    }

    static let jiraFeatureID = "jira-tools"

    static func renderFeatureValidationReport(
        _ report: SwiftFeatureValidationReport
    ) -> String {
        let id = report.id ?? "unknown"
        guard report.ok else {
            var lines = ["Validation failed for Swift feature '\(id)'."]
            lines.append(contentsOf: report.errors.map { "  Error: \($0)" })
            return lines.joined(separator: "\n") + "\n"
        }

        let warnings = report.warnings.filter {
            !$0.hasPrefix("Executable has not been built yet:")
        }
        var lines = ["Validated Swift feature '\(id)'."]
        if !warnings.isEmpty {
            lines.append(contentsOf: warnings.map { "  Warning: \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderFeatureBuildReport(
        _ report: SwiftFeatureBuildReport
    ) -> String {
        guard report.ok else {
            var lines = ["Build failed for Swift feature '\(report.id)' (exit code \(report.exitCode))."]
            let error = report.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !error.isEmpty {
                lines.append("  \(truncatedInline(error, limit: 180))")
            }
            return lines.joined(separator: "\n") + "\n"
        }

        return """
        Built Swift feature '\(report.id)'.
          Executable: \(report.executablePath)

        """
    }

    static func renderFeatureInstallReport(
        _ report: SwiftFeatureInstallReport
    ) -> String {
        guard report.ok else {
            return "Install failed for Swift feature '\(report.id)'.\n"
        }
        var states = ["installed"]
        if report.built {
            states.append("built")
        }
        if report.enabled {
            states.append("enabled")
        }
        return """
        Feature '\(report.id)' \(states.joined(separator: ", ")).
          Destination: \(report.destinationPath)

        """
    }

    static func renderFeatureAdoptReport(
        _ report: SwiftFeatureAdoptReport
    ) -> String {
        guard report.ok else {
            return "Could not create a local copy for Swift feature '\(report.id)'.\n"
        }
        return """
        Created local editable copy of Swift feature '\(report.id)' from bundled feature '\(report.adoptedFrom)'.
          Destination: \(report.destinationPath)
          Manifest: \(report.manifestPath)

        """
    }

    static func renderFeatureEditReport(
        _ report: SwiftFeatureEditReport
    ) -> String {
        guard report.ok else {
            return "Edit preparation failed for Swift feature '\(report.id)'.\n"
        }
        var lines = ["Ready to edit Swift feature '\(report.id)'."]
        if report.adopted {
            lines.append("  Local editable copy created first.")
        }
        lines.append("  Directory: \(report.directoryPath)")
        lines.append("  Manifest: \(report.manifestPath)")
        if let packagePath = report.packagePath {
            lines.append("  Package: \(packagePath)")
        }
        if let firstSource = report.sourcePaths.first {
            let extra = report.sourcePaths.count > 1 ? " (+\(report.sourcePaths.count - 1) more)" : ""
            lines.append("  Source: \(firstSource)\(extra)")
        }
        lines.append(contentsOf: report.warnings.map { "  Warning: \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    static func renderFeatureDeleteReport(
        _ report: SwiftFeatureDeleteReport
    ) -> String {
        guard report.ok else {
            return "Delete failed for Swift feature '\(report.id)'.\n"
        }
        return """
        Deleted Swift feature '\(report.id)'.
          Removed: \(report.directoryPath)

        """
    }

    static func renderFeatureListToolOutput(
        name: String,
        output: String
    ) -> String {
        let prefix: String?
        let json: String
        if let jsonStart = output.firstIndex(of: "{") {
            let head = output[..<jsonStart].trimmingCharacters(in: .whitespacesAndNewlines)
            prefix = head.isEmpty ? nil : String(head)
            json = String(output[jsonStart...])
        } else {
            prefix = nil
            json = output
        }

        if let payload = decodeFeatureOutput(TerminalFeatureListPayload.self, from: json) {
            let renderedList = renderFeatureStatusList(payload.features)
            if let prefix {
                return "\(prefix)\n\(renderedList)"
            }
            return renderedList
        }
        return name == "feature.reload"
            ? "Reloaded Swift features.\n"
            : output + "\n"
    }

    static func renderFeatureMutationToolOutput(output: String) -> String {
        guard let firstLine = output.split(separator: "\n").first.map(String.init)?.nilIfBlank else {
            return output + "\n"
        }
        return "\(firstLine)\n"
    }

    static func decodeFeatureOutput<T: Decodable>(
        _ type: T.Type,
        from output: String
    ) -> T? {
        guard let data = output.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func renderFeatureStatusList(
        _ statuses: [SwiftFeatureStatus]
    ) -> String {
        guard !statuses.isEmpty else {
            return "Features: none\n"
        }

        var lines = ["Features:\n"]
        for (offset, status) in statuses.sorted(by: featureStatusSortOrder).enumerated() {
            let availability = status.available ? "" : ", unavailable"
            let state = status.enabled ? "enabled" : "disabled"
            let source = featureSourceSummary(status)
            let tools = featureStatusToolsSummary(status)
            lines.append(
                "  \(offset + 1). \(featureDisplayName(status)) [\(status.id)] - \(state)\(availability), \(source)\(tools)\n"
            )
        }
        lines.append("\nRun /feature list to open the enable/disable menu. Builder-only management remains under /feature.\n")
        return lines.joined()
    }

    static func featureCheckboxItem(_ status: SwiftFeatureStatus) -> TerminalCheckboxMenuItem<String> {
        TerminalCheckboxMenuItem(
            value: status.id,
            title: "\(featureDisplayName(status)) [\(status.id)]",
            detail: featureMenuDetail(status),
            groupTitle: nil
        )
    }

    public static func resolvedFeatureID(
        _ rawValue: String,
        statuses: [SwiftFeatureStatus]
    ) throws -> String {
        let token = normalizedFeatureLookupKey(rawValue)
        guard !token.isEmpty else {
            throw TerminalFeatureCommandError.unknownFeature(rawValue)
        }
        if let index = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           statuses.indices.contains(index - 1) {
            return statuses.sorted(by: featureStatusSortOrder)[index - 1].id
        }

        if let status = statuses.first(where: { status in
            featureLookupKeys(status).contains(token)
        }) {
            return status.id
        }
        throw TerminalFeatureCommandError.unknownFeature(rawValue)
    }

    static func featureWizardDisplayName(from id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    static func featureWizardPrefix(from id: String) -> String {
        let value = id
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let prefix = String(value)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(prefix.nilIfBlank ?? "feature")."
    }

    static func featureWizardArguments(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func featureWizardEnvironment(_ rawValue: String) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in rawValue.split(separator: " ").map(String.init) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  !parts[0].isEmpty else {
                continue
            }
            environment[parts[0]] = parts[1]
        }
        return environment
    }

    static func featureDisplayName(_ status: SwiftFeatureStatus) -> String {
        if let displayName = status.displayName?.nilIfBlank {
            return displayName
        }
        switch status.id {
        case "search-tools":
            return "Search"
        case "web-tools":
            return "Web"
        case "git-tools":
            return "Git"
        case "swift-tools":
            return "Swift"
        case "jira-tools":
            return "Jira"
        case "xcode-tools":
            return "Xcode"
        case "figma-tools":
            return "Figma"
        default:
            return featureWizardDisplayName(from: status.id)
        }
    }

    static func featureMenuDetail(_ status: SwiftFeatureStatus) -> String {
        TerminalToolSelectionCatalog.featureDetail(status)
    }

    static func featureSourceSummary(_ status: SwiftFeatureStatus) -> String {
        if status.adoptedFrom != nil {
            return "local copy"
        }
        if status.source == .bundled {
            return "bundled"
        }
        return status.editable ? "generated, editable" : "generated"
    }

    static func featureLookupKeys(_ status: SwiftFeatureStatus) -> Set<String> {
        var keys: Set<String> = [
            normalizedFeatureLookupKey(status.id),
            normalizedFeatureLookupKey(featureDisplayName(status))
        ]
        if status.id.hasPrefix("mlx-"), status.id.hasSuffix("-tools") {
            let shortID = status.id
                .dropFirst("mlx-".count)
                .dropLast("-tools".count)
            keys.insert(normalizedFeatureLookupKey(String(shortID)))
        }
        return keys.filter { !$0.isEmpty }
    }

    static func normalizedFeatureLookupKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .unicodeScalars
        .map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        .reduce(into: "") { $0.append($1) }
        .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func featureStatusSortOrder(
        lhs: SwiftFeatureStatus,
        rhs: SwiftFeatureStatus
    ) -> Bool {
        return featureDisplayName(lhs).localizedStandardCompare(featureDisplayName(rhs)) == .orderedAscending
    }

    static func featureStatusToolsSummary(_ status: SwiftFeatureStatus) -> String {
        if !status.tools.isEmpty {
            let sample = status.tools.prefix(3).joined(separator: ", ")
            let suffix = status.tools.count > 3 ? ", ..." : ""
            let toolLabel = status.tools.count == 1 ? "tool" : "tools"
            return ", \(status.tools.count) \(toolLabel): \(sample)\(suffix)"
        }
        if status.discoversToolsAtRuntime {
            return ", discovers tools at runtime"
        }
        return ""
    }
}
