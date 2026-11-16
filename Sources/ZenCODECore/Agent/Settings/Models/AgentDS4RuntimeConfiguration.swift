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
    /// An auxiliary file (vision projector, MTP/DSpark GGUF, steering file)
    /// failed the same checks as the model path. `reason` is the description
    /// of the underlying path error.
    case auxiliaryFileInvalid(option: String, reason: String)

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
        case let .auxiliaryFileInvalid(option, reason):
            return "The DS4 \(option) file is invalid: \(reason)"
        }
    }
}

public enum AgentDS4RuntimeConfigurationError: LocalizedError, Equatable, Sendable {
    case invalidContextWindow(Int)
    case invalidPower(Int)
    case invalidMTPDraftTokens(Int)
    case invalidMTPMargin(Double)
    case invalidThreads(Int)
    case invalidPrefillChunk(Int)
    case invalidSteeringFFN(Double)
    case invalidSteeringAttn(Double)
    case invalidEngineSessions(Int)
    /// `option` is `cudaArch` or `rocmArch`.
    case invalidArchitecture(option: String, value: String)
    case invalidEngineArgument(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidContextWindow(value):
            return "The DS4 context window must be between 1 and 1048576 tokens (got \(value))."
        case let .invalidPower(value):
            return "The DS4 power must be between 1 and 100 (got \(value))."
        case let .invalidMTPDraftTokens(value):
            return "The DS4 MTP draft tokens must be between 1 and 16 (got \(value))."
        case let .invalidMTPMargin(value):
            return "The DS4 MTP margin must be between 0 and 1000 (got \(value))."
        case let .invalidThreads(value):
            return "The DS4 thread count must be greater than 0 (got \(value))."
        case let .invalidPrefillChunk(value):
            return "The DS4 prefill chunk must be greater than 0 (got \(value))."
        case let .invalidSteeringFFN(value):
            return "The DS4 FFN steering scale must be between -100 and 100 (got \(value))."
        case let .invalidSteeringAttn(value):
            return "The DS4 attention steering scale must be between -100 and 100 (got \(value))."
        case let .invalidEngineSessions(value):
            return "The DS4 engine session count must be between 1 and 8 (got \(value))."
        case let .invalidArchitecture(option, value):
            return "The DS4 \(option) value '\(value)' is invalid: use letters, digits, '_', '.' and '-' only (for example sm_120, native or gfx1151)."
        case let .invalidEngineArgument(value):
            return "The DS4 extra engine argument '\(value)' is invalid: it must not be empty or contain a newline or NUL character."
        }
    }
}

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
/// source of truth. It carries every scalar launch option plus the steering
/// file; the vision and MTP/DSpark GGUFs are chosen from the DS4 folder
/// listing instead, so they have no field here.
public struct AgentDS4RuntimeTuning: Codable, Equatable, Hashable, Sendable {
    public let contextWindow: Int
    public let ssdStreaming: Bool
    /// GLM internal MTP (`--mtp`); the MTP/DSpark support GGUF is separate.
    public let mtp: Bool
    public let power: Int
    public let dspark: Bool
    public let mtpDraftTokens: Int?
    public let mtpMargin: Double?
    public let quality: Bool
    public let threads: Int?
    public let prefillChunk: Int?
    public let warmWeights: Bool
    /// Steering direction file, relative to the DS4 folder.
    public let steeringRelativePath: String?
    public let steeringFFN: Double?
    public let steeringAttn: Double?
    public let cudaArch: String?
    public let rocmArch: String?
    public let engineSessions: Int
    public let extraEngineArguments: [String]

    public init(
        contextWindow: Int = 65_536,
        ssdStreaming: Bool = false,
        mtp: Bool = false,
        power: Int = 100,
        dspark: Bool = false,
        mtpDraftTokens: Int? = nil,
        mtpMargin: Double? = nil,
        quality: Bool = false,
        threads: Int? = nil,
        prefillChunk: Int? = nil,
        warmWeights: Bool = false,
        steeringRelativePath: String? = nil,
        steeringFFN: Double? = nil,
        steeringAttn: Double? = nil,
        cudaArch: String? = nil,
        rocmArch: String? = nil,
        engineSessions: Int = AgentDS4RuntimeManifest.defaultEngineSessions,
        extraEngineArguments: [String] = []
    ) {
        self.contextWindow = contextWindow
        self.ssdStreaming = ssdStreaming
        self.mtp = mtp
        self.power = power
        self.dspark = dspark
        self.mtpDraftTokens = mtpDraftTokens
        self.mtpMargin = mtpMargin
        self.quality = quality
        self.threads = threads
        self.prefillChunk = prefillChunk
        self.warmWeights = warmWeights
        self.steeringRelativePath = steeringRelativePath
        self.steeringFFN = steeringFFN
        self.steeringAttn = steeringAttn
        self.cudaArch = cudaArch
        self.rocmArch = rocmArch
        self.engineSessions = engineSessions
        self.extraEngineArguments = extraEngineArguments
    }
}

/// Compatibility spelling for code that calls persisted DS4 values configuration.
public typealias AgentDS4RuntimeConfiguration = AgentDS4RuntimeManifest
