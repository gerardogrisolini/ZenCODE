import Foundation

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
    case httpStatus(Int, String)
    case emptyEmbedding
    case responseBodyTooLarge(maximumBytes: Int)
}

/// Works with OpenAI-compatible `/v1/embeddings` endpoints (OpenAI, Ollama-compatible gateways,
/// vLLM/LM Studio gateways that expose the same JSON contract, etc.).
///
/// Requests are driven through the same shared SwiftNIO transport
/// (``RemoteTransportCore``) that the generation providers use, so embeddings
/// share one HTTP/SSE engine, TLS stack, and event-loop group rather than a
/// separate `URLSession` stack.
struct OpenAICompatibleEmbeddingProvider: EmbeddingProvider {
    /// Embedding responses are small JSON documents (even for high-dimensional
    /// vectors), so a 1 MiB cap leaves ample room for compatible gateways while
    /// preventing an endpoint from making the client accumulate an unbounded
    /// response body.
    static let maximumResponseBodyBytes = 1 * 1_024 * 1_024

    public let modelID: String
    public let endpoint: URL
    public let apiKey: String?
    public let extraHeaders: [String: String]
    /// A caller-supplied OpenAI-compatible model. `nil` deliberately omits
    /// `model` from the request so an endpoint-only server can choose it.
    public let requestModel: String?
    private let transport: RemoteTransportCore

    public init(
        endpoint: URL,
        model: String? = nil,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        transport: RemoteTransportCore = RemoteTransportCore()
    ) {
        self.endpoint = endpoint
        let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestModel = normalizedModel?.isEmpty == false ? normalizedModel : nil
        self.requestModel = requestModel
        self.modelID = requestModel ?? Self.endpointModelID(for: endpoint)
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.transport = transport
    }

    public func embed(_ text: String) async throws -> [Float] {
        struct ResponseBody: Decodable {
            struct Item: Decodable { let embedding: [Float]; let index: Int? }
            let data: [Item]
        }

        let request = try streamingRequest(for: text)
        let response = try await transport.openHTTPStream(request)

        guard (200..<300).contains(response.status) else {
            let body = try await collectBody(from: response.body)
            throw OpenAICompatibleEmbeddingError.httpStatus(
                response.status,
                String(data: body, encoding: .utf8) ?? ""
            )
        }

        let body = try await collectBody(from: response.body)
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: body)
        guard let embedding = decoded.data.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }).first?.embedding,
              !embedding.isEmpty else {
            throw OpenAICompatibleEmbeddingError.emptyEmbedding
        }
        return embedding
    }

    /// Collects the HTTP response body into a single `Data`, stopping before
    /// retaining any bytes beyond the embedding response limit.
    private func collectBody(from body: RemoteHTTPBody) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            guard chunk.count <= Self.maximumResponseBodyBytes - data.count else {
                // Do not leave the NIO producer draining an oversized response
                // after the caller has already received the terminal error.
                body.cancel()
                throw OpenAICompatibleEmbeddingError.responseBodyTooLarge(
                    maximumBytes: Self.maximumResponseBodyBytes
                )
            }
            data.append(chunk)
        }
        return data
    }

    /// Builds the request without performing I/O. Kept internal so request
    /// shape can be tested without contacting an embedding service.
    func streamingRequest(for text: String) throws -> RemoteHTTPStreamingRequest {
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

        var headers = [
            RemoteHTTPHeader(name: "Content-Type", value: "application/json")
        ]
        if let apiKey {
            headers.append(RemoteHTTPHeader(name: "Authorization", value: "Bearer \(apiKey)"))
        }
        for (key, value) in extraHeaders {
            headers.append(RemoteHTTPHeader(name: key, value: value))
        }

        let body = try JSONEncoder().encode(
            RequestBody(input: text, model: requestModel)
        )

        return RemoteHTTPStreamingRequest(
            url: endpoint,
            method: "POST",
            headers: headers,
            body: body
        )
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
