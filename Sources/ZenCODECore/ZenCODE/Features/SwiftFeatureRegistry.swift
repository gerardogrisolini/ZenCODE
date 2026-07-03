//
//  SwiftFeatureRegistry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

public enum SwiftFeatureStateStore {
    public static let stateFilename = "feature-state.json"

    public static func stateURL(fileManager: FileManager = .default) -> URL {
        AppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(stateFilename)
            .standardizedFileURL
    }

    public static func load(
        fileManager: FileManager = .default
    ) -> SwiftFeatureState {
        let url = stateURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SwiftFeatureState.self, from: data) else {
            return SwiftFeatureState()
        }
        return SwiftFeatureState(
            version: SwiftFeatureState.currentVersion,
            disabledBundledFeatureIDs: state.disabledBundledFeatureIDs,
            enabledBundledFeatureIDs: state.enabledBundledFeatureIDs
        )
    }

    public static func setBundledFeature(
        id rawID: String,
        enabled: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard let id = rawID.nilIfBlank else {
            throw DirectToolError.missingArgument("id")
        }

        let state = load(fileManager: fileManager)
        var disabledIDs = Set(state.disabledBundledFeatureIDs)
        var enabledIDs = Set(state.enabledBundledFeatureIDs)
        if SwiftFeatureState.defaultDisabledBundledFeatureIDs.contains(id) {
            if enabled {
                enabledIDs.insert(id)
                disabledIDs.remove(id)
            } else {
                enabledIDs.remove(id)
                disabledIDs.insert(id)
            }
        } else if enabled {
            disabledIDs.remove(id)
            enabledIDs.remove(id)
        } else {
            disabledIDs.insert(id)
            enabledIDs.remove(id)
        }
        try save(
            SwiftFeatureState(
                disabledBundledFeatureIDs: Array(disabledIDs),
                enabledBundledFeatureIDs: Array(enabledIDs)
            ),
            fileManager: fileManager
        )
    }

    private static func save(
        _ state: SwiftFeatureState,
        fileManager: FileManager
    ) throws {
        let url = stateURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: [.atomic])
    }
}

public enum SwiftFeatureRegistry {
    public static let manifestFilename = "feature.json"

    public static func appFeatureRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("features", isDirectory: true)
            .standardizedFileURL
    }

    public static func discoverFeatureBundles(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureBundle] {
        discoverFeatureRecords(searchRoots: searchRoots, fileManager: fileManager)
            .compactMap { record in
                guard record.enabled else {
                    return nil
                }
                return SwiftFeatureBundle(
                    id: record.id,
                    executableURL: record.executableURL,
                    tools: record.tools,
                    toolNamePrefixes: record.toolNamePrefixes,
                    toolNameAliases: record.toolNameAliases,
                    discoversToolsAtRuntime: record.discoversToolsAtRuntime,
                    source: .generated
                )
            }
    }

    public static func discoverFeatureRecords(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureRecord] {
        let roots = searchRoots ?? [appFeatureRootURL(fileManager: fileManager)]
        return roots.flatMap { root in
            discoverFeatureRecords(
                under: root.standardizedFileURL,
                fileManager: fileManager
            )
        }.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func discoverFeatureRecords(
        under rootURL: URL,
        fileManager: FileManager
    ) -> [SwiftFeatureRecord] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var records: [SwiftFeatureRecord] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == manifestFilename,
                  let record = featureRecord(
                      manifestURL: url.standardizedFileURL,
                      fileManager: fileManager
                  ) else {
                continue
            }
            records.append(record)
        }
        return records
    }

    public static func featureRecord(
        manifestURL: URL,
        fileManager: FileManager
    ) -> SwiftFeatureRecord? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SwiftFeatureManifest.self, from: data) else {
            return nil
        }

        let executableURL = resolvedExecutableURL(
            manifest.executable,
            relativeTo: manifestURL.deletingLastPathComponent()
        )
        let executableAvailable = fileManager.isExecutableFile(atPath: executableURL.path)
        return SwiftFeatureRecord(
            id: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description,
            source: .generated,
            executableURL: executableURL,
            manifestURL: manifestURL,
            manifestEnabled: manifest.enabled,
            executableAvailable: executableAvailable,
            tools: manifest.tools.map(\.toolDescriptor),
            toolNamePrefixes: manifest.toolNamePrefixes,
            toolNameAliases: manifest.toolNameAliases,
            discoversToolsAtRuntime: manifest.discoversToolsAtRuntime,
            build: manifest.build,
            generated: manifest.generated,
            issue: executableAvailable ? nil : "Executable not found or not executable."
        )
    }

    public static func featureRecord(
        id: String,
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> SwiftFeatureRecord? {
        discoverFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        ).first { $0.id == id }
    }

    public static func setFeatureManifestEnabled(
        manifestURL: URL,
        enabled: Bool,
        fileManager: FileManager = .default
    ) throws {
        let data = try Data(contentsOf: manifestURL)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard var dictionary = value.objectValue?.mapValues(\.jsonObject) else {
            throw DirectToolError.permissionDenied(
                "Feature manifest is not a JSON object: \(manifestURL.path)"
            )
        }
        dictionary["enabled"] = enabled
        let outputData = try JSONValue(jsonObject: dictionary).jsonData(
            outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try outputData.write(to: manifestURL, options: [.atomic])
    }

    public static func resolvedExecutableURL(
        _ path: String,
        relativeTo directoryURL: URL
    ) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return directoryURL
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }
}
