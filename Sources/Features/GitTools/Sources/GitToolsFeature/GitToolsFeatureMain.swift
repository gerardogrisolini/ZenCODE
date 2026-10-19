import Foundation
import FeatureKit
import ToolCore

public enum GitToolsFeatureRunner {
    public static func run() async {
        await FeatureRunner.run([
            AnyFeatureTool(GitStatusTool()),
            AnyFeatureTool(GitDiffTool()),
            AnyFeatureTool(GitShowTool()),
            AnyFeatureTool(GitLogTool()),
            AnyFeatureTool(GitBranchTool()),
            AnyFeatureTool(GitRemoteTool()),
            AnyFeatureTool(GitLsFilesTool()),
            AnyFeatureTool(GitGrepTool()),
            AnyFeatureTool(GitBlameTool()),
            AnyFeatureTool(GitAddTool()),
            AnyFeatureTool(GitRestoreTool()),
            AnyFeatureTool(GitCommitTool()),
            AnyFeatureTool(GitPushTool()),
            AnyFeatureTool(GitFetchTool()),
            AnyFeatureTool(GitPullTool()),
            AnyFeatureTool(GitStashTool()),
            AnyFeatureTool(GitSwitchTool())
        ])
    }
}
