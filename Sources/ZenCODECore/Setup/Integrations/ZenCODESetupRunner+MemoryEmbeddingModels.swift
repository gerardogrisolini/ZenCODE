//
//  ZenCODESetupRunner+MemoryEmbeddingModels.swift
//  ZenCODE
//

import Foundation

extension ZenCODESetupRunner {
    /// One embedding model offered by the OpenRouter preset submenu.
    struct MemoryEmbeddingModelOption: Equatable, Sendable {
        let id: String
        let name: String
        let contextLength: Int?
        /// USD price per input token, as published by OpenRouter.
        let promptPricePerToken: Double?
    }

    /// The models shown by the OpenRouter submenu and whether they came from
    /// the built-in fallback instead of the live OpenRouter catalog.
    struct MemoryEmbeddingModelCatalog: Equatable, Sendable {
        let models: [MemoryEmbeddingModelOption]
        let isFallback: Bool
    }

    /// Public OpenRouter catalog of embedding models (no API key required).
    static let openRouterEmbeddingModelsURL = "https://openrouter.ai/api/v1/embeddings/models"

    /// Short bound so an unreachable network falls back to the built-in list
    /// instead of stalling setup.
    static let openRouterEmbeddingModelsTimeout: Duration = .seconds(15)

    /// Built-in snapshot of the OpenRouter embedding catalog, used only when
    /// the live catalog cannot be loaded.
    static let openRouterEmbeddingModelsFallback: [MemoryEmbeddingModelOption] = [
        .init(id: "baai/bge-base-en-v1.5", name: "BAAI: bge-base-en-v1.5", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "baai/bge-large-en-v1.5", name: "BAAI: bge-large-en-v1.5", contextLength: 512, promptPricePerToken: 0.00000001),
        .init(id: "baai/bge-m3", name: "BAAI: bge-m3", contextLength: 8194, promptPricePerToken: 0.00000001),
        .init(id: "google/gemini-embedding-001", name: "Google: Gemini Embedding 001", contextLength: 20000, promptPricePerToken: 0.00000015),
        .init(id: "google/gemini-embedding-2", name: "Google: Gemini Embedding 2", contextLength: 8192, promptPricePerToken: 0.0000002),
        .init(id: "google/gemini-embedding-2-preview", name: "Google: Gemini Embedding 2 Preview", contextLength: 8192, promptPricePerToken: 0.0000002),
        .init(id: "intfloat/e5-base-v2", name: "Intfloat: E5-Base-v2", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "intfloat/e5-large-v2", name: "Intfloat: E5-Large-v2", contextLength: 512, promptPricePerToken: 0.00000001),
        .init(id: "intfloat/multilingual-e5-large", name: "Intfloat: Multilingual-E5-Large", contextLength: 512, promptPricePerToken: 0.00000001),
        .init(id: "liquid/lfm-2.5-embedding-350m:free", name: "LiquidAI: LFM2.5-Embedding-350M (free)", contextLength: 512, promptPricePerToken: 0),
        .init(id: "mistralai/codestral-embed-2505", name: "Mistral: Codestral Embed 2505", contextLength: 8192, promptPricePerToken: 0.00000015),
        .init(id: "mistralai/mistral-embed-2312", name: "Mistral: Mistral Embed 2312", contextLength: 8192, promptPricePerToken: 0.0000001),
        .init(id: "nvidia/llama-nemotron-embed-vl-1b-v2:free", name: "NVIDIA: Llama Nemotron Embed VL 1B V2 (free)", contextLength: 131072, promptPricePerToken: 0),
        .init(id: "nvidia/nemotron-3-embed-1b:free", name: "NVIDIA: Nemotron 3 Embed 1B (free)", contextLength: 32768, promptPricePerToken: 0),
        .init(id: "openai/text-embedding-3-large", name: "OpenAI: Text Embedding 3 Large", contextLength: 8192, promptPricePerToken: 0.00000013),
        .init(id: "openai/text-embedding-3-small", name: "OpenAI: Text Embedding 3 Small", contextLength: 8192, promptPricePerToken: 0.00000002),
        .init(id: "openai/text-embedding-ada-002", name: "OpenAI: Text Embedding Ada 002", contextLength: 8192, promptPricePerToken: 0.0000001),
        .init(id: "perplexity/pplx-embed-v1-0.6b", name: "Perplexity: Embed V1 0.6B", contextLength: 32000, promptPricePerToken: 0.000000004),
        .init(id: "perplexity/pplx-embed-v1-4b", name: "Perplexity: Embed V1 4B", contextLength: 32000, promptPricePerToken: 0.00000003),
        .init(id: "qwen/qwen3-embedding-4b", name: "Qwen: Qwen3 Embedding 4B", contextLength: 32768, promptPricePerToken: 0.00000002),
        .init(id: "qwen/qwen3-embedding-8b", name: "Qwen: Qwen3 Embedding 8B", contextLength: 40960, promptPricePerToken: 0.00000001),
        .init(id: "sentence-transformers/all-minilm-l12-v2", name: "Sentence Transformers: all-MiniLM-L12-v2", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "sentence-transformers/all-minilm-l6-v2", name: "Sentence Transformers: all-MiniLM-L6-v2", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "sentence-transformers/all-mpnet-base-v2", name: "Sentence Transformers: all-mpnet-base-v2", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "sentence-transformers/multi-qa-mpnet-base-dot-v1", name: "Sentence Transformers: multi-qa-mpnet-base-dot-v1", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "sentence-transformers/paraphrase-minilm-l6-v2", name: "Sentence Transformers: paraphrase-MiniLM-L6-v2", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "thenlper/gte-base", name: "Thenlper: GTE-Base", contextLength: 512, promptPricePerToken: 0.000000005),
        .init(id: "thenlper/gte-large", name: "Thenlper: GTE-Large", contextLength: 512, promptPricePerToken: 0.00000001),
        .init(id: "voyageai/voyage-4", name: "VoyageAI by MongoDB: voyage-4", contextLength: 32000, promptPricePerToken: 0.00000006),
        .init(id: "voyageai/voyage-4-large", name: "VoyageAI by MongoDB: voyage-4-large", contextLength: 32000, promptPricePerToken: 0.00000012),
        .init(id: "voyageai/voyage-4-lite", name: "VoyageAI by MongoDB: voyage-4-lite", contextLength: 32000, promptPricePerToken: 0.00000002),
        .init(id: "voyageai/voyage-code-4", name: "VoyageAI by MongoDB: voyage-code-4", contextLength: 32000, promptPricePerToken: 0.00000012),
        .init(id: "voyageai/voyage-multimodal-3.5", name: "VoyageAI by MongoDB: voyage-multimodal-3.5", contextLength: 32000, promptPricePerToken: 0.00000012)
    ]

