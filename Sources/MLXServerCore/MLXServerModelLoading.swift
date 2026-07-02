//
//  MLXServerModelLoading.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

public enum MLXServerModelRuntimeKind: String, Codable, Sendable, Equatable, Hashable {
    case llm
    case vlm
}

public enum MLXServerModelLoading {
    public static func loadContainer(
        configuration: ModelConfiguration,
        runtimeKind: MLXServerModelRuntimeKind = .llm,
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
        ) async throws -> ModelContainer {
        await ServerGemma4ModelRegistration.registerIfNeeded()
        _ = await MLXServerHuggingFaceCacheAccessStore.shared.activatePersistedAccess()
        let hubClient = MLXServerHuggingFaceCacheAccessStore.hubClient()
        return switch runtimeKind {
        case .llm:
            try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hubClient),
                using: MLXServerTokenizerLoader(),
                configuration: configuration,
                useLatest: useLatest,
                progressHandler: progressHandler
            )
        case .vlm:
            try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hubClient),
                using: MLXServerTokenizerLoader(),
                configuration: configuration,
                useLatest: useLatest,
                progressHandler: progressHandler
            )
        }
    }
}

protocol MLXServerChatTemplateTokenizing: MLXLMCommon.Tokenizer {
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        addGenerationPrompt: Bool
    ) throws -> [Int]
}

private struct MLXServerTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MLXServerTokenizerBridge(upstream: upstream)
    }
}

private struct MLXServerTokenizerBridge: MLXServerChatTemplateTokenizing {
    private let upstream: any Tokenizers.Tokenizer

    init(upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try applyChatTemplate(
            messages: messages,
            tools: tools,
            additionalContext: additionalContext,
            addGenerationPrompt: true
        )
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?,
        addGenerationPrompt: Bool
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: nil,
                addGenerationPrompt: addGenerationPrompt,
                truncation: false,
                maxLength: nil,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
