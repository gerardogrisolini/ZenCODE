//
//  DirectToolPresentationDefinitions.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Presentation metadata for direct tools that are not `FeatureTool`
/// conformers. Keeping this beside `DirectToolCatalog` makes the executor's
/// descriptor the source of truth while the TUI remains name-agnostic.
enum DirectToolPresentationDefinitions {
    static func definition(for name: String) -> ToolPresentationDefinition? {
        if name.hasPrefix("browser.") {
            return browserDefinition(for: name)
        }
        if name.hasPrefix("jira.") {
            return jiraDefinition(for: name)
        }
        switch name {
        // MARK: Local file and text
        case "local.pwd":
            return .standard(
                title: "Working directory",
                action: "Show",
                kind: .read,
                includesParameters: false
            )
        case "local.ls":
            return .standard(
                title: "Directory",
                action: "List",
                kind: .read,
                targetKeyPaths: ["path"],
                targetFormat: .path
            )
        case "local.readFile":
            return .fileRead()
        case "local.readFiles":
            return .standard(
                title: "Files",
                action: "Read",
                kind: .read,
                targetKeyPaths: ["paths", "file_paths"],
                targetFormat: .stringList
            )
        case "local.inspectFile":
            return .standard(
                title: "File structure",
                action: "Inspect",
                kind: .inspect,
                targetKeyPaths: ["file_path", "path"],
                targetFormat: .path
            )
        case "text.head":
            return .fileRead(title: "File beginning", action: "Read")
        case "text.tail":
            return .fileRead(title: "File ending", action: "Read")
        case "text.sort":
            return .standard(
                title: "Text file",
                action: "Sort",
                kind: .read,
                targetKeyPaths: ["path"],
                targetFormat: .path
            )
        case "text.wc":
            return .standard(
                title: "Text counts",
                action: "Count",
                kind: .inspect,
                targetKeyPaths: ["path"],
                targetFormat: .path
            )
        case "local.writeFile":
            return .fileWrite()
        case "local.replace", "local.editFile":
            return .fileEdit()
        case "local.multiEdit":
            return ToolPresentationDefinition(
                title: "File edits",
                action: "Edit",
                kind: .edit,
                target: .argument(["file_path", "path"], format: .path),
                sections: [
                    .parameters(),
                    .list(
                        label: "edits",
                        value: .argument(["edits"], format: .json)
                    )
                ],
                summary: resultSummary()
            )
        case "local.append":
            return .fileWrite(action: "Append")
        case "local.mkdir":
            return .standard(
                title: "Directory",
                action: "Create",
                kind: .create,
                targetKeyPaths: ["path"],
                targetFormat: .path
            )
        case "local.delete":
            return .standard(
                title: "Path",
                action: "Delete",
                kind: .delete,
                targetKeyPaths: ["path"],
                targetFormat: .path
            )
        case "local.move":
            return ToolPresentationDefinition(
                title: "Path",
                action: "Move",
                kind: .move,
                target: .argument(["destinationPath"], format: .path),
                metadata: [
                    ToolPresentationMetadataDefinition(
                        label: "from",
                        value: .argument(["sourcePath"], format: .path)
                    )
                ],
                sections: [.parameters()],
                summary: resultSummary()
            )
        case "local.applyPatch":
            return ToolPresentationDefinition(
                title: "Patch",
                action: "Apply",
                kind: .edit,
                target: .argument(["patch", "diff"], format: .path),
                sections: [
                    .parameters(),
                    .code(
                        label: "patch",
                        value: .argument(["patch", "diff"], format: .text),
                        languageHint: .literal("diff")
                    )
                ],
                summary: resultSummary()
            )

        // MARK: Search and web
        case "search.glob":
            return searchDefinition(
                title: "Files",
                action: "Find",
                targetKeys: ["pattern", "path"]
            )
        case "search.grep", "search.locate":
            return searchDefinition(
                title: "Text",
                action: "Search",
                targetKeys: ["pattern"]
            )
        case "web.search":
            return searchDefinition(
                title: "Web",
                action: "Search",
                targetKeys: ["query"]
            )
        case "web.fetch":
            return .standard(
                title: "Web page",
                action: "Fetch",
                kind: .read,
                targetKeyPaths: ["url"],
                targetFormat: .url
            )

        // MARK: Process, Swift, and Git
        case "local.exec":
            return .standard(
                title: "Command",
                action: "Run",
                kind: .execute,
                targetKeyPaths: ["command"],
                targetFormat: .command
            )
        case "exec.job":
            return .standard(
                title: "Background job",
                action: "Manage",
                kind: .manage,
                targetKeyPaths: ["id", "jobID", "job_id", "action"]
            )
        case "swift.build":
            return swiftDefinition(title: "Swift package", action: "Build")
        case "swift.test":
            return swiftDefinition(
                title: "Swift tests",
                action: "Test",
                targetKeys: ["filter", "target", "product", "path", "workingDirectory", "cwd"]
            )
        case "swift.run":
            return swiftDefinition(
                title: "Swift executable",
                action: "Run",
                targetKeys: ["executable", "product", "path", "workingDirectory", "cwd"]
            )
        case "swift.package":
            return swiftDefinition(
                title: "Swift package",
                action: "Manage",
                targetKeys: ["action", "path", "workingDirectory", "cwd"]
            )
        case "swift.outline":
            return .standard(
                title: "Swift outline",
                action: "Inspect",
                kind: .inspect,
                targetKeyPaths: ["file_path", "path"],
                targetFormat: .path
            )
        case "git.status":
            return gitDefinition(title: "Git status", action: "Inspect")
        case "git.diff":
            return ToolPresentationDefinition(
                title: "Git diff",
                action: "Inspect",
                kind: .read,
                target: .argument(
                    ["file_path", "file", "baseRevision", "base_revision", "base", "path", "workingDirectory", "cwd"],
                    format: .text
                ),
                sections: [
                    .parameters(),
                    .code(
                        label: "diff",
                        value: .resultOutput(),
                        languageHint: .literal("diff")
                    )
                ],
                summary: resultSummary()
            )
        case "git.show":
            return gitDefinition(
                title: "Git object",
                action: "Show",
                targetKeys: ["revision", "rev", "commit", "file_path", "path"]
            )
        case "git.log":
            return gitDefinition(title: "Git history", action: "List")
        case "git.branch":
            return gitDefinition(
                title: "Git branches",
                action: "List",
                targetKeys: ["contains", "path", "workingDirectory", "cwd"]
            )
        case "git.remote":
            return gitDefinition(title: "Git remotes", action: "List")
        case "git.lsFiles":
            return gitDefinition(title: "Git files", action: "List")
        case "git.grep":
            return searchDefinition(
                title: "Git files",
                action: "Search",
                targetKeys: ["pattern"]
            )
        case "git.blame":
            return gitDefinition(
                title: "Git blame",
                action: "Inspect",
                targetKeys: ["file", "file_path", "path"]
            )
        case "git.add":
            return gitDefinition(
                title: "Git index",
                action: "Stage",
                kind: .edit,
                targetKeys: ["paths", "path"]
            )
        case "git.restore":
            return gitDefinition(
                title: "Git files",
                action: "Restore",
                kind: .edit,
                targetKeys: ["paths", "path"]
            )
        case "git.commit":
            return gitDefinition(
                title: "Git commit",
                action: "Commit",
                kind: .execute,
                targetKeys: ["message"]
            )
        case "git.push":
            return gitDefinition(
                title: "Git remote",
                action: "Push",
                kind: .execute,
                targetKeys: ["branch", "refspec", "remote"]
            )
        case "git.fetch":
            return gitDefinition(
                title: "Git remote",
                action: "Fetch",
                kind: .execute,
                targetKeys: ["branch", "refspec", "remote"]
            )
        case "git.pull":
            return gitDefinition(
                title: "Git remote",
                action: "Pull",
                kind: .execute,
                targetKeys: ["branch", "refspec", "remote"]
            )
        case "git.stash":
            return gitDefinition(
                title: "Git stash",
                action: "Manage",
                kind: .manage,
                targetKeys: ["action", "stash", "message"]
            )
        case "git.switch":
            return gitDefinition(
                title: "Git branch",
                action: "Switch",
                kind: .execute,
                targetKeys: ["branch"]
            )

        // MARK: Feature management
        case "feature.list":
            return featureDefinition(title: "Features", action: "List", kind: .read)
        case "feature.enable":
            return featureDefinition(title: "Feature", action: "Enable", kind: .manage)
        case "feature.disable":
            return featureDefinition(title: "Feature", action: "Disable", kind: .manage)
        case "feature.delete":
            return featureDefinition(title: "Feature", action: "Delete", kind: .delete)
        case "feature.edit":
            return featureDefinition(title: "Feature", action: "Edit", kind: .edit)
        case "feature.reload":
            return featureDefinition(title: "Features", action: "Reload", kind: .execute)
        case "feature.validate":
            return featureDefinition(title: "Feature", action: "Validate", kind: .inspect)
        case "feature.build":
            return featureDefinition(title: "Feature", action: "Build", kind: .execute)
        case "feature.scaffold":
            return featureDefinition(title: "Feature", action: "Scaffold", kind: .create)
        case "feature.install":
            return featureDefinition(title: "Feature", action: "Install", kind: .create)

        // MARK: Todo and task graph
        case "todo.read":
            return .standard(
                title: "Todo list",
                action: "Read",
                kind: .read,
                includesParameters: false
            )
        case "todo.write":
            return .standard(
                title: "Todo list",
                action: "Update",
                kind: .edit,
                targetKeyPaths: ["id", "title"]
            )
        case "tasks.create":
            return taskDefinition(title: "Tasks", action: "Create", kind: .create)
        case "tasks.list":
            return taskDefinition(title: "Tasks", action: "List", kind: .read)
        case "tasks.get":
            return taskDefinition(title: "Task", action: "Get", kind: .read)
        case "tasks.update":
            return taskDefinition(title: "Task", action: "Update", kind: .edit)
        case "tasks.retry":
            return taskDefinition(title: "Task", action: "Retry", kind: .execute)
        case "tasks.cancel":
            return taskDefinition(title: "Task", action: "Cancel", kind: .delete)

        // MARK: Delegated agents
        case "agent.create":
            return agentDefinition(title: "Agent", action: "Create", kind: .create)
        case "agent.list":
            return agentDefinition(title: "Agents", action: "List", kind: .read)
        case "agent.get":
            return agentDefinition(title: "Agent", action: "Get", kind: .read)
        case "agent.message":
            return agentDefinition(title: "Agent", action: "Message", kind: .communicate)
        case "agent.wait":
            return agentDefinition(title: "Agent", action: "Wait", kind: .read)
        case "agent.close":
            return agentDefinition(title: "Agent", action: "Close", kind: .delete)

        // MARK: Prompt skills
        case "skills.list":
            return .standard(
                title: "Prompt skills",
                action: "List",
                kind: .read,
                includesParameters: false
            )
        case "skills.read":
            return .standard(
                title: "Prompt skill",
                action: "Read",
                kind: .read,
                targetKeyPaths: ["identifier"]
            )
        default:
            return nil
        }
    }

