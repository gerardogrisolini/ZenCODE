//
//  OpenRouterPromptCacheIntegrationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/06/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct OpenRouterPromptCacheIntegrationTests {
    @Test
    func liveOpenRouterSecondTurnReportsPromptCacheReuse() async throws {
        guard ProcessInfo.processInfo.environment["ZENCODE_RUN_LIVE_OPENROUTER_CACHE"] == "1" else {
            return
        }

        let selection = try Self.openRouterSelection()
        let provider = try Self.requiredProvider(from: selection)
        let apiKey = try Self.requiredAPIKey(from: selection, provider: provider)
        let client = RemoteGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: selection.modelID,
                bearerToken: nil,
                workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                configuredContextWindowLimit: selection.configuredContextWindowLimit,
                generationParameterOverrides: selection.generationParameterOverrides
                    ?? AgentGenerationParameterOverrides(),
                maxToolRounds: 1,
                maxOutputTokens: Self.maxOutputTokens,
                verboseLogging: true,
                toolAuthorizationHandler: nil
            ),
            provider: provider,
            apiKey: apiKey,
            urlSession: Self.liveURLSession()
        )
        let events = LivePromptCacheEvents()
        let sessionID = "live-openrouter-cache-\(UUID().uuidString.lowercased())"
        let thinkingSelection = selection.thinkingSelection ?? .low
        await client.createSession(
            id: sessionID,
            cwd: FileManager.default.currentDirectoryPath,
            systemPrompt: Self.systemPrompt,
            allowedToolNames: [],
            thinkingSelection: thinkingSelection,
            preserveThinking: true
        )

        _ = try await client.sendPrompt(
            sessionID: sessionID,
            prompt: Self.firstPrompt,
            attachments: [],
            onEvent: { event in
                await events.append(event)
            }
        )
        await events.markTurnBoundary()

        _ = try await client.sendPrompt(
            sessionID: sessionID,
            prompt: Self.secondPrompt,
            attachments: [],
            onEvent: { event in
                await events.append(event)
            }
        )

        let secondTurnDiagnostics = await events.secondTurnDiagnostics()
        #expect(
            !secondTurnDiagnostics.contains { $0.contains("Cache warning:") },
            "OpenRouter reported low prompt-cache reuse on the second turn: \(secondTurnDiagnostics.joined(separator: "\n"))"
        )
        #expect(
            secondTurnDiagnostics.contains {
                $0.hasPrefix("\(provider.displayTitle) cache:")
            },
            "OpenRouter did not emit verbose cache usage: \(secondTurnDiagnostics.joined(separator: "\n"))"
        )

        let metrics = await events.metrics()
        let cachedPromptTokens = metrics.compactMap(\.cachedPromptTokenCount).max()
        let promptTokens = metrics.compactMap(\.promptTokenCount).max()
        guard let cachedPromptTokens else {
            throw LivePromptCacheIntegrationError.missingCacheMetrics(
                provider: provider.displayTitleWithModelID,
                promptTokens: promptTokens
            )
        }

        #expect(
            cachedPromptTokens >= Self.minimumCachedPromptTokens,
            "OpenRouter cached only \(cachedPromptTokens) prompt tokens; expected at least \(Self.minimumCachedPromptTokens)."
        )

        let snapshot: AgentRuntimeSessionSnapshot = try #require(
            await client.snapshotSession(id: sessionID)
        )
        #expect(
            snapshot.history.contains {
                $0.role == AgentRuntimeMessage.Role.assistant && !$0.content.isEmpty
            }
        )
        #expect(
            snapshot.history.contains {
                $0.role == AgentRuntimeMessage.Role.assistant && $0.reasoningContent != nil
            }
        )
    }

    private static let maxOutputTokens = 256
    private static let minimumCachedPromptTokens = 512

    private static let systemPrompt = """
    You are running a live integration test for ZenCODE. Answer the user with only the requested marker.
    """

    private static var firstPrompt: String {
        """
        Keep the following cache anchor in context. Do not summarize it. Reply exactly: OK-1

        \(cacheAnchor)
        """
    }

    private static var secondPrompt: String {
        """
        Reuse the previous cache anchor and reply exactly: OK-2
        """
    }

    private static var cacheAnchor: String {
        (1...180)
            .map { index in
                "Cache anchor \(index): Preserve this deterministic sentence for prompt cache verification across the next OpenRouter request."
            }
            .joined(separator: "\n")
    }

    private static func openRouterSelection() throws -> AgentModelSelection {
        let requestedModel = ProcessInfo.processInfo
            .environment["ZENCODE_LIVE_OPENROUTER_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedModel, !requestedModel.isEmpty,
           let selection = AgentSettingsStore.modelSelection(forLLMID: requestedModel),
           selection.remoteProvider.map({ AgentRemoteProvider.isOpenRouterBaseURL($0.baseURL) }) == true {
            return selection
        }

        let manifest = try AgentSettingsManifestStore.loadRequired()
        let openRouterProviderIDs = Set(
            manifest.providers
                .filter { AgentRemoteProvider.isOpenRouterBaseURL($0.baseURL) }
                .map(\.id)
        )
        let candidates = manifest.models.filter { model in
            guard let providerID = model.providerID else {
                return false
            }
            return openRouterProviderIDs.contains(providerID)
        }
        let model =
            candidates.first { $0.modelID == "deepseek/deepseek-v4-flash" }
            ?? candidates.first { $0.thinkingOptions?.contains(.low) == true }
            ?? candidates.first
        guard let model,
              let selection = AgentSettingsStore.modelSelection(forLLMID: model.id) else {
            throw LivePromptCacheIntegrationError.missingOpenRouterModel
        }
        return selection
    }

    private static func requiredProvider(
        from selection: AgentModelSelection
    ) throws -> AgentRemoteProvider {
        guard let provider = selection.remoteProvider else {
            throw LivePromptCacheIntegrationError.missingOpenRouterModel
        }
        return provider
    }

    private static func requiredAPIKey(
        from selection: AgentModelSelection,
        provider: AgentRemoteProvider
    ) throws -> String {
        guard let apiKey = selection.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw LivePromptCacheIntegrationError.missingAPIKey(provider: provider.displayTitle)
        }
        return apiKey
    }

    private static func liveURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        return URLSession(configuration: configuration)
    }
}

