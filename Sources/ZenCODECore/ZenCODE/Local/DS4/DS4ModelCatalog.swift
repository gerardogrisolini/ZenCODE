//
//  DS4ModelCatalog.swift
//  ZenCODE
//
//  A local, evidence-backed catalog of runnable DS4 artifacts.
//

import Foundation

public struct DS4ModelResourceEstimate: Codable, Equatable, Hashable, Sendable {
    /// Approximate bytes occupied by the downloaded artifact(s), when the
    /// checkout documents a size. This is a disk requirement, not RAM.
    public let diskBytes: UInt64?
    /// Approximate RAM for resident operation, when the checkout documents it.
    public let residentMemoryBytes: UInt64?
    /// Approximate RAM for an explicitly supported SSD-streaming setup.
    public let streamingMemoryBytes: UInt64?
    public let isApproximate: Bool

    public init(
        diskBytes: UInt64? = nil,
        residentMemoryBytes: UInt64? = nil,
        streamingMemoryBytes: UInt64? = nil,
        isApproximate: Bool = true
    ) {
        self.diskBytes = diskBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.streamingMemoryBytes = streamingMemoryBytes
        self.isApproximate = isApproximate
    }
}

public enum DS4ModelArtifactRole: String, Codable, CaseIterable, Hashable, Sendable {
    case model
    case modelShard
}

public struct DS4ModelArtifact: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let role: DS4ModelArtifactRole

    public init(relativePath: String, role: DS4ModelArtifactRole = .model) {
        self.relativePath = relativePath
        self.role = role
    }
}

public struct DS4ModelCatalogEntry: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// The argument accepted by the checkout's `download_model.sh` target.
    public let downloadTarget: String
    public let artifacts: [DS4ModelArtifact]
    public let resources: DS4ModelResourceEstimate
    public let supportedBackends: [AgentDS4RuntimeBackend]
    public let supportsSSDStreaming: Bool
    public let evidence: [String]
    public let notes: [String]

    public init(
        id: String,
        displayName: String,
        downloadTarget: String,
        artifacts: [DS4ModelArtifact],
        resources: DS4ModelResourceEstimate,
        supportedBackends: [AgentDS4RuntimeBackend],
        supportsSSDStreaming: Bool = false,
        evidence: [String] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.downloadTarget = downloadTarget
        self.artifacts = artifacts
        self.resources = resources
        self.supportedBackends = supportedBackends
        self.supportsSSDStreaming = supportsSSDStreaming
        self.evidence = evidence
        self.notes = notes
    }

    public var modelID: String { id }

    /// The identifier accepted by the ds4 OpenAI-compatible API.
    ///
    /// Catalog ids intentionally describe download targets/quantizations and
    /// are not necessarily model ids exposed by ``/v1/models``. Keep the
    /// catalog identity for selection and persistence keys, but use this
    /// value for provider payloads and readiness checks.
    public var apiModelID: String {
        DS4ModelCatalog.canonicalAPIModelID(forCatalogID: id)
    }

    /// Compatibility spelling for callers that call the wire id an alias.
    public var apiAlias: String { apiModelID }

    public var diskBytes: UInt64? { resources.diskBytes }
    public var residentMemoryBytes: UInt64? { resources.residentMemoryBytes }
    public var streamingMemoryBytes: UInt64? { resources.streamingMemoryBytes }

    public var expectedRelativePaths: [String] {
        artifacts.map(\.relativePath)
    }

    public func supports(backend: AgentDS4RuntimeBackend) -> Bool {
        supportedBackends.contains(backend)
    }

    public func installationState(
        in installation: DS4InstallationSnapshot
    ) -> DS4ModelInstallationState {
        let present = artifacts.filter { installation.contains(relativePath: $0.relativePath) }.count
        if present == artifacts.count { return .installed }
        if present > 0 { return .partial }
        return .missing
    }
}

public enum DS4ModelInstallationState: String, Codable, CaseIterable, Hashable, Sendable {
    case installed
    case partial
    case missing
}

/// Catalog evidence captured from the checked-out DS4 tree. The catalog is
/// intentionally static and offline: it never downloads, builds, or parses a
/// GGUF header. Unknown model sizes remain nil instead of being inferred from
/// file size or a different model's requirements.
public struct DS4ModelCatalog: Codable, Equatable, Sendable {
    public let entries: [DS4ModelCatalogEntry]

    public init(entries: [DS4ModelCatalogEntry] = DS4ModelCatalog.defaultEntries) {
        self.entries = entries
    }

    public static var `default`: DS4ModelCatalog {
        DS4ModelCatalog()
    }

    public static var current: DS4ModelCatalog {
        DS4ModelCatalog()
    }

