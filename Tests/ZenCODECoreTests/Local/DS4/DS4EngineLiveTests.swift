//
//  DS4EngineLiveTests.swift
//  ZenCODE
//
//  Opt-in end-to-end test of the in-process DS4 path with a real model: it
//  loads tens of GiB, so it only runs with ZENCODE_RUN_LIVE_DS4=1.
//
//    ZENCODE_RUN_LIVE_DS4=1        enables the test
//    ZENCODE_DS4_ROOT=<dir>        DS4 checkout (default ~/Projects/ds4)
//    ZENCODE_DS4_MODEL=<file>      GGUF relative to the root (default ds4flash.gguf)
//    ZENCODE_DS4_BACKEND=<name>    metal | cuda | rocm | cpu (default metal)
//    ZENCODE_DS4_CTX=<tokens>      context size (default 32768)
//    ZENCODE_DS4_SUPPORT_DIR=<dir> where libzencode-ds4 was built (default:
//                                  the ZenCODE support directory, read only)
//
//  The engine library must already be built (ZenCODE setup or
//  Scripts/build-ds4-engine.sh).
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("DS4 engine live", .serialized)
struct DS4EngineLiveTests {
    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZENCODE_RUN_LIVE_DS4"] == "1"))
    func realModelCallsAToolAndAnswers() async throws {
        let root = Self.environment["ZENCODE_DS4_ROOT"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/ds4", isDirectory: true).path
        let model = Self.environment["ZENCODE_DS4_MODEL"] ?? "ds4flash.gguf"
        let backend = Self.environment["ZENCODE_DS4_BACKEND"].flatMap(AgentDS4RuntimeBackend.init(rawValue:)) ?? .metal
        let contextSize = Self.environment["ZENCODE_DS4_CTX"].flatMap(Int.init) ?? 32_768
        let supportDirectory = Self.environment["ZENCODE_DS4_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppStorageDirectory.appSupportDirectoryURL()
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let manifest = try AgentDS4RuntimeManifest(
            rootDirectory: root,
            modelRelativePath: model,
            backend: backend,
            contextWindow: contextSize,
            engineSessions: 1
        )
        let registry = DS4EngineRegistry()
        let ds4Environment = DS4LocalGeneration.Environment(registry: registry) { manifest in
            try DS4EngineConfigurationMapping.configuration(for: manifest, supportDirectory: supportDirectory)
        }
        let provider = AgentRemoteProvider(
            name: "DS4",
            baseURL: "http://127.0.0.1:8000/v1",
            modelID: "deepseek-v4-flash",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: manifest
        )
        let calls = DS4TestBox<[String]>([])
        let systemPrompt = "You are a terse assistant. Use the tools when asked."
        func makeClient() async throws -> RemoteGenerationClient {
            let backendClient = try AgentRemoteBackendFactory.makeRemoteBackend(
                configuration: AgentRuntimeConfiguration(
                    modelID: provider.modelID,
                    workingDirectory: workingDirectory,
                    maxToolRounds: 4,
                    maxOutputTokens: 2048,
                    toolAuthorizationHandler: nil
                ),
                mcpRuntime: DirectMCPToolRuntime(),
                resolvedModelSelection: AgentModelSelection(
                    providerKind: .remoteAPI,
                    modelID: provider.modelID,
                    remoteProvider: provider,
                    apiKey: nil,
                    configuredContextWindowLimit: contextSize,
                    generationParameterOverrides: AgentGenerationParameterOverrides(temperature: 0),
                    thinkingSelection: nil
                ),
                ds4Environment: ds4Environment
            )
            let client = try #require(backendClient as? RemoteGenerationClient)
            await client.updateToolProviders([
                AgentToolProvider(
                    tools: [
                        ToolDescriptor(
                            name: "fixture.echo",
                            description: "Returns the given text unchanged.",
                            inputSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#
                        )
                    ],
                    executor: { call in
                        calls.update { $0.append(call.argumentsJSON) }
                        return "ECHO-RESULT-42"
                    }
                )
            ])
            return client
        }
        let client = try await makeClient()
        await client.createSession(
            id: "live",
            cwd: workingDirectory.path,
            systemPrompt: systemPrompt,
            allowedToolNames: ["fixture.echo"],
            thinkingSelection: .off
        )
        let recorder = DS4EventRecorder()

        let response: DirectAgentResponse
        do {
            response = try await client.sendPrompt(
                sessionID: "live",
                prompt: "Use the fixture.echo tool to echo: ping. Then reply with exactly the tool output.",
                attachments: [],
                onEvent: recorder.handler
            )
        } catch {
            // A live failure is only diagnosable from what the model produced.
            Self.dump(recorder, calls: calls.value, messages: await client.ds4DebugMessages(sessionID: "live"))
            throw error
        }

        #expect(calls.value.contains { $0.contains("ping") })
        #expect(response.text.contains("ECHO-RESULT-42"))
        // The second round reused the first prompt from the KV - and the tokens
        // the first round generated, replayed as the exact ids the model
        // sampled (tokenizing their text again can split it differently and a
        // model with recurrent state would rebuild the whole prompt).
        let prefills = recorder.diagnostics.filter { $0.hasPrefix("DS4 prefill:") }
        #expect(prefills.count >= 2)
        #expect(prefills.dropFirst().allSatisfy { !$0.hasPrefix("DS4 prefill: 0 cached") })
        let prefillCounts = prefills.compactMap(Self.prefillCounts(of:))
        let generatedCounts = recorder.diagnostics.compactMap(Self.generatedTokenCount(of:))
        // Visible with `swift test` even when the test passes.
        let report = (prefills + recorder.diagnostics.filter { $0.hasPrefix("DS4 generation:") })
            .map { "live: \($0)" }
        FileHandle.standardError.write(Data((report.joined(separator: "\n") + "\n").utf8))
        if prefillCounts.count >= 2, let generatedInFirstRound = generatedCounts.first {
            #expect(prefillCounts[0].cached == 0)
            #expect(
                prefillCounts[1].cached == prefillCounts[0].cached + prefillCounts[0].suffix + generatedInFirstRound,
                "round 2 should reuse the prompt and the \(generatedInFirstRound) tokens of round 1: \(prefills)"
            )
        } else {
            Issue.record("missing prefill or generation diagnostics: \(recorder.diagnostics)")
        }

        // Explicit save (the `/sessions save` path), then a fresh client that
        // only has the snapshot history, as after a restart: restoring the
        // checkpoint must let the next turn reuse the saved KV prefix.
        let checkpointURL = workingDirectory.appendingPathComponent("live.ds4kv")
        #expect(try await client.saveEngineCheckpoint(sessionID: "live", to: checkpointURL) == .saved)
        #expect(FileManager.default.fileExists(atPath: checkpointURL.path))
        let snapshot = try #require(await client.snapshotSession(id: "live"))
        await client.shutdown()

        let restored = try await makeClient()
        await restored.createSession(
            id: "live",
            cwd: workingDirectory.path,
            systemPrompt: systemPrompt,
            history: snapshot.history,
            allowedToolNames: ["fixture.echo"],
            thinkingSelection: .off
        )
        let restoreOutcome = await restored.restoreEngineCheckpoint(
            sessionID: "live",
            from: checkpointURL,
            onEvent: { _ in }
        )
        #expect(restoreOutcome == .restored)
        let restoredRecorder = DS4EventRecorder()
        _ = try await restored.sendPrompt(
            sessionID: "live",
            prompt: "Reply with the single word OK.",
            attachments: [],
            onEvent: restoredRecorder.handler
        )
        let restoredPrefill = restoredRecorder.diagnostics.first { $0.hasPrefix("DS4 prefill:") }
        #expect(restoredPrefill != nil)
        #expect(restoredPrefill.map { !$0.hasPrefix("DS4 prefill: 0 cached") } ?? false)
        await restored.shutdown()
        await registry.shutdown()
    }

    /// `(cached, suffix)` of a `DS4 prefill: N cached, M tokens to evaluate` diagnostic.
    private static func prefillCounts(of diagnostic: String) -> (cached: Int, suffix: Int)? {
        guard diagnostic.hasPrefix("DS4 prefill:") else {
            return nil
        }
        let numbers = diagnostic.dropFirst("DS4 prefill:".count)
            .split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 2 else {
            return nil
        }
        return (numbers[0], numbers[1])
    }

    /// `K` of a `DS4 generation: K tokens at ...` diagnostic.
    private static func generatedTokenCount(of diagnostic: String) -> Int? {
        guard diagnostic.hasPrefix("DS4 generation: ") else {
            return nil
        }
        return diagnostic.dropFirst("DS4 generation: ".count).split(separator: " ").first.flatMap { Int($0) }
    }

    private static func dump(_ recorder: DS4EventRecorder, calls: [String], messages: [String]) {
        var lines = ["--- DS4 live diagnostics ---"]
        lines += recorder.diagnostics.map { "diagnostic: \($0)" }
        lines.append("tool calls: \(calls)")
        lines.append("visible: \(recorder.content)")
        lines.append("thoughts: \(recorder.thoughts)")
        lines += messages
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

extension RemoteGenerationClient {
    /// Live-test diagnostics: each message's role and the exact DS4 text the
    /// renderer replays (raw assistant output and tool observations).
    func ds4DebugMessages(sessionID: String) -> [String] {
        guard let lease = sessionLease(for: sessionID),
              let session = currentSession(for: lease) else {
            return []
        }
        return session.messages.map { message in
            let role = message["role"] as? String ?? "?"
            let content = (message["content"] as? String)
                ?? message["content"].map { String(describing: $0) }
                ?? ""
            var line = "[\(role)] " + ((message[DS4MessageKeys.rawAssistant] as? String) ?? content)
            if let observation = message[DS4MessageKeys.toolObservation] as? String {
                line += "\n  observation: \(observation)"
            }
            if let ids = DS4MessageKeys.rawTokenIDs(of: message) {
                let model = message[DS4MessageKeys.rawTokensModel] as? String ?? "?"
                line += "\n  tokens: \(ids.count) ids from \(model), first \(ids.prefix(8))"
            }
            return line
        }
    }
}
