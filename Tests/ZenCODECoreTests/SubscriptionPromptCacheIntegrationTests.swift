//
//  SubscriptionPromptCacheIntegrationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/06/26.
//

#if os(macOS)
import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SubscriptionPromptCacheIntegrationTests {
    @Test
    func liveChatGPTSecondTurnUsesContinuationWithoutCacheWarning() async throws {
        guard Self.liveEnabled(
            specific: "ZENCODE_RUN_LIVE_CHATGPT_CACHE"
        ) else {
            return
        }

        let selection = try Self.subscriptionSelection(
            providerID: AgentRemoteProvider.chatGPTSubscriptionProviderID,
            requestedModelEnv: "ZENCODE_LIVE_CHATGPT_MODEL",
            preferredModelID: "gpt-5.4"
        )
        let client = ChatGPTSubscriptionGenerationClient(
            configuration: Self.runtimeConfiguration(
                modelID: selection.modelID,
                contextWindow: selection.configuredContextWindowLimit,
                overrides: selection.generationParameterOverrides,
                maxOutputTokens: nil,
                verboseLogging: true
            )
        )
        let events = LiveSubscriptionCacheEvents()
        let sessionID = "live-chatgpt-cache-\(UUID().uuidString.lowercased())"

        await client.createSession(
            id: sessionID,
            cwd: FileManager.default.currentDirectoryPath,
            systemPrompt: Self.systemPrompt,
            allowedToolNames: [],
            thinkingSelection: selection.thinkingSelection ?? .low,
            preserveThinking: true
        )

        _ = try await client.sendPrompt(
            sessionID: sessionID,
            prompt: Self.firstPrompt(provider: "ChatGPT", anchorLineCount: 90),
            attachments: [],
            onEvent: { event in
                await events.append(event)
            }
        )
        let firstContinuationID = await client.continuationResponseIDForTesting(
            sessionID: sessionID
        )
        #expect(firstContinuationID != nil)
        await events.markTurnBoundary()

        _ = try await client.sendPrompt(
            sessionID: sessionID,
            prompt: Self.secondPrompt(provider: "ChatGPT"),
            attachments: [],
            onEvent: { event in
                await events.append(event)
            }
        )

        let secondTurnDiagnostics = await events.secondTurnDiagnostics()
        #expect(
            !secondTurnDiagnostics.contains { $0.contains("Cache warning:") },
            "ChatGPT reported low prompt-cache reuse on the second turn: \(secondTurnDiagnostics.joined(separator: "\n"))"
        )
        let snapshot: AgentRuntimeSessionSnapshot = try #require(
            await client.snapshotSession(id: sessionID)
        )
        #expect(snapshot.history.filter { $0.role == .assistant }.count >= 2)
        #expect(await client.hasReplayableAssistantReasoningForTesting(sessionID: sessionID))
    }

    @Test
    func liveAnthropicSecondTurnReportsPromptCacheReuse() async throws {
        guard Self.liveEnabled(
            specific: "ZENCODE_RUN_LIVE_ANTHROPIC_CACHE"
        ) else {
            return
        }

        let selection = try Self.subscriptionSelection(
            providerID: AgentRemoteProvider.anthropicSubscriptionProviderID,
            requestedModelEnv: "ZENCODE_LIVE_ANTHROPIC_MODEL",
            preferredModelID: "claude-sonnet-4-6"
        )
        let provider = try #require(selection.remoteProvider)
        let client = AnthropicSubscriptionGenerationClient(
            configuration: Self.runtimeConfiguration(
                modelID: selection.modelID,
                contextWindow: selection.configuredContextWindowLimit,
                overrides: selection.generationParameterOverrides,
                maxOutputTokens: 512,
                verboseLogging: true
            ),
            provider: provider
        )
        let events = LiveSubscriptionCacheEvents()
        let sessionID = "live-anthropic-cache-\(UUID().uuidString.lowercased())"

        await client.createSession(
            id: sessionID,
            cwd: FileManager.default.currentDirectoryPath,
            systemPrompt: Self.systemPrompt,
            allowedToolNames: [],
            thinkingSelection: selection.thinkingSelection ?? .low,
            preserveThinking: true
        )

        _ = try await client.sendPrompt(
            sessionID: sessionID,
            prompt: Self.firstPrompt(provider: "Anthropic", anchorLineCount: 160),
            attachments: [],
            onEvent: { event in
                await events.append(event)
            }
        )
        await events.markTurnBoundary()

        _ = try await client.sendPrompt(
            sessionID: sessionID,
            prompt: Self.secondPrompt(provider: "Anthropic"),
            attachments: [],
            onEvent: { event in
                await events.append(event)
            }
        )

        let secondTurnDiagnostics = await events.secondTurnDiagnostics()
        #expect(
            !secondTurnDiagnostics.contains { $0.contains("Cache warning:") },
            "Anthropic reported low prompt-cache reuse on the second turn: \(secondTurnDiagnostics.joined(separator: "\n"))"
        )
        let cachedPromptTokens = Self.maxCachedPromptTokens(
            in: secondTurnDiagnostics,
            provider: "Anthropic"
        )
        guard let cachedPromptTokens else {
            throw LiveSubscriptionCacheIntegrationError.missingCacheDiagnostic(
                provider: "Anthropic",
                diagnostics: secondTurnDiagnostics
            )
        }
        #expect(
            cachedPromptTokens >= Self.minimumAnthropicCachedPromptTokens,
            "Anthropic cached only \(cachedPromptTokens) prompt tokens; expected at least \(Self.minimumAnthropicCachedPromptTokens)."
        )

        let snapshot: AgentRuntimeSessionSnapshot = try #require(
            await client.snapshotSession(id: sessionID)
        )
        #expect(snapshot.history.filter { $0.role == .assistant }.count >= 2)
    }

    private static let minimumAnthropicCachedPromptTokens = 512

    private static let systemPrompt = """
    You are running a live integration test for ZenCODE. Answer the user with only the requested marker.
    """

    private static func liveEnabled(specific: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[specific] == "1"
            || environment["ZENCODE_RUN_LIVE_SUBSCRIPTION_CACHE"] == "1"
    }

    private static func firstPrompt(
        provider: String,
        anchorLineCount: Int
    ) -> String {
        """
        Keep the following \(provider) cache anchor in context. Do not summarize it. Reply exactly: OK-1

        \(cacheAnchor(provider: provider, lineCount: anchorLineCount))
        """
    }

    private static func secondPrompt(provider: String) -> String {
        """
        Reuse the previous \(provider) cache anchor and reply exactly: OK-2
        """
    }

    private static func cacheAnchor(provider: String, lineCount: Int) -> String {
        (1...lineCount)
            .map { index in
                "\(provider) cache anchor \(index): Preserve this deterministic sentence for live subscription prompt cache verification across the next request."
            }
            .joined(separator: "\n")
    }

    private static func runtimeConfiguration(
        modelID: String,
        contextWindow: Int?,
        overrides: AgentGenerationParameterOverrides?,
        maxOutputTokens: Int?,
        verboseLogging: Bool
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: nil,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuredContextWindowLimit: contextWindow,
            generationParameterOverrides: overrides ?? AgentGenerationParameterOverrides(),
            maxToolRounds: 1,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            toolAuthorizationHandler: nil
        )
    }

    private static func subscriptionSelection(
        providerID: UUID,
        requestedModelEnv: String,
        preferredModelID: String
    ) throws -> AgentModelSelection {
        let environment = ProcessInfo.processInfo.environment
        if let requestedModel = environment[requestedModelEnv]?.nilIfBlank,
           let selection = AgentSettingsStore.modelSelection(forLLMID: requestedModel),
           selection.remoteProvider?.id == providerID {
            return selection
        }

        let manifest = try AgentSettingsManifestStore.loadRequired()
        let candidates = manifest.models.filter { $0.providerID == providerID }
        let model =
            candidates.first { $0.modelID == preferredModelID }
            ?? candidates.first { $0.thinkingOptions?.contains(.low) == true }
            ?? candidates.first
        guard let model,
              let selection = AgentSettingsStore.modelSelection(forLLMID: model.id) else {
            throw LiveSubscriptionCacheIntegrationError.missingModel
        }
        return selection
    }

    private static func maxCachedPromptTokens(
        in diagnostics: [String],
        provider: String
    ) -> Int? {
        diagnostics
            .filter { $0.hasPrefix("\(provider) cache:") }
            .compactMap { cachedPromptTokens(in: $0) }
            .max()
    }

    private static func cachedPromptTokens(in diagnostic: String) -> Int? {
        diagnostic
            .split(whereSeparator: \.isWhitespace)
            .compactMap { part -> Int? in
                guard part.hasPrefix("cached=") else {
                    return nil
                }
                return Int(part.dropFirst("cached=".count))
            }
            .max()
    }
}