    private static func resultSummary() -> ToolPresentationSummaryDefinition {
        ToolPresentationSummaryDefinition(
            value: .resultSummary(),
            strategy: .firstLine,
            label: "summary"
        )
    }

    private static func searchDefinition(
        title: String,
        action: String,
        targetKeys: [String]
    ) -> ToolPresentationDefinition {
        .standard(
            title: title,
            action: action,
            kind: .search,
            targetKeyPaths: targetKeys
        )
    }

    private static func swiftDefinition(
        title: String,
        action: String,
        targetKeys: [String] = ["target", "product", "path", "workingDirectory", "cwd"]
    ) -> ToolPresentationDefinition {
        .standard(
            title: title,
            action: action,
            kind: .execute,
            targetKeyPaths: targetKeys
        )
    }

    private static func gitDefinition(
        title: String,
        action: String,
        kind: ToolPresentationKind = .read,
        targetKeys: [String] = ["path", "workingDirectory", "cwd"]
    ) -> ToolPresentationDefinition {
        .standard(
            title: title,
            action: action,
            kind: kind,
            targetKeyPaths: targetKeys
        )
    }

    private static func featureDefinition(
        title: String,
        action: String,
        kind: ToolPresentationKind
    ) -> ToolPresentationDefinition {
        .standard(
            title: title,
            action: action,
            kind: kind,
            targetKeyPaths: ["id", "featureID", "feature_id", "name"]
        )
    }

