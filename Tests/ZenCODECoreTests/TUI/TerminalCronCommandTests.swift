//
//  TerminalCronCommandTests.swift
//  ZenCODECoreTests
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// In-memory crontab that records every access. No test uses the system
/// `crontab`: the real one is never read or written.
private final class FakeCrontabClient: CrontabClient {
    private struct State {
        var text: String
        var writes: [String] = []
        var readCount = 0
    }

    private let state: Mutex<State>
    private let readError: (any Error & Sendable)?
    private let writeError: (any Error & Sendable)?

    init(
        text: String,
        readError: (any Error & Sendable)? = nil,
        writeError: (any Error & Sendable)? = nil
    ) {
        state = Mutex(State(text: text))
        self.readError = readError
        self.writeError = writeError
    }

    var writes: [String] { state.withLock { $0.writes } }
    var readCount: Int { state.withLock { $0.readCount } }

    func readCrontab() throws -> String {
        let text = state.withLock { state -> String in
            state.readCount += 1
            return state.text
        }
        if let readError { throw readError }
        return text
    }

    func writeCrontab(_ text: String) throws {
        if let writeError { throw writeError }
        state.withLock { state in
            state.writes.append(text)
            state.text = text
        }
    }
}

/// Stand-in for the cron runner: records each call and, unless created
/// released, holds it until `release()` before returning `outcome`. No test
/// uses the system runner: no job is ever launched.
private final class FakeCronJobRunner: CronJobRunning {
    struct Call: Equatable {
        let cronCommand: String
        let environment: [String: String]
        let homeDirectory: URL
    }

    private struct State {
        var calls: [Call] = []
        var isReleased: Bool
        var pendingRuns: [CheckedContinuation<Void, Never>] = []
        var invocationWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>
    private let outcome: ZenCronRunOutcome

    init(outcome: ZenCronRunOutcome = FakeCronJobRunner.defaultOutcome, isReleased: Bool = false) {
        state = Mutex(State(isReleased: isReleased))
        self.outcome = outcome
    }

    static let defaultOutcome = ZenCronRunOutcome(
        exitStatus: 0,
        stdout: #"{"type":"message.completed","text":"All good"}"# + "\n",
        stderr: "",
        duration: .milliseconds(1_250),
        wasTerminated: false
    )

    var calls: [Call] { state.withLock { $0.calls } }

    func run(
        cronCommand: String,
        environment: [String: String],
        homeDirectory: URL
    ) async throws -> ZenCronRunOutcome {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.calls.append(
                Call(cronCommand: cronCommand, environment: environment, homeDirectory: homeDirectory)
            )
            defer { state.invocationWaiters = [] }
            return state.invocationWaiters
        }
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard !state.isReleased else { return true }
                state.pendingRuns.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return outcome
    }

    /// Lets every held run, and every later one, return.
    func release() {
        let pending = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isReleased = true
            defer { state.pendingRuns = [] }
            return state.pendingRuns
        }
        pending.forEach { $0.resume() }
    }

    /// Returns once `run` has been called at least once.
    func waitUntilInvoked() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.calls.isEmpty else { return true }
                state.invocationWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Stand-in for the `zen` search of `/cron add`: records every `PATH` it is
/// asked about and answers with a fixed result. No test depends on what is
/// installed on the machine.
private final class FakeZenLocator: Sendable {
    private let result: String?
    private let requests = Mutex<[String]>([])

    init(result: String? = "/fake/bin/zen") {
        self.result = result
    }

    var requestedPaths: [String] { requests.withLock { $0 } }

    func locate(onPath path: String) -> String? {
        requests.withLock { $0.append(path) }
        return result
    }
}

@TerminalChatActor
@Suite(.serialized)
struct TerminalCronCommandTests {
    private static let defaultPathLine = "PATH=\(ZenCrontabDocument.defaultPath)"
    private static let userLines = [
        "# m h dom mon dow command",
        "MAILTO=root",
        "",
        "0 3 * * * /usr/bin/backup --full",
        "\t# indented comment  ",
        "*/5 * * * * /usr/local/bin/ping >/dev/null 2>&1"
    ]
    private static let userCrontab = userLines.joined(separator: "\n") + "\n"

    // MARK: - add

    @Test
    func addAppendsTheBlockAfterTheUserLinesVerbatim() async throws {
        let locator = FakeZenLocator()
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab, zen: locator)

        let output = await run("/cron add 0 9 * * 1-5 Summarize open PRs", in: terminal)

        let written = try #require(client.writes.first)
        #expect(client.writes.count == 1)
        #expect(Array(written.utf8).starts(with: Array(Self.userCrontab.utf8)))
        #expect(written.hasSuffix("\(ZenCrontabDocument.endMarker)\n"))

        let document = try ZenCrontabDocument.parse(written)
        #expect(document.foreignLines == Self.userLines)
        let items = try #require(document.block?.items)
        #expect(items.count == 1)
        guard case let .entry(entry) = items[0] else {
            Issue.record("expected a scheduled entry")
            return
        }

