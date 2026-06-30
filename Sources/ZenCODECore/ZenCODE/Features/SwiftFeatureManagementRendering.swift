//
//  SwiftFeatureManagementRendering.swift
//  ZenCODE
//

import Foundation

extension SwiftFeatureRuntime {
    func renderFeatureMutation(
        action: String,
        id: String
    ) async throws -> String {
        try await renderFeatureList(
            prefix: "Feature '\(id)' \(action).",
            includeTools: true,
            includeDisabled: true,
            discoverRuntimeTools: false
        )
    }

    func renderFeatureList(
        prefix: String? = nil,
        includeTools: Bool,
        includeDisabled: Bool,
        discoverRuntimeTools: Bool
    ) async throws -> String {
        let statuses = await featureStatuses(
            includeTools: includeTools,
            includeDisabled: includeDisabled,
            discoverRuntimeTools: discoverRuntimeTools
        )
        let payload = SwiftFeatureListPayload(features: statuses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        if let prefix {
            return "\(prefix)\n\(json)"
        }
        return json
    }

    func renderJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func requiredFeatureID(
        _ arguments: [String: Any]
    ) throws -> String {
        guard let id = arguments
            .string("id", "featureID", "feature_id", "name")?
            .nilIfBlank else {
            throw DirectToolError.missingArgument("id")
        }
        return id
    }

    func featureManifestURL(
        arguments: [String: Any]
    ) throws -> URL {
        if let manifestPath = arguments
            .string("manifestPath", "manifest_path")?
            .nilIfBlank {
            return Self.manifestURL(from: resolvedFeaturePath(manifestPath))
        }

        if let path = arguments.string("path")?.nilIfBlank {
            return Self.manifestURL(from: resolvedFeaturePath(path))
        }

        let id = try Self.requiredFeatureID(arguments)
        if let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        ),
           let manifestURL = record.manifestURL {
            return manifestURL
        }

        return featureRootURL()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
            .standardizedFileURL
    }

    func scaffoldDirectoryURL(
        id: String,
        arguments: [String: Any]
    ) throws -> URL {
        let rootURL = featureRootURL()
        let directoryURL: URL
        if let directory = arguments
            .string("directory", "directoryPath", "directory_path")?
            .nilIfBlank {
            directoryURL = resolvedFeaturePath(directory)
        } else if let path = arguments.string("path")?.nilIfBlank {
            let url = resolvedFeaturePath(path)
            if url.lastPathComponent == SwiftFeatureRegistry.manifestFilename {
                directoryURL = url.deletingLastPathComponent()
            } else {
                directoryURL = url
            }
        } else {
            directoryURL = rootURL
                .appendingPathComponent(id, isDirectory: true)
                .standardizedFileURL
        }

        guard Self.path(directoryURL, isDescendantOf: rootURL) else {
            throw DirectToolError.permissionDenied(
                "feature.scaffold can only create packages under the generated features directory: \(rootURL.path). Use feature.install for packages prepared elsewhere."
            )
        }
        return directoryURL
    }

    func installSourceManifestURL(
        arguments: [String: Any]
    ) throws -> URL {
        if let manifestPath = arguments
            .string("manifestPath", "manifest_path")?
            .nilIfBlank {
            return Self.manifestURL(from: resolvedInstallPath(manifestPath))
        }

        if let directory = arguments
            .string("directory", "directoryPath", "directory_path", "path")?
            .nilIfBlank {
            return Self.manifestURL(from: resolvedInstallPath(directory))
        }

        if let id = arguments
            .string("id", "featureID", "feature_id", "name")?
            .nilIfBlank,
           let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
           ),
           let manifestURL = record.manifestURL {
            return manifestURL
        }

        throw DirectToolError.missingArgument("path")
    }

    func installFeatureDirectory(
        sourceDirectoryURL: URL,
        destinationDirectoryURL: URL,
        overwrite: Bool
    ) throws -> Bool {
        let sourceURL = sourceDirectoryURL.standardizedFileURL
        let destinationURL = destinationDirectoryURL.standardizedFileURL
        guard sourceURL.path != destinationURL.path else {
            return false
        }
        guard !destinationURL.path.hasPrefix(sourceURL.path + "/") else {
            throw DirectToolError.permissionDenied(
                "Refusing to install a feature into a child of its source directory."
            )
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw DirectToolError.permissionDenied(
                    "Feature already exists at \(destinationURL.path). Pass overwrite=true to replace it."
                )
            }
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        try copyFeatureDirectoryContents(
            from: sourceURL,
            to: destinationURL
        )
        return true
    }

    func copyFeatureDirectoryContents(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entryURL in entries {
            guard !Self.excludedInstallEntryNames.contains(entryURL.lastPathComponent) else {
                continue
            }
            let destinationEntryURL = destinationURL.appendingPathComponent(entryURL.lastPathComponent)
            let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationEntryURL,
                    withIntermediateDirectories: true
                )
                try copyFeatureDirectoryContents(
                    from: entryURL,
                    to: destinationEntryURL
                )
            } else {
                try fileManager.copyItem(
                    at: entryURL,
                    to: destinationEntryURL
                )
            }
        }
    }

    func featureRootURL() -> URL {
        featureRootURLs().first ?? SwiftFeatureRegistry.appFeatureRootURL(
            fileManager: fileManager
        ).standardizedFileURL
    }

    func featureRootURLs() -> [URL] {
        (featureSearchRoots ?? [
            SwiftFeatureRegistry.appFeatureRootURL(fileManager: fileManager)
        ]).map(\.standardizedFileURL)
    }

    func resolvedInstallPath(_ rawPath: String) -> URL {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }

    func resolvedFeaturePath(_ rawPath: String) -> URL {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return featureRootURL()
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }
}

private struct SwiftFeatureListPayload: Codable {
    let features: [SwiftFeatureStatus]
}
