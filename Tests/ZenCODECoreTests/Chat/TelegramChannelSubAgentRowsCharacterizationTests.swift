//
//  TelegramChannelSubAgentRowsCharacterizationTests.swift
//  ZenCODE
//
//  Characterization of what the Telegram channel presents of the sub-agents:
//  the exact text of the `🤖 Sub-agent` status (summary row, then one inline
//  row per agent: a running tool, a thinking agent whose Markdown paragraph
//  the inline row discards, a partial response, a suppressed tool, a
//  completed response and a failure) and of the partial (💬) and completed
//  (✅) responses sent as messages of their own. The expected values were
//  captured on the code before the sub-agent overview layout was split
//  between the terminal UI and the shared runtime, and must not change.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Telegram sub-agent rows characterization", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelSubAgentRowsCharacterizationTests {
    private typealias Support = TelegramChannelTestSupport
    private typealias Fixtures = TelegramTurnActivityFixtures

    // MARK: - Fixtures

    private static let date = Date(timeIntervalSince1970: 1_000)

    private static func snapshot(
        id: String,
        status: DirectSubAgentRuntime.Status,
        activity: String? = nil,
        kind: DirectSubAgentRuntime.ActivityKind? = nil,
        revision: UInt64 = 0,
        toolName: String? = nil,
        toolTarget: String? = nil,
        output: String? = nil,
        outputRevision: UInt64 = 0,
        error: String? = nil
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: id,
            status: status,
            pending: status == .running || status == .queued,
            currentActivity: activity,
            currentActivityKind: kind,
            currentActivityRevision: revision,
            currentToolName: toolName,
            currentToolTarget: toolTarget,
            latestOutput: output,
            latestOutputRevision: outputRevision,
            latestError: error,
            createdAt: date,
            updatedAt: date
        )
    }

    /// One agent of every kind of row the inline status shows.
    private static let snapshots: [DirectSubAgentRuntime.AgentSnapshot] = [
        snapshot(id: "builder", status: .running, toolName: "local.exec", toolTarget: "swift test"),
        snapshot(
            id: "planner", status: .running,
            activity: "**Plan**: inspect the *parser* first\n\n- then the lexer", kind: .thinking, revision: 3
        ),
        snapshot(id: "writer", status: .running, activity: "Drafting the `README` section", kind: .content, revision: 2),
        snapshot(id: "messenger", status: .running, toolName: "agent.message", toolTarget: "coordinator"),
        snapshot(id: "reviewer", status: .idle, output: "## Review\n\nAll **tests** pass.", outputRevision: 4),
        snapshot(id: "legacy", status: .idle, output: "Done."),
        snapshot(id: "failer", status: .failed, error: "Build failed:\nexit 1"),
        snapshot(id: "waiter", status: .queued),
        snapshot(id: "sleeper", status: .standby),
        snapshot(id: "closer", status: .closed)
    ]

    private static let expectedStatus = """
        🤖 Sub-agent

        10 total ▸ 5 active ✓ 2 completed ◇ 1 standby ✗ 1 failed · 1 closed
        ● builder  [RUNNING]  · 🛠️  local.exec swift test
        ● planner  [RUNNING]  · 🤔 thinking…
        ● writer  [RUNNING]  · 💬 Drafting the `README` section
        ● messenger  [RUNNING]  · 🤔 thinking…
        ● reviewer  [COMPLETED]
        ● legacy  [COMPLETED]
        ● failer  [FAILED]  · ❌ Build failed: exit 1
        ● waiter  [QUEUED]  · 🤔 thinking…
        ● sleeper  [STANDBY]
        ● closer  [CLOSED]
        """

    private static let expectedResponses: [TelegramChannelPresenter.SubAgentResponse] = [
        .init(token: "writer\u{1F}partial\u{1F}2", heading: "💬 writer:", markdown: "Drafting the `README` section"),
        .init(token: "reviewer\u{1F}4", heading: "   ✅ Response from reviewer:\n", markdown: "## Review\n\nAll **tests** pass."),
        .init(token: "legacy\u{1F}7301570d0bb8fc6d", heading: "   ✅ Response from legacy:\n", markdown: "Done.")
    ]

    private static let expectedMessages = [
        "💬 writer:\n\nDrafting the `README` section",
        "✅ Response from reviewer:\n\n## Review\n\nAll **tests** pass.",
        "✅ Response from legacy:\n\nDone."
    ]

    // MARK: - Pure presentation

    /// The status text the presenter enqueues for the overview.
    @Test
    func theStatusTextOfEveryKindOfRowIsUnchanged() {
        let status = TerminalTelegramTurnActivity.subAgentStatusText(
            rows: TerminalSubAgentOverviewLayout.statusRows(Self.snapshots)
        )
        #expect(status == Self.expectedStatus)
        #expect(TerminalSubAgentOverviewLayout.statusRows([]).isEmpty)
    }

    /// The partial responses first, then the completed ones, with their
    /// tokens, headings and Markdown, and the payload each one is sent as.
    @Test
    func thePartialAndCompletedResponsesAreUnchanged() {
        let responses = TelegramChannelPresenter.subAgentResponses(
            of: ChatSubAgentOverview(snapshots: Self.snapshots)
        )
        #expect(responses == Self.expectedResponses)
        let payloads = responses.map { response -> String? in
            let payload = TelegramChannelPresenter.subAgentResponsePayload(
                heading: response.heading, markdown: response.markdown
            )
            guard case let .subAgentResponse(text) = payload else { return nil }
            return text
        }
        #expect(payloads == Self.expectedMessages)
    }

    // MARK: - Presenter

    /// What reaches the chat when a turn presents the overview: the status
    /// message, then each response as a message of its own.
    @Test
    func thePresenterSendsTheStatusThenEveryResponse() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter

            await presenter.turnWillStart(await Self.request(for: terminal))
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)
            await presenter.presentSubAgentOverview(
                ChatSubAgentOverview(snapshots: Self.snapshots), origin: .automatic, publication: nil
            )
            await reporter.flush()

            let effects = await log.effects
            #expect(effects.count == 1 + Self.expectedMessages.count, "\(effects)")
            if case let .create(_, text) = effects.first {
                #expect(text == Self.expectedStatus)
            } else {
                Issue.record("Unexpected effects: \(effects)")
            }
            #expect(Array(effects.dropFirst()) == Self.expectedMessages.map { .message($0) })
            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Helpers

    @ChatSessionActor
    private static func request(for terminal: TerminalChat) async -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: "go",
            sessionConfiguration: await terminal.chatSession.turnSessionConfiguration(
                for: .normal, responseLanguageSection: nil
            )
        )
    }
}
