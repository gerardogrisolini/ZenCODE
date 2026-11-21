//
//  DS4LocalGeneration.swift
//  ZenCODE
//
//  What a `RemoteGenerationClient` needs to generate through the in-process
//  DS4 engine: the model manifest, the process-wide engine registry and the
//  resolver that turns the manifest into a `DS4EngineConfiguration`.
//  `AgentRemoteBackendFactory` attaches one to every client whose selection
//  has a DS4 runtime; sub-agents built by the contextual factory share the
//  same environment (registry + resolver), hence the same engine and the
//  same FIFO generation lock.
//

import Foundation

struct DS4LocalGeneration: Sendable {
    typealias ConfigurationResolver = @Sendable (AgentDS4RuntimeManifest) throws -> DS4EngineConfiguration
    /// State of the engine library of a manifest (`/ds4 status`).
    typealias LibraryStatusResolver = @Sendable (AgentDS4RuntimeManifest) -> DS4EngineLibraryStatus

    /// Registry and configuration resolver shared by a backend and its sub-agents.
    struct Environment: Sendable {
        let registry: DS4EngineRegistry
        let resolveConfiguration: ConfigurationResolver
        let libraryStatus: LibraryStatusResolver

        init(
            registry: DS4EngineRegistry,
            resolveConfiguration: @escaping ConfigurationResolver,
            libraryStatus: @escaping LibraryStatusResolver = { manifest in
                DS4EngineConfigurationMapping.libraryStatus(for: manifest)
            }
        ) {
            self.registry = registry
            self.resolveConfiguration = resolveConfiguration
            self.libraryStatus = libraryStatus
        }

        /// `DS4EngineRegistry.shared` and the real manifest mapping.
        static let production = Environment(
            registry: .shared,
            resolveConfiguration: { manifest in
                try DS4EngineConfigurationMapping.configuration(for: manifest)
            }
        )
    }

    let manifest: AgentDS4RuntimeManifest
    let environment: Environment

    init(manifest: AgentDS4RuntimeManifest, environment: Environment = .production) {
        self.manifest = manifest
        self.environment = environment
    }

    var registry: DS4EngineRegistry {
        environment.registry
    }

    /// The engine configuration of the manifest. Throws
    /// `DS4EngineError.libraryUnavailable` when the engine library is not
    /// built (or stale) and the manifest path errors when a file is invalid.
    func engineConfiguration() throws -> DS4EngineConfiguration {
        try environment.resolveConfiguration(manifest)
    }
}

/// Maps a manifest to the `key=value` options of `zencode_ds4_engine_open`
/// (key list in `zencode_ds4_abi.h`) and locates the engine library.
enum DS4EngineConfigurationMapping {
    static let bytesPerGiB: UInt64 = 1 << 30

    /// The full engine configuration. The library must be `.built` for the
    /// manifest's root, backend and architecture; otherwise
    /// `DS4EngineError.libraryUnavailable` carries the manual build command.
    static func configuration(
        for manifest: AgentDS4RuntimeManifest,
        supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL(),
        fileManager: FileManager = .default
    ) throws -> DS4EngineConfiguration {
        let hint = DS4EngineBuilder.manualCommand(for: buildRequest(for: manifest, supportDirectory: supportDirectory))
        let status = libraryStatus(for: manifest, supportDirectory: supportDirectory)
        let libraryURL: URL
        switch status {
        case let .built(url):
            libraryURL = url
        case let .missing(expected):
            throw DS4EngineError.libraryUnavailable(
                reason: "libzencode-ds4 is not built for the \(manifest.backend.rawValue) backend (expected at \(expected.path))",
                hint: hint
            )
        case let .stale(found, expected):
            throw DS4EngineError.libraryUnavailable(
                reason: "libzencode-ds4 at \(found.path) was built from other sources, another DS4 root or another "
                    + "architecture (expected at \(expected.path))",
                hint: hint
            )
        }
        return DS4EngineConfiguration(
            libraryURL: libraryURL,
            options: try options(for: manifest, fileManager: fileManager),
            contextSize: manifest.contextWindow,
            sessionCapacity: manifest.engineSessions,
            buildHint: hint
        )
    }

    /// Whether the engine library of `manifest` is built, missing or stale.
    static func libraryStatus(
        for manifest: AgentDS4RuntimeManifest,
        supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL()
    ) -> DS4EngineLibraryStatus {
        DS4EngineLibraryLocator.status(
            rootDirectory: manifest.rootDirectory,
            backend: manifest.backend,
            arch: architecture(for: manifest),
            supportDirectory: supportDirectory
        )
    }

