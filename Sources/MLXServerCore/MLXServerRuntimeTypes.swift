//
//  MLXServerRuntimeTypes.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

public struct MLXServerChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Hashable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String
    public var reasoningContent: String?
    public var imageURLs: [URL]
    public var videoURLs: [URL]
    public var toolCalls: [MLXServerChatToolCall]
    public var toolCallID: String?
    public var toolName: String?

    public init(
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        imageURLs: [URL] = [],
        videoURLs: [URL] = [],
        toolCalls: [MLXServerChatToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        let trimmedReasoningContent = reasoningContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.reasoningContent = trimmedReasoningContent?.isEmpty == false
            ? trimmedReasoningContent
            : nil
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        let trimmedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.toolName = trimmedToolName?.isEmpty == false ? trimmedToolName : nil
    }

    public static func system(_ content: String) -> Self {
        Self(role: .system, content: content)
    }

    public static func user(
        _ content: String,
        imageURLs: [URL] = [],
        videoURLs: [URL] = []
    ) -> Self {
        Self(role: .user, content: content, imageURLs: imageURLs, videoURLs: videoURLs)
    }

    public static func assistant(
        _ content: String,
        reasoningContent: String? = nil,
        toolCalls: [MLXServerChatToolCall] = []
    ) -> Self {
        Self(
            role: .assistant,
            content: content,
            reasoningContent: reasoningContent,
            toolCalls: toolCalls
        )
    }

    public static func tool(
        _ content: String,
        toolCallID: String? = nil,
        toolName: String? = nil
    ) -> Self {
        Self(role: .tool, content: content, toolCallID: toolCallID, toolName: toolName)
    }
}

public struct MLXServerChatToolCall: Sendable, Equatable {
    public var id: String?
    public var function: ToolCall.Function

    public init(
        id: String? = nil,
        function: ToolCall.Function
    ) {
        self.id = id
        self.function = function
    }

    public init(
        id: String? = nil,
        name: String,
        arguments: [String: any Sendable]
    ) {
        self.id = id
        self.function = .init(name: name, arguments: arguments)
    }

    public init(id: String? = nil, toolCall: ToolCall) {
        self.id = id
        self.function = toolCall.function
    }

    public var toolCall: ToolCall {
        ToolCall(function: function)
    }
}

public struct MLXServerGenerationRequest: Sendable {
    public var model: MLXServerModelDescriptor
    public var messages: [MLXServerChatMessage]
    public var parameters: GenerateParameters
    public var mediaResize: CGSize?
    public var tools: [ToolSpec]?
    public var additionalContext: [String: any Sendable]?
    public var retainsReasoningInHistory: Bool
    /// Client-provided session identifier used to key the in-memory
    /// `ChatSession` and the disk KV cache entry. When absent, a stable
    /// key is derived from the conversation opening.
    public var sessionID: String?

    public init(
        model: MLXServerModelDescriptor,
        messages: [MLXServerChatMessage],
        parameters: GenerateParameters = GenerateParameters(),
        mediaResize: CGSize? = nil,
        tools: [ToolSpec]? = nil,
        additionalContext: [String: any Sendable]? = nil,
        retainsReasoningInHistory: Bool = false,
        sessionID: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.parameters = parameters
        self.mediaResize = mediaResize
        self.tools = tools
        self.additionalContext = additionalContext
        self.retainsReasoningInHistory = retainsReasoningInHistory
        let trimmedSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = trimmedSessionID?.isEmpty == false ? trimmedSessionID : nil
    }

    public var requiresVisionRuntime: Bool {
        messages.contains { message in
            !message.imageURLs.isEmpty || !message.videoURLs.isEmpty
        }
    }

    public var runtimeKind: MLXServerModelRuntimeKind {
        requiresVisionRuntime ? .vlm : model.runtimeKind
    }

        public var emitsThinking: Bool {
        additionalContext?["enable_thinking"] as? Bool ?? false
    }

    /// Whether the generated stream begins already inside a thinking block.
    ///
    /// Only Qwen-style models pre-open the thinking block in the rendered
    /// prompt (the chat template ends with `<think>`), so generation starts
    /// inside the reasoning channel. Other thinking models (e.g. gemma-4 with
    /// `<|channel>thought`…`<channel|>`, gpt-oss) emit their own opening tag at
    /// the start of generation, so they must not be treated as starting in
    /// thinking — otherwise the leading reasoning (and even the final answer)
    /// is misclassified.
    public var startsInThinking: Bool {
        guard emitsThinking else {
            return false
        }
        let name = "\(model.id) \(model.displayName)".lowercased()
        return name.contains("qwen")
    }

    /// Effective session key: the client-provided identifier, or a stable
    /// derivation from the conversation opening for stateless clients.
    public var effectiveSessionKey: String {
        sessionID ?? MLXServerChatSessionTranscript.derivedSessionKey(messages: messages)
    }
}

public struct MLXServerGenerationParameterSnapshot: Sendable, Equatable {
    public var maxTokens: Int?
    public var maxKVSize: Int?
    public var kvBits: Int?
    public var kvGroupSize: Int
    public var quantizedKVStart: Int
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var minP: Float
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int
    public var presencePenalty: Float?
    public var presenceContextSize: Int
    public var frequencyPenalty: Float?
    public var frequencyContextSize: Int
    public var prefillStepSize: Int

