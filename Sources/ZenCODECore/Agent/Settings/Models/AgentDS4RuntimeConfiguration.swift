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

/// Compatibility spelling used by callers that expose the guard as a
/// validation service.
public typealias AgentDS4PathGuardError = AgentDS4PathValidationError

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

/// Persisted configuration for the optional local DS4 runtime.
///
/// The root is canonicalized at construction time. The model and the optional
/// auxiliary files (vision projector, MTP/DSpark GGUF, steering file) are
/// stored only as relative paths below that root. Runtime process identity,
/// ports and hardware handles intentionally have no representation here.
///
/// The engine runs in-process, so these values map one-to-one to the
/// `key=value` options of `zencode_ds4_engine_open`. The format is additive:
/// every key introduced after the first release is optional when decoding, and
/// the retired `batchedSessions` key is ignored.
public struct AgentDS4RuntimeManifest: Codable, Equatable, Hashable, Sendable {
    public typealias Backend = AgentDS4RuntimeBackend

    /// Default number of sessions the engine keeps (`session_count`).
    public static let defaultEngineSessions = 2
    public static let engineSessionsRange = 1...8
    public static let mtpDraftTokensRange = 1...16
    public static let mtpMarginRange = 0.0...1000.0
    public static let steeringScaleRange = -100.0...100.0

    private enum CodingKeys: String, CodingKey {
        case rootDirectory
        case modelRelativePath
        case backend
        case contextWindow
        case ssdStreaming
        case ssdStreamingCacheExperts
        case ssdStreamingCacheBytes
        case ssdStreamingPreloadExperts
        case ssdStreamingCold
        case mtp
        case power
        case visionRelativePath
        case mtpRelativePath
        case steeringRelativePath
        case dspark
        case mtpDraftTokens
        case mtpMargin
        case quality
        case threads
        case prefillChunk
        case warmWeights
        case steeringFFN
        case steeringAttn
        case cudaArch
        case rocmArch
        case engineSessions
        case extraEngineArguments
    }

    public let rootDirectory: String
    public let modelRelativePath: String?
    public let backend: AgentDS4RuntimeBackend
    public let contextWindow: Int
    public let ssdStreaming: Bool
    public let ssdStreamingCacheExperts: UInt32?
    public let ssdStreamingCacheBytes: UInt64?
    public let ssdStreamingPreloadExperts: UInt32?
    public let ssdStreamingCold: Bool
    /// GLM internal MTP (`glm_mtp`, `--mtp`). The MTP/DSpark support GGUF is
    /// `mtpRelativePath`.
    public let mtp: Bool
    public let power: Int
    /// Vision projector GGUF (`vision_path`), relative to `rootDirectory`.
    public let visionRelativePath: String?
    /// MTP / DSpark support GGUF (`mtp_path`, `--mtp-model`), relative to `rootDirectory`.
    public let mtpRelativePath: String?
    /// Directional steering file (`directional_steering_file`), relative to
    /// `rootDirectory`. Not necessarily a GGUF.
    public let steeringRelativePath: String?
    /// `dspark` (`--dspark`).
    public let dspark: Bool
    /// `mtp_draft_tokens` (`--mtp-draft`), 1...16.
    public let mtpDraftTokens: Int?
    /// `mtp_margin` (`--mtp-margin`), 0...1000.
    public let mtpMargin: Double?
    public let quality: Bool
    /// `n_threads`, greater than zero.
    public let threads: Int?
    /// `prefill_chunk`, greater than zero.
    public let prefillChunk: Int?
    public let warmWeights: Bool
    /// `directional_steering_ffn`, -100...100.
    public let steeringFFN: Double?
    /// `directional_steering_attn`, -100...100.
    public let steeringAttn: Double?
    /// CUDA architecture the engine library is built for (for example `sm_120` or `native`).
    public let cudaArch: String?
    /// ROCm target the engine library is built for (for example `gfx1151`).
    public let rocmArch: String?
    /// Number of sessions the engine keeps (`session_count`), 1...8.
    public let engineSessions: Int
    /// Opaque `extra_arg` tokens (distributed / tensor-parallel / multi-GPU);
    /// the engine validates them when it opens.
    public let extraEngineArguments: [String]

