//
//  AgentMemoryEmbeddingSettingsManifest.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Memory-embedding configuration persisted in `settings.json`.
///
/// Three distinct states are represented without extra user-visible fields:
/// - A valid ``endpoint`` enables an OpenAI-compatible embedding provider.
/// - A nil endpoint (``disabled``) forces BM25-only retrieval and deliberately
///   suppresses the legacy `ZENCODE_MEMORY_EMBEDDING_ENDPOINT` fallback so the
///   user's explicit choice prevails.
/// - When the entire `memoryEmbedding` key is **absent** from the manifest,
///   `AgentSettingsManifest` normalizes it to `nil`, which preserves the legacy
///   environment-variable fallback for existing v10 installations.
///
/// The endpoint chooses its own embedding model and authentication policy;
/// ZenCODE neither persists nor probes a model identifier, API key, or any
/// other embedding-side setting.
public struct AgentMemoryEmbeddingSettingsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case endpoint
    }

    /// The normalized absolute HTTP(S) embedding endpoint, or `nil` when
    /// embeddings are explicitly disabled (BM25 only).
    public let endpoint: String?

    /// The explicitly-disabled marker: endpoint is absent, semantic retrieval
    /// is off, and the legacy environment fallback is suppressed.
    public static let disabled = Self(endpoint: nil)

    /// Creates a value from `endpoint`. Pass `nil` for ``disabled``. Non-nil
    /// invalid values are retained only by this direct initializer so callers
    /// can surface their own validation error; `AgentSettingsManifest` drops
    /// them and decoding rejects them.
    public init(endpoint: String?) {
        if let endpoint {
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            self.endpoint = Self.normalizedEndpoint(trimmed) ?? trimmed
        } else {
            self.endpoint = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawEndpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        guard let rawEndpoint else {
            self.endpoint = nil
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(endpoint, forKey: .endpoint)
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
    public static func validated(endpoint rawEndpoint: String) -> Self? {
        guard let endpoint = normalizedEndpoint(rawEndpoint) else {
            return nil
        }
        return Self(endpoint: endpoint)
    }
}
