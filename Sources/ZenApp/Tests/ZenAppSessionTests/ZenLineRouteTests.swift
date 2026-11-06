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
        #expect(route("/voice", running: true) == .runBeside)
        #expect(route("/voice pause", running: true) == .runBeside)
        #expect(route("/voice off", running: true) == .runBeside)
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

    @Test("The window's commands: the shared ones, /artifacts run by the window, then /telegram, /voice, and /exit")
    func windowCommands() throws {
        // The window's /artifacts takes the place of the shared one: the order is unchanged.
        #expect(ZenAppCommands.descriptors.map(\.command)
            == ChatCommandRegistry.sharedDescriptors.map(\.command) + ["/telegram", "/voice", "/exit"])
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
        #expect(ZenAppCommands.descriptors.filter {
            $0.command != "/artifacts" && $0.command != "/telegram" && $0.command != "/voice" && $0.command != "/exit"
        } == ChatCommandRegistry.sharedDescriptors.filter { $0.command != "/artifacts" })
        let visible = ZenAppCommands.visibleDescriptors(in: [])
        #expect(visible.allSatisfy { $0.availability.isEmpty })
        #expect(visible.last?.command == "/exit")
        #expect(ZenAppCommands.visibleDescriptors(in: .builderAgent).count >= visible.count)
        #expect(ZenAppCommands.context(for: nil) == [])
    }

    @Test("/telegram: hidden without the Telegram fact, right before /exit with it; the status and off run while a prompt is generating, on does not")
    func telegramCommand() throws {
        #expect(ZenAppCommands.telegramEnabled.rawValue == 1 << 16)
        #expect(!ZenAppCommands.visibleDescriptors(in: []).contains { $0.command == "/telegram" })
        #expect(!ZenAppCommands.visibleDescriptors(in: .builderAgent).contains { $0.command == "/telegram" })
        let visible = ZenAppCommands.visibleDescriptors(in: ZenAppCommands.telegramEnabled).map(\.command)
        #expect(visible.suffix(3) == ["/telegram", "/voice", "/exit"])
        #expect(visible.filter { $0 == "/telegram" }.count == 1)

        let telegram = try #require(registry.descriptor(forLine: "/telegram off"))
        #expect(telegram == ZenAppCommands.telegram)
        #expect(telegram.scope == .channel)
        #expect(telegram.availability == ZenAppCommands.telegramEnabled)
        #expect(telegram.hiddenMessage == nil)
        #expect(telegram.summary == "turn Telegram on/off")
        #expect(registry.message(forHiddenLine: "/telegram", context: [], isGenerating: false)
            == "ZenCODE: unknown command '/telegram'.\n")
        #expect(registry.message(forHiddenLine: "/telegram", context: ZenAppCommands.telegramEnabled, isGenerating: false)
            == nil)

        #expect(registry.isAvailableDuringGeneration("/telegram"))
        #expect(registry.isAvailableDuringGeneration("/telegram off"))
        #expect(registry.isAvailableDuringGeneration("/telegram OFF"))
        #expect(!registry.isAvailableDuringGeneration("/telegram on"))
        #expect(!registry.isAvailableDuringGeneration("/telegram status"))
        #expect(!ZenAppCommands.changesStatusFacts("/telegram on"))

        #expect(ZenAppCommands.context(for: nil, telegramConfigured: true) == ZenAppCommands.telegramEnabled)
        #expect(ZenAppCommands.context(for: nil, telegramConfigured: false) == [])
        let builder = try #require(AgentProfileStore.defaultProfiles().first { AgentProfileStore.isBuilderAgent($0) })
        #expect(ZenAppCommands.context(for: builder, telegramConfigured: true)
            == [.builderAgent, ZenAppCommands.telegramEnabled])
    }

    @Test("A line runs: /telegram and /telegram off run beside it, any other /telegram line is refused; hidden, /telegram runs beside and answers as unknown")
    func telegramWhileRunning() {
        let context = ZenAppCommands.telegramEnabled
        #expect(route("/telegram", running: true, context: context) == .runBeside)
        #expect(route("/telegram off", running: true, context: context) == .runBeside)
        #expect(route("/telegram on", running: true, context: context)
            == .refuse("ZenCODE: command '/telegram' is unavailable while a prompt is running."))
        #expect(route("/telegram foo", running: true, context: context)
            == .refuse("ZenCODE: command '/telegram' is unavailable while a prompt is running."))
        // Hidden: as in the terminal, the line runs beside the prompt and the
        // shared layer answers it as an unknown command; `on` is refused with
        // the unknown-command answer.
        #expect(route("/telegram", running: true) == .runBeside)
        #expect(route("/telegram on", running: true) == .refuse("ZenCODE: unknown command '/telegram'."))
        #expect(route("/telegram on", running: false, context: context) == .run)
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
