//
//  LocalExecPermissionAuthorizerTests+Dialog.swift
//  ZenCODE
//
//  Non-interactive authorization and terminal dialog tests of the local.exec
//  permission authorizer, with the consent requests and fake readers they
//  use.
//

import Foundation
import Testing
@testable import ZenCODECore

extension LocalExecPermissionAuthorizerTests {
    @Test
    func nonInteractiveAuthorizationAllowsUngatedToolsWithoutConsent() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let reader = FakeConsentReader(answers: ["c"])
        await authorizer.setConsentReader({ prompt in await reader.next(prompt: prompt) })
        let request = AgentToolAuthorizationRequest(
            sessionID: "headless",
            toolCallID: "read",
            toolName: "local.read",
            title: "Read file",
            kind: "read",
            command: "README.md",
            workingDirectory: "/tmp/project"
        )

        #expect(await authorizer.authorizeNonInteractively(request))
        #expect(await reader.recordedPrompts().isEmpty)
    }

    @Test
    func nonInteractiveAuthorizationDeniesNewGatedRequestWithoutReadingConsent() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let reader = FakeConsentReader(answers: ["a"])
        await authorizer.setConsentReader({ prompt in await reader.next(prompt: prompt) })

        #expect(!(await authorizer.authorizeNonInteractively(Self.consentRequest())))
        #expect(await reader.recordedPrompts().isEmpty)
    }

    @Test
    func presentDialogRetriesUntilRecognizedKeyThenDecides() async {
        let authorizer = LocalExecPermissionAuthorizer()
        let recorder = FakeConsentReader(answers: ["x", "a"])
        await authorizer.setConsentReader({ prompt in await recorder.next(prompt: prompt) })
        let decision = await authorizer.terminalHost.presentDialog(for: Self.consentRequest())
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
        let decision = await authorizer.terminalHost.presentDialog(for: Self.consentRequest())
        // EOF yields no consent (fail-closed at the dialog layer).
        #expect(decision == nil)
        let count = await recorder.recordedPrompts().count
        #expect(count == 1)
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
