//
//  MLXServerModelSetupRunner+Types.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import HuggingFace
import MLXServerCore

func repositoryDisplayName(_ repositoryID: String) -> String {
    repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
}

public struct MLXServerQuickModelSetupResult: Equatable, Sendable {
    public let downloadedModelID: String?
    public let configuredModelCount: Int

    public var hasUsableModel: Bool {
        configuredModelCount > 0
    }

    public init(downloadedModelID: String?, configuredModelCount: Int) {
        self.downloadedModelID = downloadedModelID
        self.configuredModelCount = configuredModelCount
    }
}

enum MLXServerModelSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Local MLX model setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during ZenCODE MLX model setup."
        }
    }
}

enum MLXServerModelSearchSelection: Equatable {
    case model(Int)
    case searchAgain
    case continueWithoutDownload
}

enum MLXServerModelSetupInputParser {
    static func parseSearchSelection(
        _ value: String,
        defaultSelection: Int,
        allowedRange: ClosedRange<Int>
    ) -> MLXServerModelSearchSelection? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedSearchCommand(trimmed)
        if searchAgainCommands.contains(normalized) {
            return .searchAgain
        }
        if continueWithoutDownloadCommands.contains(normalized) {
            return .continueWithoutDownload
        }

        let selectionText = trimmed.isEmpty ? String(defaultSelection) : trimmed
        guard let selection = Int(selectionText),
              allowedRange.contains(selection) else {
            return nil
        }
        return .model(selection)
    }

    private static let searchAgainCommands = Set([
        "s",
        "search",
        "search again",
        "again",
        "r",
        "retry",
        "cerca",
        "cerca ancora",
        "ricerca"
    ])

    private static let continueWithoutDownloadCommands = Set([
        "c",
        "continue",
        "continue without download",
        "skip",
        "skip download",
        "no download",
        "without download",
        "continua",
        "continua senza scaricare",
        "senza scaricare",
        "salta",
        "non scaricare"
    ])

    private static func normalizedSearchCommand(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum MLXServerHuggingFaceCacheRemovalResult: Equatable {
    case removed
    case notFound
    case invalidRepositoryID
}
enum MLXServerHuggingFaceCacheRemoval {
    static func remove(
        repositoryID: String,
        cache: HubCache,
        fileManager: FileManager = .default
    ) throws -> MLXServerHuggingFaceCacheRemovalResult {
        guard let repoID = Repo.ID(rawValue: repositoryID) else {
            return .invalidRepositoryID
        }

        let urls = removalURLs(repoID: repoID, cache: cache)
        var removedAny = false
        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            try fileManager.removeItem(at: url)
            removedAny = true
        }
        return removedAny ? .removed : .notFound
    }

    static func removalURLs(
        repositoryID: String,
        cache: HubCache
    ) -> [URL]? {
        guard let repoID = Repo.ID(rawValue: repositoryID) else {
            return nil
        }
        return removalURLs(repoID: repoID, cache: cache)
    }

    static func removalURLs(
        repoID: Repo.ID,
        cache: HubCache
    ) -> [URL] {
        let repositoryURL = cache.repoDirectory(repo: repoID, kind: .model)
        let metadataURL = cache.metadataDirectory(repo: repoID, kind: .model)
        return [
            repositoryURL,
            metadataURL,
            cache.lockPath(for: repositoryURL),
            cache.lockPath(for: metadataURL)
        ]
    }
}

struct ConfiguredModelRecord: Sendable {
    var record: MLXServerModelRecord
}

struct MLXServerCachedModelCandidate: Sendable {
    var repositoryID: String
    var revision: String
    var snapshotURL: URL

    var displayName: String {
        repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
    }
}

extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
