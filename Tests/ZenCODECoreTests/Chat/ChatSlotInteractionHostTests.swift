//
//  ChatSlotInteractionHostTests.swift
//  ZenCODE
//
//  The interaction host of a slot as the slot changes the host that
//  answers: setting the host that is already active moves nothing, a
//  request still without an answer is asked again on the new host, and an
//  answer the previous host gave as the slot switched is the answer.
//

import Foundation
import Testing
@testable import ZenCODECore

/// A host whose `readLine` waits until the test answers it, recording what
/// it is asked and the cancellations it sees. A cancellation answers `nil`,
/// as every host does, unless `answersAfterCancellation`: the request then
/// stays open for the answer the operator already gave as the slot switched.
private actor GatedLineHost: ChatInteractionHost {
    nonisolated var capabilities: ChatChannelCapabilities {
        [.textInput]
    }

    private let answersAfterCancellation: Bool
    private(set) var prompts: [String] = []
    private(set) var cancellationCount = 0
    private var waiter: CheckedContinuation<String?, Never>?

    init(answersAfterCancellation: Bool = false) {
        self.answersAfterCancellation = answersAfterCancellation
    }

    /// Whether a line is asked and not answered yet.
    var isWaiting: Bool {
        waiter != nil
    }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        nil
    }

    func readLine(prompt: String) async -> String? {
        prompts.append(prompt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.requestWasCancelled() }
        }
    }

    /// Answers the line asked, if any.
    func answer(_ line: String?) {
        let pending = waiter
        waiter = nil
        pending?.resume(returning: line)
    }

    private func requestWasCancelled() {
        cancellationCount += 1
        if !answersAfterCancellation {
            answer(nil)
        }
    }
}

/// A host without identity, like the host that refuses everything between
/// incarnations.
private struct ValueHost: ChatInteractionHost {
    var capabilities: ChatChannelCapabilities {
        []
    }

    func requestToolConsent(
        _ request: AgentToolAuthorizationRequest
    ) async -> ChatConsentDecision? {
        nil
    }
}

@Suite("Chat slot interaction host", .timeLimit(.minutes(1)))
struct ChatSlotInteractionHostTests {
    /// Setting the host that is already active moves nothing: the same
    /// object, whatever the channel and incarnation it is set for, or a host
    /// without identity set again for the same channel and incarnation. The
    /// request waiting on it is neither cancelled nor asked again.
    @Test
    func settingTheActiveHostAgainMovesNothing() async {
        let host = GatedLineHost()
        let slotHost = ChatSlotInteractionHost(activeHost: host)
        slotHost.setActiveHost(host, channel: .primary, incarnationEpoch: 1)
        #expect(slotHost.activeHostGeneration == 0)

        let answer = Task { await slotHost.readLine(prompt: "Your name?") }
        await Self.waitUntil { await host.isWaiting }
        slotHost.setActiveHost(host, channel: .primary, incarnationEpoch: 1)
        slotHost.setActiveHost(host, channel: .primary, incarnationEpoch: 2)
        #expect(slotHost.activeHostGeneration == 0)
        #expect(slotHost.openRequestCount == 1)
        await host.answer("Alice")
        #expect(await answer.value == "Alice")
        #expect(await host.prompts == ["Your name?"])
        #expect(await host.cancellationCount == 0)

        // A host without identity is the same host for the same channel and
        // incarnation, another one otherwise.
        slotHost.setActiveHost(ValueHost(), channel: .primary, incarnationEpoch: nil)
        #expect(slotHost.activeHostGeneration == 1)
        slotHost.setActiveHost(ValueHost(), channel: .primary, incarnationEpoch: nil)
        #expect(slotHost.activeHostGeneration == 1)
        slotHost.setActiveHost(ValueHost(), channel: .telegram, incarnationEpoch: nil)
        #expect(slotHost.activeHostGeneration == 2)
        slotHost.setActiveHost(ValueHost(), channel: .telegram, incarnationEpoch: 3)
        #expect(slotHost.activeHostGeneration == 3)
    }

    /// A request still without an answer when the slot switches is withdrawn
    /// from the previous host and asked again on the new one, whose answer
    /// the caller receives.
    @Test
    func aRequestWithoutAnAnswerAtTheSwitchIsAskedAgainOnTheNewHost() async {
        let previous = GatedLineHost()
        let next = GatedLineHost()
        let slotHost = ChatSlotInteractionHost(activeHost: previous)
        slotHost.setActiveHost(previous, channel: .primary, incarnationEpoch: 1)

        let answer = Task { await slotHost.readLine(prompt: "Your city?") }
        await Self.waitUntil { await previous.isWaiting }
        slotHost.setActiveHost(next, channel: .telegram, incarnationEpoch: 1)
        await Self.waitUntil { await next.isWaiting }
        #expect(await previous.cancellationCount == 1)
        await next.answer("Rome")
        #expect(await answer.value == "Rome")
        #expect(await previous.prompts == ["Your city?"])
        #expect(await next.prompts == ["Your city?"])
        #expect(slotHost.openRequestCount == 0)
    }

    /// An answer the previous host gave as the slot switched is the answer:
    /// the operator already decided, so the request is not asked again on
    /// the new host.
    @Test
    func anAnswerThePreviousHostGaveAtTheSwitchIsTheAnswer() async {
        let previous = GatedLineHost(answersAfterCancellation: true)
        let next = GatedLineHost()
        let slotHost = ChatSlotInteractionHost(activeHost: previous)
        slotHost.setActiveHost(previous, channel: .telegram, incarnationEpoch: 1)

        let answer = Task { await slotHost.readLine(prompt: "Your name?") }
        await Self.waitUntil { await previous.isWaiting }
        slotHost.setActiveHost(next, channel: .primary, incarnationEpoch: 1)
        await Self.waitUntil { await previous.cancellationCount == 1 }
        await previous.answer("Alice")
        #expect(await answer.value == "Alice")
        #expect(await next.prompts.isEmpty)
        #expect(slotHost.openRequestCount == 0)
    }

    private static func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0 ..< 500 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
