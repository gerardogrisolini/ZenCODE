//
//  AgentDS4RuntimeConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Persisted, provider-neutral metadata for an optional local DS4 runtime.
//  This contract deliberately excludes process identity, listening ports and
//  machine-specific hardware handles: those values belong to the live runtime.
//

import Foundation

/// The DS4 backend selected when the runtime is opened.
public enum AgentDS4RuntimeBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case metal
    case cuda
    case rocm
    case cpu
}

/// Compatibility spelling for callers that refer to the backend simply as DS4.
public typealias AgentDS4Backend = AgentDS4RuntimeBackend

/// Errors raised while canonicalizing or resolving persisted DS4 paths.
public enum AgentDS4PathValidationError: LocalizedError, Equatable, Sendable {
    case emptyRootDirectory
    case rootDirectoryMustBeAbsolute(String)
    case rootDirectoryContainsInvalidCharacter(String)
    case rootDirectoryIsNotDirectory(String)
    case emptyModelRelativePath
    case modelPathMustBeRelative(String)
    case modelPathContainsTraversal(String)
    case modelPathContainsInvalidCharacter(String)
    case modelPathEscapesRoot(String)
    case modelPathContainsSymbolicLink(String)
    case modelPathNotRegularFile(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRootDirectory:
            return "The DS4 root directory must not be empty."
        case let .rootDirectoryMustBeAbsolute(path):
            return "The DS4 root directory must be absolute: \(path)"
        case let .rootDirectoryContainsInvalidCharacter(path):
            return "The DS4 root directory contains an invalid character: \(path)"
        case let .rootDirectoryIsNotDirectory(path):
            return "The DS4 root path is not a directory: \(path)"
        case .emptyModelRelativePath:
            return "The DS4 model relative path must not be empty."
        case let .modelPathMustBeRelative(path):
            return "The DS4 model path must be relative to the runtime root: \(path)"
        case let .modelPathContainsTraversal(path):
            return "The DS4 model path cannot contain '..' traversal components: \(path)"
        case let .modelPathContainsInvalidCharacter(path):
            return "The DS4 model path contains an invalid character: \(path)"
        case let .modelPathEscapesRoot(path):
            return "The DS4 model path resolves outside the runtime root: \(path)"
        case let .modelPathContainsSymbolicLink(path):
            return "The DS4 model path cannot traverse a symbolic link: \(path)"
        case let .modelPathNotRegularFile(path):
            return "The DS4 model path is not an existing regular file: \(path)"
        }
    }
}

/// Compatibility spelling used by callers that expose the guard as a
/// validation service.
public typealias AgentDS4PathGuardError = AgentDS4PathValidationError

public enum AgentDS4RuntimeConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidContextWindow(Int)
    case invalidPower(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidContextWindow(value):
            return "The DS4 context window must be between 1 and 1048576 tokens (got \(value))."
        case let .invalidPower(value):
            return "The DS4 power must be between 1 and 100 (got \(value))."
        }
    }
}

/// Compatibility spelling for configuration validation errors.
public typealias AgentDS4RuntimeManifestError = AgentDS4RuntimeConfigurationError

public enum AgentDS4PathGuard {
    /// Returns an absolute, lexically standardized root path. Existing
    /// symlinked roots are resolved before persistence so the stored root is
    /// stable and model containment can be checked against the real directory.
    public static func canonicalRootDirectory(
        _ value: String,
        fileManager: FileManager = .default
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentDS4PathValidationError.emptyRootDirectory
        }

