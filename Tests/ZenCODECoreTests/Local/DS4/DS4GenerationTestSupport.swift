//
//  DS4GenerationTestSupport.swift
//  ZenCODE
//
//  Helpers for the tests of the in-process DS4 generation path: a
//  `DS4Engine` that records what the client asks (transcripts, sampling,
//  generation limits) on top of `MockDS4Engine`, and a harness that builds
//  `RemoteGenerationClient`s through `AgentRemoteBackendFactory` with a
//  private registry and a UUID-named temporary directory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// `MockDS4Engine` plus a record of every synced transcript and generate call
/// (a transcript synced from a prepared one is recorded as its operations).
final class RecordingDS4Engine: DS4Engine {
    struct GenerateCall: Sendable, Hashable {
        let sessionID: String
        let maxTokens: Int
        let thinkMode: Int32
        let sampling: DS4SamplingParameters
    }

    let base: MockDS4Engine
    private let syncedTranscripts = Mutex<[[DS4TranscriptOperation]]>([])
    private let generateCalls = Mutex<[GenerateCall]>([])
    private let generateResults = Mutex<[DS4GenerateResult]>([])

    init(base: MockDS4Engine) {
        self.base = base
    }

    var transcripts: [[DS4TranscriptOperation]] {
        syncedTranscripts.withLock { $0 }
    }

    var generations: [GenerateCall] {
        generateCalls.withLock { $0 }
    }

    /// The result of every successful `generate`, in order.
    var results: [DS4GenerateResult] {
        generateResults.withLock { $0 }
    }

    /// `(cached, suffix, total)` of every successful sync, in order.
    var syncs: [(cached: Int, suffix: Int)] {
        base.calls.compactMap { call in
            if case let .sync(_, cached, suffix) = call {
                return (cached, suffix)
            }
            return nil
        }
    }

    var info: DS4EngineInfo { base.info }

    func tokenCount(of transcript: [DS4TranscriptOperation]) async throws -> Int {
        try await base.tokenCount(of: transcript)
    }

    func prepare(transcript: [DS4TranscriptOperation]) async throws -> DS4PreparedTranscript {
        try await base.prepare(transcript: transcript)
    }

    func renderText(of transcript: [DS4TranscriptOperation]) async throws -> String {
        try await base.renderText(of: transcript)
    }

    func thinkMode(parseLevel: String) -> Int32? {
        base.thinkMode(parseLevel: parseLevel)
    }

    func thinkMode(forContext mode: Int32, contextSize: Int) async -> Int32 {
        await base.thinkMode(forContext: mode, contextSize: contextSize)
    }

    func sync(
        sessionID: String,
        transcript: [DS4TranscriptOperation],
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        let result = try await base.sync(sessionID: sessionID, transcript: transcript, onProgress: onProgress)
        syncedTranscripts.withLock { $0.append(transcript) }
        return result
    }

    func sync(
        sessionID: String,
        prepared: DS4PreparedTranscript,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async throws -> DS4SyncResult {
        let result = try await base.sync(sessionID: sessionID, prepared: prepared, onProgress: onProgress)
        syncedTranscripts.withLock { $0.append(prepared.operations) }
        return result
    }

    func generate(
        sessionID: String,
        maxTokens: Int,
        thinkMode: Int32,
        sampling: DS4SamplingParameters,
        onText: @escaping @Sendable (String) -> DS4EmitDecision
    ) async throws -> DS4GenerateResult {
        generateCalls.withLock {
            $0.append(GenerateCall(sessionID: sessionID, maxTokens: maxTokens, thinkMode: thinkMode, sampling: sampling))
        }
        let result = try await base.generate(
            sessionID: sessionID,
            maxTokens: maxTokens,
            thinkMode: thinkMode,
            sampling: sampling,
            onText: onText
        )
        generateResults.withLock { $0.append(result) }
        return result
    }

    func stats(sessionID: String) async -> DS4SessionStats {
        await base.stats(sessionID: sessionID)
    }

    func liveSessionCount() async -> Int {
        await base.liveSessionCount()
    }

    func setPower(sessionID: String, percent: Int) async throws {
        try await base.setPower(sessionID: sessionID, percent: percent)
    }

    func setSteeringFFN(sessionID: String, scale: Double) async throws {
        try await base.setSteeringFFN(sessionID: sessionID, scale: scale)
    }

    func saveCheckpoint(sessionID: String, to url: URL, trailer: Data?) async throws -> DS4CheckpointSaveOutcome {
        try await base.saveCheckpoint(sessionID: sessionID, to: url, trailer: trailer)
    }

    func loadCheckpoint(sessionID: String, from url: URL) async throws -> Data? {
        try await base.loadCheckpoint(sessionID: sessionID, from: url)
    }

    func releaseSession(_ sessionID: String) async {
        await base.releaseSession(sessionID)
    }

    func close() async {
        await base.close()
    }
}

/// Collects client events.
final class DS4EventRecorder: Sendable {
    private let storage = Mutex<[DirectAgentEvent]>([])

    var events: [DirectAgentEvent] {
        storage.withLock { $0 }
    }

    var handler: @Sendable (DirectAgentEvent) async -> Void {
        { [self] event in storage.withLock { $0.append(event) } }
    }

    var content: String {
        events.compactMap { if case let .content(text) = $0 { text } else { nil } }.joined()
    }

    var thoughts: String {
        events.compactMap { if case let .thought(text) = $0 { text } else { nil } }.joined()
    }

    var diagnostics: [String] {
        events.compactMap { if case let .diagnostic(text) = $0 { text } else { nil } }
    }

    var statuses: [String] {
        events.compactMap { if case let .status(text) = $0 { text } else { nil } }
    }

