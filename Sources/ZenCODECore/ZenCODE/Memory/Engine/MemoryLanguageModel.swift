import Foundation

protocol MemoryLanguageModel: Sendable {
    func complete(system: String, user: String) async throws -> String
}

enum OpenAICompatibleChatError: Error, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse
}

/// Minimal OpenAI-compatible chat-completions client used by the optional intelligence layer.
/// The endpoint should point to a `/v1/chat/completions` compatible route.
struct OpenAICompatibleChatModel: MemoryLanguageModel {
    public let endpoint: URL
    public let model: String
    public let apiKey: String?
    public let extraHeaders: [String: String]
    public let temperature: Double
    private let transport: RemoteTransportCore

    public init(
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        temperature: Double = 0,
        transport: RemoteTransportCore = RemoteTransportCore()
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.temperature = temperature
        self.transport = transport
    }

    public func complete(system: String, user: String) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
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
            Request(
                model: model,
                messages: [
                    Message(role: "system", content: system),
                    Message(role: "user", content: user)
                ],
                temperature: temperature
            )
        )

        let request = RemoteHTTPStreamingRequest(
            url: endpoint,
            method: "POST",
            headers: headers,
            body: body
        )
        let response = try await transport.sendRequest(request)

        guard (200..<300).contains(response.status) else {
            throw OpenAICompatibleChatError.httpStatus(
                response.status,
                String(data: response.body, encoding: .utf8) ?? ""
            )
        }
        let decoded = try JSONDecoder().decode(Response.self, from: response.body)
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAICompatibleChatError.emptyResponse
        }
        return content
    }
}

enum MemoryIntelligenceError: Error, Sendable, Equatable {
    case invalidJSON(String)
}

/// Uses a small/fast language model to decide whether memory recall is useful and to rewrite
/// the prompt into lexical queries, tags and entities. No embedding model is required.
struct LLMMemoryQueryAnalyzer: MemoryQueryAnalyzer {
    public let model: any MemoryLanguageModel
    public let maxQueries: Int

    public init(model: any MemoryLanguageModel, maxQueries: Int = 4) {
        self.model = model
        self.maxQueries = max(1, maxQueries)
    }

    public func analyze(_ prompt: String) async throws -> MemoryQueryPlan {
        struct Response: Decodable {
            var shouldRecall: Bool
            var queries: [String]?
            var tags: [String]?
            var entities: [String]?
            var intent: String?
        }

        let system = """
        You are a memory-query planner for an AI agent. Decide whether durable past memory can help answer the current user prompt. Return JSON only with this schema:
        {"shouldRecall":true,"queries":["compact lexical query"],"tags":["tag"],"entities":["entity"],"intent":"short intent"}
        If memory is unnecessary, set shouldRecall=false and return empty arrays. When recall is useful, produce up to \(maxQueries) concise lexical queries using likely synonyms and concrete terms. Do not answer the user.
        """
        let raw = try await model.complete(system: system, user: prompt)
        let response: Response = try MemoryJSON.decode(Response.self, from: raw)
        var queries = Array((response.queries ?? []).prefix(maxQueries))
        if response.shouldRecall && queries.isEmpty { queries = [prompt] }
        return MemoryQueryPlan(
            shouldRecall: response.shouldRecall,
            queries: queries,
            tags: response.tags ?? [],
            entities: response.entities ?? [],
            intent: response.intent
        )
    }
}

/// Uses a language model to remove false-positive retrievals before memories enter the main context.
struct LLMMemorySelector: MemorySelector {
    public let model: any MemoryLanguageModel
    public let maxCandidates: Int

    public init(model: any MemoryLanguageModel, maxCandidates: Int = 20) {
        self.model = model
        self.maxCandidates = max(1, maxCandidates)
    }

    public func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        guard limit > 0, !candidates.isEmpty else { return [] }

        struct Response: Decodable { var selected: [String] }
        let considered = Array(candidates.prefix(maxCandidates))
        let encodedCandidates = considered.map { candidate in
            "ID=\(candidate.memory.id) | category=\(candidate.memory.category.rawValue) | tags=\(candidate.memory.tags.joined(separator: ",")) | memory=\(candidate.memory.content)"
        }.joined(separator: "\n")

        let system = """
        You select memories for an AI agent's context. Keep only memories that materially help answer the current prompt. Reject merely topical, stale, contradictory, or redundant items. Return JSON only:
        {"selected":["memory-id"]}
        Select at most \(limit) IDs and never invent IDs.
        """
        let user = "Current prompt:\n\(context)\n\nCandidates:\n\(encodedCandidates)"
        let raw = try await model.complete(system: system, user: user)
        let response: Response = try MemoryJSON.decode(Response.self, from: raw)
        let selectedIDs = response.selected.prefix(limit)
        let byID = Dictionary(uniqueKeysWithValues: considered.map { ($0.memory.id, $0) })
        return selectedIDs.compactMap { byID[$0] }
    }
}

/// Extracts durable memories from a completed turn or transcript. The host controls when this
/// is called, so extraction never adds latency unless explicitly enabled in the agent workflow.
struct LLMMemoryExtractor: MemoryExtractor {
    public let model: any MemoryLanguageModel
    public let defaultScope: EngineMemoryScope
    public let maxMemories: Int

    public init(
        model: any MemoryLanguageModel,
        defaultScope: EngineMemoryScope = .project,
        maxMemories: Int = 6
    ) {
        self.model = model
        self.defaultScope = defaultScope
        self.maxMemories = max(1, maxMemories)
    }

    public func extract(from context: String) async throws -> [MemoryDraft] {
        struct Item: Decodable {
            var content: String
            var category: String?
            var tags: [String]?
            var trust: String?
            var confidence: Float?
        }
        struct Response: Decodable { var memories: [Item] }

        let system = """
        You extract durable memory for an AI agent. Store only information likely to be useful in future turns: stable facts, preferences, named entities, explicit decisions and corrections. Ignore transient chatter, temporary status, obvious information and the assistant's speculation. Return JSON only:
        {"memories":[{"content":"...","category":"fact|preference|entity|correction","tags":["..."],"trust":"high|medium|low","confidence":0.0}]}
        Return at most \(maxMemories) items. Do not duplicate the same fact.
        """
        let raw = try await model.complete(system: system, user: context)
        let response: Response = try MemoryJSON.decode(Response.self, from: raw)

        return response.memories.prefix(maxMemories).compactMap { item in
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let category: EngineMemoryCategory = switch item.category?.lowercased() {
            case "preference": .preference
            case "entity": .entity
            case "correction": .correction
            case "fact", .none: .fact
            case .some(let value): .custom(value)
            }
            let trust = TrustLevel(rawValue: item.trust?.lowercased() ?? "") ?? .medium
            return MemoryDraft(
                content: content,
                category: category,
                tags: item.tags ?? [],
                trust: trust,
                scope: defaultScope,
                confidence: item.confidence ?? 1
            )
        }
    }
}

enum MemoryJSON {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.components(separatedBy: .newlines)
            payload = lines.dropFirst().dropLast().joined(separator: "\n")
                .replacingOccurrences(of: "^json\\s*", with: "", options: .regularExpression)
        } else if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            payload = String(trimmed[first...last])
        } else {
            payload = trimmed
        }
        guard let data = payload.data(using: .utf8) else {
            throw MemoryIntelligenceError.invalidJSON(text)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MemoryIntelligenceError.invalidJSON(text)
        }
    }
}
