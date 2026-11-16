//
//  TerminalChat+FeatureToolOutput.swift
//  ZenCODE
//
//  Rendering of the Swift feature management tool outputs: the decoded
//  scaffold, validation, build, install, promotion, edit and delete reports
//  and the list and mutation outputs.
//

import Foundation
import ToolCore

extension TerminalChat {
    public nonisolated static func renderFeatureManagementToolOutput(
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
                return renderFeatureScaffoldReport(report)
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
        case "feature.promote":
            if let report = decodeFeatureOutput(SwiftFeaturePromotionReport.self, from: trimmedOutput) {
                return renderFeaturePromotionReport(report)
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

    public nonisolated static func featureManagementToolSucceeded(
        name: String,
        output: String
    ) -> Bool {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "feature.validate":
            return decodeFeatureOutput(SwiftFeatureValidationReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.scaffold":
            return decodeFeatureOutput(SwiftFeatureScaffoldReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.build":
            return decodeFeatureOutput(SwiftFeatureBuildReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.install":
            return decodeFeatureOutput(SwiftFeatureInstallReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.edit", "feature.update":
            return decodeFeatureOutput(SwiftFeatureEditReport.self, from: trimmedOutput)?.ok ?? true
        case "feature.promote":
            return decodeFeatureOutput(SwiftFeaturePromotionReport.self, from: trimmedOutput)?.ok ?? true
        default:
            return true
        }
    }

    nonisolated static func renderFeatureScaffoldReport(
        _ report: SwiftFeatureScaffoldReport
    ) -> String {
        var lines = [
            "Created Swift feature '\(report.id)'.",
            "  Source: \(report.directoryPath)",
            "  Tool: \(report.toolName)"
        ]
        if let validation = report.validation, !validation.ok {
            lines.append("  Validation failed.")
            lines.append(contentsOf: validation.errors.map { "  Error: \($0)" })
        }
        if let build = report.build {
            if build.ok {
                lines.append("  Executable: \(build.executablePath)")
            } else {
                lines.append("  Build failed (exit code \(build.exitCode)).")
                let error = build.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !error.isEmpty {
                    lines.append("  \(truncatedInline(error, limit: 180))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    nonisolated static func renderFeatureValidationReport(
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

    nonisolated static func renderFeatureBuildReport(
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

    nonisolated static func renderFeatureInstallReport(
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

    nonisolated static func renderFeaturePromotionReport(
        _ report: SwiftFeaturePromotionReport
    ) -> String {
        var lines = [
            "Promoted Swift feature '\(report.id)'.",
            "  Destination: \(report.destinationPath)",
            "  Distribution manifest: \(report.manifestPath)",
            "  Git checkout: \(report.gitRoot) [\(report.gitBranch ?? "detached")]"
        ]
        if report.built {
            lines.append("  Preflight build and --list-tools succeeded (\(report.listedTools.count) tools).")
        }
        if !report.changedPaths.isEmpty {
            lines.append("  Git changes: \(report.changedPaths.joined(separator: ", "))")
        }
        lines.append(contentsOf: report.warnings.map { "  Warning: \($0)" })
        return lines.joined(separator: "\n") + "\n\n"
    }

    nonisolated static func renderFeatureEditReport(
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

    nonisolated static func renderFeatureDeleteReport(
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

    nonisolated static func renderFeatureListToolOutput(
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

    nonisolated static func renderFeatureMutationToolOutput(output: String) -> String {
        guard let firstLine = output.split(separator: "\n").first.map(String.init)?.nilIfBlank else {
            return output + "\n"
        }
        return "\(firstLine)\n"
    }

    nonisolated static func decodeFeatureOutput<T: Decodable>(
        _ type: T.Type,
        from output: String
    ) -> T? {
        guard let data = output.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
