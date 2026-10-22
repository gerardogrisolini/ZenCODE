import Foundation
import FeatureKit
import ToolCore

struct GitAddTool: FeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let paths: [String]?
        let all: Bool?
    }

    static let name = "git.add"
    static let description = "Stages files for commit. Pass paths or all=true."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.array("paths"), .boolean("all")]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["add"]
        if input.all == true {
            args.append("-A")
        } else {
            let paths = input.paths ?? input.path.map { [$0] } ?? []
            guard !paths.isEmpty else { throw GitToolsFeatureError.missingArgument("paths") }
            args.append("--")
            args.append(contentsOf: paths)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitRestoreTool: FeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let paths: [String]?
        let staged: Bool?
        let worktree: Bool?
        let discardChanges: Bool?
    }

    static let name = "git.restore"
    static let description = "Unstages files with staged=true, or discards worktree changes only when worktree=true and discardChanges=true."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.array("paths"), .boolean("staged"), .boolean("worktree"), .boolean("discardChanges")]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let staged = input.staged == true
        let worktree = input.worktree == true
        guard staged || worktree else { throw GitToolsFeatureError.missingArgument("staged or worktree") }
        if worktree && input.discardChanges != true {
            throw GitToolsFeatureError.permissionDenied("Refusing to discard worktree changes without discardChanges=true.")
        }
        var args = ["restore"]
        if staged {
            args.append("--staged")
        }
        if worktree {
            args.append("--worktree")
        }
        args.append("--")
        args.append(contentsOf: input.paths ?? input.path.map { [$0] } ?? ["."])
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitCommitTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let message: String?
        let all: Bool?
    }

    static let name = "git.commit"
    static let description = "Creates a git commit from staged changes. Pass message for the commit message."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("message"), .boolean("all")],
        required: ["message"]
    )

    static func arguments(for input: Input) throws -> [String] {
        guard let message = input.message?.nilIfBlank else { throw GitToolsFeatureError.missingArgument("message") }
        var args = ["commit"]
        if input.all == true {
            args.append("-a")
        }
        // `-m` takes the next argv element verbatim, so a message starting with
        // `-` is never parsed as an option.
        args.append(contentsOf: ["-m", message])
        return args
    }
}

struct GitPushTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let remote: String?
        let branch: String?
        let refspec: String?
        let setUpstream: Bool?
        let set_upstream: Bool?
        let forceWithLease: Bool?
        let force_with_lease: Bool?
        let tags: Bool?
        let dryRun: Bool?
        let dry_run: Bool?
    }

    static let name = "git.push"
    static let description = "Pushes commits to a remote. Supports remote, branch/refspec, setUpstream, forceWithLease, tags, and dryRun."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("remote"), .string("branch"), .string("refspec"),
               .boolean("setUpstream"), .boolean("set_upstream"),
               .boolean("forceWithLease"), .boolean("force_with_lease"),
               .boolean("tags"), .boolean("dryRun"), .boolean("dry_run")]
    )

    static func arguments(for input: Input) throws -> [String] {
        let setUpstream = input.setUpstream == true || input.set_upstream == true
        let remote = try input.remote?.nilIfBlank.map { try GitToolsSupport.remote($0) }
        let branchOrRefspec = try firstNonBlank(input.branch, input.refspec)
            .map { try GitToolsSupport.refspec($0, named: "branch") }
        if setUpstream && (remote == nil || branchOrRefspec == nil) {
            throw GitToolsFeatureError.missingArgument("remote and branch")
        }

        var args = ["push"]
        if input.dryRun == true || input.dry_run == true {
            args.append("--dry-run")
        }
        if setUpstream {
            args.append("--set-upstream")
        }
        if input.forceWithLease == true || input.force_with_lease == true {
            args.append("--force-with-lease")
        }
        if input.tags == true {
            args.append("--tags")
        }
        if let remote {
            args.append(remote)
        }
        if let branchOrRefspec {
            args.append(branchOrRefspec)
        }
        return args
    }
}

struct GitFetchTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let remote: String?
        let branch: String?
        let refspec: String?
        let all: Bool?
        let prune: Bool?
        let tags: Bool?
    }

    static let name = "git.fetch"
    static let description = "Fetches objects and refs from a remote without merging. Supports remote, branch/refspec, all, prune, and tags."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("remote"), .string("branch"), .string("refspec"),
               .boolean("all"), .boolean("prune"), .boolean("tags")]
    )

    static func arguments(for input: Input) throws -> [String] {
        var args = ["fetch"]
        if input.all == true {
            args.append("--all")
        }
        if input.prune == true {
            args.append("--prune")
        }
        if input.tags == true {
            args.append("--tags")
        }
        if input.all != true {
            try GitToolsSupport.appendRemote(to: &args, remote: input.remote, branch: input.branch, refspec: input.refspec)
        }
        return args
    }
}

struct GitPullTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let remote: String?
        let branch: String?
        let refspec: String?
        let rebase: Bool?
        let ffOnly: Bool?
        let ff_only: Bool?
        let allowUnrelatedHistories: Bool?
        let allow_unrelated_histories: Bool?
    }

    static let name = "git.pull"
    static let description = "Fetches and integrates changes from a remote. Defaults to --ff-only for safety; set rebase=true to rebase or ffOnly=false to allow a merge commit."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("remote"), .string("branch"), .string("refspec"),
               .boolean("rebase"), .boolean("ffOnly"), .boolean("ff_only"),
               .boolean("allowUnrelatedHistories"), .boolean("allow_unrelated_histories")]
    )

    static func arguments(for input: Input) throws -> [String] {
        var args = ["pull"]
        let rebase = input.rebase == true
        // Default to a fast-forward-only pull unless the caller opts out or rebases.
        let ffOnly = input.ffOnly ?? input.ff_only ?? !rebase
        if rebase {
            args.append("--rebase")
        } else if ffOnly {
            args.append("--ff-only")
        }
        if input.allowUnrelatedHistories == true || input.allow_unrelated_histories == true {
            args.append("--allow-unrelated-histories")
        }
        try GitToolsSupport.appendRemote(to: &args, remote: input.remote, branch: input.branch, refspec: input.refspec)
        return args
    }
}

struct GitStashTool: FeatureTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let action: String?
        let message: String?
        let stash: String?
        let includeUntracked: Bool?
        let paths: [String]?
    }

    static let name = "git.stash"
    static let description = "Runs git stash list/show/push/apply/pop/drop with structured arguments."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("action"), .string("message"), .string("stash"),
               .boolean("includeUntracked"), .array("paths")]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let action = (input.action?.nilIfBlank ?? "list").lowercased()
        let args = try GitToolsSupport.gitStashArguments(action: action, input: input)
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitSwitchTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let branch: String?
        let create: Bool?
    }

    static let name = "git.switch"
    static let description = "Switches branches, optionally creating the branch when create=true."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.string("branch"), .boolean("create")],
        required: ["branch"]
    )

    static func arguments(for input: Input) throws -> [String] {
        guard let branch = input.branch?.nilIfBlank else { throw GitToolsFeatureError.missingArgument("branch") }
        var args = ["switch"]
        if input.create == true {
            args.append("-c")
        }
        args.append(try GitToolsSupport.positional(branch, named: "branch"))
        return args
    }
}
