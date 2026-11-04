//
//  ZenConversationLogicTests.swift
//  ZenApp
//
//  The pure logic of the conversation shell: following the bottom, where the
//  turn separators go, the row cache, the tool-call durations, what Esc
//  does, and the tab bar.
//

import Foundation
import SwiftUI
import Testing
import ToolCore
import ZenAppSession
import ZenCODECore

@testable import ZenCODEApp

// MARK: - Fixtures

private func prompt(_ id: String, startsTurn: Bool = true) -> ZenTranscriptItem {
    ZenTranscriptItem(
        id: id,
        turnID: 1,
        startsTurn: startsTurn,
        content: .userPrompt(text: "prompt \(id)", attachments: [], origin: .app)
    )
}

private func assistant(_ id: String) -> ZenTranscriptItem {
    ZenTranscriptItem(id: id, turnID: 1, content: .assistantText("answer \(id)", isStreaming: false))
}

private func toolCall(_ id: String, name: String = "local.exec", completed: Bool) -> ZenTranscriptItem {
    let call = DirectAgentToolCall(
        id: "call-\(id)",
        name: name,
        argumentsObject: [:],
        argumentsJSON: "{}"
    )
    let result = completed ? DirectAgentToolResult(output: "ok", summary: "ok") : nil
    return ZenTranscriptItem(id: id, turnID: 1, content: .toolCall(call: call, result: result))
}

private func metrics(
    offsetY: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat = 500,
    bottomInset: CGFloat = 0
) -> ZenScrollMetrics {
    ZenScrollMetrics(
        offsetY: offsetY,
        contentHeight: contentHeight,
        viewportHeight: viewportHeight,
        bottomInset: bottomInset
    )
}

/// A geometry as the scroll view of a window reports it on macOS: 40 points
/// of bars over the top, 150 points of bottom chrome over the bottom, and a
/// container of the 310 points between them (a 500-point viewport). The
/// offset starts at -40 and stops at `contentHeight + 150 - 500`.
private func windowGeometry(offsetY: CGFloat, contentHeight: CGFloat) -> ScrollGeometry {
    ScrollGeometry(
        contentOffset: CGPoint(x: 0, y: offsetY),
        contentSize: CGSize(width: 600, height: contentHeight),
        contentInsets: EdgeInsets(top: 40, leading: 0, bottom: 150, trailing: 0),
        containerSize: CGSize(width: 600, height: 310)
    )
}

// MARK: - Following the bottom

@Suite("Scroll follow")
struct ZenScrollFollowTests {
    @Test("while following, content that grows by less than the threshold still scrolls to the bottom")
    func smallGrowthStaysPinned() {
        // At the bottom: 1000 - 500 - 500 = 0.
        let old = metrics(offsetY: 500, contentHeight: 1000)
        // A streamed line adds 12 points: still "at the bottom" (12 <= 24),
        // but the line would be half-hidden without a scroll.
        let new = metrics(offsetY: 500, contentHeight: 1012)
        #expect(new.isAtBottom)
        #expect(ZenScrollMetrics.followStep(old: old, new: new, isFollowing: true) == .scrollToBottom)
    }

    @Test("while following, content that grows a lot scrolls to the bottom")
    func largeGrowthScrolls() {
        let old = metrics(offsetY: 500, contentHeight: 1000)
        let new = metrics(offsetY: 500, contentHeight: 1400)
        #expect(ZenScrollMetrics.followStep(old: old, new: new, isFollowing: true) == .scrollToBottom)
    }

    @Test("a layout change that leaves the bottom in place keeps following without a scroll")
    func pinnedLayoutChange() {
        let old = metrics(offsetY: 500, contentHeight: 1000)
        let new = metrics(offsetY: 500.5, contentHeight: 1001)
        #expect(ZenScrollMetrics.followStep(old: old, new: new, isFollowing: true) == .setFollowing(true))
    }

    @Test("content that fits the container never scrolls")
    func contentFits() {
        let old = metrics(offsetY: 0, contentHeight: 200)
        let new = metrics(offsetY: 0, contentHeight: 260)
        #expect(ZenScrollMetrics.followStep(old: old, new: new, isFollowing: true) == .setFollowing(true))
    }

