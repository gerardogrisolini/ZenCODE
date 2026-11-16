//
//  AgentDS4RuntimeManifest.swift
//  ZenCODE
//
//  Persisted configuration for the optional local DS4 runtime: the canonical
//  root, the relative model and auxiliary paths, the engine options, and
//  their validation.
//

import Foundation

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
