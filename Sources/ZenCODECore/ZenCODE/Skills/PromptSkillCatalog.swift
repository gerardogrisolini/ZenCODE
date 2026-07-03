//
//  PromptSkillCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(CryptoKit)

import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum PromptSkillCatalog {
    public static func appCatalogSearchRoots(fileManager: FileManager = .default) -> [URL] {
        let skillsDirectoryURL = AppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("skills", isDirectory: true)
            .standardizedFileURL
        return [skillsDirectoryURL]
    }

    public static func defaultSearchRoots(fileManager: FileManager = .default) -> [URL] {
        var searchRoots = appCatalogSearchRoots(fileManager: fileManager)

        #if os(macOS)
        let homeDirectory = UserHomeDirectory.current(fileManager: fileManager)
        let codexHome = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
        searchRoots.append(contentsOf: [
            codexHome.appendingPathComponent("skills", isDirectory: true),
            codexHome.appendingPathComponent("vendor_imports", isDirectory: true),
            codexHome
                .appendingPathComponent(".tmp", isDirectory: true)
                .appendingPathComponent("plugins", isDirectory: true)
        ])
        #endif

        return uniqueStandardizedURLs(searchRoots)
    }

    public static func discoverSkills(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [PromptSkill] {
        let roots = searchRoots ?? defaultSearchRoots(fileManager: fileManager)
        var skillsByKey: [String: PromptSkill] = [:]

        for skillMarkdownURL in skillMarkdownURLs(in: roots, fileManager: fileManager) {
            guard let payload = try? PromptSkillMarkdownParser.parse(url: skillMarkdownURL) else {
                continue
            }
            let skill = PromptSkill(payload: payload)
            let key = skill.sourceHash.nilIfBlank ?? skill.canonicalName
            guard skillsByKey[key] == nil else {
                continue
            }
            skillsByKey[key] = skill
        }

        return skillsByKey.values.sorted { lhs, rhs in
            let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return lhs.canonicalName.localizedStandardCompare(rhs.canonicalName) == .orderedAscending
        }
    }

    private static func skillMarkdownURLs(
        in searchRoots: [URL],
        fileManager: FileManager
    ) -> [URL] {
        var fileURLs: [URL] = []
        var seenPaths: Set<String> = []

        for searchRoot in uniqueStandardizedURLs(searchRoots) {
            let directSkillURL = searchRoot
                .appendingPathComponent("SKILL.md")
                .standardizedFileURL
            if isRegularFile(at: directSkillURL, fileManager: fileManager),
               seenPaths.insert(directSkillURL.path).inserted {
                fileURLs.append(directSkillURL)
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: searchRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(
                      at: searchRoot,
                      includingPropertiesForKeys: [.isRegularFileKey],
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                continue
            }

            while let fileURL = enumerator.nextObject() as? URL {
                let standardizedURL = fileURL.standardizedFileURL
                guard standardizedURL.lastPathComponent == "SKILL.md",
                      seenPaths.insert(standardizedURL.path).inserted,
                      isRegularFile(at: standardizedURL, fileManager: fileManager) else {
                    continue
                }
                fileURLs.append(standardizedURL)
            }
        }

        return fileURLs
    }

    private static func isRegularFile(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return true
    }

    private static func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
        var uniqueURLs: [URL] = []
        var seenPaths: Set<String> = []

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard seenPaths.insert(standardizedURL.path).inserted else {
                continue
            }
            uniqueURLs.append(standardizedURL)
        }

        return uniqueURLs
    }
}
