//
//  ZenCODEOptionalFeatureInstaller.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore

/// Standalone CLI entry point for copying optional feature packages out of a
/// ZenCODE checkout and building them under the user's local feature root.
///
/// The actual materialization, manifest generation, build and enable work is
/// deliberately owned by `SwiftFeatureRuntime.installOptionalFeature`. Keeping
/// this layer limited to parsing, selection and presentation lets the setup
/// wizard and the installer use the exact same feature lifecycle.
enum ZenCODEOptionalFeatureInstaller {
    private static let option = "--install-features"
    private static let noFeaturesOption = "--no-features"
    private static let zenPackagePathOption = "--zen-package-path"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains { argument in
            argument == option || argument.hasPrefix("\(option)=")
        }
    }

    static func run(arguments: [String]) async -> Int32 {
        switch parse(arguments: arguments) {
        case .invalid(let message):
            writeMessage("ZenCODE: \(message)\n")
            writeMessage("Usage: zen --install-features [id,id,...] [--no-features] [--zen-package-path DIR]\n")
            return 2
        case .request(let request):
            return await run(request: request)
        }
    }

    private static func run(request: Request) async -> Int32 {
        if request.skipInstallation {
            writeMessage("Optional feature installation skipped (--no-features).\n")
            return 0
        }

        let runtime = SwiftFeatureRuntime()
        let availableFeatures = SwiftFeatureRuntime.optionalFeatures()
            .filter(\.supportedOnCurrentPlatform)
            .sorted(by: featureSortOrder)

        var ids = request.ids
        let requestedExplicitly = !ids.isEmpty
        if ids.isEmpty {
            guard standardInputIsTerminal() else {
                writeMessage(
                    "No optional feature ids were supplied because standard input is not a terminal. " +
                    "Run 'zen --install-features git-tools --zen-package-path <ZenCODE checkout>' to install a feature.\n"
                )
                return 0
            }

            guard !availableFeatures.isEmpty else {
                writeMessage("No optional features are available on this platform.\n")
                return 0
            }

            let initiallySelected = Set(
                availableFeatures
                    .filter(\.installed)
                    .map(\.id)
            )
            let menuItems = availableFeatures.map(featureCheckboxItem)
            guard let selectedIDs = await TerminalCheckboxMenu.selectOffActor(
                title: "Install optional features",
                items: menuItems,
                selected: initiallySelected
            ) else {
                writeMessage("Optional feature selection cancelled.\n")
                return 0
            }
            ids = availableFeatures.map(\.id).filter(selectedIDs.contains)
        }

        guard !ids.isEmpty else {
            writeMessage("No optional features selected.\n")
            return 0
        }

        let sourceRootURL = request.zenPackagePath.map(resolvedDirectoryURL)
        let featuresByID = Dictionary(
            uniqueKeysWithValues: availableFeatures.map { ($0.id, $0) }
        )
        var didFail = false

        for id in ids {
            let feature = featuresByID[id]
            let title = feature.map { "\($0.displayName) [\($0.id)]" } ?? "[\(id)]"
            writeMessage("\nInstalling optional feature \(title)\n")

            do {
                let report = try await runtime.installOptionalFeature(
                    id: id,
                    zenPackageRootURL: sourceRootURL,
                    build: true,
                    enable: true,
                    progress: { message in
                        writeMessage("  • \(message)\n")
                    }
                )
                if report.ok {
                    if report.copied {
                        writeMessage("  Copied: \(report.destinationPath)\n")
                    } else {
                        writeMessage("  Source package was already current: \(report.destinationPath)\n")
                    }
                    writeMessage("  ✓ Built and enabled \(report.productName).\n")
                } else {
                    didFail = true
                    writeMessage("  ✗ \(title) was not installed completely.\n")
                    writeReportErrors(report.errors)
                    writeMessage(
                        "    Fix the reported issue, then retry: zen --install-features \(id)" +
                        sourcePathHint(request.zenPackagePath) + "\n"
                    )
                }
            } catch {
                didFail = true
                writeMessage("  ✗ Could not install \(title): \(error.localizedDescription)\n")
                writeMessage(
                    "    Resolve the reported issue, then retry: zen --install-features \(id)" +
                        sourcePathHint(request.zenPackagePath) + "\n"
                )
            }
        }

        // A menu is an opportunistic installer step, especially when run at the
        // tail of a platform installer. Explicit ids, instead, are scripting
        // requests and must make failures observable to the caller.
        return didFail && requestedExplicitly ? 1 : 0
    }

    private static func parse(arguments: [String]) -> ParseResult {
        var ids = [String]()
        var zenPackagePath: String?
        var skipInstallation = false
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case option:
                if index + 1 < arguments.count,
                   !arguments[index + 1].hasPrefix("-") {
                    appendIDs(arguments[index + 1], to: &ids)
                    index += 2
                } else {
                    index += 1
                }
            case noFeaturesOption:
                skipInstallation = true
                index += 1
            case zenPackagePathOption:
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("-") else {
                    return .invalid("\(zenPackagePathOption) requires a directory argument.")
                }
                zenPackagePath = arguments[index + 1]
                index += 2
            case let value where value.hasPrefix("\(option)="):
                appendIDs(String(argument.dropFirst(option.count + 1)), to: &ids)
                index += 1
            case let value where value.hasPrefix("\(zenPackagePathOption)="):
                let path = String(argument.dropFirst(zenPackagePathOption.count + 1))
                guard !path.isEmpty else {
                    return .invalid("\(zenPackagePathOption) requires a directory argument.")
                }
                zenPackagePath = path
                index += 1
            default:
                return .invalid("Unknown option for \(option): \(argument)")
            }
        }

        return .request(
            Request(
                ids: orderedUnique(ids),
                zenPackagePath: zenPackagePath,
                skipInstallation: skipInstallation
            )
        )
    }

    private static func appendIDs(_ value: String, to ids: inout [String]) {
        ids.append(contentsOf: value.split(separator: ",").compactMap { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        })
    }

    private static func orderedUnique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func resolvedDirectoryURL(_ path: String) -> URL {
        let pathURL = URL(fileURLWithPath: path, isDirectory: true)
        if pathURL.path.hasPrefix("/") {
            return pathURL.standardizedFileURL
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .appendingPathComponent(path, isDirectory: true)
        .standardizedFileURL
    }

    private static func featureCheckboxItem(
        _ feature: SwiftFeatureOptionalFeature
    ) -> TerminalCheckboxMenuItem<String> {
        TerminalCheckboxMenuItem(
            value: feature.id,
            title: "\(feature.displayName) [\(feature.id)]",
            detail: "\(feature.description) — \(featureInstallationState(feature))",
            groupTitle: feature.installed ? "Installed" : "Installable"
        )
    }

    private static func featureInstallationState(_ feature: SwiftFeatureOptionalFeature) -> String {
        guard feature.installed else {
            return "not installed"
        }
        if feature.enabled {
            return "installed and enabled"
        }
        if feature.built {
            return "installed; disabled"
        }
        return "installed; build required"
    }

    private static func featureSortOrder(
        _ lhs: SwiftFeatureOptionalFeature,
        _ rhs: SwiftFeatureOptionalFeature
    ) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func sourcePathHint(_ path: String?) -> String {
        guard let path, !path.isEmpty else {
            return " --zen-package-path <ZenCODE checkout>"
        }
        return " --zen-package-path \(path)"
    }

    private static func writeReportErrors(_ errors: [String]) {
        if errors.isEmpty {
            writeMessage("    The feature build or enable step did not complete.\n")
            return
        }
        for error in errors {
            writeMessage("    \(error)\n")
        }
    }

    private static func standardInputIsTerminal() -> Bool {
        TerminalRawInput.supportsInteractiveInput()
    }

    // Installer progress and diagnostics both use stderr so stdout remains
    // available to callers; this preserves the existing CLI output contract.
    private static func writeMessage(_ text: String) {
        AgentOutput.standardError.writeString(text)
    }

    private struct Request {
        let ids: [String]
        let zenPackagePath: String?
        let skipInstallation: Bool
    }

    private enum ParseResult {
        case request(Request)
        case invalid(String)
    }
}
