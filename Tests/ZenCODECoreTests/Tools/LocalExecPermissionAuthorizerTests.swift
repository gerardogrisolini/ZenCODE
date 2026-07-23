//
//  LocalExecPermissionAuthorizerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 05/06/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct LocalExecPermissionAuthorizerTests {
    @Test
    func commandPermissionIdentityExtractsExecutable() {
        // Plain executables.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "swift test --filter ZenCODECoreTests") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "git status --short --branch") == "git")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "python3 --version") == "python3")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "xcodebuild -list") == "xcodebuild")
        // Redirections are skipped, leaving the real executable.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "ls -la > out.txt") == "ls")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "2>&1 swift build") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: ">out.txt echo hi") == "echo")
        // Harmless built-ins are skipped so the real command surfaces.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "pwd && rm -rf tmp") == "rm")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "true && rm -rf tmp") == "rm")
        // Environment assignments and wrappers are unwrapped.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "FOO=bar swift build") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "env CI=1 swift test") == "swift")
        // Grouping delimiters are stripped.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "(cd /tmp && make)") == "make")
        // Leading/trailing whitespace and redirections are handled.
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo")
    }

    @Test
    func commandPermissionIdentitiesRetainEveryExecutableInOneRequest() {
        #expect(
            LocalExecPermissionAuthorizer.commandPermissionIdentities(
                for: "swift build 2>&1 | tail -n 20 || true"
            ) == ["swift", "tail"]
        )
        #expect(
            LocalExecPermissionAuthorizer.commandPermissionIdentities(
                for: "cat \"$(rm -rf /tmp/x)\""
            ) == ["cat", "rm"]
        )
    }

    @Test
    func tooManyCommandsFallbackIsExactAndNeverPersisted() {
        let prefix = (0..<64).map { "tool\($0)" }
        let firstCommand = (prefix + ["tailA"]).joined(separator: "; ")
        let secondCommand = (prefix + ["taila"]).joined(separator: "; ")

        let identities = LocalExecPermissionAuthorizer
            .persistedCommandPermissionIdentities(for: firstCommand)
        #expect(identities.last == LocalExecCommandParser.tooManyCommandsIdentity)

        let permissions = AgentPermissionsManifest()
            .appendingLocalExecAllowedCommandIdentities(identities)
        #expect(
            !permissions.containsLocalExecAllowedCommand(
                LocalExecCommandParser.tooManyCommandsIdentity
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                firstCommand,
                permissions: permissions
            )
        )

        let firstCacheIdentities = LocalExecPermissionAuthorizer
            .localExecPermissionCacheIdentities(for: firstCommand)
        let secondCacheIdentities = LocalExecPermissionAuthorizer
            .localExecPermissionCacheIdentities(for: secondCommand)
        #expect(firstCacheIdentities.last != secondCacheIdentities.last)
        let firstFallbackKey = LocalExecPermissionAuthorizer.permissionCacheKey(
            toolName: "local.exec",
            identity: firstCacheIdentities.last ?? ""
        )
        let secondFallbackKey = LocalExecPermissionAuthorizer.permissionCacheKey(
            toolName: "local.exec",
            identity: secondCacheIdentities.last ?? ""
        )
        #expect(firstFallbackKey != secondFallbackKey)
    }

    @Test
    func analysisDepthFallbackIsExactAndNeverPersisted() {
        func deeplyNested(_ leaf: String) -> String {
            var command = leaf
            for _ in 0..<12 {
                command = "cat \"$(\(command))\""
            }
            return command
        }

        let firstCommand = deeplyNested("touch /tmp/Marker")
        let secondCommand = deeplyNested("touch /tmp/marker")
        let identities = LocalExecPermissionAuthorizer
            .persistedCommandPermissionIdentities(for: firstCommand)
        #expect(identities.contains(LocalExecCommandParser.analysisDepthLimitIdentity))

        let permissions = AgentPermissionsManifest()
            .appendingLocalExecAllowedCommandIdentities(identities)
        #expect(
            !permissions.containsLocalExecAllowedCommand(
                LocalExecCommandParser.analysisDepthLimitIdentity
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                firstCommand,
                permissions: permissions
            )
        )

        let firstCacheIdentity = LocalExecPermissionAuthorizer
            .localExecPermissionCacheIdentities(for: firstCommand)
            .first { $0.hasPrefix(LocalExecCommandParser.analysisDepthLimitIdentity) } ?? ""
        let secondCacheIdentity = LocalExecPermissionAuthorizer
            .localExecPermissionCacheIdentities(for: secondCommand)
            .first { $0.hasPrefix(LocalExecCommandParser.analysisDepthLimitIdentity) } ?? ""
        #expect(
            LocalExecPermissionAuthorizer.permissionCacheKey(
                toolName: "local.exec",
                identity: firstCacheIdentity
            ) != LocalExecPermissionAuthorizer.permissionCacheKey(
                toolName: "local.exec",
                identity: secondCacheIdentity
            )
        )
    }

    @Test
    func persistedCommandPermissionIdentityExtractsExecutable() {
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "swift test --filter ZenCODECoreTests") == "swift")
        // `pwd` is a harmless builtin, so the first authorizable executable is
        // `git`. Decorative `echo` is filtered.
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "pwd && git status") == "git")
        // `echo` with redirection is NOT decorative and remains prompt-worthy.
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo")
    }

    @Test
    func allSkipCommandYieldsNilIdentity() {
        // M5: a command consisting entirely of harmless built-ins yields no
        // identity, consistent with `localExecAuthorizationCommands` returning [].
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "true") == nil)
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "false") == nil)
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "cd /tmp") == nil)
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "true") == nil)
    }

    @Test
    func persistedPermissionMatchesRegardlessOfCase() {
        // F10: the persisted manifest matches case-insensitively; verify the
        // identity extraction and manifest membership agree across cases.
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: ["Swift"]
        )
        #expect(permissions.containsLocalExecAllowedCommand("swift"))
        #expect(permissions.containsLocalExecAllowedCommand("SWIFT"))
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift build",
                permissions: permissions
            )
        )
    }

    @Test
    func persistedAllowedCommandsMatchExecutablesRegardlessOfArguments() {
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift test --filter OldFilter",
                "pwd && git status"
            ]
        )

        // `swift test --filter OldFilter` normalizes to the `swift` identity.
        // `pwd && git status` skips the harmless `pwd` and normalizes to `git`.
        #expect(permissions.localExecAllowedCommands == ["swift", "git"])
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift test --filter ZenCODECoreTests",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "pwd && git status",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "  pwd && git log  ",
                permissions: permissions
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "rm -rf /tmp",
                permissions: permissions
            )
        )

        let pipelinePermissions = AgentPermissionsManifest(
            localExecAllowedCommands: ["swift", "tail"]
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift build | tail -n 20",
                permissions: pipelinePermissions
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift build | tail -n 20",
                permissions: AgentPermissionsManifest(localExecAllowedCommands: ["swift"])
            )
        )
    }

    @Test
    func terminalWorkspaceConsentAcceptsOnlyAffirmativeAnswers() {
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess(""))
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("y"))
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("YES"))
        #expect(TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("  yes  \r"))
        #expect(!TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("n"))
        #expect(!TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("no"))
        #expect(!TerminalWorkspaceToolAccessStore.terminalConsentAllowsAccess("maybe"))
    }

    @Test
    func terminalPermissionDecisionMapsSingleKeyAnswers() {
        // Empty (Enter) defaults to run-once, matching the prior macOS dialog.
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "") == .allowOnce)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "r") == .allowOnce)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "R") == .allowOnce)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "a") == .allowAlways)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "A") == .allowAlways)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "c") == .deny)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "C") == .deny)
        // Unrecognized keys yield no decision so the prompt re-asks.
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "x") == nil)
        // Whitespace is not a valid choice: only a genuine Enter (empty input)
        // defaults to run-once, so spaces/tabs re-prompt rather than authorize.
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: " ") == nil)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "\t") == nil)
        // Multi-character/word answers are unrecognized and re-prompt.
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "run") == nil)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "yes") == nil)
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: "no") == nil)
        // A valid key with surrounding whitespace still maps correctly.
        #expect(LocalExecPermissionAuthorizer.permissionDecision(forTerminalAnswer: " R\r\n") == .allowOnce)
    }

    @Test
    func terminalPromptIncludesCommandAndDirectory() {
        let request = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: "local.exec",
            title: "Run swift tests",
            kind: "shell",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )
        let prompt = LocalExecPermissionAuthorizer.terminalPrompt(for: request)
        #expect(!prompt.contains(request.title))
        #expect(prompt.contains("/tmp/project"))
        #expect(prompt.contains("swift test --filter One"))
        #expect(prompt.contains("[R]un once / [A]lways / [C]ancel"))
        #expect(prompt.hasSuffix("╯\n"))
    }

    @Test
    func terminalPromptIncludesAlwaysScopeHint() {
        // local.exec: the executable identity is authorized across sessions.
        let shellRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: "local.exec",
            title: "Run swift tests",
            kind: "shell",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )
        let shellPrompt = LocalExecPermissionAuthorizer.terminalPrompt(for: shellRequest)
        #expect(shellPrompt.contains("across sessions"))

        // Destructive tool: "Always" applies to this session only.
        let deleteRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: "local.delete",
            title: "Delete file",
            kind: "destructive",
            command: "rm -rf /tmp/scratch",
            workingDirectory: "/tmp/project"
        )
        let deletePrompt = LocalExecPermissionAuthorizer.terminalPrompt(for: deleteRequest)
        #expect(deletePrompt.contains("session only"))
    }

    @Test
    func terminalPromptReflowsLongCommandsWithinTerminalWidth() {
        let columns = 48
        let request = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: "local.exec",
            title: "Run a command whose arguments exceed the card width",
            kind: "shell",
            command: "printf '%s' "
                + String(repeating: "very-long-argument ", count: 12)
                + "tail-token",
            workingDirectory: "/tmp/project"
        )

        let prompt = LocalExecPermissionAuthorizer.terminalPrompt(
            for: request,
            terminalColumns: columns
        )
        let renderedRows = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleRows = renderedRows.map(TerminalANSIText.stripANSI)
        let boxRows = visibleRows.filter {
            $0.hasPrefix("╭")
                || $0.hasPrefix("│")
                || $0.hasPrefix("├")
                || $0.hasPrefix("╰")
        }
        let bodyRows = boxRows.filter { $0.hasPrefix("│") }

        // Never use the rightmost terminal cell: terminals can autowrap a row
        // that exactly fills it, which would damage the box and panel layout.
        #expect(renderedRows.allSatisfy {
            TerminalANSIText.visibleWidth($0) <= columns - 1
        })
        #expect(boxRows.first?.hasPrefix("╭") == true)
        #expect(boxRows.last?.hasPrefix("╰") == true)
        #expect(bodyRows.count > 5)
        #expect(bodyRows.allSatisfy { $0.hasSuffix("│") })
        #expect(prompt.contains("tail-token"))
    }

    @Test
    func nonInteractiveConsentMessageIsActionable() {
        let request = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: "local.exec",
            title: "Run swift tests",
            kind: "shell",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )
        let message = LocalExecPermissionAuthorizer.nonInteractiveConsentMessage(for: request)
        // Explains why and stays fail-closed.
        #expect(message.contains("no interactive terminal"))
        #expect(message.contains("blocked by design"))
        // Names the command so the operator knows what was blocked.
        #expect(message.contains("swift test --filter One"))
        // Offers a concrete remediation.
        #expect(message.contains("[A]lways"))
    }

    @Test
    func sanitizedForTerminalStripsControlSequences() {
        // A crafted command carrying ESC/CSI, carriage return, and bell must not
        // be able to clear, overwrite, or beep-spoof the consent prompt.
        let cleaned = LocalExecPermissionAuthorizer.sanitizedForTerminal(
            "\u{1B}[31mrm\rfinal\u{0007}"
        )
        #expect(!cleaned.contains("\u{1B}"))
        #expect(!cleaned.contains("\r"))
        #expect(!cleaned.contains("\u{0007}"))
        #expect(cleaned.contains("rm"))
        #expect(cleaned.contains("final"))
        // Newlines and tabs are preserved for readability.
        #expect(
            LocalExecPermissionAuthorizer.sanitizedForTerminal("a\nb\tc").contains("\n")
        )
    }

    @Test
    func alwaysChoiceHintExplainsScope() {
        #expect(
            LocalExecPermissionAuthorizer.alwaysChoiceHint(forToolName: "local.exec")
                .contains("across sessions")
        )
        #expect(
            LocalExecPermissionAuthorizer.alwaysChoiceHint(forToolName: "local.delete")
                .contains("session only")
        )
    }

    @Test
    func presentDialogRetriesUntilRecognizedKeyThenDecides() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let recorder = FakeConsentReader(answers: ["x", "a"])
        await authorizer.setConsentReader({ prompt in await recorder.next(prompt: prompt) })
        let decision = await authorizer.presentDialog(for: Self.consentRequest())
        // The unrecognized first key is ignored, the second decides.
        #expect(decision == .allowAlways)
        // Both attempts consumed, and the retry used the retry prompt.
        let prompts = await recorder.recordedPrompts()
        #expect(prompts.count == 2)
        #expect(prompts.last == LocalExecPermissionAuthorizer.terminalRetryPrompt())
    }

    @Test
    func presentDialogReturnsNilOnImmediateEOF() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let recorder = FakeConsentReader(answers: [nil])
        await authorizer.setConsentReader({ prompt in await recorder.next(prompt: prompt) })
        let decision = await authorizer.presentDialog(for: Self.consentRequest())
        // EOF yields no consent (fail-closed at the dialog layer).
        #expect(decision == nil)
        let count = await recorder.recordedPrompts().count
        #expect(count == 1)
    }

    @Test
    func presentDialogDeniesOnCancelKey() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let recorder = FakeConsentReader(answers: ["c"])
        await authorizer.setConsentReader({ prompt in await recorder.next(prompt: prompt) })
        let decision = await authorizer.presentDialog(for: Self.consentRequest())
        #expect(decision == .deny)
    }

    @Test
    func concurrentAuthorizationDialogsUseOnlyOneTerminalReaderAtATime() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let reader = BlockingConsentReader()
        await authorizer.setConsentReader({ prompt in
            await reader.next(prompt: prompt)
        })

        let first = Task {
            await authorizer.authorize(
                Self.destructiveConsentRequest(toolCallID: "first", command: "delete one")
            )
        }
        await reader.waitUntilFirstInvocation()

        let second = Task {
            await authorizer.authorize(
                Self.destructiveConsentRequest(toolCallID: "second", command: "delete two")
            )
        }

        // Give the second task ample opportunity to enter the re-entrant actor.
        // Without the explicit dialog queue it starts a second TTY read here.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await reader.recordedInvocationCount() == 1)

        await reader.releaseFirstInvocation()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await reader.recordedInvocationCount() == 2)
    }

    @Test
    func cancellingQueuedAuthorizationDoesNotLeaveDialogBlocked() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let reader = BlockingConsentReader()
        await authorizer.setConsentReader({ prompt in
            await reader.next(prompt: prompt)
        })

        let first = Task {
            await authorizer.authorize(
                Self.destructiveConsentRequest(toolCallID: "first", command: "delete one")
            )
        }
        await reader.waitUntilFirstInvocation()

        let queued = Task {
            await authorizer.authorize(
                Self.destructiveConsentRequest(toolCallID: "queued", command: "delete queued")
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        queued.cancel()

        #expect(await queued.value == false)
        #expect(await reader.recordedInvocationCount() == 1)

        await reader.releaseFirstInvocation()
        #expect(await first.value)
    }

    @Test
    func cancellingActiveAuthorizationCannotApproveAfterReaderReturns() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let reader = BlockingConsentReader()
        await authorizer.setConsentReader({ prompt in
            await reader.next(prompt: prompt)
        })

        let authorization = Task {
            await authorizer.authorize(
                Self.destructiveConsentRequest(toolCallID: "active", command: "delete active")
            )
        }
        await reader.waitUntilFirstInvocation()
        authorization.cancel()
        await reader.releaseFirstInvocation()

        #expect(await authorization.value == false)
    }

    private static func consentRequest() -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call",
            toolName: "local.exec",
            title: "Run swift tests",
            kind: "shell",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )
    }

    private static func destructiveConsentRequest(
        toolCallID: String,
        command: String
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: toolCallID,
            toolName: "local.delete",
            title: "Delete test file",
            kind: "destructive",
            command: command,
            workingDirectory: "/tmp/project"
        )
    }

    @Test
    func settingsManifestDecodesButDoesNotEncodeLegacyLocalExecPermissions() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            localExecAllowedCommands: [
                "swift"
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("localExecAllowedCommands"))

        let legacyData = Data(
            #"""
            {
              "version": 8,
              "models": [],
              "localExecAllowedCommands": ["swift"]
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: legacyData)
        #expect(decoded.localExecAllowedCommands == ["swift"])
    }

    @Test
    func permissionsManifestRoundTripsLocalExecPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("permissions.json")

        let manifest = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift test",
                "swift build",
                " pwd && git status "
            ]
        )
        try AgentPermissionsManifestStore.save(manifest, to: url)
        let decoded = try AgentPermissionsManifestStore.loadRequired(from: url)

        // `pwd` is a harmless builtin and is skipped, so the entry normalizes
        // to its first authorizable executable `git`.
        #expect(decoded.localExecAllowedCommands == ["swift", "git"])
        #expect(decoded.containsLocalExecAllowedCommand("SWIFT"))
        #expect(decoded.containsLocalExecAllowedCommand("GIT"))
    }

    @Test
    func permissionsManifestSeparatesCommandsFromParsedIdentities() {
        let parsedCommands = AgentPermissionsManifest(
            localExecAllowedCommands: ["swift build | tail -n 20"]
        )
        #expect(parsedCommands.localExecAllowedCommands == ["swift", "tail"])

        let parsedIdentities = AgentPermissionsManifest()
            .appendingLocalExecAllowedCommandIdentities(["true", "./My Tool", "TRUE"])
        #expect(parsedIdentities.localExecAllowedCommands == ["true", "./My Tool"])
    }
}

