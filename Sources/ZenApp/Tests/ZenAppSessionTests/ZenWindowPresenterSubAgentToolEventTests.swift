//
//  ZenWindowPresenterSubAgentToolEventTests.swift
//  ZenAppSessionTests
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

/// Counts the git-summary refreshes a presenter asks the window for.
private final class RefreshCounter: Sendable {
    let count = Mutex(0)
}

@Suite
struct ZenWindowPresenterSubAgentToolEventTests {
    @Test("A delegated agent's completed file mutation refreshes the git summary; a start or a read does not")
    @ChatSessionActor
    func delegatedFileMutationRefreshesTheGitSummary() async {
        let presenter = ZenWindowPresenter()
        let refreshes = RefreshCounter()
        presenter.fileMutationHandler = { refreshes.count.withLock { $0 += 1 } }
        let write = DirectAgentToolCall(
            id: "write", name: "local.writeFile",
            argumentsObject: ["path": "a.swift"], argumentsJSON: "{}"
        )
        let read = DirectAgentToolCall(
            id: "read", name: "local.readFile",
            argumentsObject: ["path": "a.swift"], argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "ok", summary: "ok")

        await presenter.presentSubAgentToolEvent(DirectSubAgentToolEvent(
            agentID: "worker", agentName: "worker", toolCall: write,
            lifecycle: .started, rootSessionID: "root"
        ))
        #expect(refreshes.count.withLock { $0 } == 0)
        await presenter.presentSubAgentToolEvent(DirectSubAgentToolEvent(
            agentID: "worker", agentName: "worker", toolCall: read,
            lifecycle: .completed(result), rootSessionID: "root"
        ))
        #expect(refreshes.count.withLock { $0 } == 0)
        await presenter.presentSubAgentToolEvent(DirectSubAgentToolEvent(
            agentID: "worker", agentName: "worker", toolCall: write,
            lifecycle: .completed(result), rootSessionID: "root"
        ))
        #expect(refreshes.count.withLock { $0 } == 1)
    }
}