        guard trimmed.hasPrefix("/") else {
            throw AgentDS4PathValidationError.rootDirectoryMustBeAbsolute(trimmed)
        }
        guard !trimmed.contains("\0"), !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw AgentDS4PathValidationError.rootDirectoryContainsInvalidCharacter(trimmed)
        }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        if fileManager.fileExists(atPath: canonicalURL.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: canonicalURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw AgentDS4PathValidationError.rootDirectoryIsNotDirectory(canonicalURL.path)
            }
        }
        return canonicalURL.path
    }

    /// Canonicalizes a model path while preserving its relative-to-root form.
    /// Traversal is rejected rather than normalized away, which prevents a
    /// persisted path from changing meaning when the root later changes.
    public static func normalizedModelRelativePath(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentDS4PathValidationError.emptyModelRelativePath
        }
        guard !trimmed.contains("\0"), !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw AgentDS4PathValidationError.modelPathContainsInvalidCharacter(trimmed)
        }

        let hasWindowsAbsolutePrefix = trimmed.count >= 3
            && trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)] == ":"
            && (trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == "/"
                || trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == "\\")
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\"),
              !hasWindowsAbsolutePrefix,
              URL(string: trimmed)?.scheme == nil else {
            throw AgentDS4PathValidationError.modelPathMustBeRelative(trimmed)
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
            throw AgentDS4PathValidationError.modelPathContainsTraversal(trimmed)
        }

        let normalizedComponents = components.compactMap { component -> String? in
            guard !component.isEmpty, component != "." else {
                return nil
            }
            return String(component)
        }
        guard !normalizedComponents.isEmpty else {
            throw AgentDS4PathValidationError.emptyModelRelativePath
        }

        return normalizedComponents.joined(separator: "/")
    }

    /// Resolves an existing model and verifies that every path component is a
    /// regular, non-symbolic-link file below the canonical root.
    public static func resolveModelURL(
        rootDirectory: String,
        modelRelativePath: String,
        fileManager: FileManager = .default,
        requireExistingFile: Bool = true
    ) throws -> URL {
        let rootPath = try canonicalRootDirectory(rootDirectory, fileManager: fileManager)
        let relativePath = try normalizedModelRelativePath(modelRelativePath)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let candidateURL = rootURL
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL

        guard isDescendant(candidateURL, of: rootURL) else {
            throw AgentDS4PathValidationError.modelPathEscapesRoot(candidateURL.path)
        }

        var cursor = rootURL
        for component in relativePath.split(separator: "/") {
            cursor.appendPathComponent(String(component), isDirectory: false)
            if isSymbolicLink(cursor, fileManager: fileManager) {
                throw AgentDS4PathValidationError.modelPathContainsSymbolicLink(cursor.path)
            }
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: candidateURL.path,
            isDirectory: &isDirectory
        )
        if exists {
            let attributes = try fileManager.attributesOfItem(atPath: candidateURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw AgentDS4PathValidationError.modelPathNotRegularFile(candidateURL.path)
            }
        } else if requireExistingFile {
            throw AgentDS4PathValidationError.modelPathNotRegularFile(candidateURL.path)
        }

        let resolvedURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedURL, of: rootURL) else {
            throw AgentDS4PathValidationError.modelPathEscapesRoot(resolvedURL.path)
        }
        guard !isSymbolicLink(resolvedURL, fileManager: fileManager) else {
            throw AgentDS4PathValidationError.modelPathContainsSymbolicLink(resolvedURL.path)
        }
        return candidateURL
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == "/" {
            return candidatePath.hasPrefix("/") && candidatePath != rootPath
        }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }
}

/// Setup values for the dedicated DS4 runtime tuning options.
///
/// The setup runner uses this value both for the defaults shown to the user
/// and as a test seam, while ``AgentDS4RuntimeManifest`` remains the persisted
/// source of truth.
public struct AgentDS4RuntimeTuning: Codable, Equatable, Hashable, Sendable {
    public let contextWindow: Int
    public let ssdStreaming: Bool
    public let mtp: Bool
    public let power: Int

    public init(
        contextWindow: Int = 65_536,
        ssdStreaming: Bool = false,
        mtp: Bool = false,
        power: Int = 100
    ) {
        self.contextWindow = contextWindow
        self.ssdStreaming = ssdStreaming
        self.mtp = mtp
        self.power = power
    }
}

/// Persisted configuration for the optional local DS4 runtime.
///
/// The root is canonicalized at construction time. The model, when present,
/// is stored only as a relative path below that root. Runtime process identity,
/// ports and hardware handles intentionally have no representation here.
public struct AgentDS4RuntimeManifest: Codable, Equatable, Hashable, Sendable {
    public typealias Backend = AgentDS4RuntimeBackend

    private enum CodingKeys: String, CodingKey {
        case rootDirectory
        case modelRelativePath
        case backend
        case contextWindow
        case batchedSessions
        case ssdStreaming
        case ssdStreamingCacheExperts
        case ssdStreamingCacheBytes
        case ssdStreamingPreloadExperts
        case ssdStreamingCold
        case mtp
        case power
    }

    public let rootDirectory: String
    public let modelRelativePath: String?
    public let backend: AgentDS4RuntimeBackend
    public let contextWindow: Int
    public let batchedSessions: Bool
    public let ssdStreaming: Bool
    public let ssdStreamingCacheExperts: UInt32?
    public let ssdStreamingCacheBytes: UInt64?
    public let ssdStreamingPreloadExperts: UInt32?
    public let ssdStreamingCold: Bool
    public let mtp: Bool
    public let power: Int