    @Test("scrolling up stops the following, even while the content grows")
    func scrollUpStops() {
        let old = metrics(offsetY: 500, contentHeight: 1000)
        let scrolledUp = metrics(offsetY: 300, contentHeight: 1000)
        #expect(ZenScrollMetrics.followStep(old: old, new: scrolledUp, isFollowing: true) == .setFollowing(false))

        let grownWhileScrollingUp = metrics(offsetY: 300, contentHeight: 1050)
        #expect(
            ZenScrollMetrics.followStep(old: old, new: grownWhileScrollingUp, isFollowing: true)
                == .setFollowing(false)
        )
    }

    @Test("without following, growth does not scroll; scrolling back to the bottom resumes")
    func notFollowing() {
        let old = metrics(offsetY: 300, contentHeight: 1000)
        let grown = metrics(offsetY: 300, contentHeight: 1100)
        #expect(ZenScrollMetrics.followStep(old: old, new: grown, isFollowing: false) == .setFollowing(false))

        let backAtBottom = metrics(offsetY: 590, contentHeight: 1100)
        #expect(ZenScrollMetrics.followStep(old: grown, new: backAtBottom, isFollowing: false) == .setFollowing(true))
    }

    @Test("the bottom inset counts toward the end of the content")
    func bottomInset() {
        let atBottom = metrics(offsetY: 560, contentHeight: 1000, bottomInset: 60)
        #expect(atBottom.distanceFromBottom == 0)
        let above = metrics(offsetY: 500, contentHeight: 1000, bottomInset: 60)
        #expect(above.distanceFromBottom == 60)
        #expect(!above.isAtBottom)
    }

    @Test("a window's geometry counts the bottom chrome's inset once: where the scroll stops is the bottom")
    func geometryCountsTheInsetsOnce() {
        let end = ZenScrollMetrics(windowGeometry(offsetY: 650, contentHeight: 1000))
        #expect(end.viewportHeight == 500)
        #expect(end.distanceFromBottom == 0)
        #expect(end.isAtBottom)

        let top = ZenScrollMetrics(windowGeometry(offsetY: -40, contentHeight: 1000))
        #expect(top.distanceFromBottom == 690)
        #expect(!top.isAtBottom)
    }

    @Test("content that grows under the bottom chrome is scrolled into view and keeps being followed")
    func growthUnderTheBottomChrome() {
        // The content first fits above the chrome, then grows past it.
        let fits = ZenScrollMetrics(windowGeometry(offsetY: -40, contentHeight: 300))
        let grown = ZenScrollMetrics(windowGeometry(offsetY: -40, contentHeight: 340))
        #expect(ZenScrollMetrics.followStep(old: fits, new: grown, isFollowing: true) == .scrollToBottom)

        // The scroll stops at 340 + 150 - 500 = -10: the bottom, still
        // followed (no "Jump to latest").
        let scrolled = ZenScrollMetrics(windowGeometry(offsetY: -10, contentHeight: 340))
        #expect(ZenScrollMetrics.followStep(old: grown, new: scrolled, isFollowing: true) == .setFollowing(true))
    }

    @Test("the visible height is the chat between the bars")
    func visibleHeight() {
        let metrics = ZenScrollMetrics(windowGeometry(offsetY: 650, contentHeight: 1000))
        #expect(metrics.topInset == 40)
        #expect(metrics.visibleHeight == 310)
    }

    @Test("the view is far from the bottom only with more than a visible height of chat under it")
    func farFromTheBottom() {
        // The bottom is at 650; the visible height is 310.
        let atBottom = ZenScrollMetrics(windowGeometry(offsetY: 650, contentHeight: 1000))
        #expect(!atBottom.isFarFromBottom)

        // Scrolled up, but less than a visible height: no button.
        let scrolledUp = ZenScrollMetrics(windowGeometry(offsetY: 400, contentHeight: 1000))
        #expect(!scrolledUp.isAtBottom)
        #expect(!scrolledUp.isFarFromBottom)
        let exactlyOneHeight = ZenScrollMetrics(windowGeometry(offsetY: 340, contentHeight: 1000))
        #expect(!exactlyOneHeight.isFarFromBottom)

        // More than a visible height under the view: the button.
        let farUp = ZenScrollMetrics(windowGeometry(offsetY: 339, contentHeight: 1000))
        #expect(farUp.isFarFromBottom)

        // Content that grows while the operator reads far enough above.
        let grownUnderTheReader = ZenScrollMetrics(windowGeometry(offsetY: 400, contentHeight: 1100))
        #expect(grownUnderTheReader.isFarFromBottom)
    }
}