        let directory = terminal.configuration.workingDirectory.path
        #expect(directory.contains("/ZenCODE-cron-"))
        #expect(entry.schedule == "0 9 * * 1-5")
        // cron finds `zen` through the PATH line at the head of the block.
        #expect(entry.cronLine.hasPrefix("0 9 * * 1-5 zen --working-directory "))
        #expect(
            entry.cronLine.contains(
                "--working-directory \(ZenCronJobCommand.shellQuote(directory)) --jsonl -p 'Summarize open PRs'"
            )
        )
        #expect(entry.job?.executable == "zen")
        #expect(entry.job?.prompt == "Summarize open PRs")
        #expect(entry.job?.workingDirectory == directory)
        #expect(document.block?.path == nil)
        #expect(written.contains("\n\(ZenCrontabDocument.beginMarker)\n\(Self.defaultPathLine)\n"))
        #expect(written.contains("\n\(entry.markerLine)\n\(entry.cronLine)\n"))
        #expect(locator.requestedPaths == [ZenCrontabDocument.defaultPath])
        #expect(
            output == "Scheduled prompt #1 added:\n  \(entry.cronLine)\n"
                + "  zen: /fake/bin/zen (PATH=/usr/local/bin:/usr/bin:/bin)\n"
        )
    }

    @Test
    func addWritesThePathLineBeforeMailToAndTheEntry() async throws {
        let (terminal, client) = try makeTerminal(
            crontab: try makeCrontab(foreign: ["# keep"], mailTo: "ops@example.com", prompts: ["First"])
        )

        _ = await run("/cron add @daily Second", in: terminal)

        let written = try #require(client.writes.first)
        let lines = written.components(separatedBy: "\n")
        let begin = try #require(lines.firstIndex(of: ZenCrontabDocument.beginMarker))
        #expect(lines[begin + 1] == Self.defaultPathLine)
        #expect(lines[begin + 2] == "MAILTO=ops@example.com")
        #expect(lines[begin + 3].hasPrefix("# zencode-cron id="))
        #expect(written.components(separatedBy: "\nPATH=").count == 2)
    }

    @Test
    func addConfirmationShowsTheBinaryCronWillUse() async throws {
        let locator = FakeZenLocator(result: "/opt/homebrew/bin/zen")
        let (terminal, _) = try makeTerminal(crontab: "", zen: locator)

        let output = await run("/cron add @daily Hello", in: terminal)

        let lines = output.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "Scheduled prompt #1 added:")
        #expect(lines[1].hasPrefix("  @daily zen --working-directory "))
        #expect(lines[2] == "  zen: /opt/homebrew/bin/zen (PATH=/usr/local/bin:/usr/bin:/bin)")
        #expect(lines[3] == "")
    }

    @Test
    func addRefusesWhenNoZenIsOnThePathAndWritesNothing() async throws {
        let locator = FakeZenLocator(result: nil)
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab, zen: locator)

        let output = await run("/cron add 0 9 * * 1-5 Summarize open PRs", in: terminal)

        #expect(
            output == "ZenCODE: cron runs `zen` with PATH=/usr/local/bin:/usr/bin:/bin, "
                + "but no executable zen was found there. "
                + "Install ZenCODE in /usr/local/bin (Scripts/install.sh) before scheduling prompts.\n"
        )
        let error = ZenCrontabError.zenNotOnPath(path: ZenCrontabDocument.defaultPath)
        #expect(output == "ZenCODE: \(error.localizedDescription)\n")
        #expect(client.writes.isEmpty)
        #expect(client.readCount == 1)
        #expect(locator.requestedPaths == [ZenCrontabDocument.defaultPath])
    }

    @Test
    func addPassesTheBlocksCustomPathToTheLocator() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], path: "/opt/zen/bin:/usr/bin", prompts: ["First"])
        let locator = FakeZenLocator(result: "/opt/zen/bin/zen")
        let (terminal, client) = try makeTerminal(crontab: existing, zen: locator)

        let output = await run("/cron add @daily Second", in: terminal)

        #expect(locator.requestedPaths == ["/opt/zen/bin:/usr/bin"])
        #expect(output.hasSuffix("  zen: /opt/zen/bin/zen (PATH=/opt/zen/bin:/usr/bin)\n"))
        // The hand-edited PATH survives the write.
        let written = try #require(client.writes.first)
        let document = try ZenCrontabDocument.parse(written)
        #expect(document.block?.path == "/opt/zen/bin:/usr/bin")
        #expect(document.block?.items.count == 2)
        #expect(written.contains("\n\(ZenCrontabDocument.beginMarker)\nPATH=/opt/zen/bin:/usr/bin\n"))
    }

    @Test
    func addSearchesTheCustomPathWithoutItsOuterDoubleQuotes() async throws {
        // A block holding only a PATH is empty, so give it a MAILTO to exist.
        let text = [
            ZenCrontabDocument.beginMarker,
            "MAILTO=\"\"",
            "PATH=\"/opt/zen/bin:/usr/bin\"",
            ZenCrontabDocument.endMarker,
            ""
        ].joined(separator: "\n")
        let locator = FakeZenLocator(result: nil)
        let (terminal, client) = try makeTerminal(crontab: text, zen: locator)

        let output = await run("/cron add @daily Hello", in: terminal)

        #expect(locator.requestedPaths == ["/opt/zen/bin:/usr/bin"])
        #expect(output.contains("PATH=/opt/zen/bin:/usr/bin, but no executable zen"))
        #expect(client.writes.isEmpty)
    }

    @Test
    func addNumbersTheNewEntryAfterTheExistingOnes() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], prompts: ["First", "Second"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        let output = await run("/cron add @daily Third", in: terminal)

        let written = try #require(client.writes.first)
        let items = try #require(ZenCrontabDocument.parse(written).block?.items)
        #expect(items.count == 3)
        #expect(output.hasPrefix("Scheduled prompt #3 added:\n  @daily "))
        // The two earlier entries are re-emitted byte for byte.
        let before = try #require(ZenCrontabDocument.parse(existing).block?.items)
        #expect(Array(items.prefix(2)) == before)
    }

    @Test
    func addPassesTheAgentOnlyWhenOneIsSelected() async throws {
        let (terminal, client) = try makeTerminal(crontab: "")
        terminal.selectedAgent = nil
        _ = await run("/cron add @hourly Without agent", in: terminal)
        let withoutAgent = try #require(client.writes.last)
        #expect(!withoutAgent.contains("--agent"))

        let agent = try #require(AgentProfileStore.defaultProfiles().first)
        terminal.selectedAgent = agent
        _ = await run("/cron add @hourly With agent", in: terminal)
        let withAgent = try #require(client.writes.last)
        let items = try #require(ZenCrontabDocument.parse(withAgent).block?.items)
        guard case let .entry(entry) = try #require(items.last) else {
            Issue.record("expected a scheduled entry")
            return
        }
        #expect(entry.cronLine.contains(" --agent \(ZenCronJobCommand.shellQuote(agent.name)) --working-directory "))
        #expect(entry.job?.agentName == agent.name)
    }

    @Test
    func addKeepsQuotesAndPercentSignsInThePrompt() async throws {
        let (terminal, client) = try makeTerminal(crontab: "")

        _ = await run("/cron add 30 6 * * * Report 100% of the repo's \"open\" PRs", in: terminal)

        let written = try #require(client.writes.first)
        let items = try #require(ZenCrontabDocument.parse(written).block?.items)
        guard case let .entry(entry) = try #require(items.first) else {
            Issue.record("expected a scheduled entry")
            return
        }
        #expect(entry.job?.prompt == "Report 100% of the repo's \"open\" PRs")
        // A bare `%` would end the command at the first one when cron runs it.
        #expect(!entry.cronLine.contains(" 100% "))
    }

    @Test(arguments: [
        ("/cron add 61 9 * * * Hello", "Invalid cron schedule"),
        ("/cron add @bogus Hello", "Invalid cron schedule"),
        ("/cron add 0 9 * * *", "cannot be scheduled"),
        ("/cron add @daily", "cannot be scheduled"),
        ("/cron add 0 9 * * * first\nsecond", "cannot be scheduled"),
        ("/cron add 0 9 * * * first\r\nsecond", "cannot be scheduled"),
        ("/cron add 0 9 * *", "Usage: /cron"),
        ("/cron add", "Usage: /cron")
    ])
    func rejectedAddNeverTouchesTheCrontab(command: String, expected: String) async throws {
        let locator = FakeZenLocator()
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab, zen: locator)

        let output = await run(command, in: terminal)

        #expect(output.contains(expected))
        #expect(client.writes.isEmpty)
        #expect(client.readCount == 0)
        #expect(locator.requestedPaths.isEmpty)
    }

    // MARK: - remove

    @Test
    func removingTheOnlyEntryDropsTheWholeBlock() async throws {
        let existing = try makeCrontab(foreign: ["# keep", "0 1 * * * /bin/backup"], prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        let output = await run("/cron remove 1", in: terminal)

        #expect(client.writes == ["# keep\n0 1 * * * /bin/backup\n"])
        #expect(!(client.writes.first ?? "").contains("ZenCODE cron"))
        #expect(output == "Scheduled prompt #1 removed.\n")
    }

    @Test
    func removingTheLastThingInTheCrontabWritesAnEmptyCrontab() async throws {
        let existing = try makeCrontab(prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        _ = await run("/cron remove 1", in: terminal)

        #expect(client.writes == [""])
    }

    @Test
    func removingAnEntryKeepsTheMailToAndTheOthers() async throws {
        let existing = try makeCrontab(
            foreign: ["# keep"],
            mailTo: "ops@example.com",
            prompts: ["One", "Two"]
        )
        let (terminal, client) = try makeTerminal(crontab: existing)

        _ = await run("/cron remove 1", in: terminal)

        let written = try #require(client.writes.first)
        let document = try ZenCrontabDocument.parse(written)
        #expect(document.foreignLines == ["# keep"])
        #expect(document.block?.mailTo == "ops@example.com")
        let items = try #require(document.block?.items)
        #expect(items.count == 1)
        guard case let .entry(entry) = items[0] else {
            Issue.record("expected a scheduled entry")
            return
        }
        #expect(entry.job?.prompt == "Two")
    }

    @Test
    func removingAnEntryThatDoesNotExistWritesNothing() async throws {
        let existing = try makeCrontab(prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        for number in ["9", "0", "-1"] {
            let output = await run("/cron remove \(number)", in: terminal)
            #expect(output == "ZenCODE: No scheduled prompt #\(number). Use /cron list.\n")
        }
        #expect(client.writes.isEmpty)
    }

    @Test(arguments: ["/cron remove", "/cron remove abc", "/cron remove 1 2"])
    func removeWithoutAValidNumberShowsTheUsage(command: String) async throws {
        let (terminal, client) = try makeTerminal(crontab: try makeCrontab(prompts: ["Only"]))

        let output = await run(command, in: terminal)

        #expect(output == TerminalChat.cronUsageMessage)
        #expect(client.writes.isEmpty)
        #expect(client.readCount == 0)
    }

    // MARK: - mailto

    @Test
    func mailToNoneWritesAnEmptyMailToAfterThePathLine() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        let output = await run("/cron mailto none", in: terminal)

        let written = try #require(client.writes.first)
        let lines = written.components(separatedBy: "\n")
        let begin = try #require(lines.firstIndex(of: ZenCrontabDocument.beginMarker))
        #expect(lines[begin + 1] == Self.defaultPathLine)
        #expect(lines[begin + 2] == "MAILTO=\"\"")
        #expect(try ZenCrontabDocument.parse(written).block?.mailTo == "")
        #expect(output == "MAILTO for scheduled prompts: \"\" (mail disabled)\n")
    }

    @Test
    func mailToKeepsACustomPathInPlace() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], path: "/opt/zen/bin:/usr/bin", prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        _ = await run("/cron mailto ops@example.com", in: terminal)

        let written = try #require(client.writes.first)
        let lines = written.components(separatedBy: "\n")
        let begin = try #require(lines.firstIndex(of: ZenCrontabDocument.beginMarker))
        #expect(lines[begin + 1] == "PATH=/opt/zen/bin:/usr/bin")
        #expect(lines[begin + 2] == "MAILTO=ops@example.com")
        #expect(try ZenCrontabDocument.parse(written).block?.items.count == 1)
    }

    @Test
    func mailToOnACrontabWithoutABlockCreatesItWithThePathLine() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        _ = await run("/cron mailto none", in: terminal)

        #expect(
            client.writes == [
                Self.userCrontab + "\n"
                    + "\(ZenCrontabDocument.beginMarker)\n\(Self.defaultPathLine)\nMAILTO=\"\"\n"
                    + "\(ZenCrontabDocument.endMarker)\n"
            ]
        )
    }

    @Test
    func mailToDefaultRemovesTheMailToLine() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], mailTo: "ops@example.com", prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        let output = await run("/cron mailto default", in: terminal)

        let written = try #require(client.writes.first)
        let block = try #require(ZenCrontabDocument.parse(written).block)
        #expect(block.mailTo == nil)
        #expect(block.items.count == 1)
        let blockText = try #require(written.components(separatedBy: ZenCrontabDocument.beginMarker).last)
        #expect(!blockText.contains("MAILTO="))
        #expect(output == "MAILTO for scheduled prompts: not set (cron default: local mailbox of the crontab owner)\n")
    }

    @Test
    func mailToAddressIsStoredAsGiven() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        let output = await run("/cron mailto ops@example.com", in: terminal)

        let written = try #require(client.writes.first)
        #expect(Array(written.utf8).starts(with: Array(Self.userCrontab.utf8)))
        #expect(written.contains("\nMAILTO=ops@example.com\n"))
        #expect(try ZenCrontabDocument.parse(written).block?.mailTo == "ops@example.com")
        #expect(output == "MAILTO for scheduled prompts: ops@example.com\n")
    }

    @Test
    func mailToDefaultWithoutABlockLeavesTheUserLinesUntouched() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        _ = await run("/cron mailto default", in: terminal)

        #expect(client.writes == [Self.userCrontab])
    }

    @Test(arguments: [
        "/cron mailto two words",
        "/cron mailto a\"b@example.com",
        "/cron mailto a\nb@example.com",
        "/cron mailto a\r\nb@example.com",
        "/cron mailto none extra"
    ])
    func invalidMailToAddressesAreRejectedBeforeAnyWrite(command: String) async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        let output = await run(command, in: terminal)

        #expect(output.hasPrefix("ZenCODE: Invalid MAILTO value"))
        #expect(client.writes.isEmpty)
        #expect(client.readCount == 0)
    }

    @Test
    func mailToWithoutAnArgumentReportsTheCurrentValueWithoutWriting() async throws {
        let (unsetTerminal, unsetClient) = try makeTerminal(crontab: Self.userCrontab)
        let unset = await run("/cron mailto", in: unsetTerminal)
        #expect(unset == "MAILTO: not set (cron default: local mailbox of the crontab owner)\n")
        #expect(unsetClient.writes.isEmpty)

        let (setTerminal, setClient) = try makeTerminal(
            crontab: try makeCrontab(mailTo: "ops@example.com", prompts: ["Only"])
        )
        let configured = await run("/cron mailto", in: setTerminal)
        #expect(configured == "MAILTO: ops@example.com\n")

        let (disabledTerminal, _) = try makeTerminal(crontab: try makeCrontab(mailTo: "", prompts: ["Only"]))
        let disabled = await run("/cron mailto", in: disabledTerminal)
        #expect(disabled == "MAILTO: \"\" (mail disabled)\n")
        #expect(setClient.writes.isEmpty)
    }

    // MARK: - list

    @Test
    func renderCronListShowsEveryKindOfItem() throws {
        let text = [
            ZenCrontabDocument.beginMarker,
            "PATH=/opt/zen/bin:/usr/bin",
            "MAILTO=ops@example.com",
            "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-01-02T03:04:05Z",
            "0 9 * * 1-5 '/usr/local/bin/zen' --agent 'Builder' --working-directory '/work/a b' --jsonl -p 'Check CI'",
            "# zencode-cron id=22222222-2222-2222-2222-222222222222 created=2026-01-02T03:04:05Z",
            "@daily /usr/bin/true",
            "not a cron line",
            ZenCrontabDocument.endMarker,
            ""
        ].joined(separator: "\n")

        // The `PATH=` header line is not an item: the table is the same with or without it.
        let rendered = TerminalChat.renderCronList(try ZenCrontabDocument.parse(text))

        #expect(
            rendered == """
            Scheduled prompts — MAILTO: ops@example.com
              1. 0 9 * * 1-5 · agent: Builder · dir: /work/a b · prompt: Check CI
              2. @daily · command: /usr/bin/true
              3. (unrecognized) not a cron line
            Results are mailed by cron; set the recipient with /cron mailto <address>.

            """
        )
    }

    @Test
    func renderCronListUsesTheDefaultAgentNameAndMailToDescriptions() throws {
        let empty = TerminalChat.renderCronList(ZenCrontabDocument())
        #expect(
            empty == """
            Scheduled prompts — MAILTO: not set (cron default: local mailbox of the crontab owner)
            No scheduled prompts. Use /cron add <schedule> <prompt>.
            Results are mailed by cron; set the recipient with /cron mailto <address>.

            """
        )

        let disabled = TerminalChat.renderCronList(
            try ZenCrontabDocument.parse(try makeCrontab(mailTo: "", prompts: ["Check CI"]))
        )
        #expect(disabled.hasPrefix("Scheduled prompts — MAILTO: \"\" (mail disabled)\n"))
        #expect(disabled.contains("  1. 0 9 * * * · agent: default · dir: /work/project · prompt: Check CI\n"))
    }

    @Test
    func listAndBareCronPrintTheSameTableWithoutWriting() async throws {
        let (terminal, client) = try makeTerminal(
            crontab: try makeCrontab(foreign: ["# keep"], prompts: ["Check CI"])
        )

        let bare = await run("/cron", in: terminal)
        let list = await run("/cron list", in: terminal)

        #expect(bare == list)
        #expect(bare.contains("prompt: Check CI"))
        #expect(client.readCount == 2)
        #expect(client.writes.isEmpty)
    }

    // MARK: - errors and unknown subcommands

    @Test(arguments: ["/cron bogus", "/cron list extra"])
    func unknownSubcommandsShowTheUsageWithoutTouchingTheCrontab(command: String) async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        let output = await run(command, in: terminal)

        #expect(output == TerminalChat.cronUsageMessage)
        #expect(client.writes.isEmpty)
        #expect(client.readCount == 0)
    }

    @Test
    func crontabFailuresAreReportedAndNothingIsWritten() async throws {
        let unavailable = FakeCrontabClient(text: "", readError: ZenCrontabError.crontabUnavailable)
        let (terminal, _) = try makeTerminal(client: unavailable)
        #expect(
            await run("/cron list", in: terminal)
                == "ZenCODE: crontab is not installed; see zen --doctor\n"
        )
        #expect(unavailable.writes.isEmpty)

        let malformed = FakeCrontabClient(text: "\(ZenCrontabDocument.beginMarker)\n0 1 * * * /bin/true\n")
        let (malformedTerminal, _) = try makeTerminal(client: malformed)
        let malformedOutput = await run("/cron add @daily Hello", in: malformedTerminal)
        #expect(malformedOutput.hasPrefix("ZenCODE: The ZenCODE block in your crontab is malformed"))
        #expect(malformed.writes.isEmpty)

        let rejected = FakeCrontabClient(
            text: "",
            writeError: ZenCrontabError.commandFailed(status: 1, detail: "not allowed")
        )
        let (rejectedTerminal, _) = try makeTerminal(client: rejected)
        #expect(
            await run("/cron add @daily Hello", in: rejectedTerminal)
                == "ZenCODE: crontab failed with exit status 1: not allowed\n"
        )
    }

    // MARK: - run

    @Test
    func runStartsOneDeferredRunAndRejectsASecondWhileItIsInFlight() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], prompts: ["Check CI", "Other"])
        let (terminal, client) = try makeTerminal(crontab: existing)
        let runner = FakeCronJobRunner()
        terminal.cronJobRunner = runner
        let items = try #require(ZenCrontabDocument.parse(existing).block?.items)
        guard case let .entry(entry) = items[0] else {
            Issue.record("expected a scheduled entry")
            return
        }

        let started = await run("/cron run 1", in: terminal)
        #expect(started == "Running scheduled prompt #1 as cron would…\n")
        let active = try #require(terminal.activeCronRun)
        #expect(active.number == 1)

        await runner.waitUntilInvoked()
        #expect(
            runner.calls == [
                FakeCronJobRunner.Call(
                    cronCommand: entry.cronCommand,
                    environment: ZenCronEnvironment.minimal(path: ZenCrontabDocument.defaultPath),
                    homeDirectory: UserHomeDirectory.current()
                )
            ]
        )
        #expect(runner.calls.first?.environment["PATH"] == "/usr/local/bin:/usr/bin:/bin")

        // Another entry, or the same one: refused while #1 is running.
        for command in ["/cron run 1", "/cron run 2"] {
            let refused = await run(command, in: terminal)
            #expect(refused == "ZenCODE: A /cron run is already in progress (#1). Wait for its report.\n")
            #expect(terminal.activeCronRun?.number == 1)
            #expect(terminal.activeCronRun?.task == active.task)
        }
        #expect(runner.calls.count == 1)
        #expect(client.writes.isEmpty)

        // The deferred report reaches the terminal only, never the immediate
        // output of whatever Telegram command is in progress when it lands.
        terminal.telegramImmediateCommandOutput = []
        defer { terminal.telegramImmediateCommandOutput = nil }
        runner.release()
        await terminal.activeCronRun?.task.value

        #expect(terminal.activeCronRun == nil)
        #expect(terminal.telegramImmediateCommandOutput == [])
        #expect(runner.calls.count == 1)
    }

    @Test
    func runGivesTheJobTheDefaultBlockPathInCronsMinimalEnvironment() async throws {
        let (terminal, _) = try makeTerminal(crontab: try makeCrontab(prompts: ["Check CI"]))
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        _ = await run("/cron run 1", in: terminal)
        await terminal.activeCronRun?.task.value

        let environment = try #require(runner.calls.first?.environment)
        #expect(environment["PATH"] == ZenCrontabDocument.defaultPath)
        #expect(environment["SHELL"] == "/bin/sh")
        #expect(environment == ZenCronEnvironment.minimal(path: ZenCrontabDocument.defaultPath))
        #expect(Set(environment.keys).isSubset(of: ["HOME", "SHELL", "PATH", "LOGNAME", "USER"]))
    }

    @Test
    func runGivesTheJobTheBlocksCustomPath() async throws {
        let existing = try makeCrontab(foreign: ["# keep"], path: "/opt/zen/bin:/usr/bin", prompts: ["Check CI"])
        let (terminal, _) = try makeTerminal(crontab: existing)
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        _ = await run("/cron run 1", in: terminal)
        await terminal.activeCronRun?.task.value

        let environment = try #require(runner.calls.first?.environment)
        #expect(environment["PATH"] == "/opt/zen/bin:/usr/bin")
        #expect(environment == ZenCronEnvironment.minimal(path: "/opt/zen/bin:/usr/bin"))
    }

    @Test
    func runGivesTheJobTheCustomPathWithoutItsOuterDoubleQuotes() async throws {
        let text = [
            ZenCrontabDocument.beginMarker,
            "PATH=\"/opt/zen/bin:/usr/bin\"",
            "# zencode-cron id=11111111-1111-1111-1111-111111111111 created=2026-01-02T03:04:05Z",
            "@daily zen --working-directory '/work' --jsonl -p 'Check CI'",
            ZenCrontabDocument.endMarker,
            ""
        ].joined(separator: "\n")
        let (terminal, _) = try makeTerminal(crontab: text)
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        _ = await run("/cron run 1", in: terminal)
        await terminal.activeCronRun?.task.value

        #expect(runner.calls.first?.environment["PATH"] == "/opt/zen/bin:/usr/bin")
        #expect(runner.calls.first?.cronCommand == "zen --working-directory '/work' --jsonl -p 'Check CI'")
    }

    @Test
    func runCanStartAgainOnceThePreviousReportIsWritten() async throws {
        let (terminal, _) = try makeTerminal(crontab: try makeCrontab(prompts: ["Check CI"]))
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        for _ in 0..<2 {
            #expect(await run("/cron run 1", in: terminal) == "Running scheduled prompt #1 as cron would…\n")
            await terminal.activeCronRun?.task.value
            #expect(terminal.activeCronRun == nil)
        }
        #expect(runner.calls.count == 2)
    }

    @Test
    func runRefusesAnUnrecognizedItemWithoutInvokingTheRunner() async throws {
        let text = [
            ZenCrontabDocument.beginMarker,
            "not a cron line",
            ZenCrontabDocument.endMarker,
            ""
        ].joined(separator: "\n")
        let (terminal, client) = try makeTerminal(crontab: text)
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        let output = await run("/cron run 1", in: terminal)

        #expect(output == "ZenCODE: Scheduled prompt #1 is not a recognized ZenCODE entry.\n")
        #expect(terminal.activeCronRun == nil)
        #expect(runner.calls.isEmpty)
        #expect(client.writes.isEmpty)
    }

    @Test
    func runOfAMissingEntryReportsItWithoutInvokingTheRunner() async throws {
        let (terminal, client) = try makeTerminal(crontab: try makeCrontab(prompts: ["Only"]))
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        for number in ["2", "0", "-1"] {
            let output = await run("/cron run \(number)", in: terminal)
            #expect(output == "ZenCODE: No scheduled prompt #\(number). Use /cron list.\n")
        }
        #expect(terminal.activeCronRun == nil)
        #expect(runner.calls.isEmpty)
        #expect(client.writes.isEmpty)
    }

    @Test(arguments: ["/cron run", "/cron run abc", "/cron run 1 2"])
    func runWithoutAValidNumberShowsTheUsage(command: String) async throws {
        let (terminal, client) = try makeTerminal(crontab: try makeCrontab(prompts: ["Only"]))
        let runner = FakeCronJobRunner(isReleased: true)
        terminal.cronJobRunner = runner

        let output = await run(command, in: terminal)

        #expect(output == TerminalChat.cronUsageMessage)
        #expect(client.readCount == 0)
        #expect(runner.calls.isEmpty)
        #expect(terminal.activeCronRun == nil)
    }

    @Test
    func renderCronRunReportShowsTheCompletedMessage() {
        let report = TerminalChat.renderCronRunReport(
            number: 3,
            outcome: ZenCronRunOutcome(
                exitStatus: 0,
                stdout: [
                    #"{"type":"run.started","schema":1}"#,
                    #"{"type":"message.completed","text":"Two PRs are open.\nBoth pass CI."}"#,
                    #"{"type":"run.completed"}"#,
                    ""
                ].joined(separator: "\n"),
                stderr: "",
                duration: .milliseconds(12_340),
                wasTerminated: false
            )
        )

        #expect(
            report == """
            Scheduled prompt #3 finished in 12.3s with exit status 0.
            Result:
            Two PRs are open.
            Both pass CI.

            """
        )
    }

    @Test
    func renderCronRunReportShowsTheErrorRecordAndTheStderrTail() {
        let stderr = (1...25).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let report = TerminalChat.renderCronRunReport(
            number: 1,
            outcome: ZenCronRunOutcome(
                exitStatus: 1,
                stdout: #"{"type":"error","category":"provider","message":"Model unavailable"}"# + "\n",
                stderr: stderr,
                duration: .milliseconds(450),
                wasTerminated: false
            )
        )

        let expectedTail = (6...25).map { "line \($0)" }.joined(separator: "\n")
        #expect(
            report == """
            Scheduled prompt #1 finished in 0.5s with exit status 1.
            Error (provider): Model unavailable
            stderr (last 20 lines):
            \(expectedTail)

            """
        )
    }

    @Test
    func renderCronRunReportWithoutJSONLSaysSoAndQuotesAShortStderr() {
        let report = TerminalChat.renderCronRunReport(
            number: 2,
            outcome: ZenCronRunOutcome(
                exitStatus: 127,
                stdout: "",
                stderr: "sh: /opt/zen/bin/zen: not found\n",
                duration: .zero,
                wasTerminated: false
            )
        )

        #expect(
            report == """
            Scheduled prompt #2 finished in 0.0s with exit status 127.
            No JSONL result on stdout.
            stderr (last 20 lines):
            sh: /opt/zen/bin/zen: not found

            """
        )
    }

    @Test
    func renderCronRunReportOfATerminatedRunOmitsAWhitespaceOnlyStderr() {
        let report = TerminalChat.renderCronRunReport(
            number: 4,
            outcome: ZenCronRunOutcome(
                exitStatus: 143,
                stdout: "not json\n",
                stderr: " \n\t\n",
                duration: .seconds(3),
                wasTerminated: true
            )
        )

        #expect(
            report == """
            Scheduled prompt #4 was terminated.
            No JSONL result on stdout.

            """
        )
    }

    @Test(arguments: [
        (Duration.zero, "0.0s"),
        (.milliseconds(49), "0.0s"),
        (.milliseconds(50), "0.1s"),
        (.milliseconds(12_349), "12.3s"),
        (.milliseconds(12_350), "12.4s"),
        (.milliseconds(59_960), "60.0s"),
        (.seconds(3_725), "3725.0s"),
        (.milliseconds(-1_500), "0.0s")
    ])
    func cronRunDurationIsShownInSecondsWithOneDecimal(duration: Duration, expected: String) {
        #expect(TerminalChat.cronRunDurationDescription(duration) == expected)
    }

    // MARK: - Command surface

    @Test
    func cronIsAKnownCommandWithHelpAndSuggestions() async throws {
        #expect(TerminalChat.isKnownSlashCommand("/cron"))
        #expect(TerminalChat.isKnownSlashCommand("/cron add @daily Hello"))
        #expect(TerminalChat.submittedLineRole(for: "/cron list") == .slashCommand(token: "/cron"))

        let descriptors = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        )
        let cron = try #require(descriptors.first { $0.command == "/cron" })
        #expect(cron.summary == "schedule prompts with crontab: list, add, remove, run, mailto")
        #expect(!cron.requiresArgument)
        for usage in [
            "/cron [list]",
            "/cron add <schedule> <prompt>",
            "/cron remove <n>",
            "/cron run <n>",
            "/cron mailto [address|none|default]"
        ] {
            #expect(cron.help.contains(usage))
        }

        let (terminal, _) = try makeTerminal(crontab: "")
        #expect(terminal.renderHelpTextForCurrentAgent().contains(cron.help))
        let suggestions = terminal.commandSuggestionsForCurrentAgent()
        #expect(suggestions.contains { $0.command == "/cron" && !$0.requiresArgument })
        #expect(
            TerminalPromptCompletion.matches(
                buffer: Array("/cro"),
                cursorIndex: 4,
                commands: suggestions
            ).map(\.command) == ["/cron"]
        )
    }

    @Test
    func cronCompletionListsEverySubcommand() async throws {
        let arguments = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/cron")
        #expect(arguments.map(\.command) == ["list", "add", "remove", "run", "mailto"])
        #expect(arguments.map(\.requiresArgument) == [false, true, true, true, false])

        let (terminal, _) = try makeTerminal(crontab: "")
        let matches = TerminalPromptCompletion.matches(
            buffer: Array("/cron m"),
            cursorIndex: 7,
            commands: terminal.commandSuggestionsForCurrentAgent()
        )
        #expect(matches.map(\.command) == ["mailto"])
    }

    // MARK: - Completion explains the parameters

    @Test
    func cronSubcommandRowsExplainTheirParameters() {
        let arguments = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/cron")
        #expect(
            arguments.map(\.summary) == [
                "show scheduled prompts with their numbers",
                "<schedule> <prompt> · e.g. @daily Summarize open PRs",
                "<n> · delete entry n from /cron list",
                "<n> · run entry n now, as cron would",
                "[address|none|default] · where cron mails results"
            ]
        )
        #expect(arguments.allSatisfy { !$0.isHint })
    }

    @Test(arguments: [
        ("/cron add ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *"
        ]),
        ("/cron ADD ", [
            "@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot",
            "0 9 * * 1-5", "*/15 * * * *", "30 18 * * *"
        ]),
        ("/cron add @", ["@hourly", "@daily", "@weekly", "@monthly", "@yearly", "@reboot"]),
        ("/cron add @d", ["@daily"]),
        ("/cron add @D", ["@daily"]),
        ("/cron ADD @d", ["@daily"]),
        ("/cron add @daily", ["@daily"]),
        ("/cron add @m", ["@monthly", "@midnight"]),
        ("/cron add @mid", ["@midnight"]),
        ("/cron add @a", ["@annually"]),
        ("/cron add @nope", []),
        ("/cron add 0", ["<minute>"]),
        ("/cron add */15", ["<minute>"]),
        ("/cron add 0 ", ["<hour>"]),
        ("/cron add 0 9", ["<hour>"]),
        ("/cron add 0 9 ", ["<day-of-month>"]),
        ("/cron add 0 9 * ", ["<month>"]),
        ("/cron add 0 9 * * ", ["<day-of-week>"]),
        ("/cron add 0 9 * * 1", ["<day-of-week>"]),
        ("/cron add 0 9 * * 1-5 ", ["<prompt>"]),
        ("/cron add 0 9 * * 1-5 Summ", ["<prompt>"]),
        ("/cron add 0 9 * * 1-5 Summarize open PRs", ["<prompt>"]),
        ("/cron add @daily ", ["<prompt>"]),
        ("/cron add @daily Summarize open PRs", ["<prompt>"]),
        ("/cron ADD @daily Summarize open PRs", ["<prompt>"]),
        ("/cron remove ", ["<n>"]),
        ("/cron remove 2", ["<n>"]),
        ("/cron REMOVE ", ["<n>"]),
        ("/cron remove 2 ", []),
        ("/cron run ", ["<n>"]),
        ("/cron run 2 ", []),
        ("/cron mailto ", ["<address>", "none", "default"]),
        ("/cron MAILTO ", ["<address>", "none", "default"]),
        ("/cron mailto n", ["none"]),
        ("/cron mailto none", ["none"]),
        ("/cron mailto D", ["default"]),
        ("/cron mailto ops@", ["<address>"]),
        ("/cron mailto none ", []),
        ("/cron list ", []),
        ("/cron list x", []),
        ("/cron bogus ", []),
        ("/cron bogus x", [])
    ])
    func cronCompletionFollowsTheSlotUnderTheCursor(text: String, expected: [String]) {
        #expect(cronCompletions(text).map(\.command) == expected, "typed: \(text)")
    }

    @Test
    func cronScheduleSlotListsAliasesThenFiveFieldExamplesThatKeepASeparator() {
        let rows = cronCompletions("/cron add ")

        #expect(
            rows.map(\.summary) == [
                "every hour, at minute 0",
                "every day at midnight",
                "every Sunday at midnight",
                "on the 1st of each month at midnight",
                "every 1 January at midnight",
                "when the system starts",
                "weekdays at 09:00",
                "every 15 minutes",
                "every day at 18:30"
            ]
        )
        // Accepting one leaves a space for the prompt instead of sending.
        #expect(rows.allSatisfy { $0.requiresArgument && !$0.isHint })
    }

    @Test
    func aHandWrittenScheduleNeverGetsExamplesThatWouldHijackIt() {
        for text in ["/cron add 0", "/cron add */", "/cron add 3", "/cron add *"] {
            let rows = cronCompletions(text)
            #expect(rows.count == 1, "typed: \(text)")
            #expect(rows.first?.command == "<minute>", "typed: \(text)")
            #expect(rows.first?.isHint == true, "typed: \(text)")
        }
    }

    @Test(arguments: [
        ("/cron add 0", "<minute>", "0-59, */n, a-b or a,b"),
        ("/cron add 0 ", "<hour>", "0-23"),
        ("/cron add 0 9 ", "<day-of-month>", "1-31"),
        ("/cron add 0 9 * ", "<month>", "1-12"),
        ("/cron add 0 9 * * ", "<day-of-week>", "0-7 (0 and 7 = Sunday)"),
        ("/cron add 0 9 * * 1-5 ", "<prompt>", "text the agent runs headless, on one line"),
        ("/cron add @daily ", "<prompt>", "text the agent runs headless, on one line"),
        ("/cron remove ", "<n>", "entry number shown by /cron list"),
        ("/cron run ", "<n>", "entry number shown by /cron list"),
        ("/cron mailto ", "<address>", "e-mail address cron mails results to")
    ])
    func guideRowsNameTheSlotAndAreNeverInserted(text: String, command: String, summary: String) throws {
        let row = try #require(cronCompletions(text).first)

        #expect(row.command == command)
        #expect(row.summary == summary)
        #expect(row.isHint)
        #expect(!row.requiresArgument)
    }

    @Test
    func mailToOffersTheGuideFirstSoTheInitialSelectionCannotDisableMail() {
        let rows = cronCompletions("/cron mailto ")

        #expect(rows.map(\.command) == ["<address>", "none", "default"])
        #expect(rows.map(\.isHint) == [true, false, false])
        #expect(rows.map(\.requiresArgument) == [false, false, false])
        #expect(rows[1].summary == "disable mail for scheduled prompts")
        #expect(rows[2].summary == "cron default: local mailbox of the crontab owner")
    }

    @Test
    func completionOnAFieldFollowsTheCursorNotTheEndOfTheLine() {
        let line = "/cron add 0 9 * * 1-5 Summarize"

        // After the `0`: still the first field.
        #expect(cronCompletions(line, cursorIndex: 11).map(\.command) == ["<minute>"])
        // Right before the `9`: the second field, empty prefix.
        #expect(cronCompletions(line, cursorIndex: 12).map(\.command) == ["<hour>"])
        // Inside the prompt.
        #expect(cronCompletions(line, cursorIndex: 27).map(\.command) == ["<prompt>"])

        let completion = TerminalPromptCompletion.completion(
            buffer: Array(line),
            cursorIndex: 13
        )
        #expect(
            completion?.kind == .laterArgument(command: "/cron", precedingArguments: ["add", "0"])
        )
        #expect(completion?.prefix == "9")
        #expect(completion?.replacementRange == 12..<13)
    }

    @Test
    func everyAliasAndExampleOfTheScheduleSlotIsAcceptedByTheScheduleParser() throws {
        var schedules = TerminalPromptCompletionCatalog.cronScheduleExamples.map(\.command)
        schedules += cronCompletions("/cron add ").map(\.command)
        // The synonyms only show once a letter is typed.
        schedules += cronCompletions("/cron add @a").map(\.command)
        schedules += cronCompletions("/cron add @mid").map(\.command)

        #expect(schedules.count >= 14)
        for schedule in schedules {
            _ = try ZenCronSchedule(parsing: schedule)
        }
    }

    @Test
    func cronCompletionTextsStayShort() {
        var rows = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/cron")
        for text in [
            "/cron add ", "/cron add @", "/cron add @m", "/cron add @a", "/cron add 0",
            "/cron add 0 ", "/cron add 0 9 ", "/cron add 0 9 * ", "/cron add 0 9 * * ",
            "/cron add @daily ", "/cron remove ", "/cron run ", "/cron mailto "
        ] {
            rows += cronCompletions(text)
        }

        for row in rows {
            #expect(row.summary.count <= 70, "\(row.command): \(row.summary)")
        }
    }

    @Test
    func laterSlotsOfEveryOtherCommandOfferNothing() throws {
        for (command, arguments) in TerminalPromptCompletionCatalog.argumentsByCommand where command != "/cron" {
            let subcommand = try #require(arguments.first?.command)
            #expect(!TerminalPromptCompletionCatalog.completesLaterArguments(of: command))
            #expect(
                TerminalPromptCompletionCatalog.laterArgumentSuggestions(
                    for: command,
                    precedingArguments: [subcommand],
                    prefix: ""
                ).isEmpty,
                "\(command) \(subcommand)"
            )
            let line = "\(command) \(subcommand) x"
            #expect(
                TerminalPromptCompletion.matches(
                    buffer: Array(line),
                    cursorIndex: Array(line).count,
                    commands: [TerminalCommandSuggestion(command: command, summary: "")]
                ).isEmpty,
                "\(line)"
            )
        }
        #expect(TerminalPromptCompletionCatalog.completesLaterArguments(of: "/cron"))
    }

    @Test
    func cronOperandsAreOfferedOnlyWhenTheCommandIsAvailableToTheAgent() throws {
        let (terminal, _) = try makeTerminal(crontab: "")
        let available = terminal.commandSuggestionsForCurrentAgent()
        #expect(available.contains { $0.command == "/cron" })
        #expect(
            TerminalPromptCompletion.matches(
                buffer: Array("/cron mailto "),
                cursorIndex: 13,
                commands: available
            ).map(\.command) == ["<address>", "none", "default"]
        )

        let withoutCron = available.filter { $0.command != "/cron" }
        for text in ["/cron ma", "/cron mailto ", "/cron add @d", "/cron add 0 9 "] {
            #expect(
                TerminalPromptCompletion.matches(
                    buffer: Array(text),
                    cursorIndex: Array(text).count,
                    commands: withoutCron
                ).isEmpty,
                "\(text)"
            )
        }
    }

    @Test
    func completingNeverReadsTheCrontab() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)
        let commands = terminal.commandSuggestionsForCurrentAgent()

        for text in ["/cron ", "/cron add ", "/cron add 0 9 ", "/cron remove ", "/cron mailto "] {
            _ = TerminalPromptCompletion.matches(
                buffer: Array(text),
                cursorIndex: Array(text).count,
                commands: commands
            )
        }

        #expect(client.readCount == 0)
        #expect(client.writes.isEmpty)
    }

    @Test
    func mailToLineSentFromTheGuideShowsTheCurrentValue() async throws {
        let existing = try makeCrontab(mailTo: "ops@example.com", prompts: ["Only"])
        let (terminal, client) = try makeTerminal(crontab: existing)

        // Enter on the guide sends the line as typed, trailing space included.
        let output = await run("/cron mailto ", in: terminal)

        #expect(output == "MAILTO: ops@example.com\n")
        #expect(client.writes.isEmpty)
    }

    @Test
    func slashCronReachesTheHandlerThroughTheDispatcher() async throws {
        let (terminal, client) = try makeTerminal(crontab: Self.userCrontab)

        let action = await terminal.submittedLineAction("/cron list")

        guard case .continueChat = action else {
            Issue.record("expected /cron to continue the chat")
            return
        }
        #expect(client.readCount == 1)
        #expect(client.writes.isEmpty)
    }

    // MARK: - Helpers

    /// Menu rows for `text` with `/cron` available, the cursor at `cursorIndex`
    /// (the end of the line by default). Pure: no terminal, no crontab.
    private func cronCompletions(
        _ text: String,
        cursorIndex: Int? = nil
    ) -> [TerminalCommandSuggestion] {
        let buffer = Array(text)
        return TerminalPromptCompletion.matches(
            buffer: buffer,
            cursorIndex: cursorIndex ?? buffer.count,
            commands: [TerminalCommandSuggestion(command: "/cron", summary: "schedule prompts")]
        )
    }

    private func makeTerminal(
        crontab: String,
        zen: FakeZenLocator = FakeZenLocator()
    ) throws -> (TerminalChat, FakeCrontabClient) {
        try makeTerminal(client: FakeCrontabClient(text: crontab), zen: zen)
    }

    private func makeTerminal(
        client: FakeCrontabClient,
        zen: FakeZenLocator = FakeZenLocator()
    ) throws -> (TerminalChat, FakeCrontabClient) {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-cron-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
        terminal.crontabClient = client
        // Never the system runner, even in tests that do not expect a run.
        terminal.cronJobRunner = FakeCronJobRunner(isReleased: true)
        // Never the machine's PATH search: `/cron add` must not depend on a `zen` being installed.
        terminal.cronZenLocator = { zen.locate(onPath: $0) }
        terminal.selectedAgent = nil
        return (terminal, client)
    }

    /// Runs `/cron …` and returns what it wrote, captured the same way the
    /// Telegram bridge captures immediate command output.
    private func run(_ command: String, in terminal: TerminalChat) async -> String {
        terminal.telegramImmediateCommandOutput = []
        await terminal.handleCronCommand(command)
        defer { terminal.telegramImmediateCommandOutput = nil }
        return terminal.telegramImmediateCommandOutput?.joined() ?? ""
    }

    /// Crontab text with `foreign` user lines followed by a ZenCODE block.
    private func makeCrontab(
        foreign: [String] = [],
        mailTo: String? = nil,
        path: String? = nil,
        prompts: [String] = []
    ) throws -> String {
        var document = ZenCrontabDocument(foreignLines: foreign)
        let schedule = try ZenCronSchedule(parsing: "0 9 * * *")
        for prompt in prompts {
            document.appendEntry(
                schedule: schedule,
                job: ZenCronJobCommand(
                    executable: "zen",
                    supportDirectory: nil,
                    agentName: nil,
                    workingDirectory: "/work/project",
                    prompt: prompt
                )
            )
        }
        if let mailTo {
            document.setMailTo(mailTo)
        }
        if let path {
            var block = document.block ?? ZenCrontabDocument.Block()
            block.path = path
            document.block = block
        }
        return document.render()
    }
}