    public init(
        rootDirectory: String,
        modelRelativePath: String? = nil,
        backend: AgentDS4RuntimeBackend = .metal,
        contextWindow: Int = 65_536,
        batchedSessions: Bool = false,
        ssdStreaming: Bool = false,
        ssdStreamingCacheExperts: UInt32? = nil,
        ssdStreamingCacheBytes: UInt64? = nil,
        ssdStreamingPreloadExperts: UInt32? = nil,
        ssdStreamingCold: Bool = false,
        mtp: Bool = false,
        power: Int = 100,
        fileManager: FileManager = .default
    ) throws {
        guard (1...1_048_576).contains(contextWindow) else {
            throw AgentDS4RuntimeConfigurationError.invalidContextWindow(contextWindow)
        }
        guard (1...100).contains(power) else {
            throw AgentDS4RuntimeConfigurationError.invalidPower(power)
        }

        let canonicalRoot = try AgentDS4PathGuard.canonicalRootDirectory(
            rootDirectory,
            fileManager: fileManager
        )
        let normalizedModelPath = try modelRelativePath.map {
            try AgentDS4PathGuard.normalizedModelRelativePath($0)
        }

        self.rootDirectory = canonicalRoot
        self.modelRelativePath = normalizedModelPath
        self.backend = backend
        self.contextWindow = contextWindow
        self.batchedSessions = batchedSessions
        self.ssdStreaming = ssdStreaming
        self.ssdStreamingCacheExperts = ssdStreamingCacheExperts
        self.ssdStreamingCacheBytes = ssdStreamingCacheBytes
        self.ssdStreamingPreloadExperts = ssdStreamingPreloadExperts
        self.ssdStreamingCold = ssdStreamingCold
        self.mtp = mtp
        self.power = power

        // Validate every existing path component even before a selected model
        // is materialized. Runtime resolution remains strict about existence.
        if let normalizedModelPath {
            _ = try AgentDS4PathGuard.resolveModelURL(
                rootDirectory: canonicalRoot,
                modelRelativePath: normalizedModelPath,
                fileManager: fileManager,
                requireExistingFile: false
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rootDirectory: try container.decode(String.self, forKey: .rootDirectory),
            modelRelativePath: try container.decodeIfPresent(String.self, forKey: .modelRelativePath),
            backend: try container.decodeIfPresent(
                AgentDS4RuntimeBackend.self,
                forKey: .backend
            ) ?? .metal,
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 65_536,
            batchedSessions: try container.decodeIfPresent(Bool.self, forKey: .batchedSessions) ?? false,
            ssdStreaming: try container.decodeIfPresent(Bool.self, forKey: .ssdStreaming) ?? false,
            ssdStreamingCacheExperts: try container.decodeIfPresent(
                UInt32.self,
                forKey: .ssdStreamingCacheExperts
            ),
            ssdStreamingCacheBytes: try container.decodeIfPresent(
                UInt64.self,
                forKey: .ssdStreamingCacheBytes
            ),
            ssdStreamingPreloadExperts: try container.decodeIfPresent(
                UInt32.self,
                forKey: .ssdStreamingPreloadExperts
            ),
            ssdStreamingCold: try container.decodeIfPresent(Bool.self, forKey: .ssdStreamingCold) ?? false,
            mtp: try container.decodeIfPresent(Bool.self, forKey: .mtp) ?? false,
            power: try container.decodeIfPresent(Int.self, forKey: .power) ?? 100
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootDirectory, forKey: .rootDirectory)
        try container.encodeIfPresent(modelRelativePath, forKey: .modelRelativePath)
        try container.encode(backend, forKey: .backend)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(batchedSessions, forKey: .batchedSessions)
        try container.encode(ssdStreaming, forKey: .ssdStreaming)
        try container.encodeIfPresent(ssdStreamingCacheExperts, forKey: .ssdStreamingCacheExperts)
        try container.encodeIfPresent(ssdStreamingCacheBytes, forKey: .ssdStreamingCacheBytes)
        try container.encodeIfPresent(ssdStreamingPreloadExperts, forKey: .ssdStreamingPreloadExperts)
        try container.encode(ssdStreamingCold, forKey: .ssdStreamingCold)
        try container.encode(mtp, forKey: .mtp)
        try container.encode(power, forKey: .power)
    }

    /// Resolves the configured model when one is selected. Resolution is
    /// intentionally strict and fails if the file is missing, symlinked or
    /// outside the canonical root.
    public func resolvedModelURL(
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let modelRelativePath else {
            return nil
        }
        return try AgentDS4PathGuard.resolveModelURL(
            rootDirectory: rootDirectory,
            modelRelativePath: modelRelativePath,
            fileManager: fileManager
        )
    }

    /// Strict non-optional variant for runtime code that requires a model.
    public func requiredModelURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let modelURL = try resolvedModelURL(fileManager: fileManager) else {
            throw AgentDS4PathValidationError.emptyModelRelativePath
        }
        return modelURL
    }

    /// Alias useful to runtime adapters that use an imperative verb.
    public func resolveModelURL(
        fileManager: FileManager = .default
    ) throws -> URL? {
        try resolvedModelURL(fileManager: fileManager)
    }
}

/// Compatibility spelling for code that calls persisted DS4 values configuration.
public typealias AgentDS4RuntimeConfiguration = AgentDS4RuntimeManifest
