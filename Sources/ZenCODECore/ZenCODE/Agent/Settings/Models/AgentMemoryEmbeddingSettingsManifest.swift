//
//  AgentMemoryEmbeddingSettingsManifest.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Memory-embedding configuration persisted in `settings.json`.
///
/// Four distinct states are represented without extra user-visible fields:
/// - A valid ``endpoint`` enables an OpenAI-compatible embedding provider,
///   optionally paired with a ``model`` identifier and — for the OpenRouter
///   preset only — a non-secret ``providerID`` reference to the configured
///   provider whose API key is reused at runtime.
/// - A nil endpoint (``disabled``) forces BM25-only retrieval and deliberately
///   suppresses the legacy `ZENCODE_MEMORY_EMBEDDING_ENDPOINT` fallback so the
///   user's explicit choice prevails.
/// - When the entire `memoryEmbedding` key is **absent** from the manifest,
///   `AgentSettingsManifest` normalizes it to `nil`, which preserves the legacy
///   environment-variable fallback for existing v10/v11 installations.
///
/// `model` and `providerID` are optional: legacy endpoint-only configurations
/// (and custom endpoints typed by hand in setup) keep them nil. When `model` is
/// present, ZenCODE sends it in the `/v1/embeddings` request body; when
/// `providerID` is present, the resolver derives the Authorization key from the
/// configured provider's `remoteAPIKeysByProviderID` entry instead of duplicating
/// the secret in the embeddings manifest.
public struct AgentMemoryEmbeddingSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case endpoint
        case model
        case providerID
    }

    /// Canonical OpenRouter embeddings endpoint proposed by setup when a
    /// configured provider is OpenRouter.
    public static let openRouterEmbeddingsEndpoint = "https://openrouter.ai/api/v1/embeddings"
    /// Embedding model precompiled with the OpenRouter proposal.
    public static let openRouterEmbeddingsModel = "qwen/qwen3-embedding-8b"

    /// The normalized absolute HTTP(S) embedding endpoint, or `nil` when
    /// embeddings are explicitly disabled (BM25 only).
    public let endpoint: String?
    /// Optional OpenAI-compatible model identifier sent in the request body.
    /// Nil keeps the endpoint-only behavior: the server chooses the model.
    public let model: String?
    /// Optional non-secret reference to a configured provider whose API key is
    /// reused for this embedding endpoint. Present only for provider presets
    /// (OpenRouter); nil for custom/legacy endpoint-only configurations.
    public let providerID: UUID?

    /// The explicitly-disabled marker: endpoint is absent, semantic retrieval
    /// is off, and the legacy environment fallback is suppressed.
    public static let disabled = Self(endpoint: nil)

    /// Creates a value from `endpoint`. Pass `nil` for ``disabled``. Non-nil
    /// invalid values are retained only by this direct initializer so callers
    /// can surface their own validation error; `AgentSettingsManifest` drops
    /// them and decoding rejects them. A nil endpoint forces `model` and
    /// `providerID` to nil so the disabled state stays canonical.
    public init(endpoint: String?, model: String? = nil, providerID: UUID? = nil) {
        if let endpoint {
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            self.endpoint = Self.normalizedEndpoint(trimmed) ?? trimmed
            self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            self.providerID = providerID
        } else {
            self.endpoint = nil
            self.model = nil
            self.providerID = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEndpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        guard let rawEndpoint else {
            self.endpoint = nil
            self.model = nil
            self.providerID = nil
            return
        }
        guard let endpoint = Self.normalizedEndpoint(rawEndpoint) else {
            throw DecodingError.dataCorruptedError(
                forKey: .endpoint,
                in: container,
                debugDescription: "Memory embedding endpoint must be a non-empty absolute http:// or https:// URL without embedded credentials."
            )
        }
        self.endpoint = endpoint
        self.model = try container.decodeIfPresent(String.self, forKey: .model)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        self.providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(endpoint, forKey: .endpoint)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(providerID, forKey: .providerID)
    }

    /// The endpoint as a URL when this value carries a valid endpoint.
    public var endpointURL: URL? {
        guard let endpoint else { return nil }
        return Self.url(for: endpoint)
    }

    /// `true` when a valid endpoint is configured (provider mode).
    public var isConfigured: Bool {
        endpointURL != nil
    }

    /// `true` when embeddings are explicitly disabled (BM25 only, no env
    /// fallback). The field is present in the manifest but carries no endpoint.
    public var isExplicitlyDisabled: Bool {
        endpoint == nil
    }

    /// Returns the canonical endpoint string when `rawEndpoint` is an absolute
    /// HTTP(S) URL with a host and no embedded credentials. This validation is
    /// entirely local and never performs a network request.
    public static func normalizedEndpoint(_ rawEndpoint: String) -> String? {
        let trimmed = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.nilIfBlank,
              components.user?.nilIfBlank == nil,
              components.password?.nilIfBlank == nil else {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()
        guard let url = components.url else {
            return nil
        }
        return url.absoluteString
    }

    /// Parses and validates an endpoint without performing I/O.
    public static func url(for rawEndpoint: String) -> URL? {
        guard let normalized = normalizedEndpoint(rawEndpoint) else {
            return nil
        }
        return URL(string: normalized)
    }

    /// Returns a valid normalized settings value, or `nil` for invalid input.
    /// `model` and `providerID` are optional and preserved when the endpoint is
    /// valid.
    public static func validated(
        endpoint rawEndpoint: String,
        model: String? = nil,
        providerID: UUID? = nil
    ) -> Self? {
        guard let endpoint = normalizedEndpoint(rawEndpoint) else {
            return nil
        }
        return Self(endpoint: endpoint, model: model, providerID: providerID)
    }
}
