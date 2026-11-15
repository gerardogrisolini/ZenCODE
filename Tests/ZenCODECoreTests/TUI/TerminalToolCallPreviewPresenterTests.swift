//
//  TerminalToolCallPreviewPresenterTests.swift
//  ZenCODE
//
//  The terminal presenter of the live file write/edit preview: the pending
//  assistant commentary goes out before the header of a drawn call and is
//  offered to voice mode once; the tool call that follows finds it taken. A
//  call that is not drawn leaves the commentary to its tool start.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal tool-call preview presenter", .timeLimit(.minutes(1)))
struct TerminalToolCallPreviewPresenterTests {
    private static let commentary = "I will write the file."

    private struct Fixture {
        let directory: URL
        let renderer: TerminalChatRenderCoordinator
        let terminal: TerminalChat
        let buffer: TerminalAssistantResponseBuffer
        let voiceQueue: TerminalChatEventQueue
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-call-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = TerminalChatRenderCoordinator(
            stdinIsTerminal: false, standardOutput: nil, standardError: nil,
            standardOutputIsTerminal: false, standardErrorIsTerminal: false,
            cursorTopology: .separate,
            capturesWrites: true, streamingFlushDelay: nil, columnWidthProvider: { 100 }
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: directory
            ), stdinIsTerminal: false, sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
            telegramTransportFactory: nil, renderCoordinator: renderer
        )
        let buffer = TerminalAssistantResponseBuffer()
        await buffer.append(Self.commentary)
        terminal.activeAssistantOutput = buffer
        let voiceQueue = TerminalChatEventQueue()
        terminal.voiceController = PreviewListeningVoiceController()
        terminal.voiceEventQueue = voiceQueue
        return Fixture(
            directory: directory,
            renderer: renderer,
            terminal: terminal,
            buffer: buffer,
            voiceQueue: voiceQueue
        )
    }

    private func toolCall(name: String, arguments: [String: Any], json: String) -> DirectAgentToolCall {
        presentedToolCall(id: "call-1", name: name, argumentsObject: arguments, argumentsJSON: json)
    }

    private func offeredCommentaries(_ queue: TerminalChatEventQueue) async -> [String] {
        queue.finish()
        var offered: [String] = []
        for await event in queue.events {
            if case let .voiceCommentary(text) = event {
                offered.append(text)
            }
        }
        return offered
    }

    private func plainText(_ renderer: TerminalChatRenderCoordinator) async -> String {
        TerminalANSIText.stripANSI(await renderer.capturedWriteEvents().map(\.text).joined())
    }

    @Test
    func thePendingCommentaryGoesOutBeforeTheHeaderOnce() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let presenter = fixture.terminal.chatSessionPresenter

        for event: DirectAgentToolCallPreview in [
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("let x = 1\n"),
            .parameterEnded,
            .ended
        ] {
            await presenter.presentToolCallPreview(event)
        }
        await presenter.presentToolCallStarted(toolCall(
            name: "local.writeFile",
            arguments: ["path": "A.swift", "content": "let x = 1\n"],
            json: #"{"path":"A.swift","content":"let x = 1\n"}"#
        ))

        let text = await plainText(fixture.renderer)
        #expect(text.components(separatedBy: Self.commentary).count - 1 == 1)
        let commentary = try #require(text.range(of: Self.commentary))
        let header = try #require(text.range(of: "🛠️  write A.swift"))
        #expect(commentary.upperBound <= header.lowerBound)
        #expect(text.contains("🛠️  write A.swift\nlet x = 1\n"))
        #expect(await fixture.buffer.takePending() == "")
        #expect(await offeredCommentaries(fixture.voiceQueue) == [Self.commentary])
    }

    @Test
    func aCallThatIsNotDrawnLeavesTheCommentaryToItsToolStart() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let presenter = fixture.terminal.chatSessionPresenter

        for event: DirectAgentToolCallPreview in [
            .toolStarted(name: "local.readFile"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .ended
        ] {
            await presenter.presentToolCallPreview(event)
        }
        #expect(await fixture.renderer.capturedWriteEvents().isEmpty)

        await presenter.presentToolCallStarted(toolCall(
            name: "local.readFile",
            arguments: ["path": "A.swift"],
            json: #"{"path":"A.swift"}"#
        ))

        let text = await plainText(fixture.renderer)
        #expect(text.components(separatedBy: Self.commentary).count - 1 == 1)
        #expect(await offeredCommentaries(fixture.voiceQueue) == [Self.commentary])
    }
    @Test
    func twoDrawnCallsOfOneBlockTakeTheCommentaryOnce() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let presenter = fixture.terminal.chatSessionPresenter

        for event: DirectAgentToolCallPreview in [
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "path"),
            .parameterText("A.swift"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("let a = 1\n"),
            .parameterEnded,
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("B.swift"),
            .parameterEnded,
            .parameterStarted(name: "new"),
            .parameterText("let b = 2\n"),
            .parameterEnded,
            .ended
        ] {
            await presenter.presentToolCallPreview(event)
        }
        await presenter.presentToolCallStarted(toolCall(
            name: "local.writeFile",
            arguments: ["path": "A.swift", "content": "let a = 1\n"],
            json: #"{"path":"A.swift","content":"let a = 1\n"}"#
        ))
        await presenter.presentToolCallStarted(toolCall(
            name: "local.editFile",
            arguments: ["path": "B.swift", "old": "", "new": "let b = 2\n"],
            json: #"{"path":"B.swift","old":"","new":"let b = 2\n"}"#
        ))

        let text = await plainText(fixture.renderer)
        #expect(text.components(separatedBy: Self.commentary).count - 1 == 1)
        let commentary = try #require(text.range(of: Self.commentary))
        let first = try #require(text.range(of: "🛠️  write A.swift\nlet a = 1\n"))
        let second = try #require(text.range(of: "🛠️  edit B.swift\n+ let b = 2\n"))
        #expect(commentary.upperBound <= first.lowerBound)
        #expect(first.upperBound <= second.lowerBound)
        #expect(await fixture.buffer.takePending() == "")
        #expect(await offeredCommentaries(fixture.voiceQueue) == [Self.commentary])
    }
}

/// A voice controller that listens and never speaks, so the terminal offers
/// commentary to its queue.
private actor PreviewListeningVoiceController: VoiceModeController {
    nonisolated let languageCode = "en"
    private(set) var isActive = true
    private(set) var isPaused = false
    var isSpeaking: Bool { false }

    func start() async {}

    func stop() async {
        isActive = false
    }

    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        false
    }

    func interruptPlayback() async {}

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {}

    func discardDictation(through id: UInt64) async {}
}
