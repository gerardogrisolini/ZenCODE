//
//  SwiftFeatureRuntimeTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
@testable import ZenCODECore
import Testing

extension SwiftFeatureRuntimeTests {
    @Test
    func scriptedModelGeneratesBuildsEnablesAndUsesFeature() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-scripted-model-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let featureRootURL = rootURL.appendingPathComponent("features", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [featureRootURL])
        let executor = DirectToolExecutor(
            outputLimit: 200_000,
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let scriptedModel = ScriptedFeatureAuthoringModelBackend(
            toolExecutor: executor
        )
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in scriptedModel }
        )
        let recorder = DirectAgentEventRecorder()
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "scripted-model-feature-test",
            modelID: "scripted-model",
            workingDirectory: workspaceURL,
            systemPrompt: MLXSystemPromptBuilder.defaultAgentInstructions(),
            cacheKey: nil,
            history: [],
            allowedToolNames: [
                "feature.scaffold",
                "feature.validate",
                "feature.build",
                "feature.enable",
                "local.replace",
                SwiftFeatureRuntime.featurePackageToolsAllowedName
            ],
            maxToolRounds: 20
        )

        let response = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "Genera una feature Swift riusabile che inverta il testo e usala con la parola desserts.",
            attachments: [],
            onEvent: { event in
                await recorder.record(event)
            }
        )

        let toolNames = await recorder.startedToolNames()
        let reverseOutput = await recorder.completedOutput(for: "scripted.reverse")
        let packageURL = featureRootURL
            .appendingPathComponent("scripted-reverse", isDirectory: true)
            .appendingPathComponent("Package.swift")
        let packageFirstLine = try String(
            contentsOf: packageURL,
            encoding: .utf8
        ).components(separatedBy: .newlines).first

        #expect(response.text.contains("scripted.reverse"))
        #expect(response.text.contains("stressed"))
        #expect(toolNames == [
            "feature.scaffold",
            "local.replace",
            "feature.validate",
            "feature.build",
            "feature.enable",
            "scripted.reverse"
        ])
        #expect(reverseOutput == "stressed")
        #expect(packageFirstLine == "// swift-tools-version: 6.3")
    }
}

actor SwiftFeatureTestAgentRuntimeBackend: AgentRuntimeBackend {
    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test")
    }
}