    var contextWindows: [DirectAgentContextWindowStatus] {
        events.compactMap { if case let .contextWindow(status) = $0 { status } else { nil } }
    }
}

/// A Sendable box around a `Mutex` (a `Mutex` cannot be captured by copy).
final class DS4TestBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        storage.withLock { $0 }
    }

    func update(_ body: (inout Value) -> Void) {
        storage.withLock { body(&$0) }
    }
}

/// A DS4 model selection backed by a mock engine and a private registry.
final class DS4ClientHarness: Sendable {
    static let toolName = "fixture.echo"
    static let systemPrompt = "You are the ZenCODE test agent."

    let base: URL
    let manifest: AgentDS4RuntimeManifest
    let configuration: DS4EngineConfiguration
    let engine: RecordingDS4Engine
    let registry: DS4EngineRegistry
    let environment: DS4LocalGeneration.Environment
    private let opens = DS4TestBox(0)
    private let toolArguments = DS4TestBox<[String]>([])

    init(
        syntax: DS4ToolSyntax = .dsml41,
        contextSize: Int = 8192,
        hasVision: Bool = false,
        visionRelativePath: String? = nil,
        syncDelay: Duration = .zero,
        chunkDelay: Duration = .zero,
        generationGate: MockDS4Gate? = nil,
        steeringRelativePath: String? = nil,
        power: Int = 100,
        libraryStatus: DS4EngineLibraryStatus? = nil
    ) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.base = base
        manifest = try AgentDS4RuntimeManifest(
            rootDirectory: base.path,
            modelRelativePath: "model.gguf",
            contextWindow: contextSize,
            power: power,
            visionRelativePath: visionRelativePath,
            steeringRelativePath: steeringRelativePath
        )
        let configuration = DS4EngineConfiguration.mock(
            model: base.appendingPathComponent("model.gguf").path,
            contextSize: contextSize
        )
        self.configuration = configuration
        let engine = RecordingDS4Engine(base: MockDS4Engine(
            configuration: configuration,
            info: DS4EngineInfo(
                modelName: "mock-ds4",
                modelID: 41,
                routedQuantBits: 2,
                hasVision: hasVision,
                toolSyntaxID: syntax.rawValue,
                mtpDraftTokens: 1,
                contextSize: contextSize
            ),
            syncDelay: syncDelay,
            chunkDelay: chunkDelay,
            generationGate: generationGate
        ))
        self.engine = engine
        let opens = self.opens
        let registry = DS4EngineRegistry { _, _ in
            opens.update { $0 += 1 }
            return engine
        }
        self.registry = registry
        environment = DS4LocalGeneration.Environment(
            registry: registry,
            resolveConfiguration: { _ in configuration },
            libraryStatus: { _ in libraryStatus ?? .built(configuration.libraryURL) }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    var openCount: Int {
        opens.value
    }

    /// Arguments received by the `fixture.echo` tool, in order.
    var echoedArguments: [String] {
        toolArguments.value
    }

    var mock: MockDS4Engine {
        engine.base
    }

    var provider: AgentRemoteProvider {
        AgentRemoteProvider(
            name: "DS4",
            baseURL: "http://127.0.0.1:8000/v1",
            modelID: "deepseek-v4-flash",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: manifest
        )
    }

    func selection(
        overrides: AgentGenerationParameterOverrides? = nil,
        contextWindowLimit: Int? = nil
    ) -> AgentModelSelection {
        AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: provider.modelID,
            remoteProvider: provider,
            apiKey: nil,
            configuredContextWindowLimit: contextWindowLimit,
            generationParameterOverrides: overrides,
            thinkingOptions: nil,
            thinkingSelection: nil
        )
    }

    func runtimeConfiguration(maxToolRounds: Int = 6, maxOutputTokens: Int? = nil) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: provider.modelID,
            workingDirectory: base,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            toolAuthorizationHandler: nil
        )
    }

    /// A client built by the backend factory, with the `fixture.echo` tool
    /// and a session `sessionID` limited to it.
    func makeClient(
        sessionID: String = "session",
        maxToolRounds: Int = 6,
        maxOutputTokens: Int? = nil,
        overrides: AgentGenerationParameterOverrides? = nil,
        history: [AgentRuntimeMessage] = [],
        thinkingSelection: AgentThinkingSelection? = .off,
        preserveThinking: Bool = false
    ) async throws -> RemoteGenerationClient {
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: runtimeConfiguration(maxToolRounds: maxToolRounds, maxOutputTokens: maxOutputTokens),
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: selection(overrides: overrides),
            ds4Environment: environment
        )
        let client = try #require(backend as? RemoteGenerationClient)
        await installTool(on: client)
        await client.createSession(
            id: sessionID,
            cwd: base.path,
            systemPrompt: Self.systemPrompt,
            history: history,
            allowedToolNames: [Self.toolName],
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        return client
    }

    func installTool(on client: RemoteGenerationClient) async {
        let arguments = toolArguments
        await client.updateToolProviders([
            AgentToolProvider(
                tools: [
                    ToolDescriptor(
                        name: Self.toolName,
                        description: "Echoes its text.",
                        inputSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#
                    )
                ],
                executor: { call in
                    arguments.update { $0.append(call.argumentsJSON) }
                    return "echo: \(call.argumentsJSON)"
                }
            )
        ])
    }

    /// The DSML 4.1 markup of one `fixture.echo` call.
    static func dsml41EchoCall(_ text: String) -> String {
        "\n\n<｜DSML｜ calls>\n<｜DSML｜ invoke name=\"\(toolName)\">\n"
            + "<｜DSML｜ parameter name=\"text\" string=\"true\">\(text)</｜DSML｜ parameter>\n"
            + "</｜DSML｜ invoke>\n</｜DSML｜ calls>"
    }
}
