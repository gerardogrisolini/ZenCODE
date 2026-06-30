//
//  MLXServerModelsManifestStore.swift
//  ZenCODE
//

import Foundation

public enum MLXServerModelsManifestStore {
    public static let modelsFilename = "models.json"

    public static func modelsURL(fileManager: FileManager = .default) -> URL {
        MLXServerSettingsStore.supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(modelsFilename)
            .standardizedFileURL
    }

    public static func loadRequired(
        from url: URL = modelsURL(),
        fileManager: FileManager = .default
    ) throws -> MLXServerModelsManifest {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MLXServerModelsManifestError.missingModels(url)
        }
        return try loadManifest(from: url).validated()
    }

    public static func save(
        _ manifest: MLXServerModelsManifest,
        to url: URL = modelsURL(),
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(try manifest.validated())
        try data.write(to: url, options: [.atomic])
    }

    private static func loadManifest(from url: URL) throws -> MLXServerModelsManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MLXServerModelsManifest.self, from: data)
    }
}

public enum MLXServerModelsManifestError: LocalizedError, Equatable, Sendable {
    case missingModels(URL)
    case emptyModelID
    case emptyRepositoryID
    case duplicateModel(String)
    case noEnabledModels
    case defaultModelNotFound(String)
    case modelNotConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .missingModels(let url):
            return "models.json not found at \(url.path). Run zen --setup and choose local MLX models setup first."
        case .emptyModelID:
            return "Model id can not be empty."
        case .emptyRepositoryID:
            return "Model repository id can not be empty."
        case .duplicateModel(let id):
            return "Duplicate model id in models.json: \(id)."
        case .noEnabledModels:
            return "models.json does not contain any enabled model."
        case .defaultModelNotFound(let id):
            return "Default model is not enabled or configured in models.json: \(id)."
        case .modelNotConfigured(let id):
            return "Model is not configured in models.json: \(id)."
        }
    }
}