    public init(parameters: GenerateParameters) {
        self.maxTokens = parameters.maxTokens
        self.maxKVSize = parameters.maxKVSize
        self.kvBits = parameters.kvBits
        self.kvGroupSize = parameters.kvGroupSize
        self.quantizedKVStart = parameters.quantizedKVStart
        self.temperature = parameters.temperature
        self.topP = parameters.topP
        self.topK = parameters.topK
        self.minP = parameters.minP
        self.repetitionPenalty = parameters.repetitionPenalty
        self.repetitionContextSize = parameters.repetitionContextSize
        self.presencePenalty = parameters.presencePenalty
        self.presenceContextSize = parameters.presenceContextSize
        self.frequencyPenalty = parameters.frequencyPenalty
        self.frequencyContextSize = parameters.frequencyContextSize
        self.prefillStepSize = parameters.prefillStepSize
    }
}

public struct MLXServerModelLoadEvent: Sendable, Equatable {
    public var modelID: String
    public var runtimeKind: MLXServerModelRuntimeKind
    public var generationDefaults: MLXServerModelGenerationDefaults
    public var parameters: MLXServerGenerationParameterSnapshot

    public init(
        model: MLXServerModelDescriptor,
        runtimeKind: MLXServerModelRuntimeKind,
        parameters: GenerateParameters
    ) {
        self.modelID = model.id
        self.runtimeKind = runtimeKind
        self.generationDefaults = model.generationDefaults
        self.parameters = MLXServerGenerationParameterSnapshot(parameters: parameters)
    }
}

public struct MLXServerModelUnloadEvent: Sendable, Equatable {
    public var modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }
}

public struct MLXServerGenerationOutput: Sendable {
    public var text: String
    public var toolCalls: [ToolCall]
    public var info: GenerateCompletionInfo?

    public init(text: String, toolCalls: [ToolCall] = [], info: GenerateCompletionInfo?) {
        self.text = text
        self.toolCalls = toolCalls
        self.info = info
    }
}

public enum MLXServerRuntimeError: LocalizedError, Sendable, Equatable {
    case emptyPrompt

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "Prompt can not be empty."
        }
    }
}

public struct MLXServerChatCacheEvent: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case memoryHit = "memory_hit"
        case diskHit = "disk_hit"
        case diskPrefixHit = "disk_prefix_hit"
        case miss
    }

    public var status: Status
    public var cachedSessionCount: Int
    public var modelSessionCount: Int
    public var priorTranscriptCount: Int
    public var bestCommonPrefixCount: Int
    public var bestCachedTranscriptCount: Int
    public var bestModelCommonPrefixCount: Int
    public var bestModelCachedTranscriptCount: Int
    public var bestModelSameSystemSignature: Bool?
    public var bestModelSameToolsSignature: Bool?
    public var bestModelSameAdditionalContextSignature: Bool?
    public var bestModelSameMediaResizeSignature: Bool?
    public var bestModelSameReasoningRetention: Bool?
    public var restoredPromptPrefixTokenCount: Int?
    public var cachedPromptTokenCount: Int?

    public init(
        status: Status,
        cachedSessionCount: Int,
        modelSessionCount: Int,
        priorTranscriptCount: Int,
        bestCommonPrefixCount: Int,
        bestCachedTranscriptCount: Int,
        bestModelCommonPrefixCount: Int = 0,
        bestModelCachedTranscriptCount: Int = 0,
        bestModelSameSystemSignature: Bool? = nil,
        bestModelSameToolsSignature: Bool? = nil,
        bestModelSameAdditionalContextSignature: Bool? = nil,
        bestModelSameMediaResizeSignature: Bool? = nil,
        bestModelSameReasoningRetention: Bool? = nil,
        restoredPromptPrefixTokenCount: Int? = nil,
        cachedPromptTokenCount: Int? = nil
    ) {
        self.status = status
        self.cachedSessionCount = cachedSessionCount
        self.modelSessionCount = modelSessionCount
        self.priorTranscriptCount = priorTranscriptCount
        self.bestCommonPrefixCount = bestCommonPrefixCount
        self.bestCachedTranscriptCount = bestCachedTranscriptCount
        self.bestModelCommonPrefixCount = bestModelCommonPrefixCount
        self.bestModelCachedTranscriptCount = bestModelCachedTranscriptCount
        self.bestModelSameSystemSignature = bestModelSameSystemSignature
        self.bestModelSameToolsSignature = bestModelSameToolsSignature
        self.bestModelSameAdditionalContextSignature = bestModelSameAdditionalContextSignature
        self.bestModelSameMediaResizeSignature = bestModelSameMediaResizeSignature
        self.bestModelSameReasoningRetention = bestModelSameReasoningRetention
        self.restoredPromptPrefixTokenCount = restoredPromptPrefixTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
    }
}

public protocol MLXServerRuntimeGenerating: Sendable {
    func generateChatSession(
        request: MLXServerGenerationRequest
    ) async throws -> AsyncThrowingStream<Generation, Error>

    func generateChatSessionText(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerGenerationOutput
}

public protocol MLXServerRuntimeCacheDiagnosing: Sendable {
    func consumeLastChatCacheEvent() async -> MLXServerChatCacheEvent?
}

extension MLXServerRuntime: MLXServerRuntimeGenerating {
    public func generateChatSession(
        request: MLXServerGenerationRequest
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        try await generateChatSession(request: request, progressHandler: { _ in })
    }

    public func generateChatSessionText(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerGenerationOutput {
        try await generateChatSessionText(request: request, progressHandler: { _ in })
    }
}

extension MLXServerRuntime: MLXServerRuntimeCacheDiagnosing {
    public func consumeLastChatCacheEvent() async -> MLXServerChatCacheEvent? {
        defer {
            lastChatCacheEvent = nil
        }
        return lastChatCacheEvent
    }
}

public enum MLXServerReasoningTranscript {
    public static func reasoningSummary(_ text: String) -> String {
        "reasoning_summary:\n\(text)"
    }
}

