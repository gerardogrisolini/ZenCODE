import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol EmbeddingProvider: Sendable {
    var modelID: String { get }
    func embed(_ text: String) async throws -> [Float]
}

/// Dependency-free deterministic embedder intended for tests, demos and offline plumbing.
/// It is a signed feature-hashing bag-of-words encoder; it is NOT a semantic language model.
struct DeterministicHashEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let dimensions: Int

    public init(dimensions: Int = 128, modelID: String = "zenmemory-hash-v1") {
        precondition(dimensions > 0)
        self.dimensions = dimensions
        self.modelID = modelID
    }

    public func embed(_ text: String) async throws -> [Float] {
        var vector = Array(repeating: Float.zero, count: dimensions)
        for token in MemorySearch.tokens(text) {
            let hash = fnv1a64(token)
            let index = Int(hash % UInt64(dimensions))
            let sign: Float = (hash & (1 << 63)) == 0 ? 1 : -1
            vector[index] += sign
        }
        let norm = sqrtf(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

enum OpenAICompatibleEmbeddingError: Error, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyEmbedding
}

/// Works with OpenAI-compatible `/v1/embeddings` endpoints (OpenAI, Ollama-compatible gateways,
/// vLLM/LM Studio gateways that expose the same JSON contract, etc.).
struct OpenAICompatibleEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let endpoint: URL
    public let apiKey: String?
    public let extraHeaders: [String: String]
    /// A caller-supplied OpenAI-compatible model. `nil` deliberately omits
    /// `model` from the request so an endpoint-only server can choose it.
    public let requestModel: String?
    private let session: URLSession

    public init(
        endpoint: URL,
        model: String? = nil,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestModel = normalizedModel?.isEmpty == false ? normalizedModel : nil
        self.requestModel = requestModel
        self.modelID = requestModel ?? Self.endpointModelID(for: endpoint)
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.session = session
    }

    public func embed(_ text: String) async throws -> [Float] {
        struct ResponseBody: Decodable {
            struct Item: Decodable { let embedding: [Float]; let index: Int? }
            let data: [Item]
        }

        let request = try request(for: text)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAICompatibleEmbeddingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleEmbeddingError.httpStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let embedding = decoded.data.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }).first?.embedding,
              !embedding.isEmpty else {
            throw OpenAICompatibleEmbeddingError.emptyEmbedding
        }
        return embedding
    }

    /// Builds the request without performing I/O. Kept internal so request
    /// shape can be tested without contacting an embedding service.
    func request(for text: String) throws -> URLRequest {
        struct RequestBody: Encodable {
            let input: String
            let model: String?

            private enum CodingKeys: String, CodingKey {
                case input
                case model
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(input, forKey: .input)
                try container.encodeIfPresent(model, forKey: .model)
            }
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(input: text, model: requestModel)
        )
        return request
    }

    /// A stable, endpoint-derived graph identity for endpoint-only providers.
    /// It intentionally hashes rather than stores the URL itself, so an
    /// endpoint's query string is not copied into durable graph metadata.
    public static func endpointModelID(for endpoint: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in endpoint.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "openai-compatible-endpoint-v1-\(String(hash, radix: 16))"
    }
}