    public init(
        rootDirectory: String,
        modelRelativePath: String? = nil,
        backend: AgentDS4RuntimeBackend = .metal,
        contextWindow: Int = 65_536,
        ssdStreaming: Bool = false,
        ssdStreamingCacheExperts: UInt32? = nil,
        ssdStreamingCacheBytes: UInt64? = nil,
        ssdStreamingPreloadExperts: UInt32? = nil,
        ssdStreamingCold: Bool = false,
        mtp: Bool = false,
        power: Int = 100,
        visionRelativePath: String? = nil,
        mtpRelativePath: String? = nil,
        steeringRelativePath: String? = nil,
        dspark: Bool = false,
        mtpDraftTokens: Int? = nil,
        mtpMargin: Double? = nil,
        quality: Bool = false,
        threads: Int? = nil,
        prefillChunk: Int? = nil,
        warmWeights: Bool = false,
        steeringFFN: Double? = nil,
        steeringAttn: Double? = nil,
        cudaArch: String? = nil,
        rocmArch: String? = nil,
        engineSessions: Int = AgentDS4RuntimeManifest.defaultEngineSessions,
        extraEngineArguments: [String] = [],
        fileManager: FileManager = .default
    ) throws {
        guard (1...1_048_576).contains(contextWindow) else {
            throw AgentDS4RuntimeConfigurationError.invalidContextWindow(contextWindow)
        }
        guard (1...100).contains(power) else {
            throw AgentDS4RuntimeConfigurationError.invalidPower(power)
        }
        if let mtpDraftTokens, !Self.mtpDraftTokensRange.contains(mtpDraftTokens) {
            throw AgentDS4RuntimeConfigurationError.invalidMTPDraftTokens(mtpDraftTokens)
        }
        if let mtpMargin, !Self.mtpMarginRange.contains(mtpMargin) {
            throw AgentDS4RuntimeConfigurationError.invalidMTPMargin(mtpMargin)
        }
        if let threads, threads < 1 {
            throw AgentDS4RuntimeConfigurationError.invalidThreads(threads)
        }
        if let prefillChunk, prefillChunk < 1 {
            throw AgentDS4RuntimeConfigurationError.invalidPrefillChunk(prefillChunk)
        }
        if let steeringFFN, !Self.steeringScaleRange.contains(steeringFFN) {
            throw AgentDS4RuntimeConfigurationError.invalidSteeringFFN(steeringFFN)
        }
        if let steeringAttn, !Self.steeringScaleRange.contains(steeringAttn) {
            throw AgentDS4RuntimeConfigurationError.invalidSteeringAttn(steeringAttn)
        }
        guard Self.engineSessionsRange.contains(engineSessions) else {
            throw AgentDS4RuntimeConfigurationError.invalidEngineSessions(engineSessions)
        }
        let normalizedCUDAArch = try Self.normalizedArchitecture(cudaArch, option: "cudaArch")
        let normalizedROCmArch = try Self.normalizedArchitecture(rocmArch, option: "rocmArch")
        for argument in extraEngineArguments where !Self.isValidEngineArgument(argument) {
            throw AgentDS4RuntimeConfigurationError.invalidEngineArgument(argument)
        }

        let canonicalRoot = try AgentDS4PathGuard.canonicalRootDirectory(
            rootDirectory,
            fileManager: fileManager
        )
        let normalizedModelPath = try modelRelativePath.map {
            try AgentDS4PathGuard.normalizedModelRelativePath($0)
        }
        let normalizedVisionPath = try Self.validatedAuxiliaryPath(
            visionRelativePath,
            option: "vision",
            rootDirectory: canonicalRoot,
            fileManager: fileManager
        )
        let normalizedMTPPath = try Self.validatedAuxiliaryPath(
            mtpRelativePath,
            option: "MTP",
            rootDirectory: canonicalRoot,
            fileManager: fileManager
        )
        let normalizedSteeringPath = try Self.validatedAuxiliaryPath(
            steeringRelativePath,
            option: "steering",
            rootDirectory: canonicalRoot,
            fileManager: fileManager
        )

        self.rootDirectory = canonicalRoot
        self.modelRelativePath = normalizedModelPath
        self.backend = backend
        self.contextWindow = contextWindow
        self.ssdStreaming = ssdStreaming
        self.ssdStreamingCacheExperts = ssdStreamingCacheExperts
        self.ssdStreamingCacheBytes = ssdStreamingCacheBytes
        self.ssdStreamingPreloadExperts = ssdStreamingPreloadExperts
        self.ssdStreamingCold = ssdStreamingCold
        self.mtp = mtp
        self.power = power
        self.visionRelativePath = normalizedVisionPath
        self.mtpRelativePath = normalizedMTPPath
        self.steeringRelativePath = normalizedSteeringPath
        self.dspark = dspark
        self.mtpDraftTokens = mtpDraftTokens
        self.mtpMargin = mtpMargin
        self.quality = quality
        self.threads = threads
        self.prefillChunk = prefillChunk
        self.warmWeights = warmWeights
        self.steeringFFN = steeringFFN
        self.steeringAttn = steeringAttn
        self.cudaArch = normalizedCUDAArch
        self.rocmArch = normalizedROCmArch
        self.engineSessions = engineSessions
        self.extraEngineArguments = extraEngineArguments

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
        // `batchedSessions` (retired with the external ds4-server) is not a
        // coding key, so a stored value is skipped here and dropped on the
        // next write.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rootDirectory: try container.decode(String.self, forKey: .rootDirectory),
            modelRelativePath: try container.decodeIfPresent(String.self, forKey: .modelRelativePath),
            backend: try container.decodeIfPresent(
                AgentDS4RuntimeBackend.self,
                forKey: .backend
            ) ?? .metal,
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 65_536,
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
            power: try container.decodeIfPresent(Int.self, forKey: .power) ?? 100,
            visionRelativePath: try container.decodeIfPresent(String.self, forKey: .visionRelativePath),
            mtpRelativePath: try container.decodeIfPresent(String.self, forKey: .mtpRelativePath),
            steeringRelativePath: try container.decodeIfPresent(String.self, forKey: .steeringRelativePath),
            dspark: try container.decodeIfPresent(Bool.self, forKey: .dspark) ?? false,
            mtpDraftTokens: try container.decodeIfPresent(Int.self, forKey: .mtpDraftTokens),
            mtpMargin: try container.decodeIfPresent(Double.self, forKey: .mtpMargin),
            quality: try container.decodeIfPresent(Bool.self, forKey: .quality) ?? false,
            threads: try container.decodeIfPresent(Int.self, forKey: .threads),
            prefillChunk: try container.decodeIfPresent(Int.self, forKey: .prefillChunk),
            warmWeights: try container.decodeIfPresent(Bool.self, forKey: .warmWeights) ?? false,
            steeringFFN: try container.decodeIfPresent(Double.self, forKey: .steeringFFN),
            steeringAttn: try container.decodeIfPresent(Double.self, forKey: .steeringAttn),
            cudaArch: try container.decodeIfPresent(String.self, forKey: .cudaArch),
            rocmArch: try container.decodeIfPresent(String.self, forKey: .rocmArch),
            engineSessions: try container.decodeIfPresent(Int.self, forKey: .engineSessions)
                ?? Self.defaultEngineSessions,
            extraEngineArguments: try container.decodeIfPresent(
                [String].self,
                forKey: .extraEngineArguments
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootDirectory, forKey: .rootDirectory)
        try container.encodeIfPresent(modelRelativePath, forKey: .modelRelativePath)
        try container.encode(backend, forKey: .backend)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(ssdStreaming, forKey: .ssdStreaming)
        try container.encodeIfPresent(ssdStreamingCacheExperts, forKey: .ssdStreamingCacheExperts)
        try container.encodeIfPresent(ssdStreamingCacheBytes, forKey: .ssdStreamingCacheBytes)
        try container.encodeIfPresent(ssdStreamingPreloadExperts, forKey: .ssdStreamingPreloadExperts)
        try container.encode(ssdStreamingCold, forKey: .ssdStreamingCold)
        try container.encode(mtp, forKey: .mtp)
        try container.encode(power, forKey: .power)
        try container.encodeIfPresent(visionRelativePath, forKey: .visionRelativePath)
        try container.encodeIfPresent(mtpRelativePath, forKey: .mtpRelativePath)
        try container.encodeIfPresent(steeringRelativePath, forKey: .steeringRelativePath)
        try container.encode(dspark, forKey: .dspark)
        try container.encodeIfPresent(mtpDraftTokens, forKey: .mtpDraftTokens)
        try container.encodeIfPresent(mtpMargin, forKey: .mtpMargin)
        try container.encode(quality, forKey: .quality)
        try container.encodeIfPresent(threads, forKey: .threads)
        try container.encodeIfPresent(prefillChunk, forKey: .prefillChunk)
        try container.encode(warmWeights, forKey: .warmWeights)
        try container.encodeIfPresent(steeringFFN, forKey: .steeringFFN)
        try container.encodeIfPresent(steeringAttn, forKey: .steeringAttn)
        try container.encodeIfPresent(cudaArch, forKey: .cudaArch)
        try container.encodeIfPresent(rocmArch, forKey: .rocmArch)
        try container.encode(engineSessions, forKey: .engineSessions)
        if !extraEngineArguments.isEmpty {
            try container.encode(extraEngineArguments, forKey: .extraEngineArguments)
        }
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

    /// Resolves the vision projector with the same rigor as the model: it must
    /// be an existing regular file below the root, without symbolic links.
    public func resolvedVisionURL(
        fileManager: FileManager = .default
    ) throws -> URL? {
        try Self.resolvedAuxiliaryURL(
            visionRelativePath,
            option: "vision",
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )
    }

    /// Resolves the MTP / DSpark support GGUF like ``resolvedModelURL(fileManager:)``.
    public func resolvedMTPURL(
        fileManager: FileManager = .default
    ) throws -> URL? {
        try Self.resolvedAuxiliaryURL(
            mtpRelativePath,
            option: "MTP",
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )
    }

    /// Resolves the directional steering file like ``resolvedModelURL(fileManager:)``.
    public func resolvedSteeringURL(
        fileManager: FileManager = .default
    ) throws -> URL? {
        try Self.resolvedAuxiliaryURL(
            steeringRelativePath,
            option: "steering",
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )
    }

    // MARK: Validation helpers

    /// The architecture of a build target ends up on a command line, so only
    /// `[A-Za-z0-9_.-]+` is accepted. Blank values mean "use the default" and
    /// are stored as `nil`.
    static func normalizedArchitecture(_ value: String?, option: String) throws -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let isValid = trimmed.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "-":
                return true
            default:
                return false
            }
        }
        guard isValid else {
            throw AgentDS4RuntimeConfigurationError.invalidArchitecture(option: option, value: trimmed)
        }
        return trimmed
    }

    /// Engine arguments are opaque (the engine validates them on open); only
    /// tokens that cannot survive a `key=value` string are rejected here.
    static func isValidEngineArgument(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func validatedAuxiliaryPath(
        _ value: String?,
        option: String,
        rootDirectory: String,
        fileManager: FileManager
    ) throws -> String? {
        guard let value else {
            return nil
        }
        do {
            let normalized = try AgentDS4PathGuard.normalizedModelRelativePath(value)
            _ = try AgentDS4PathGuard.resolveModelURL(
                rootDirectory: rootDirectory,
                modelRelativePath: normalized,
                fileManager: fileManager,
                requireExistingFile: false
            )
            return normalized
        } catch let error as AgentDS4PathValidationError {
            throw Self.auxiliaryError(error, option: option)
        }
    }

    private static func resolvedAuxiliaryURL(
        _ relativePath: String?,
        option: String,
        rootDirectory: String,
        fileManager: FileManager
    ) throws -> URL? {
        guard let relativePath else {
            return nil
        }
        do {
            return try AgentDS4PathGuard.resolveModelURL(
                rootDirectory: rootDirectory,
                modelRelativePath: relativePath,
                fileManager: fileManager
            )
        } catch let error as AgentDS4PathValidationError {
            throw Self.auxiliaryError(error, option: option)
        }
    }

    private static func auxiliaryError(
        _ error: AgentDS4PathValidationError,
        option: String
    ) -> AgentDS4PathValidationError {
        if case .auxiliaryFileInvalid = error {
            return error
        }
        return .auxiliaryFileInvalid(
            option: option,
            reason: error.errorDescription ?? String(describing: error)
        )
    }
}

/// Compatibility spelling for code that calls persisted DS4 values configuration.
public typealias AgentDS4RuntimeConfiguration = AgentDS4RuntimeManifest
