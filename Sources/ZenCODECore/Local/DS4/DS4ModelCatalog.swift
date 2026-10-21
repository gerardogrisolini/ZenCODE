//
//  DS4ModelCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  A small, offline catalog of well-known DS4 GGUF artifacts. It only maps
//  files found in a DS4 folder to a display name and to the model id served by
//  the ds4 OpenAI-compatible API; it never downloads or parses a GGUF.
//

import Foundation

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
    public let artifacts: [DS4ModelArtifact]

    public init(
        id: String,
        displayName: String,
        artifacts: [DS4ModelArtifact]
    ) {
        self.id = id
        self.displayName = displayName
        self.artifacts = artifacts
    }

    /// The identifier accepted by the ds4 OpenAI-compatible API.
    ///
    /// Catalog ids describe download targets/quantizations and are not
    /// necessarily model ids exposed by `/v1/models`. Keep the catalog
    /// identity for selection and persistence keys, but use this value for
    /// provider payloads and readiness checks.
    public var apiModelID: String {
        DS4ModelCatalog.canonicalAPIModelID(forCatalogID: id)
    }
}

public struct DS4ModelCatalog: Codable, Equatable, Sendable {
    public let entries: [DS4ModelCatalogEntry]

    public init(entries: [DS4ModelCatalogEntry] = DS4ModelCatalog.defaultEntries) {
        self.entries = entries
    }

    public static var `default`: DS4ModelCatalog {
        DS4ModelCatalog()
    }

    /// The only model ids the ds4 server serves from `/v1/models`.
    public static let servedAPIModelIDs: [String] = [
        "deepseek-v4-flash",
        "deepseek-v4-pro",
        "deepseek-v4.1-flash",
        "qwen3.8-flash-next",
        "glm-5.2",
        "glm-5.3-flash"
    ]

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

    /// Infers the ds4 API model id from a GGUF file name (case-insensitive).
    /// Order matters: the more specific DeepSeek variants are tested first.
    /// Returns nil when the name does not identify a served model family.
    public static func inferredAPIModelID(fromFileName fileName: String) -> String? {
        let name = fileName.lowercased()
        func has(_ needle: String) -> Bool { name.contains(needle) }
        if has("deepseek-v4.1") { return "deepseek-v4.1-flash" }
        if has("deepseek-v4-pro") || has("v4-pro") { return "deepseek-v4-pro" }
        if has("deepseek-v4-flash") { return "deepseek-v4-flash" }
        if has("qwen3.8") { return "qwen3.8-flash-next" }
        if has("glm-5.3") { return "glm-5.3-flash" }
        if has("glm-5.2") { return "glm-5.2" }
        return nil
    }

    public func entry(id: String) -> DS4ModelCatalogEntry? {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { $0.id.lowercased() == normalized }
    }

    /// Finds the entry that lists `relativePath` among its artifacts.
    public func entry(forArtifactPath relativePath: String) -> DS4ModelCatalogEntry? {
        let normalized = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        return entries.first { entry in
            entry.artifacts.contains { $0.relativePath == normalized }
        }
    }

    public static var defaultEntries: [DS4ModelCatalogEntry] {
        [
            DS4ModelCatalogEntry(
                id: "ds4f-q2",
                displayName: "DeepSeek V4 Flash Q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "ds4f-q2-q4",
                displayName: "DeepSeek V4 Flash mixed Q2/Q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed-0731.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "ds4f-q4",
                displayName: "DeepSeek V4 Flash Q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "ds4f-mxfp4",
                displayName: "DeepSeek V4 Flash MXFP4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Flash-MXFP4Experts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-mxfp4-0731.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "ds41f-q2",
                displayName: "DeepSeek V4.1 Flash Q2",
                // Current `download_model.sh ds41f-q2` artifact first; the
                // earlier file name stays recognized for existing folders.
                artifacts: [
                    DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf"),
                    DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4.1-Flash-Q2.gguf")
                ]
            ),
            DS4ModelCatalogEntry(
                id: "ds41f-q4",
                displayName: "DeepSeek V4.1 Flash Q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4.1-Flash-Q4.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "pro-q2-imatrix",
                displayName: "DeepSeek V4 PRO Q2 imatrix",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix-0813.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "pro-q4-split",
                displayName: "DeepSeek V4 PRO Q4 split",
                artifacts: [
                    DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Pro-Q4K-Layers00-30.gguf", role: .modelShard),
                    DS4ModelArtifact(relativePath: "gguf/DeepSeek-V4-Pro-Q4K-Layers-31-output.gguf", role: .modelShard)
                ]
            ),
            DS4ModelCatalogEntry(
                id: "glm-unsloth-q4",
                displayName: "GLM 5.2 Unsloth Q4",
                artifacts: DS4ModelCatalog.shards(base: "GLM-5.2-UD-Q4_K_XL", count: 11)
            ),
            DS4ModelCatalogEntry(
                id: "glm-antirez-iq2xxs",
                displayName: "GLM 5.2 antirez IQ2 XXS",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.2-UD-IQ2_XXS_RoutedIQ2XXS_blk78Q2K.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "glm-antirez-q2",
                displayName: "GLM 5.2 antirez Q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.2-UD-Q2_K_RoutedQ2K.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "glm-antirez-q4",
                displayName: "GLM 5.2 antirez Q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.2-UD-Q4_K_RoutedQ4K.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "glm53-full-q2",
                displayName: "GLM 5.3 full Q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.3-UD-IQ2_XXS_RoutedIQ2XXS_blk78Q2K.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "glm53-q2",
                displayName: "GLM 5.3 Flash Q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.3-Flash-Q2.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "glm53-q4",
                displayName: "GLM 5.3 Flash Q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/GLM-5.3-Flash-Q4_K.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "qwen38-q2",
                displayName: "Qwen3.8 Flash Next Q2",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/Qwen3.8-Flash-Next-Q2.gguf")]
            ),
            DS4ModelCatalogEntry(
                id: "qwen38-q4k",
                displayName: "Qwen3.8 Flash Next Q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/Qwen3.8-Flash-Next-Q4.gguf")]
            )
        ]
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
