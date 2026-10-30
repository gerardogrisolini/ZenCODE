import FeatureKit
import Testing
import ToolCore
@testable import GitToolsFeature

/// ACP clients (Xcode) render `execute` as "Terminal Command". Only the core
/// `local.exec` tool may use that kind; every Git tool must present as
/// something else while keeping its action and the rest of its presentation.
@Suite("GitTools presentation kinds")
struct GitToolsPresentationKindTests {
    private struct Expectation {
        let name: String
        let tool: AnyFeatureTool
        let kind: ToolPresentationKind
        let action: String
    }

    private static let expectations: [Expectation] = [
        Expectation(name: "git.status", tool: AnyFeatureTool(GitStatusTool()), kind: .read, action: "Inspect"),
        Expectation(name: "git.diff", tool: AnyFeatureTool(GitDiffTool()), kind: .read, action: "Inspect"),
        Expectation(name: "git.show", tool: AnyFeatureTool(GitShowTool()), kind: .read, action: "Show"),
        Expectation(name: "git.log", tool: AnyFeatureTool(GitLogTool()), kind: .read, action: "List"),
        Expectation(name: "git.branch", tool: AnyFeatureTool(GitBranchTool()), kind: .read, action: "List"),
        Expectation(name: "git.remote", tool: AnyFeatureTool(GitRemoteTool()), kind: .read, action: "List"),
        Expectation(name: "git.lsFiles", tool: AnyFeatureTool(GitLsFilesTool()), kind: .read, action: "List"),
        Expectation(name: "git.grep", tool: AnyFeatureTool(GitGrepTool()), kind: .search, action: "Search"),
        Expectation(name: "git.blame", tool: AnyFeatureTool(GitBlameTool()), kind: .read, action: "Inspect"),
        Expectation(name: "git.add", tool: AnyFeatureTool(GitAddTool()), kind: .edit, action: "Stage"),
        Expectation(name: "git.restore", tool: AnyFeatureTool(GitRestoreTool()), kind: .edit, action: "Restore"),
        Expectation(name: "git.commit", tool: AnyFeatureTool(GitCommitTool()), kind: .other, action: "Commit"),
        Expectation(name: "git.push", tool: AnyFeatureTool(GitPushTool()), kind: .other, action: "Push"),
        Expectation(name: "git.fetch", tool: AnyFeatureTool(GitFetchTool()), kind: .other, action: "Fetch"),
        Expectation(name: "git.pull", tool: AnyFeatureTool(GitPullTool()), kind: .other, action: "Pull"),
        Expectation(name: "git.stash", tool: AnyFeatureTool(GitStashTool()), kind: .manage, action: "Manage"),
        Expectation(name: "git.switch", tool: AnyFeatureTool(GitSwitchTool()), kind: .other, action: "Switch")
    ]

    @Test func noGitToolPresentsAsExecute() {
        for expectation in Self.expectations {
            #expect(
                expectation.tool.descriptor.presentation?.kind != .execute,
                "\(expectation.name) must not use the execute presentation kind"
            )
        }
    }

    @Test func toolKindsAndActionsMatchTheExpectedPresentation() {
        for expectation in Self.expectations {
            let descriptor = expectation.tool.descriptor
            let presentation = descriptor.presentation

            #expect(descriptor.name == expectation.name)
            #expect(presentation?.kind == expectation.kind, "\(expectation.name) kind")
            #expect(presentation?.action == expectation.action, "\(expectation.name) action")
        }
    }

    @Test func remoteAndCommitToolsKeepTheirTargetsAndTitlesWhenPresentedAsOther() {
        let commit = GitCommitTool.presentation
        #expect(commit.title == "Git commit")
        #expect(commit.target == .argument(["message"], format: .automatic))

        for presentation in [GitPushTool.presentation, GitFetchTool.presentation, GitPullTool.presentation] {
            #expect(presentation.title == "Git remote")
            #expect(presentation.target == .argument(["branch", "refspec", "remote"], format: .automatic))
        }

        let switchBranch = GitSwitchTool.presentation
        #expect(switchBranch.title == "Git branch")
        #expect(switchBranch.target == .argument(["branch"], format: .automatic))
    }
}