/// Deterministic consent reader for `presentDialog` loop/EOF coverage. Returns
/// the queued answers in order (nil models EOF) and records every prompt seen.
private actor FakeConsentReader {
    private let answers: [String?]
    private var index = 0
    private var prompts: [String] = []

    init(answers: [String?]) {
        self.answers = answers
    }

    func next(prompt: String) -> String? {
        prompts.append(prompt)
        guard index < answers.count else {
            return nil
        }
        defer { index += 1 }
        return answers[index]
    }

    func recordedPrompts() -> [String] {
        prompts
    }
}

/// Holds the first read open so a second concurrent authorization has time to
/// attempt another read. A correct authorizer queues that second request.
private actor BlockingConsentReader {
    private var invocationCount = 0
    private var firstInvocationContinuation: CheckedContinuation<Void, Never>?
    private var firstInvocationWaiters: [CheckedContinuation<Void, Never>] = []

    func next(prompt _: String) async -> String? {
        invocationCount += 1
        if invocationCount == 1 {
            let waiters = firstInvocationWaiters
            firstInvocationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstInvocationContinuation = continuation
            }
        }
        return "r"
    }

    func waitUntilFirstInvocation() async {
        guard invocationCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            firstInvocationWaiters.append(continuation)
        }
    }

    func releaseFirstInvocation() {
        firstInvocationContinuation?.resume()
        firstInvocationContinuation = nil
    }

    func recordedInvocationCount() -> Int {
        invocationCount
    }
}