// MARK: - Turn separators

@Suite("Turn separators")
@MainActor
struct ZenTurnSeparatorTests {
    @Test("a separator precedes every row that starts a turn, except the first")
    func separatorsBeforeTurnStarts() {
        let rows = ZenConversationRow.rows(for: [
            prompt("1-log-1"),
            assistant("1-log-2"),
            prompt("1-log-3"),
            assistant("1-log-4"),
            prompt("local-a"),
        ])
        #expect(rows.map(\.id) == ["1-log-1", "1-log-2", "1-log-3", "1-log-4", "local-a"])
        #expect(rows.map(\.showsSeparator) == [false, false, true, false, true])
    }

    @Test("a prompt row that does not start a turn gets no separator")
    func promptWithoutTurnStart() {
        let rows = ZenConversationRow.rows(for: [
            prompt("1-log-1"),
            assistant("1-log-2"),
            prompt("1-log-3", startsTurn: false),
            assistant("1-log-4"),
        ])
        #expect(rows.map(\.showsSeparator) == [false, false, false, false])
    }

    @Test("rows before the first turn start (a command, a notice) do not count as a turn")
    func rowsBeforeFirstTurn() {
        let command = ZenTranscriptItem(id: "local-c", turnID: nil, content: .commandLine("/plan add tests"))
        let rows = ZenConversationRow.rows(for: [command, assistant("1-log-1"), prompt("1-log-2"), prompt("1-log-3")])
        #expect(rows.map(\.showsSeparator) == [false, false, false, true])
    }

    @Test("hidden tool calls are left out and do not move the separators")
    func hiddenToolCalls() {
        let rows = ZenConversationRow.rows(for: [
            prompt("1-log-1"),
            toolCall("1-log-2", name: "agent.message", completed: true),
            toolCall("1-log-3", completed: true),
            prompt("1-log-4"),
        ])
        #expect(rows.map(\.id) == ["1-log-1", "1-log-3", "1-log-4"])
        #expect(rows.map(\.showsSeparator) == [false, false, true])
    }

    @Test("file artifacts are left out (they show in the sidebar) and do not move the separators")
    func fileArtifactsAreLeftOut() {
        let turn = SessionFileArtifactHistory.Turn(number: 1, artifacts: [
            FileChangeArtifact(absolutePath: "/p/a.swift", displayPath: "a.swift", status: .modified),
        ])
        let rows = ZenConversationRow.rows(for: [
            prompt("1-log-1"),
            ZenTranscriptItem(id: "1-log-2", turnID: 1, content: .fileArtifacts(turn, agentID: nil, isSealed: false)),
            assistant("1-log-3"),
            ZenTranscriptItem(id: "1-log-4", turnID: 1, content: .fileArtifacts(turn, agentID: "agent_1", isSealed: true)),
            prompt("1-log-5"),
            ZenTranscriptItem(id: "1-log-6", turnID: 1, content: .fileArtifacts(turn, agentID: nil, isSealed: false)),
            prompt("1-log-7"),
        ])
        #expect(rows.map(\.id) == ["1-log-1", "1-log-3", "1-log-5", "1-log-7"])
        #expect(rows.map(\.showsSeparator) == [false, false, true, true])
    }

