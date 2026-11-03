//
//  ZenLineRouteTests.swift
//  ZenAppSessionTests
//

import Foundation
import Testing
import ZenCODECore
@testable import ZenAppSession

@Suite(.serialized)
struct ZenLineRouteTests {
    private let registry = ZenAppCommands.registry

    private func route(
        _ line: String,
        running: Bool,
        queued: Bool = false,
        registry: ChatCommandRegistry? = nil,
        context: ChatCommandContext = []
    ) -> ZenLineRoute {
        ZenLineRoute.route(
            for: line,
            isLineRunning: running,
            hasQueuedLines: queued,
            registry: registry ?? self.registry,
            context: context
        )
    }

    @Test("Nothing runs: every line runs now")
    func idleLinesRun() {
        #expect(route("Hello", running: false) == .run)
        #expect(route("/models", running: false) == .run)
        #expect(route("  /help  ", running: false) == .run)
    }

    @Test("Nothing runs but lines wait: the line waits behind them")
    func idleWithQueueQueues() {
        #expect(route("Hello", running: false, queued: true) == .queue)
        #expect(route("/help", running: false, queued: true) == .queue)
    }

    @Test("A line runs: a prompt waits in the queue")
    func promptsQueueWhileRunning() {
        #expect(route("Next prompt", running: true) == .queue)
        #expect(route("Next prompt", running: true, queued: true) == .queue)
    }

    @Test("A line runs: a command available during generation runs beside it")
    func generationCommandsRunBeside() {
        #expect(route("/help", running: true) == .runBeside)
        #expect(route("/tasks", running: true) == .runBeside)
        #expect(route("/tasks list", running: true) == .runBeside)
        #expect(route("/artifacts", running: true) == .runBeside)
    }

    @Test("A line runs: any other command is refused with the terminal's message")
    func otherCommandsAreRefused() {
        #expect(route("/models", running: true)
            == .refuse("ZenCODE: command '/models' is unavailable while a prompt is running."))
        #expect(route("/tasks retry t1", running: true)
            == .refuse("ZenCODE: command '/tasks' is unavailable while a prompt is running."))
        #expect(route("/sessions new", running: true)
            == .refuse("ZenCODE: command '/sessions' is unavailable while a prompt is running."))
        #expect(route("/nope", running: true) == .refuse("ZenCODE: unknown command '/nope'."))
        // As in the terminal, /exit waits for the prompt to end.
        #expect(route("/exit", running: true)
            == .refuse("ZenCODE: command '/exit' is unavailable while a prompt is running."))
    }

    @Test("A line runs: a hidden command answers as hidden")
    func hiddenCommandsAnswerAsHidden() {
        let registry = ChatCommandRegistry(
            shared: ChatCommandRegistry.sharedDescriptors,
            channel: [(after: "", descriptors: [
                ChatCommandDescriptor(
                    command: "/builder", summary: "b", help: "b",
                    scope: .channel, availability: .builderAgent, hiddenMessage: "Builder only."
                ),
                ChatCommandDescriptor(
                    command: "/secret", summary: "s", help: "s",
                    scope: .channel, availability: .builderAgent
                ),
            ])]
        )
        #expect(route("/builder", running: true, registry: registry)
            == .refuse("ZenCODE: command '/builder' is unavailable while a prompt is running."))
        #expect(route("/secret", running: true, registry: registry)
            == .refuse("ZenCODE: unknown command '/secret'."))
        #expect(route("/secret", running: true, registry: registry, context: .builderAgent)
            == .refuse("ZenCODE: command '/secret' is unavailable while a prompt is running."))
    }

    @Test("The window's commands: the shared ones, /artifacts run by the window, then /exit")
    func windowCommands() throws {
        // The window's /artifacts takes the place of the shared one: the order is unchanged.
        #expect(ZenAppCommands.descriptors.map(\.command)
            == ChatCommandRegistry.sharedDescriptors.map(\.command) + ["/exit"])
        #expect(registry.descriptor(forLine: "/exit")?.scope == .channel)
        #expect(!registry.isAvailableDuringGeneration("/exit"))
        #expect(ZenAppCommands.exit.summary == "close this window")
        let artifacts = try #require(registry.descriptor(forLine: "/artifacts"))
        #expect(artifacts == ZenAppCommands.artifacts)
        #expect(artifacts.scope == .channel)
        #expect(artifacts.summary == "show or hide the artifacts sidebar")
        #expect(registry.isAvailableDuringGeneration("/artifacts"))
        #expect(ZenAppCommands.descriptors.filter { $0.command == "/artifacts" } == [ZenAppCommands.artifacts])
        // Every other shared command is the shared descriptor itself.
        #expect(ZenAppCommands.descriptors.filter { $0.command != "/artifacts" && $0.command != "/exit" }
            == ChatCommandRegistry.sharedDescriptors.filter { $0.command != "/artifacts" })
        let visible = ZenAppCommands.visibleDescriptors(in: [])
        #expect(visible.allSatisfy { $0.availability.isEmpty })
        #expect(visible.last?.command == "/exit")
        #expect(ZenAppCommands.visibleDescriptors(in: .builderAgent).count >= visible.count)
        #expect(ZenAppCommands.context(for: nil) == [])
    }

    @Test("The selections and the session operations refresh the status facts; other lines do not")
    func statusFactCommands() {
        for line in ["/models", "/think high", "/agents", "/tools", "/skills", "/sessions new", "/session save"] {
            #expect(ZenAppCommands.changesStatusFacts(line), "\(line)")
        }
        for line in ["/help", "/tasks", "/attach x", "/exit", "Hello", "/nope"] {
            #expect(!ZenAppCommands.changesStatusFacts(line), "\(line)")
        }
    }

    @Test("Attaching quotes the path for the /attach splitter")
    @MainActor
    func attachCommandLines() {
        #expect(ZenWindowSession.attachCommandLine(for: URL(fileURLWithPath: "/tmp/plain.png"))
            == "/attach \"/tmp/plain.png\"")
        #expect(ZenWindowSession.attachCommandLine(for: URL(fileURLWithPath: "/tmp/with space/a \"q\" \\b.png"))
            == "/attach \"/tmp/with space/a \\\"q\\\" \\\\b.png\"")
    }
}
