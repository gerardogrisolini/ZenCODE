//
//  ZenWorktreeSessionRequestTests.swift
//  ZenAppSessionTests
//

import Foundation
import Testing
@testable import ZenAppSession

@Suite("Worktree session request")
@MainActor
struct ZenWorktreeSessionRequestTests {
    actor Recorder {
        var calls: [(String, URL)] = []
        var shouldFail = false

        func prepare(_ name: String, _ workspace: URL) throws -> URL {
            calls.append((name, workspace))
            if shouldFail { throw Failure() }
            return workspace.appendingPathComponent("worktree")
        }

        func setFailure(_ fail: Bool) { shouldFail = fail }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "Git failed" }
    }

    @Test("Blank names never prepare a worktree")
    func blankName() async {
        let recorder = Recorder()
        let request = ZenWorktreeSessionRequest { try await recorder.prepare($0, $1) }
        let workspace = URL(fileURLWithPath: "/tmp/project")
        request.name = "  \n"
        #expect(await request.confirm(in: workspace) == nil)
        #expect(request.errorMessage == nil)
        #expect(await recorder.calls.isEmpty)
    }

    @Test("The shared worktree manager rejects an invalid name before accessing the repository")
    func invalidName() async {
        let request = ZenWorktreeSessionRequest()
        let workspace = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        request.name = "bad/name"
        #expect(await request.confirm(in: workspace) == nil)
        #expect(request.errorMessage?.contains("--worktree") == true)
        #expect(!request.isPreparing)
    }

    @Test("A valid name prepares in the source workspace; failures remain retryable")
    func prepareAndRetry() async {
        let recorder = Recorder()
        let request = ZenWorktreeSessionRequest { try await recorder.prepare($0, $1) }
        let workspace = URL(fileURLWithPath: "/tmp/project")
        request.name = "feature"
        await recorder.setFailure(true)
        #expect(await request.confirm(in: workspace) == nil)
        #expect(request.errorMessage == "Git failed")
        #expect(!request.isPreparing)

        await recorder.setFailure(false)
        #expect(await request.confirm(in: workspace) == workspace.appendingPathComponent("worktree"))
        let calls = await recorder.calls
        #expect(calls.count == 2)
        #expect(calls.last?.0 == "feature")
        #expect(calls.last?.1 == workspace)
        #expect(request.errorMessage == nil)
    }
}
