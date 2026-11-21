//  Created by Gerardo Grisolini on 30/05/26.
//
// SwiftFeaturePromotion+Package.swift

import Foundation
import ToolCore
import ZenPackageMetadata
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension SwiftFeatureRuntime {
    static func normalizedPromotionPackageManifest(_ contents: String, packageURL: URL) throws -> String {
        var normalized = contents
        guard normalized.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == SwiftFeatureRuntime.zenPackagePathMarker
        }) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) must contain the '\(SwiftFeatureRuntime.zenPackagePathMarker)' marker before the ZenCODE dependency."
            )
        }
        if normalized.contains("enableUpcomingFeature(\"MemberImportVisibility\")") { return normalized }
        let importMarker = "import PackageDescription\n"
        guard let importRange = normalized.range(of: importMarker) else {
            throw DirectToolError.permissionDenied("\(packageURL.path) must import PackageDescription.")
        }
        normalized.replaceSubrange(importRange, with: """
            import PackageDescription

            let memberImportVisibilitySettings: [SwiftSetting] = [
                .enableUpcomingFeature("MemberImportVisibility")
            ]
            """)
        guard let targetStart = normalized.range(of: ".executableTarget(") else {
            throw DirectToolError.permissionDenied("\(packageURL.path) must declare an executableTarget.")
        }
        let suffix = String(normalized[targetStart.upperBound...])
        let targetPattern = #"\n(\s*)\](\n\s*)\)"#
        guard let expression = try? NSRegularExpression(pattern: targetPattern),
              let match = expression.firstMatch(
                  in: String(suffix),
                  range: NSRange(suffix.startIndex..<suffix.endIndex, in: suffix)
              ),
              let firstIndentRange = Range(match.range(at: 1), in: suffix),
              let secondIndentRange = Range(match.range(at: 2), in: suffix) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) has an unsupported target layout; add MemberImportVisibility explicitly."
            )
        }
        let firstIndent = suffix[firstIndentRange]
        let secondIndent = suffix[secondIndentRange].dropFirst() // captured newline
        let replacement = "\n\(firstIndent)],\n\(firstIndent)swiftSettings: memberImportVisibilitySettings\n\(secondIndent))"
        var normalizedSuffix = String(suffix)
        normalizedSuffix.replaceSubrange(Range(match.range, in: normalizedSuffix)!, with: replacement)
        normalized.replaceSubrange(targetStart.upperBound..<normalized.endIndex, with: normalizedSuffix)
        return normalized
    }

    /// Promotion accepts old Builder scaffolds that predate the marker, but only
    /// when their manifest contains exactly one local package dependency. This
    /// keeps the compatibility fallback deterministic and avoids rewriting an
    /// unrelated local dependency.
    static func promotionPackageManifestRewritingZenPackagePath(
        _ contents: String,
        zenPackagePath: String,
        packageURL: URL
    ) throws -> String {
        if contents.components(separatedBy: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == zenPackagePathMarker
        }) {
            var lines = contents.components(separatedBy: "\n")
            guard let markerIndex = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == zenPackagePathMarker
            }) else { return contents }
            var dependencyIndex = markerIndex + 1
            while dependencyIndex < lines.count,
                  lines[dependencyIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                dependencyIndex += 1
            }
            guard dependencyIndex < lines.count,
                  let rewritten = promotionRewrittenPackagePathLine(
                    lines[dependencyIndex], zenPackagePath: zenPackagePath
                  ) else {
                throw DirectToolError.permissionDenied(
                    "\(packageURL.path) must declare .package(path:) after the package-path marker."
                )
            }
            lines[dependencyIndex] = rewritten
            return lines.joined(separator: "\n")
        }

        let pattern = #"(?m)^(\s*)(\.package\(\s*path:\s*\"(?:[^\"\\]|\\.)*\"\s*\).*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw DirectToolError.permissionDenied("Could not inspect \(packageURL.path).")
        }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        let matches = expression.matches(in: contents, range: range)
        guard matches.count == 1,
              let match = matches.first,
              let fullRange = Range(match.range(at: 0), in: contents),
              let indentRange = Range(match.range(at: 1), in: contents) else {
            throw DirectToolError.permissionDenied(
                "\(packageURL.path) must contain the package-path marker or exactly one local .package(path:) dependency."
            )
        }
        let indent = contents[indentRange]
        let replacement = "\(indent)\(zenPackagePathMarker)\n\(indent).package(name: \"ZenCODE\", path: \(swiftStringLiteral(zenPackagePath)))"
        return contents.replacingCharacters(in: fullRange, with: replacement)
    }

    static func promotionRewrittenPackagePathLine(_ line: String, zenPackagePath: String) -> String? {
        let pattern = #"^(\s*)\.package\(\s*(?:name:\s*\"ZenCODE\"\s*,\s*)?path:\s*\"(?:[^\"\\]|\\.)*\"\s*\)(.*)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let indentRange = Range(match.range(at: 1), in: line),
              let trailingRange = Range(match.range(at: 2), in: line) else { return nil }
        return line[indentRange]
            + ".package(name: \"ZenCODE\", path: \(swiftStringLiteral(zenPackagePath)))"
            + line[trailingRange]
    }

    static func packageManifestDeclaresProduct(_ contents: String, productName: String) -> Bool {
        let quoted = swiftLiteral(productName)
        return contents.contains("name: \(quoted)")
    }
    static func promotionDistributionManifestData(
        sourceManifest: SwiftFeatureManifest,
        productName: String,
        sourceRelativePath: String,
        isInstalledOnLinux: Bool,
        normalizedDescription: String,
        normalizedToolNamePrefixes: [String]
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(sourceManifest)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw DirectToolError.permissionDenied("Could not encode feature distribution metadata.")
        }
        object["distributionSchemaVersion"] = 1
        object["productName"] = productName
        object["sourceRelativePath"] = sourceRelativePath
        object["isInstalledOnLinux"] = isInstalledOnLinux
        object["platforms"] = isInstalledOnLinux ? ["macOS", "linux"] : ["macOS"]
        object["description"] = normalizedDescription
        object["toolNamePrefixes"] = normalizedToolNamePrefixes
        if let generated = object["generated"] { object["origin"] = generated }
        object.removeValue(forKey: "enabled")
        object.removeValue(forKey: "generated")
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    func promotionListTools(executableURL: URL, workingDirectory: URL) async throws -> [String] {
        let result = try await AsyncProcessRunner.run(
            executableURL: executableURL,
            arguments: ["--list-tools"],
            workingDirectory: workingDirectory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 120
        )
        guard !result.timedOut, result.exitCode == 0 else {
            throw DirectToolError.processFailed(
                "feature.promote --list-tools failed: \(result.stderr.nilIfBlank ?? "exit code \(result.exitCode)")"
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: result.stdoutData) as? [String: Any],
              let rawTools = object["tools"] as? [[String: Any]], !rawTools.isEmpty else {
            throw DirectToolError.invalidResponse("feature.promote expected a non-empty tools array from --list-tools.")
        }
        var descriptors: [ToolDescriptor] = []
        for rawTool in rawTools {
            let descriptor: ToolDescriptor
            do {
                descriptor = try JSONDecoder().decode(
                    ToolDescriptor.self,
                    from: JSONSerialization.data(withJSONObject: rawTool)
                )
            } catch {
                throw DirectToolError.invalidResponse(
                    "feature.promote received an invalid tool descriptor: \(error.localizedDescription)"
                )
            }
            guard descriptor.presentation?.isSemanticallyValid == true else {
                throw DirectToolError.invalidResponse(
                    "Tool '\(descriptor.name)' lacks explicit valid presentation metadata."
                )
            }
            guard (try? JSONSerialization.jsonObject(with: Data(descriptor.inputSchema.utf8))) != nil else {
                throw DirectToolError.invalidResponse("Tool '\(descriptor.name)' has invalid inputSchema JSON.")
            }
            descriptors.append(descriptor)
        }
        let errors = Self.validationErrorsForToolNames(descriptors.map(\.name))
        guard errors.isEmpty else { throw DirectToolError.permissionDenied(errors.joined(separator: "\n")) }
        return ToolDescriptor.canonicalized(descriptors).map(\.name)
    }

    static func promotionPackageResolvedData(
        in featureDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> Data? {
        let entries = try fileManager.contentsOfDirectory(
            at: featureDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        guard let resolvedURL = entries.first(where: { $0.lastPathComponent == "Package.resolved" }) else {
            return nil
        }
        let values = try resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw DirectToolError.permissionDenied(
                "Package.resolved must be a regular file, not a symbolic link: \(resolvedURL.path)"
            )
        }
        return try Data(contentsOf: resolvedURL)
    }

    static func assertPromotionManifestPathsAreConfined(
        _ manifest: SwiftFeatureManifest,
        featureDirectoryURL: URL
    ) throws {
        let root = featureDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        func confinedURL(_ rawPath: String, field: String) throws -> URL {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            guard !expanded.hasPrefix("/") else {
                throw DirectToolError.permissionDenied("Promotion manifest \(field) must be relative to the feature package.")
            }
            let candidate = root.appendingPathComponent(expanded)
                .resolvingSymlinksInPath().standardizedFileURL
            guard path(candidate, isDescendantOf: root) else {
                throw DirectToolError.permissionDenied("Promotion manifest \(field) escapes the feature package.")
            }
            return candidate
        }

        _ = try confinedURL(manifest.executable, field: "executable")
        if let build = manifest.build {
            if let packagePath = build.packagePath?.nilIfBlank {
                let packageURL = try confinedURL(packagePath, field: "build.packagePath")
                guard packageURL == root else {
                    throw DirectToolError.permissionDenied(
                        "Promotion manifest build.packagePath must identify the package root."
                    )
                }
            }
            if let executablePath = build.executablePath?.nilIfBlank {
                _ = try confinedURL(executablePath, field: "build.executablePath")
            }
            let pathChangingArguments: Set<String> = [
                "--package-path", "--scratch-path", "--build-path", "--cache-path",
                "--config-path", "--security-path"
            ]
            guard !build.arguments.contains(where: { argument in
                pathChangingArguments.contains(argument)
                    || pathChangingArguments.contains(where: { argument.hasPrefix($0 + "=") })
            }) else {
                throw DirectToolError.permissionDenied(
                    "Promotion manifest build arguments cannot override SwiftPM package or storage paths."
                )
            }
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    func assertPromotionControlledPathsAreSafe(
        gitRoot: URL,
        paths: [URL],
        destinationExisted: Bool,
        overwrite: Bool
    ) async throws {
        let relative = paths.map { Self.relativePath(from: gitRoot, to: $0) }
        let result = try await runPromotionGit(
            ["status", "--short", "--untracked-files=all", "--"] + relative,
            at: gitRoot
        )
        guard result.exitCode == 0 else {
            throw DirectToolError.permissionDenied("Could not inspect controlled promotion paths in Git.")
        }
        let lines = result.stdout
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if lines.isEmpty { return }
        let destinationPath = relative[0]
        let catalogPaths = Set(relative.dropFirst())
        let destinationOnly = destinationExisted && overwrite && lines.allSatisfy {
            let path = $0.count > 3 ? String($0.dropFirst(3)) : $0
            return path == destinationPath || path.hasPrefix(destinationPath + "/")
        }
        let expectedNewCatalogs = lines.allSatisfy {
            guard $0.hasPrefix("??") else { return false }
            let path = $0.count > 3 ? String($0.dropFirst(3)) : $0
            return catalogPaths.contains(path)
        }
        guard destinationOnly || expectedNewCatalogs else {
            throw DirectToolError.permissionDenied(
                "Controlled promotion paths have uncommitted Git changes:\n"
                    + lines.joined(separator: "\n")
                    + "\nUnrelated changes are allowed; clean or stash package/catalog paths first."
            )
        }
    }
#else
    func assertPromotionControlledPathsAreSafe(
        gitRoot: URL, paths: [URL], destinationExisted: Bool, overwrite: Bool
    ) async throws { _ = gitRoot; _ = paths; _ = destinationExisted; _ = overwrite }
#endif

    func copyPromotionDirectoryContents(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let allowedTopLevel: Set<String> = [
            "Package.swift", "Package.resolved", "Sources", "Tests",
            "README", "README.md", "LICENSE", "LICENSE.md", "NOTICE", "NOTICE.md"
        ]
        let entries = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries where allowedTopLevel.contains(entry.lastPathComponent) {
            try copyPromotionEntry(entry, to: destinationURL.appendingPathComponent(entry.lastPathComponent))
        }
    }

    func copyPromotionEntry(_ entry: URL, to destination: URL) throws {
        let forbiddenNames: Set<String> = [".build", ".swiftpm", ".git", ".DS_Store", SwiftFeatureRegistry.manifestFilename]
        guard !forbiddenNames.contains(entry.lastPathComponent) else { return }
        let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { return }
        if values.isDirectory == true {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
            for child in children {
                try copyPromotionEntry(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else if values.isRegularFile == true {
            try fileManager.copyItem(at: entry, to: destination)
        }
    }

    func removePromotionArtifacts(from directoryURL: URL, removeBuilderManifest: Bool) throws {
        var names = [".build", ".swiftpm", ".git", ".DS_Store"]
        if removeBuilderManifest { names.append(SwiftFeatureRegistry.manifestFilename) }
        for name in names {
            let url = directoryURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    static func platformLinuxArgument(_ arguments: [String: Any]) -> Bool? {
        if let explicit = arguments.bool(
            "isInstalledOnLinux", "is_installed_on_linux", "linux", "supportedOnLinux", "supported_on_linux"
        ) {
            return explicit
        }
        let platforms = Self.stringArrayArgument(arguments, keys: ["platforms", "supportedPlatforms", "supported_platforms"])
        guard !platforms.isEmpty else { return nil }
        return platforms.contains { $0.lowercased() == "linux" }
    }

    static func relativePath(from sourceURL: URL, to destinationURL: URL) -> String {
        let source = sourceURL.standardizedFileURL.pathComponents
        let destination = destinationURL.standardizedFileURL.pathComponents
        var common = 0
        while common < source.count, common < destination.count, source[common] == destination[common] { common += 1 }
        let up = Array(repeating: "..", count: max(0, source.count - common))
        let down = Array(destination.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    static func swiftLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    static func swiftLiteralArray(_ values: [String]) -> String {
        "[" + values.map(swiftLiteral).joined(separator: ", ") + "]"
    }

    func promotionGitChangedPaths(rootURL: URL, paths: [URL]) async -> [String] {
#if canImport(Darwin) || canImport(Glibc)
        let relative = paths.map { Self.relativePath(from: rootURL, to: $0) }
        guard let result = try? await runPromotionGit(["status", "--short", "--"] + relative, at: rootURL),
              result.exitCode == 0 else { return relative }
        let lines = result.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        return lines.isEmpty ? relative : lines
#else
        return paths.map { Self.relativePath(from: rootURL, to: $0) }
#endif
    }
}
