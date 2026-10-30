import Foundation
import FeatureKit
import ToolCore

private func gitPresentation(
    title: String,
    action: String,
    kind: ToolPresentationKind = .read,
    targetKeys: [String] = ["path", "workingDirectory"]
) -> ToolPresentationDefinition {
    .standard(title: title, action: action, kind: kind, targetKeyPaths: targetKeys)
}

extension GitStatusTool {
    static var presentation: ToolPresentationDefinition { gitPresentation(title: "Git status", action: "Inspect") }
}

extension GitDiffTool {
    static var presentation: ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: "Git diff",
            action: "Inspect",
            kind: .read,
            target: .argument(["file_path", "file", "baseRevision", "base_revision", "base", "path"], format: .text),
            sections: [
                .parameters(),
                .code(label: "diff", value: .resultOutput(), languageHint: .literal("diff"))
            ],
            summary: ToolPresentationSummaryDefinition(value: .resultSummary(), strategy: .firstLine, label: "summary")
        )
    }
}

extension GitShowTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git object", action: "Show", targetKeys: ["revision", "rev", "commit", "file_path", "path"])
    }
}

extension GitLogTool {
    static var presentation: ToolPresentationDefinition { gitPresentation(title: "Git history", action: "List") }
}

extension GitBranchTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git branches", action: "List", targetKeys: ["contains", "path", "workingDirectory"])
    }
}

extension GitRemoteTool {
    static var presentation: ToolPresentationDefinition { gitPresentation(title: "Git remotes", action: "List") }
}

extension GitLsFilesTool {
    static var presentation: ToolPresentationDefinition { gitPresentation(title: "Git files", action: "List") }
}

extension GitGrepTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Git files", action: "Search", kind: .search, targetKeyPaths: ["pattern"])
    }
}

extension GitBlameTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git blame", action: "Inspect", targetKeys: ["file", "file_path", "path"])
    }
}

extension GitAddTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git index", action: "Stage", kind: .edit, targetKeys: ["paths", "path"])
    }
}

extension GitRestoreTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git files", action: "Restore", kind: .edit, targetKeys: ["paths", "path"])
    }
}

extension GitCommitTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git commit", action: "Commit", kind: .other, targetKeys: ["message"])
    }
}

extension GitPushTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git remote", action: "Push", kind: .other, targetKeys: ["branch", "refspec", "remote"])
    }
}

extension GitFetchTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git remote", action: "Fetch", kind: .other, targetKeys: ["branch", "refspec", "remote"])
    }
}

extension GitPullTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git remote", action: "Pull", kind: .other, targetKeys: ["branch", "refspec", "remote"])
    }
}

extension GitStashTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git stash", action: "Manage", kind: .manage, targetKeys: ["action", "stash", "message"])
    }
}

extension GitSwitchTool {
    static var presentation: ToolPresentationDefinition {
        gitPresentation(title: "Git branch", action: "Switch", kind: .other, targetKeys: ["branch"])
    }
}
