//
//  RemoteModelCatalog+HuggingFace.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension RemoteModelCatalogClient {
    func shouldEnrichWithHuggingFace(baseURL: String) -> Bool {
        enrichesHuggingFaceMetadata
            && !AgentRemoteProvider.isOpenRouterBaseURL(baseURL)
    }

    static func huggingFaceRepositoryID(from modelID: String) -> String? {
        let trimmedModelID = AgentRemoteProvider.normalizedModelID(modelID)
        guard !trimmedModelID.isEmpty else {
            return nil
        }
        let components = trimmedModelID
            .split(separator: "/")
            .map(String.init)
        guard components.count >= 2 else {
            return nil
        }
        let owner = components[0]
        guard !owner.contains(":") else {
            return nil
        }
        let repositoryName = components[1...].joined(separator: "/")
        guard !repositoryName.isEmpty else {
            return nil
        }
        return "\(owner)/\(repositoryName)"
    }

    func fetchHuggingFaceModelMetadata(
        repositoryID: String
    ) async throws -> HuggingFaceModelMetadata? {
        do {
            let apiResponse = try await fetchHuggingFaceAPIModel(repositoryID: repositoryID)
            let resolvedRepositoryID = apiResponse.repositoryID.nilIfBlank ?? repositoryID
                        var metadata = HuggingFaceModelMetadata(
                contextLength: contextLengthValue(apiResponse.rootValue),
                thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(
                    apiResponse.metadata.removingSparseIdentifierKeys()
                )
            )


            let siblingNames = Set(apiResponse.siblingFilenames.map { $0.lowercased() })
            if siblingNames.contains("config.json"),
               let config = try await fetchHuggingFaceJSONFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "config.json"
               ) {
                metadata.merge(
                    contextLength: contextLengthValue(config),
                    thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(config.anyValueDictionary)
                )
            }
            if siblingNames.contains("tokenizer_config.json"),
               let tokenizerConfig = try await fetchHuggingFaceJSONFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "tokenizer_config.json"
               ) {
                metadata.merge(
                    contextLength: contextLengthValue(tokenizerConfig),
                    thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(tokenizerConfig.anyValueDictionary)
                )
            }
            if siblingNames.contains("generation_config.json"),
               let generationConfig = try await fetchHuggingFaceJSONFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "generation_config.json"
               ) {
                metadata.merge(
                    contextLength: contextLengthValue(generationConfig),
                    thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(generationConfig.anyValueDictionary)
                )
            }
            if siblingNames.contains("readme.md"),
               let readme = try await fetchHuggingFaceTextFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "README.md"
               ) {
                metadata.merge(
                    contextLength: contextLength(fromText: readme),
                    thinkingSupport: Self.thinkingSupport(fromHuggingFaceReadme: readme)
                )
            }

            return metadata.isEmpty ? nil : metadata
        } catch {
            return nil
        }
    }

    func fetchHuggingFaceAPIModel(
        repositoryID: String
    ) async throws -> HuggingFaceAPIModelResponse {
        let data = try await fetchHuggingFaceData(path: "api/models/\(repositoryID)", accept: "application/json")
        let rootValue = try decodeJSON(JSONValue.self, from: data)
        let response = try decodeJSON(HuggingFaceAPIModelResponse.self, from: data)
        return HuggingFaceAPIModelResponse(
            id: response.id,
            modelID: response.modelID,
            siblings: response.siblings,
            rootValue: rootValue
        )
    }

    func fetchHuggingFaceJSONFile(
        repositoryID: String,
        filename: String
    ) async throws -> JSONValue? {
        do {
            let data = try await fetchHuggingFaceData(
                path: "\(repositoryID)/raw/main/\(filename)",
                accept: "application/json"
            )
            return try decodeJSON(JSONValue.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchHuggingFaceTextFile(
        repositoryID: String,
        filename: String
    ) async throws -> String? {
        do {
            let data = try await fetchHuggingFaceData(
                path: "\(repositoryID)/raw/main/\(filename)",
                accept: "text/plain"
            )
            return String(data: data, encoding: .utf8)?.nilIfBlank
        } catch {
            return nil
        }
    }

    func fetchHuggingFaceData(
        path: String,
        accept: String
    ) async throws -> Data {
        let url = try huggingFaceURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("ZenCODE", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        return data
    }

    func huggingFaceURL(path: String) throws -> URL {
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(huggingFaceBaseURL)/\(sanitizedPath)") else {
            throw RemoteModelCatalogClientError.invalidURL(huggingFaceBaseURL)
        }
        return url
    }

    static func thinkingSupport(fromHuggingFaceReadme readme: String) -> MLXModelThinkingSupport? {
        let lowercasedReadme = readme.lowercased()
        let compactReadme = normalizedMetadataKey(readme)
        let mentionsThinking = compactReadme.contains("reasoningmode")
            || compactReadme.contains("thinkingmode")
            || compactReadme.contains("reasoningeffort")
            || compactReadme.contains("nonthink")
            || compactReadme.contains("<think>")
            || compactReadme.contains("thinkingon")
            || compactReadme.contains("reasoningon")
        guard mentionsThinking else {
            return nil
        }

        var levels: [MLXThinkingSelection] = []
        func append(_ selection: MLXThinkingSelection) {
            guard !levels.contains(selection) else {
                return
            }
            levels.append(selection)
        }

        if containsWholeWord("minimal", in: lowercasedReadme) {
            append(.minimal)
        }
        if containsWholeWord("low", in: lowercasedReadme) {
            append(.low)
        }
        if containsWholeWord("medium", in: lowercasedReadme) {
            append(.medium)
        }
        if compactReadme.contains("thinkhigh")
            || compactReadme.contains("reasoningefforthigh")
            || lowercasedReadme.contains(#"reasoning_effort":"high"#)
            || lowercasedReadme.contains(#"reasoning_effort="high""#) {
            append(.high)
        }
        if compactReadme.contains("thinkmax")
            || compactReadme.contains("reasoningeffortmax")
            || compactReadme.contains("maximumreasoningeffort")
            || lowercasedReadme.contains(#"reasoning_effort":"max"#)
            || lowercasedReadme.contains(#"reasoning_effort="max""#) {
            append(.xhigh)
        }

        if !levels.isEmpty || compactReadme.contains("reasoningeffort") {
            return .effort(levels: levels)
        }
        return .generic
    }

    static func containsWholeWord(
        _ word: String,
        in text: String
    ) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

}

struct HuggingFaceModelMetadata {
    var contextLength: Int?
    var thinkingSupport: MLXModelThinkingSupport?

    var isEmpty: Bool {
        contextLength == nil && thinkingSupport == nil
    }

    mutating func merge(
        contextLength: Int? = nil,
        thinkingSupport: MLXModelThinkingSupport? = nil
    ) {
        if self.contextLength == nil {
            self.contextLength = contextLength
        }
        if self.thinkingSupport == nil {
            self.thinkingSupport = thinkingSupport
        }
    }
}

struct HuggingFaceAPIModelResponse: Decodable {
    struct Sibling: Decodable {
        let rfilename: String?
    }

    let id: String?
    let modelID: String?
    let siblings: [Sibling]
    let rootValue: JSONValue

    enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case siblings
    }

    init(
        id: String?,
        modelID: String?,
        siblings: [Sibling],
        rootValue: JSONValue
    ) {
        self.id = id
        self.modelID = modelID
        self.siblings = siblings
        self.rootValue = rootValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.siblings = try container.decodeIfPresent([Sibling].self, forKey: .siblings) ?? []
        self.rootValue = .null
    }

    var repositoryID: String {
        modelID?.nilIfBlank ?? id?.nilIfBlank ?? ""
    }

    var metadata: [String: Any] {
        rootValue.anyValueDictionary
    }

    var siblingFilenames: [String] {
        siblings.compactMap { $0.rfilename?.nilIfBlank }
    }
}


extension OpenRouterModelInfo {
    var needsHuggingFaceMetadataEnrichment: Bool {
        contextLength == nil || thinkingSupport == nil
    }

    func enriched(with metadata: HuggingFaceModelMetadata?) -> OpenRouterModelInfo {
        guard let metadata else {
            return self
        }
        return OpenRouterModelInfo(
            id: id,
            name: name,
            contextLength: contextLength ?? metadata.contextLength,
            pricing: pricing,
            thinkingSupport: thinkingSupport ?? metadata.thinkingSupport,
            generationParameterOverrides: generationParameterOverrides,
            installed: installed,
            loaded: loaded,
            serverLoaded: serverLoaded
        )
    }
}
