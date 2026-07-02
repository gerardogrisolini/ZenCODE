//
//  SwiftFeatureRuntimeValidation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

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
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
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
        ".DS_Store"
    ]

    static func swiftExecutableURL(fileManager: FileManager) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["SWIFT_EXECUTABLE"],
            "/usr/bin/swift",
            "/Library/Developer/CommandLineTools/usr/bin/swift",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
            "/usr/local/bin/swift"
        ].compactMap { $0?.nilIfBlank }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/usr/bin/swift")
    }
}