    /// Loads the live OpenRouter embedding catalog, falling back to
    /// ``openRouterEmbeddingModelsFallback`` (with a notice) when the request
    /// fails or returns no models. The loader is injectable for tests.
    static func loadOpenRouterEmbeddingModels(
        loader: @Sendable () async throws -> [MemoryEmbeddingModelOption] = {
            try await fetchOpenRouterEmbeddingModels()
        }
    ) async -> MemoryEmbeddingModelCatalog {
        do {
            let models = try await loader()
            if !models.isEmpty {
                return MemoryEmbeddingModelCatalog(
                    models: models.sorted { $0.id < $1.id },
                    isFallback: false
                )
            }
            AgentOutput.standardError.writeString(
                "OpenRouter returned no embedding models; showing the built-in list.\n"
            )
        } catch {
            AgentOutput.standardError.writeString(
                "Unable to load OpenRouter embedding models (\(error.localizedDescription)); showing the built-in list.\n"
            )
        }
        return MemoryEmbeddingModelCatalog(
            models: openRouterEmbeddingModelsFallback,
            isFallback: true
        )
    }

    /// Fetches `GET /api/v1/embeddings/models`. The catalog is public, so no
    /// API key is sent.
    static func fetchOpenRouterEmbeddingModels(
        transport: RemoteTransportCore = RemoteTransportCore()
    ) async throws -> [MemoryEmbeddingModelOption] {
        guard let url = URL(string: openRouterEmbeddingModelsURL) else {
            throw RemoteModelCatalogClientError.invalidURL(openRouterEmbeddingModelsURL)
        }
        let response = try await transport.sendRequest(
            RemoteHTTPStreamingRequest(
                url: url,
                method: "GET",
                headers: [
                    RemoteHTTPHeader(name: "Accept", value: "application/json"),
                    RemoteHTTPHeader(name: "X-Title", value: "ZenCODE")
                ],
                timeout: openRouterEmbeddingModelsTimeout
            )
        )
        guard (200..<300).contains(response.status) else {
            throw RemoteModelCatalogClientError.serverError(
                response.status,
                "HTTP \(response.status)"
            )
        }
        return try decodeOpenRouterEmbeddingModels(from: response.body)
    }