private actor LivePromptCacheEvents {
    private var diagnostics: [String] = []
    private var allMetrics: [DirectAgentGenerationMetrics] = []
    private var turnBoundaryIndex: Int?

    func append(_ event: DirectAgentEvent) {
        switch event {
        case let .diagnostic(message):
            diagnostics.append(message)
        case let .metrics(metrics):
            allMetrics.append(metrics)
        default:
            break
        }
    }

    func markTurnBoundary() {
        turnBoundaryIndex = diagnostics.count
    }

    func secondTurnDiagnostics() -> [String] {
        Array(diagnostics[(turnBoundaryIndex ?? 0)...])
    }

    func metrics() -> [DirectAgentGenerationMetrics] {
        allMetrics
    }
}

private enum LivePromptCacheIntegrationError: LocalizedError {
    case missingOpenRouterModel
    case missingAPIKey(provider: String)
    case missingCacheMetrics(provider: String, promptTokens: Int?)

    var errorDescription: String? {
        switch self {
        case .missingOpenRouterModel:
            return "No OpenRouter model is configured in ~/.zencode/settings.json."
        case let .missingAPIKey(provider):
            return "No API key is configured for \(provider)."
        case let .missingCacheMetrics(provider, promptTokens):
            let promptDescription = promptTokens.map(String.init) ?? "unknown"
            return """
            \(provider) completed the live two-turn request but did not report cached prompt tokens \
            (promptTokens=\(promptDescription)). The client path ran, but cache reuse cannot be proven from provider metrics.
            """
        }
    }
}
