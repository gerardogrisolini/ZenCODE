#if ZENCODE_LOCAL_MLX
//
//  ZenCODEMLXResetCommands.swift
//  ZenCODE
//

import Foundation
import MLXServerCore

enum ZenCODEMLXResetConfigurationCommand {
    static func run(fileManager: FileManager = .default) throws {
        let fileURLs = uniqueURLs([
            MLXServerSettingsStore.settingsURL(fileManager: fileManager),
            MLXServerModelsManifestStore.modelsURL(fileManager: fileManager)
        ])

        var removed: [URL] = []
        var missing: [URL] = []
        for url in fileURLs {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removed.append(url)
            } else {
                missing.append(url)
            }
        }

        FileHandle.standardError.writeString("ZenCODE MLX reset completed.\n")
        printURLs("Removed", removed)
        if removed.isEmpty {
            printURLs("Missing", missing)
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            guard seen.insert(url.path).inserted else {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func printURLs(_ title: String, _ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        FileHandle.standardError.writeString("\(title):\n")
        for url in urls {
            FileHandle.standardError.writeString("- \(url.path)\n")
        }
    }
}

enum ZenCODEMLXResetDiskCacheCommand {
    static func run(fileManager: FileManager = .default) throws {
        let settings = MLXServerSettingsStore.loadOrDefault(fileManager: fileManager)
        let cacheDirectory = settings.diskKVCache.configuration.directory.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            FileHandle.standardError.writeString(
                "Disk KV cache not found: \(cacheDirectory.path)\n"
            )
            return
        }

        let children = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }

        FileHandle.standardError.writeString(
            "Disk KV cache cleared: \(cacheDirectory.path)\n"
        )
    }
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}

#endif