    /// Maps a catalog/download identity to the canonical id emitted by the
    /// checked-out ds4 server. Unknown/custom catalog entries deliberately
    /// retain their id so offline fixtures and future catalog additions remain
    /// usable until an explicit server alias is documented.
    public static func canonicalAPIModelID(forCatalogID id: String) -> String {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "ds4f-q2", "ds4f-q2-q4", "ds4f-q4", "ds4f-mxfp4":
            return "deepseek-v4-flash"
        case "ds41f-q2", "ds41f-q4":
            return "deepseek-v4.1-flash"
        case "pro-q2-imatrix", "pro-q4-split":
            return "deepseek-v4-pro"
        case "glm-unsloth-q4", "glm-antirez-iq2xxs", "glm-antirez-q2", "glm-antirez-q4":
            return "glm-5.2"
        case "glm53-full-q2", "glm53-q2", "glm53-q4":
            return "glm-5.3-flash"
        case "qwen38-q2", "qwen38-q4k":
            return "qwen3.8-flash-next"
        default:
            return id.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static var defaultEntries: [DS4ModelCatalogEntry] {
        let modelEvidence = [
            "ds4/download_model.sh",
            "ds4/docs/MODELS.md",
            "ds4/README.md"
        ]
        let gpuBackends: [AgentDS4RuntimeBackend] = [.metal, .cuda, .rocm]
        let metalCUDA: [AgentDS4RuntimeBackend] = [.metal, .cuda]
        let metalOnly: [AgentDS4RuntimeBackend] = [.metal]
        let gib = DS4ModelCatalog.bytes(gib:)

        return [
            DS4ModelCatalogEntry(
                id: "ds4f-q2",
                displayName: "DeepSeek V4 Flash Q2",
                downloadTarget: "ds4f-q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(81),
                    residentMemoryBytes: gib(96)
                ),
                supportedBackends: gpuBackends,
                evidence: modelEvidence,
                notes: ["Starting Flash model for 96/128 GB systems."]
            ),
            DS4ModelCatalogEntry(
                id: "ds4f-q2-q4",
                displayName: "DeepSeek V4 Flash mixed Q2/Q4",
                downloadTarget: "ds4f-q2-q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed-0731.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(98),
                    residentMemoryBytes: gib(128)
                ),
                supportedBackends: gpuBackends,
                evidence: modelEvidence,
                notes: ["Higher-quality mixed quant for 128 GB systems."]
            ),
            DS4ModelCatalogEntry(
                id: "ds4f-q4",
                displayName: "DeepSeek V4 Flash Q4",
                downloadTarget: "ds4f-q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(153),
                    residentMemoryBytes: gib(256)
                ),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Recommended for 256 GB or larger machines."]
            ),
            DS4ModelCatalogEntry(
                id: "ds4f-mxfp4",
                displayName: "DeepSeek V4 Flash MXFP4",
                downloadTarget: "ds4f-mxfp4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-MXFP4Experts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-mxfp4-0731.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(156),
                    residentMemoryBytes: gib(256)
                ),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Native MXFP4 routed experts; supported by Metal and CUDA in the checkout."]
            ),
            DS4ModelCatalogEntry(
                id: "ds41f-q2",
                displayName: "DeepSeek V4.1 Flash Q2",
                downloadTarget: "ds41f-q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4.1-Flash-Q2.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(341),
                    residentMemoryBytes: gib(152),
                    streamingMemoryBytes: gib(128)
                ),
                supportedBackends: metalCUDA,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Metal and CUDA text inference; one 128 GB Mac uses SSD streaming."]
            ),
            DS4ModelCatalogEntry(
                id: "ds41f-q4",
                displayName: "DeepSeek V4.1 Flash Q4",
                downloadTarget: "ds41f-q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4.1-Flash-Q4.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(483),
                    residentMemoryBytes: gib(294)
                ),
                supportedBackends: metalOnly,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Two-part download joined by the checkout script; streaming is required on smaller Macs."]
            ),
            DS4ModelCatalogEntry(
                id: "pro-q2-imatrix",
                displayName: "DeepSeek V4 PRO Q2 imatrix",
                downloadTarget: "pro-q2-imatrix",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix-0813.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(430),
                    residentMemoryBytes: gib(512)
                ),
                supportedBackends: metalOnly,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Intended for 512 GB resident systems or an explicitly configured streaming run."]
            ),
            DS4ModelCatalogEntry(
                id: "pro-q4-split",
                displayName: "DeepSeek V4 PRO Q4 split",
                downloadTarget: "pro-q4-split",
                artifacts: [
                    DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Pro-Q4K-Layers00-30.gguf", role: .modelShard),
                    DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Pro-Q4K-Layers-31-output.gguf", role: .modelShard)
                ],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(838)
                ),
                supportedBackends: metalOnly,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Two split artifacts for distributed/pipeline execution."]
            ),
            DS4ModelCatalogEntry(
                id: "glm-unsloth-q4",
                displayName: "GLM 5.2 Unsloth Q4",
                downloadTarget: "glm-unsloth-q4",
                artifacts: DS4ModelCatalog.shards(base: "GLM-5.2-UD-Q4_K_XL", count: 11),
                resources: DS4ModelResourceEstimate(),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Eleven-shard artifact; checkout documents no single aggregate size here."]
            ),
            DS4ModelCatalogEntry(
                id: "glm-antirez-iq2xxs",
                displayName: "GLM 5.2 antirez IQ2 XXS",
                downloadTarget: "glm-antirez-iq2xxs",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.2-UD-IQ2_XXS_RoutedIQ2XXS_blk78Q2K.gguf")],
                resources: DS4ModelResourceEstimate(),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Reduced-memory routed quant; checkout does not state a byte estimate for this target."]
            ),
            DS4ModelCatalogEntry(
                id: "glm-antirez-q2",
                displayName: "GLM 5.2 antirez Q2",
                downloadTarget: "glm-antirez-q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.2-UD-Q2_K_RoutedQ2K.gguf")],
                resources: DS4ModelResourceEstimate(diskBytes: gib(262)),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence
            ),
            DS4ModelCatalogEntry(
                id: "glm-antirez-q4",
                displayName: "GLM 5.2 antirez Q4",
                downloadTarget: "glm-antirez-q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.2-UD-Q4_K_RoutedQ4K.gguf")],
                resources: DS4ModelResourceEstimate(diskBytes: gib(434)),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence
            ),
            DS4ModelCatalogEntry(
                id: "glm53-full-q2",
                displayName: "GLM 5.3 full Q2",
                downloadTarget: "glm53-full-q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.3-UD-IQ2_XXS_RoutedIQ2XXS_blk78Q2K.gguf")],
                resources: DS4ModelResourceEstimate(diskBytes: gib(197)),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Intended for 256 GB systems or SSD streaming."]
            ),
            DS4ModelCatalogEntry(
                id: "glm53-q2",
                displayName: "GLM 5.3 Flash Q2",
                downloadTarget: "glm53-q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.3-Flash-Q2.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(90),
                    residentMemoryBytes: gib(128)
                ),
                supportedBackends: gpuBackends,
                evidence: modelEvidence
            ),
            DS4ModelCatalogEntry(
                id: "glm53-q4",
                displayName: "GLM 5.3 Flash Q4",
                downloadTarget: "glm53-q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.3-Flash-Q4_K.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(178)
                ),
                supportedBackends: gpuBackends,
                supportsSSDStreaming: true,
                evidence: modelEvidence,
                notes: ["Two-Mac tensor parallelism or single-Mac SSD streaming."]
            ),
            DS4ModelCatalogEntry(
                id: "qwen38-q2",
                displayName: "Qwen3.8 Flash Next Q2",
                downloadTarget: "qwen38-q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/Qwen3.8-Flash-Next-Q2.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(137.10),
                    residentMemoryBytes: gib(64)
                ),
                supportedBackends: metalCUDA,
                evidence: modelEvidence,
                notes: ["Checkout recommends an 8K context and 1,024-token prefill chunk on 64 GB Macs."]
            ),
            DS4ModelCatalogEntry(
                id: "qwen38-q4k",
                displayName: "Qwen3.8 Flash Next Q4",
                downloadTarget: "qwen38-q4k",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/Qwen3.8-Flash-Next-Q4.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: gib(165.11),
                    residentMemoryBytes: gib(128)
                ),
                supportedBackends: metalCUDA,
                evidence: modelEvidence,
                notes: ["Checkout documents 69.74 GiB main weights and a 128 GB Mac starting point."]
            )
        ]
    }


    public func entry(id: String) -> DS4ModelCatalogEntry? {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { $0.id.lowercased() == normalized || $0.downloadTarget.lowercased() == normalized }
    }

    public var runnableEntries: [DS4ModelCatalogEntry] { entries }

    public func entries(supporting backend: AgentDS4RuntimeBackend) -> [DS4ModelCatalogEntry] {
        entries.filter { $0.supports(backend: backend) }
    }

    private static func bytes(gib: Double) -> UInt64 {
        precondition(gib >= 0 && gib <= Double(UInt64.max) / Double(1024 * 1024 * 1024))
        return UInt64(gib * Double(1024 * 1024 * 1024))
    }

    private static func shards(base: String, count: Int) -> [DS4ModelArtifact] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            DS4ModelArtifact(
                relativePath: "gguf/\(base)-\(String(format: "%05d", index))-of-\(String(format: "%05d", count)).gguf",
                role: .modelShard
            )
        }
    }
}
