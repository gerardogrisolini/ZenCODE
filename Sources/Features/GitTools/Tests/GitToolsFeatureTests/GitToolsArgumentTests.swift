import Foundation
import Testing
@testable import GitToolsFeature

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite("GitTools argument hardening")
struct GitToolsArgumentTests {
    @Test func pushRejectsForceAsRemote() throws {
        let input = try decode(GitPushTool.Input.self, #"{"remote":"--force","branch":"main"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitPushTool.arguments(for: input) }
    }

    @Test func pushRejectsForcedRefspec() throws {
        let input = try decode(GitPushTool.Input.self, #"{"remote":"origin","refspec":"+refs/heads/main:refs/heads/main"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitPushTool.arguments(for: input) }
    }

    @Test func pushRejectsExtHelper() throws {
        let input = try decode(GitPushTool.Input.self, #"{"remote":"EXT::sh -c id","branch":"main"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitPushTool.arguments(for: input) }
        let fd = try decode(GitPushTool.Input.self, #"{"remote":"fd::3","branch":"main"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitPushTool.arguments(for: fd) }
    }

    @Test func pushAcceptsValidValues() throws {
        let input = try decode(GitPushTool.Input.self, #"{"remote":"origin","branch":"feature/x","setUpstream":true}"#)
        #expect(try GitPushTool.arguments(for: input) == ["push", "--set-upstream", "origin", "feature/x"])
        let url = try decode(GitPushTool.Input.self, #"{"remote":"https://example.com/a/b.git","branch":"main"}"#)
        #expect(try GitPushTool.arguments(for: url) == ["push", "https://example.com/a/b.git", "main"])
        let ssh = try decode(GitPushTool.Input.self, #"{"remote":"git@github.com:a/b.git"}"#)
        #expect(try GitPushTool.arguments(for: ssh) == ["push", "git@github.com:a/b.git"])
    }

    @Test func fetchRejectsUploadPack() throws {
        let input = try decode(GitFetchTool.Input.self, #"{"remote":"--upload-pack=touch /tmp/x"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitFetchTool.arguments(for: input) }
        let ok = try decode(GitFetchTool.Input.self, #"{"remote":"origin","branch":"main","prune":true}"#)
        #expect(try GitFetchTool.arguments(for: ok) == ["fetch", "--prune", "origin", "main"])
    }

    @Test func pullRejectsOptionLikeBranch() throws {
        let input = try decode(GitPullTool.Input.self, #"{"remote":"origin","branch":"--force"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitPullTool.arguments(for: input) }
    }

    @Test func grepUsesDashEForPattern() throws {
        let input = try decode(GitGrepTool.Input.self, #"{"pattern":"--open-files-in-pager=sh","paths":["Sources"]}"#)
        let args = try GitGrepTool.arguments(for: input)
        #expect(args == ["grep", "-n", "-I", "-m", "200", "-e", "--open-files-in-pager=sh", "--", "Sources"])
        let files = try decode(GitGrepTool.Input.self, #"{"pattern":"foo","filesOnly":true}"#)
        #expect(try GitGrepTool.arguments(for: files) == ["grep", "-I", "-l", "-e", "foo"])
    }

    @Test func revisionArgumentsAreValidated() throws {
        let diff = try decode(GitDiffTool.Input.self, #"{"baseRevision":"--output=/tmp/x"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitDiffTool.arguments(for: diff) }
        let show = try decode(GitShowTool.Input.self, #"{"revision":"--help"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitShowTool.arguments(for: show) }
        let branch = try decode(GitBranchTool.Input.self, #"{"contains":"-x"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitBranchTool.arguments(for: branch) }
        let sw = try decode(GitSwitchTool.Input.self, #"{"branch":"--orphan"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitSwitchTool.arguments(for: sw) }
        let stash = try decode(GitStashTool.Input.self, #"{"action":"drop","stash":"--all"}"#)
        #expect(throws: GitToolsFeatureError.self) { try GitToolsSupport.gitStashArguments(action: "drop", input: stash) }
    }

    @Test func validRevisionsKeepPathSeparator() throws {
        let show = try decode(GitShowTool.Input.self, #"{"revision":"HEAD~1","file":"a.swift"}"#)
        #expect(try GitShowTool.arguments(for: show) == ["show", "HEAD~1", "--", "a.swift"])
        let diff = try decode(GitDiffTool.Input.self, #"{"baseRevision":"main","file":"-weird"}"#)
        #expect(try GitDiffTool.arguments(for: diff) == ["diff", "main", "--", "-weird"])
    }

    @Test func positionalRejectsBlankAndControlCharacters() {
        #expect(throws: GitToolsFeatureError.self) { try GitToolsSupport.positional("  ", named: "x") }
        #expect(throws: GitToolsFeatureError.self) { try GitToolsSupport.positional("a\nb", named: "x") }
        #expect(throws: GitToolsFeatureError.self) { try GitToolsSupport.positional("a\0b", named: "x") }
    }
}
