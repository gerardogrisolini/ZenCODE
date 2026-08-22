//
//  SwiftFeatureRuntimeValidation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import ToolCore

extension SwiftFeatureRuntime {
    static func manifestURL(from url: URL) -> URL {
        if url.lastPathComponent == SwiftFeatureRegistry.manifestFilename {
            return url.standardizedFileURL
        }
        return url
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
            .standardizedFileURL
    }

    static func path(_ candidate: URL, isDescendantOf root: URL) -> Bool {
        // `standardizedFileURL` is lexical only; resolve symlinks on both
        // operands before comparing so a symlink under a feature root cannot
        // redirect scaffold/delete/install outside that root.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
    }

    static func resolveBuildPackageDirectory(
        build: SwiftFeatureBuildManifest,
        featureDirectoryURL: URL
    ) -> URL {
        guard let packagePath = build.packagePath?.nilIfBlank else {
            return featureDirectoryURL
        }
        return SwiftFeatureRegistry.resolvedExecutableURL(
            packagePath,
            relativeTo: featureDirectoryURL
        )
    }

    static func validatePackageSwiftToolsVersion(
        packageDirectoryURL: URL
    ) -> [String] {
        let packageURL = packageDirectoryURL.appendingPathComponent("Package.swift")
        guard let firstLine = try? String(contentsOf: packageURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .first else {
            return ["Package.swift not found at \(packageURL.path)."]
        }

        let expected = "// swift-tools-version: \(generatedSwiftToolsVersion)"
        guard firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            return [
                "Package.swift must target Swift tools \(generatedSwiftToolsVersion). Expected first line: \(expected)"
            ]
        }
        return []
    }

    static func validationErrorsForToolNames(
        _ toolNames: [String]
    ) -> [String] {
        var errors: [String] = []
        let duplicates = Dictionary(grouping: toolNames, by: { $0 })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
            .map(\.key)
            .sorted()
        if !duplicates.isEmpty {
            errors.append("Duplicate tool names: \(duplicates.joined(separator: ", ")).")
        }

        let reservedToolNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        for toolName in toolNames {
            if toolName.nilIfBlank == nil {
                errors.append("Feature contains an empty tool name.")
            } else if toolName == "local.exec" {
                errors.append("local.exec is core and cannot be implemented by a feature.")
            } else if toolName.hasPrefix("feature.") {
                errors.append("Tool namespace 'feature.' is reserved for kernel feature management: \(toolName).")
            } else if reservedToolNames.contains(toolName) {
                errors.append("Tool name '\(toolName)' already exists in the core catalog.")
            }
        }
        return errors
    }

    static func validationErrorsForRouting(
        toolNamePrefixes: [String],
        toolNameAliases: [String]
    ) -> [String] {
        var errors: [String] = []
        for prefix in toolNamePrefixes {
            let normalized = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty {
                errors.append("Feature contains an empty tool name prefix.")
            } else if normalized.hasPrefix("feature.") {
                errors.append("Tool prefix 'feature.' is reserved for kernel feature management: \(prefix).")
            }
        }
        for alias in toolNameAliases {
            if SwiftFeatureRuntime.isFeatureManagementToolName(alias) {
                errors.append("Tool alias '\(alias)' is reserved for kernel feature management.")
            }
        }
        return errors
    }

    static func isValidFeatureID(_ id: String) -> Bool {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return false
        }
        return !id.contains("..")
            && !id.contains("/")
            && !id.contains("\\")
    }

    static let excludedInstallEntryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        ".DS_Store",
        SwiftFeatureRegistry.distributionManifestFilename
    ]

    static func swiftExecutableURL(
        fileManager: FileManager,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardCandidatePaths: [String]? = nil
    ) throws -> URL {
        var candidates: [String] = []
        if let explicitPath = environment["SWIFT_EXECUTABLE"]?.nilIfBlank {
            if explicitPath.contains("/") {
                candidates.append(expandedPath(explicitPath, environment: environment))
            } else {
                appendExecutablePaths(
                    named: explicitPath,
                    searchPath: environment["PATH"],
                    environment: environment,
                    to: &candidates
                )
            }
        }

        if let swiftlyBinDirectory = environment["SWIFTLY_BIN_DIR"]?.nilIfBlank {
            candidates.append(
                executablePath(
                    named: "swift",
                    directoryPath: swiftlyBinDirectory,
                    environment: environment
                )
            )
        }
        appendExecutablePaths(
            named: "swift",
            searchPath: environment["PATH"],
            environment: environment,
            to: &candidates
        )

        if let swiftlyHomeDirectory = environment["SWIFTLY_HOME_DIR"]?.nilIfBlank {
            candidates.append(
                executablePath(
                    named: "swift",
                    directoryPath: "\(swiftlyHomeDirectory)/bin",
                    environment: environment
                )
            )
        }
        if let xdgDataHome = environment["XDG_DATA_HOME"]?.nilIfBlank {
            candidates.append(
                executablePath(
                    named: "swift",
                    directoryPath: "\(xdgDataHome)/swiftly/bin",
                    environment: environment
                )
            )
        }
        if let homeDirectory = environment["HOME"]?.nilIfBlank {
            candidates.append(
                executablePath(
                    named: "swift",
                    directoryPath: "\(homeDirectory)/.local/share/swiftly/bin",
                    environment: environment
                )
            )
        }

        candidates.append(contentsOf: standardCandidatePaths ?? standardSwiftExecutablePaths)
        var checkedPaths: [String] = []
        var seenPaths = Set<String>()
        for candidate in candidates {
            let candidateURL = URL(
                fileURLWithPath: expandedPath(candidate, environment: environment)
            ).standardizedFileURL
            guard seenPaths.insert(candidateURL.path).inserted else {
                continue
            }
            checkedPaths.append(candidateURL.path)
            if fileManager.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        throw DirectToolError.processFailed(
            "Swift executable not found. Checked: \(checkedPaths.joined(separator: ", ")). "
                + "Ensure 'swift --version' works in the environment that launches ZenCODE, "
                + "source the Swiftly env.sh file, or set SWIFT_EXECUTABLE to the Swift binary."
        )
    }

    private static func appendExecutablePaths(
        named executableName: String,
        searchPath: String?,
        environment: [String: String],
        to candidates: inout [String]
    ) {
        for directoryPath in searchPath?.split(separator: ":").map(String.init) ?? [] {
            let trimmedPath = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else {
                continue
            }
            candidates.append(
                executablePath(
                    named: executableName,
                    directoryPath: trimmedPath,
                    environment: environment
                )
            )
        }
    }

    private static func executablePath(
        named executableName: String,
        directoryPath: String,
        environment: [String: String]
    ) -> String {
        URL(
            fileURLWithPath: expandedPath(directoryPath, environment: environment),
            isDirectory: true
        )
        .appendingPathComponent(executableName)
        .path
    }

    private static func expandedPath(
        _ path: String,
        environment: [String: String]
    ) -> String {
        guard let homeDirectory = environment["HOME"]?.nilIfBlank else {
            return path
        }
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + path.dropFirst()
        }
        return path
    }

    private static var standardSwiftExecutablePaths: [String] {
        var paths = [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
            "/usr/local/swift/usr/bin/swift",
            "/opt/swift/usr/bin/swift"
        ]
        #if os(macOS)
        paths.append("/Library/Developer/CommandLineTools/usr/bin/swift")
        paths.append(
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
        )
        #endif
        return paths
    }
}