    private static func taskDefinition(
        title: String,
        action: String,
        kind: ToolPresentationKind
    ) -> ToolPresentationDefinition {
        .standard(
            title: title,
            action: action,
            kind: kind,
            targetKeyPaths: ["id", "taskID", "task_id", "graphID", "graph_id", "title", "name"]
        )
    }

    private static func agentDefinition(
        title: String,
        action: String,
        kind: ToolPresentationKind
    ) -> ToolPresentationDefinition {
        .standard(
            title: title,
            action: action,
            kind: kind,
            targetKeyPaths: ["name", "agent", "id", "taskID", "task_id"]
        )
    }

    private static func browserDefinition(
        for name: String
    ) -> ToolPresentationDefinition {
        let targetKeys = [
            "url", "query", "pageId", "page_id", "ref", "condition",
            "action", "baselinePath", "baseline_path", "candidatePath",
            "candidate_path"
        ]
        let (title, action, kind): (String, String, ToolPresentationKind)
        switch name {
        case "browser.google_search":
            (title, action, kind) = ("Browser search", "Search", .search)
        case "browser.visit_page", "browser.goto":
            (title, action, kind) = ("Web page", "Visit", .read)
        case "browser.open":
            (title, action, kind) = ("Browser page", "Open", .create)
        case "browser.close_page":
            (title, action, kind) = ("Browser page", "Close", .delete)
        case "browser.reset_state":
            (title, action, kind) = ("Browser state", "Reset", .delete)
        case "browser.act", "browser.dialog":
            (title, action, kind) = ("Browser action", "Perform", .execute)
        case "browser.screenshot", "browser.print_pdf":
            (title, action, kind) = ("Browser artifact", "Capture", .create)
        case "browser.wait", "browser.wait_element":
            (title, action, kind) = ("Browser condition", "Wait", .read)
        case "browser.assert", "browser.assert_element":
            (title, action, kind) = ("Browser condition", "Assert", .inspect)
        case "browser.pages", "browser.read", "browser.snapshot", "browser.console":
            (title, action, kind) = ("Browser page", "Read", .read)
        default:
            (title, action, kind) = ("Browser", "Inspect", .inspect)
        }
        return .standard(
            title: title,
            action: action,
            kind: kind,
            targetKeyPaths: targetKeys,
            targetFormat: name == "browser.visit_page" || name == "browser.goto"
                ? .url
                : .text
        )
    }

    private static func jiraDefinition(
        for name: String
    ) -> ToolPresentationDefinition {
        switch name {
        case "jira.search":
            return .standard(
                title: "Jira issues",
                action: "Search",
                kind: .search,
                targetKeyPaths: ["query"]
            )
        case "jira.read":
            return .standard(
                title: "Jira issue",
                action: "Read",
                kind: .read,
                targetKeyPaths: ["issueKey", "issue_key", "key", "url", "query"]
            )
        default:
            return .standard(
                title: "Jira account",
                action: "Sign out",
                kind: .manage,
                includesParameters: false
            )
        }
    }
}