    /// Pure decoding of the OpenRouter embedding catalog. Entries without an
    /// identifier are skipped; prices may be JSON strings or numbers.
    static func decodeOpenRouterEmbeddingModels(
        from data: Data
    ) throws -> [MemoryEmbeddingModelOption] {
        struct Catalog: Decodable {
            let data: [Entry]
        }
        struct Entry: Decodable {
            let id: String?
            let name: String?
            let context_length: Int?
            let pricing: Pricing?
        }
        struct Pricing: Decodable {
            let prompt: Double?

            private enum CodingKeys: String, CodingKey { case prompt }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let number = try? container.decodeIfPresent(Double.self, forKey: .prompt) {
                    prompt = number
                } else if let string = try? container.decodeIfPresent(String.self, forKey: .prompt) {
                    prompt = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    prompt = nil
                }
            }
        }

        let catalog: Catalog
        do {
            catalog = try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            throw RemoteModelCatalogClientError.invalidResponse
        }
        return catalog.data.compactMap { entry in
            guard let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                return nil
            }
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return MemoryEmbeddingModelOption(
                id: id,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                contextLength: entry.context_length,
                promptPricePerToken: entry.pricing?.prompt
            )
        }
    }

    /// Pure submenu construction. The default is the currently configured
    /// OpenRouter model when it is listed, otherwise `defaultModel` when
    /// listed, otherwise the first model.
    static func openRouterEmbeddingModelMenu(
        models: [MemoryEmbeddingModelOption],
        existingSettings: AgentMemoryEmbeddingSettingsManifest?,
        defaultModel: String
    ) -> (
        items: [TerminalCheckboxMenuItem<String>],
        defaultChoice: String?
    ) {
        let items = models.map { model in
            TerminalCheckboxMenuItem(
                value: model.id,
                title: model.id,
                detail: openRouterEmbeddingModelDetail(model)
            )
        }
        let ids = Set(models.map(\.id))
        var current: String?
        if let existingSettings,
           let endpoint = existingSettings.endpoint,
           AgentRemoteProvider.isOpenRouterBaseURL(endpoint),
           let model = existingSettings.model,
           ids.contains(model) {
            current = model
        }
        let defaultChoice = current
            ?? (ids.contains(defaultModel) ? defaultModel : models.first?.id)
        return (items, defaultChoice)
    }

    static func openRouterEmbeddingModelDetail(
        _ model: MemoryEmbeddingModelOption
    ) -> String {
        var parts = [model.name]
        if let price = formattedEmbeddingPrice(model.promptPricePerToken) {
            parts.append(price)
        }
        if let contextLength = model.contextLength, contextLength > 0 {
            parts.append("\(contextLength) input tokens")
        }
        return parts.joined(separator: " · ")
    }

    /// Formats a per-token USD price as a per-million-token price
    /// (`$0.02/M tokens`), or `free` when zero.
    static func formattedEmbeddingPrice(_ perToken: Double?) -> String? {
        guard let perToken, perToken.isFinite, perToken >= 0 else {
            return nil
        }
        if perToken == 0 {
            return "free"
        }
        var text = String(format: "%.4f", perToken * 1_000_000)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return "$\(text)/M tokens"
    }
}