    @Test("the row cache computes the rows again only when the transcript changes")
    func rowCache() {
        let cache = ZenConversationRowCache()
        #expect(cache.rows(for: []).isEmpty)

        let first = [prompt("1-log-1"), assistant("1-log-2")]
        let rows = cache.rows(for: first)
        #expect(rows.map(\.id) == ["1-log-1", "1-log-2"])
        #expect(cache.rows(for: first) == rows)

        let second = first + [prompt("1-log-3")]
        #expect(cache.rows(for: second).map(\.showsSeparator) == [false, false, true])

        // A new session: other ids, the first prompt has no separator.
        let newSession = [prompt("2-log-1")]
        #expect(cache.rows(for: newSession).map(\.id) == ["2-log-1"])
        #expect(cache.rows(for: newSession).map(\.showsSeparator) == [false])
    }
}

// MARK: - Tool durations

@Suite("Tool durations")
@MainActor
struct ZenToolDurationTests {
    @Test("a call is timed from the transcript that shows it running to the one with its result")
    func timesARunningCall() {
        let durations = ZenToolDurations()
        let start = ContinuousClock.now
        durations.observe([toolCall("1-log-1", completed: false)], at: start)
        #expect(durations.duration(for: toolCall("1-log-1", completed: false)) == nil)

        // A later transcript that still shows it running does not restart it.
        durations.observe([toolCall("1-log-1", completed: false)], at: start + .seconds(1))
        let finished = toolCall("1-log-1", completed: true)
        durations.observe([finished], at: start + .seconds(3))
        #expect(durations.duration(for: finished) == .seconds(3))

        // Seen again later: the duration stays.
        durations.observe([finished], at: start + .seconds(9))
        #expect(durations.duration(for: finished) == .seconds(3))
    }

    @Test("a call first seen with its result has no duration")
    func restoredCall() {
        let durations = ZenToolDurations()
        let restored = toolCall("1-log-4", completed: true)
        durations.observe([restored], at: .now)
        #expect(durations.duration(for: restored) == nil)
    }

    @Test("ids of another session never inherit a duration")
    func idsAcrossEpochs() {
        let durations = ZenToolDurations()
        let start = ContinuousClock.now
        durations.observe([toolCall("1-log-2", completed: false)], at: start)
        durations.observe([toolCall("1-log-2", completed: true)], at: start + .seconds(2))
        #expect(durations.duration(for: toolCall("1-log-2", completed: true)) == .seconds(2))

        // The same log sequence in the next session is another row.
        let nextSession = toolCall("2-log-2", completed: true)
        durations.observe([nextSession], at: start + .seconds(5))
        #expect(durations.duration(for: nextSession) == nil)

        // A running call of the next session is timed on its own.
        durations.observe([toolCall("2-log-3", completed: false)], at: start + .seconds(6))
        durations.observe([toolCall("2-log-3", completed: true)], at: start + .seconds(7))
        #expect(durations.duration(for: toolCall("2-log-3", completed: true)) == .seconds(1))
        #expect(durations.duration(for: toolCall("1-log-2", completed: true)) == .seconds(2))
    }

    @Test("rows that are not completed tool calls have no duration")
    func otherRows() {
        let durations = ZenToolDurations()
        durations.observe([prompt("1-log-1"), assistant("1-log-2")], at: .now)
        #expect(durations.duration(for: prompt("1-log-1")) == nil)
        #expect(durations.duration(for: assistant("1-log-2")) == nil)
    }
}

// MARK: - Esc

@Suite("Esc routing")
struct ZenEscapeRoutingTests {
    private let consent = ChatPendingRequest.Kind.toolConsent(AgentToolAuthorizationRequest(
        turnID: nil,
        sessionID: "s",
        toolCallID: "c",
        toolName: "local.exec",
        title: "Run a command",
        kind: "execute",
        command: "ls",
        workingDirectory: "/tmp"
    ))

    @Test("Esc with a tool consent waiting denies its request once")
    func consentDenies() {
        let id = UUID()
        #expect(ZenEscapeAction(pendingRequestID: id, kind: consent) == .denyConsent(requestID: id))
        #expect(ZenEscapeAction.consentAnswer == .consent(.denyOnce))
    }

    @Test("Esc without a request stops the turn")
    func noRequestStops() {
        #expect(ZenEscapeAction(pendingRequestID: nil, kind: nil) == .stop)
        #expect(ZenEscapeAction(pendingRequest: nil) == .stop)
    }