private actor ScriptedFeatureAuthoringModelBackend: AgentRuntimeBackend {
    private struct Session {
        let cwd: URL
        var allowedToolNames: Set<String>?
    }

    private let toolExecutor: DirectToolExecutor
    private var sessions: [String: Session] = [:]

    init(toolExecutor: DirectToolExecutor) {
        self.toolExecutor = toolExecutor
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        sessions[id] = Session(
            cwd: URL(fileURLWithPath: cwd),
            allowedToolNames: allowedToolNames
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        if sessions[id] == nil {
            createSession(
                id: id,
                cwd: cwd,
                systemPrompt: systemPrompt,
                history: history,
                cacheKey: cacheKey,
                allowedToolNames: allowedToolNames,
                thinkingSelection: thinkingSelection,
                preserveThinking: preserveThinking
            )
        }
    }

    func updateSessionOptions(
        id: String,
        systemPrompt _: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        guard var session = sessions[id] else {
            return
        }
        session.allowedToolNames = allowedToolNames
        sessions[id] = session
    }

    func closeSession(id: String) {
        sessions[id] = nil
    }

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "scripted-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        await toolExecutor.descriptors()
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        guard let session = sessions[sessionID] else {
            throw ScriptedFeatureAuthoringModelError.missingSession
        }
        guard prompt.localizedCaseInsensitiveContains("feature") else {
            throw ScriptedFeatureAuthoringModelError.unexpectedPrompt(prompt)
        }

        func callTool(
            id: Int,
            _ name: String,
            arguments: [String: Any]
        ) async throws -> String {
            let toolCall = DirectAgentToolCall(
                id: "scripted-feature-tool-\(id)",
                name: name,
                argumentsObject: arguments,
                argumentsJSON: try Self.jsonString(from: arguments)
            )
            await onEvent(.toolCallStarted(toolCall))
            let result = await toolExecutor.execute(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: session.cwd,
                allowedToolNames: session.allowedToolNames
            )
            await onEvent(.toolCallCompleted(toolCall, result))
            if result.output.hasPrefix("Tool error:") {
                throw ScriptedFeatureAuthoringModelError.toolFailed(name, result.output)
            }
            return result.output
        }

        let scaffoldOutput = try await callTool(
            id: 1,
            "feature.scaffold",
            arguments: [
                "id": "scripted-reverse",
                "toolName": "scripted.reverse"
            ]
        )
        let scaffold = try JSONDecoder().decode(
            SwiftFeatureScaffoldReport.self,
            from: Data(scaffoldOutput.utf8)
        )
        _ = try await callTool(
            id: 2,
            "local.replace",
            arguments: [
                "path": scaffold.sourcePath,
                "oldString": #"return input.text ?? """#,
                "newString": #"return String((input.text ?? "").reversed())"#
            ]
        )

        let validationOutput = try await callTool(
            id: 3,
            "feature.validate",
            arguments: [
                "id": "scripted-reverse"
            ]
        )
        let validation = try JSONDecoder().decode(
            SwiftFeatureValidationReport.self,
            from: Data(validationOutput.utf8)
        )
        guard validation.ok else {
            throw ScriptedFeatureAuthoringModelError.validationFailed(validation.errors)
        }

        let buildOutput = try await callTool(
            id: 4,
            "feature.build",
            arguments: [
                "id": "scripted-reverse"
            ]
        )
        let build = try JSONDecoder().decode(
            SwiftFeatureBuildReport.self,
            from: Data(buildOutput.utf8)
        )
        guard build.ok else {
            throw ScriptedFeatureAuthoringModelError.buildFailed(build.stderr)
        }

        _ = try await callTool(
            id: 5,
            "feature.enable",
            arguments: [
                "id": "scripted-reverse"
            ]
        )
        let reverseOutput = try await callTool(
            id: 6,
            "scripted.reverse",
            arguments: [
                "text": "desserts"
            ]
        )
        guard reverseOutput == "stressed" else {
            throw ScriptedFeatureAuthoringModelError.unexpectedToolOutput(reverseOutput)
        }

        return DirectAgentResponse(
            text: "Generated feature scripted.reverse returned \(reverseOutput).",
            stopReason: "end_turn",
            modelID: "scripted-model"
        )
    }

    private static func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONValue(jsonObject: object).jsonData(
            outputFormatting: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private enum ScriptedFeatureAuthoringModelError: LocalizedError {
    case missingSession
    case unexpectedPrompt(String)
    case toolFailed(String, String)
    case validationFailed([String])
    case buildFailed(String)
    case unexpectedToolOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The scripted feature authoring model has no active session."
        case let .unexpectedPrompt(prompt):
            return "The scripted feature authoring model received an unexpected prompt: \(prompt)"
        case let .toolFailed(name, output):
            return "Tool \(name) failed during scripted feature authoring: \(output)"
        case let .validationFailed(errors):
            return "Generated feature validation failed: \(errors.joined(separator: "\n"))"
        case let .buildFailed(stderr):
            return "Generated feature build failed: \(stderr)"
        case let .unexpectedToolOutput(output):
            return "Generated feature returned unexpected output: \(output)"
        }
    }
}

private actor DirectAgentEventRecorder {
    private var startedNames: [String] = []
    private var completedOutputsByName: [String: String] = [:]

    func record(_ event: DirectAgentEvent) {
        switch event {
        case let .toolCallStarted(toolCall):
            startedNames.append(toolCall.name)
        case let .toolCallCompleted(toolCall, result):
            completedOutputsByName[toolCall.name] = result.output
        default:
            break
        }
    }

    func startedToolNames() -> [String] {
        startedNames
    }

    func completedOutput(for toolName: String) -> String? {
        completedOutputsByName[toolName]
    }
}