    static func buildRequest(
        for manifest: AgentDS4RuntimeManifest,
        supportDirectory: URL
    ) -> DS4EngineBuildRequest {
        DS4EngineBuildRequest(
            rootDirectory: manifest.rootDirectory,
            backend: manifest.backend,
            cudaArch: manifest.cudaArch,
            rocmArch: manifest.rocmArch,
            supportDirectory: supportDirectory
        )
    }

    /// The architecture the library is built for (`cudaArch` / `rocmArch`).
    static func architecture(for manifest: AgentDS4RuntimeManifest) -> String? {
        switch manifest.backend {
        case .cuda:
            manifest.cudaArch
        case .rocm:
            manifest.rocmArch
        case .metal, .cpu:
            nil
        }
    }

    /// Engine options of the manifest, in a stable order. Paths are absolute
    /// and resolved by the manifest resolvers (missing, symlinked or escaping
    /// files throw). Boolean options are passed only when enabled, optional
    /// values only when set; `extra_arg` keeps the manifest order.
    static func options(
        for manifest: AgentDS4RuntimeManifest,
        fileManager: FileManager = .default
    ) throws -> [DS4EngineOption] {
        var options: [DS4EngineOption] = []
        func add(_ key: String, _ value: String) {
            options.append(DS4EngineOption(key: key, value: value))
        }
        func add(_ key: String, flag: Bool) {
            if flag {
                add(key, "1")
            }
        }

        add("ds4_root", manifest.rootDirectory)
        add("model_path", try manifest.requiredModelURL(fileManager: fileManager).path)
        if let url = try manifest.resolvedMTPURL(fileManager: fileManager) {
            add("mtp_path", url.path)
        }
        if let url = try manifest.resolvedVisionURL(fileManager: fileManager) {
            add("vision_path", url.path)
        }
        add("backend", manifest.backend.rawValue)
        if let threads = manifest.threads {
            add("n_threads", String(threads))
        }
        add("context_size", String(manifest.contextWindow))
        add("session_count", String(manifest.engineSessions))
        if let prefillChunk = manifest.prefillChunk {
            add("prefill_chunk", String(prefillChunk))
        }
        if let draftTokens = manifest.mtpDraftTokens {
            add("mtp_draft_tokens", String(draftTokens))
        }
        if let margin = manifest.mtpMargin {
            add("mtp_margin", format(margin))
        }
        add("glm_mtp", flag: manifest.mtp)
        add("dspark", flag: manifest.dspark)
        add("power_percent", String(manifest.power))
        add("quality", flag: manifest.quality)
        add("warm_weights", flag: manifest.warmWeights)
        add("ssd_streaming", flag: manifest.ssdStreaming)
        add("ssd_streaming_cold", flag: manifest.ssdStreamingCold)
        if let cache = cacheExpertsValue(
            experts: manifest.ssdStreamingCacheExperts,
            bytes: manifest.ssdStreamingCacheBytes
        ) {
            add("ssd_streaming_cache_experts", cache)
        }
        if let preload = manifest.ssdStreamingPreloadExperts {
            add("ssd_streaming_preload_experts", String(preload))
        }
        if let url = try manifest.resolvedSteeringURL(fileManager: fileManager) {
            add("directional_steering_file", url.path)
        }
        if let ffn = manifest.steeringFFN {
            add("directional_steering_ffn", format(ffn))
        }
        if let attn = manifest.steeringAttn {
            add("directional_steering_attn", format(attn))
        }
        for argument in manifest.extraEngineArguments {
            add("extra_arg", argument)
        }
        return options
    }

    /// `ssd_streaming_cache_experts`: an expert count, or a byte budget as
    /// whole GiB (`<N>GB`, rounded down, at least 1). The count wins when
    /// both are set (the key cannot repeat).
    static func cacheExpertsValue(experts: UInt32?, bytes: UInt64?) -> String? {
        if let experts, experts > 0 {
            return String(experts)
        }
        if let bytes, bytes > 0 {
            return "\(max(bytes / bytesPerGiB, 1))GB"
        }
        return nil
    }

    /// Decimal text for the shim's float parser: whole values without a
    /// trailing ".0", the others in Swift's shortest round-trip form.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}