    @Test("Esc with a request that is not a consent stops the turn")
    func otherRequestsStop() {
        let id = UUID()
        #expect(ZenEscapeAction(pendingRequestID: id, kind: .readLine(prompt: "Name")) == .stop)
        #expect(
            ZenEscapeAction(
                pendingRequestID: id,
                kind: .chooseOne(title: "Model", items: [], selectedID: nil)
            ) == .stop
        )
    }

    @Test("Esc acts in the conversation only: a sub-agent tab consumes it and does nothing")
    func onlyTheConversationTab() {
        let id = UUID()
        #expect(ZenEscapeAction(selectedTab: .chat, pendingRequestID: nil, kind: nil) == .stop)
        #expect(ZenEscapeAction(selectedTab: .chat, pendingRequestID: id, kind: consent) == .denyConsent(requestID: id))
        #expect(ZenEscapeAction(selectedTab: .subAgent("a"), pendingRequestID: nil, kind: nil) == .consume)
        #expect(ZenEscapeAction(selectedTab: .subAgent("a"), pendingRequestID: id, kind: consent) == .consume)
        #expect(
            ZenEscapeAction(selectedTab: .subAgent("a"), pendingRequestID: id, kind: .readLine(prompt: "Name")) == .consume
        )
    }
}

// MARK: - Tabs

@Suite("Window tab bar")
struct ZenWindowTabBarTests {
    @Test("the bar shows while a sub-agent tab is open")
    func barVisibility() {
        #expect(!ZenWindowTabBarLogic.showsBar(subAgentTabCount: 0))
        #expect(ZenWindowTabBarLogic.showsBar(subAgentTabCount: 1))
        #expect(ZenWindowTabBarLogic.showsBar(subAgentTabCount: 5))
    }

    @Test("the Chat tab has a badge while a request waits and another tab shows")
    func chatBadge() {
        #expect(ZenWindowTabBarLogic.showsChatBadge(hasPendingRequest: true, selectedTab: .subAgent("a")))
        #expect(!ZenWindowTabBarLogic.showsChatBadge(hasPendingRequest: true, selectedTab: .chat))
        #expect(!ZenWindowTabBarLogic.showsChatBadge(hasPendingRequest: false, selectedTab: .subAgent("a")))
        #expect(!ZenWindowTabBarLogic.showsChatBadge(hasPendingRequest: false, selectedTab: .chat))
    }

    @Test("a sub-agent tab is titled with the agent's name on one line, cut with an ellipsis, else its id")
    func titles() {
        #expect(ZenWindowTabBarLogic.title(name: "transcript-dev", agentID: "agent_1") == "transcript-dev")
        #expect(ZenWindowTabBarLogic.title(name: "two\nlines", agentID: "agent_1") == "two lines")
        #expect(ZenWindowTabBarLogic.title(name: "  ", agentID: "agent_1") == "agent_1")
        #expect(ZenWindowTabBarLogic.title(name: nil, agentID: "agent_1") == "agent_1")
        let long = ZenWindowTabBarLogic.title(name: String(repeating: "x", count: 80), agentID: "agent_1")
        #expect(long.count <= ZenWindowTabBarLogic.titleLimit + 1)
        #expect(long.hasSuffix("…"))
    }

    @Test("the rows of a sub-agent transcript put a separator before every prompt after the brief")
    func subAgentSeparators() {
        let items = ZenSubAgentTranscriptProjection.items(
            for: [
                .userPrompt(text: "Brief", attachments: [], origin: .unknown),
                .assistantText("On it."),
                .toolCallStarted(DirectAgentToolCall(id: "m", name: "agent.message", argumentsObject: [:], argumentsJSON: "{}")),
                .userPrompt(text: "A message", attachments: [], origin: .unknown),
                .assistantText("Done."),
            ],
            agentID: "a"
        )
        let rows = ZenConversationRow.rows(for: items)
        // `agent.message` is hidden, as in the conversation.
        #expect(rows.map(\.id) == ["subagent-a-0", "subagent-a-1", "subagent-a-3", "subagent-a-4"])
        #expect(rows.map(\.showsSeparator) == [false, false, true, false])
    }
}
