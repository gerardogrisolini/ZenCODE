import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The live workspace checkpoint: a read-only core tool with no file change
/// launches no Git, any other tool does, and the repository root is looked
/// up once per tracker.
@Suite
struct TurnFileChangeLiveCheckpointTests {
    @Test
    func readOnlyCompletionLaunchesNoGitButExecDoes() async throws {
        await Task.yield()
        try await withChatHarness { harness in
            let file = harness.workspace.appendingPathComponent("file.txt")
            try Self.commit(file, in: harness.workspace)
            let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: harness.workspace)
            await coordinator.prepareForTurn()
            let context = try #require(await harness.controller.beginFileArtifactTurn(coordinator: coordinator))
            try Data("outside\n".utf8).write(to: file)
            let result = DirectAgentToolResult(output: "done", summary: "done")
            let launched = await coordinator.gitInvocationCount()

            await harness.controller.publishLiveFileArtifacts(
                result, callID: "read", toolName: "local.readFile", context: context
            )
            #expect(await coordinator.gitInvocationCount() == launched)

            await harness.controller.publishLiveFileArtifacts(
                result, callID: "exec", toolName: "local.exec", context: context
            )
            #expect(await coordinator.gitInvocationCount() > launched)
            #expect(await harness.presenter.events.contains(.liveArtifacts(agentID: nil, paths: ["file.txt"])))
        }
    }

    @Test
    func repositoryRootIsLookedUpOncePerTracker() async throws {
        await Task.yield()
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        try Self.commit(repository.appendingPathComponent("seed.txt"), in: repository)
        let tracker = TurnFileChangeTracker(baseDirectoryURL: repository)
        await tracker.prepareInitialWorktreeBaselineIfNeeded()
        // `rev-parse` and `status` of a clean worktree.
        #expect(await tracker.gitInvocationCount == 2)
        #expect(await tracker.cachedRepositoryRootPath != nil)
        _ = await tracker.collectLiveSummary(matching: [])
        _ = await tracker.collectLiveSummary(matching: [])
        // Only `status` each time: the root comes from the cache.
        #expect(await tracker.gitInvocationCount == 4)
    }

    /// Writes `file` and commits it in a new repository at `directory`.
    private static func commit(_ file: URL, in directory: URL) throws {
        try Data("committed\n".utf8).write(to: file)
        let commit = ["-c", "user.name=ZenCODE Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        for arguments in [["init"], ["add", "."], commit + ["commit", "-m", "initial"]] {
            let process = Process()
            process.executableURL = GitExecutableResolver.executableURL()
            process.arguments = ["-C", directory.path] + arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