private actor LiveSubscriptionCacheEvents {
    private var diagnostics: [String] = []
    private var turnBoundaryIndex: Int?

    func append(_ event: DirectAgentEvent) {
        if case let .diagnostic(message) = event {
            diagnostics.append(message)
        }
    }

    func markTurnBoundary() {
        turnBoundaryIndex = diagnostics.count
    }

    func secondTurnDiagnostics() -> [String] {
        Array(diagnostics[(turnBoundaryIndex ?? 0)...])
    }
}

private extension ChatGPTSubscriptionGenerationClient {
    func continuationResponseIDForTesting(sessionID: String) -> String? {
        sessions[sessionID]?.continuation?.responseID.nilIfBlank
    }

    func hasReplayableAssistantReasoningForTesting(sessionID: String) -> Bool {
        sessions[sessionID]?.messages.contains { message in
            guard (message["role"] as? String) == "assistant" else {
                return false
            }
            return (message["reasoning_content"] as? String)?.nilIfBlank != nil
                || (message["reasoning_items"] as? String)?.nilIfBlank != nil
        } ?? false
    }
}

private enum LiveSubscriptionCacheIntegrationError: LocalizedError {
    case missingModel
    case missingCacheDiagnostic(provider: String, diagnostics: [String])

    var errorDescription: String? {
        switch self {
        case .missingModel:
            return "No matching subscription model is configured in ~/.zencode/settings.json."
        case let .missingCacheDiagnostic(provider, diagnostics):
            return """
            \(provider) completed the live two-turn request but did not emit a cache diagnostic with cached prompt tokens.
            Diagnostics:
            \(diagnostics.joined(separator: "\n"))
            """
        }
    }
}
#endif
