import Foundation
import FeatureKit
import ToolCore

struct GitStatusTool: FeatureTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
    }

    static let name = "git.status"
    static let description = "Runs git status --short --branch in the working directory."
    static let inputSchema = buildInputSchema(CommonSchemaProperties.workingDirectory)

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try await GitToolsSupport.runGit(["status", "--short", "--branch"], input: input, context: context)
    }
}

struct GitDiffTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let staged: Bool?
        let cached: Bool?
        let file: String?
        let file_path: String?
        let filePath: String?
        let baseRevision: String?
        let base_revision: String?
        let base: String?
    }

    static let name = "git.diff"
    static let description = "Runs git diff. Pass staged=true for --staged."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + CommonSchemaProperties.staged
            + [.string("file"), .string("file_path")]
            + CommonSchemaProperties.baseRevision
    )

    static func arguments(for input: Input) throws -> [String] {
        var args = ["diff"]
        if input.staged == true || input.cached == true {
            args.append("--cached")
        }
        if let baseRevision = firstNonBlank(input.baseRevision, input.base_revision, input.base) {
            args.append(try GitToolsSupport.positional(baseRevision, named: "baseRevision"))
        }
        if let file = firstNonBlank(input.file, input.file_path, input.filePath, input.path) {
            args.append("--")
            args.append(file)
        }
        return args
    }
}

struct GitShowTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let revision: String?
        let rev: String?
        let commit: String?
        let file: String?
        let file_path: String?
        let filePath: String?
    }

    static let name = "git.show"
    static let description = "Runs git show for a revision or object."
    static let inputSchema = buildInputSchema(
        [.string("revision"), .string("rev"), .string("commit")]
            + CommonSchemaProperties.pathAliases
            + [.string("workingDirectory")]
    )

    static func arguments(for input: Input) throws -> [String] {
        let revision = try GitToolsSupport.positional(
            firstNonBlank(input.revision, input.rev, input.commit) ?? "HEAD",
            named: "revision"
        )
        var args = ["show", revision]
        if let file = firstNonBlank(input.file, input.file_path, input.filePath, input.path) {
            args.append("--")
            args.append(file)
        }
        return args
    }
}

struct GitLogTool: FeatureTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let limit: Int?
        let n: Int?
    }

    static let name = "git.log"
    static let description = "Runs git log --oneline."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.number("limit"), .number("n")]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let limit = max(1, min(input.limit ?? input.n ?? 20, 200))
        return try await GitToolsSupport.runGit(["log", "--oneline", "-n", "\(limit)"], input: input, context: context)
    }
}

struct GitBranchTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let all: Bool?
        let remotes: Bool?
        let contains: String?
    }

    static let name = "git.branch"
    static let description = "Lists local, remote, or all branches."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.boolean("all"), .boolean("remotes"), .string("contains")]
    )

    static func arguments(for input: Input) throws -> [String] {
        var args = ["branch"]
        if input.all == true {
            args.append("--all")
        } else if input.remotes == true {
            args.append("--remotes")
        }
        if let contains = input.contains?.nilIfBlank {
            args.append(contentsOf: ["--contains", try GitToolsSupport.positional(contains, named: "contains")])
        }
        return args
    }
}

struct GitRemoteTool: FeatureTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
    }

    static let name = "git.remote"
    static let description = "Lists configured remotes and URLs."
    static let inputSchema = buildInputSchema(CommonSchemaProperties.workingDirectory)

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        try await GitToolsSupport.runGit(["remote", "-v"], input: input, context: context)
    }
}

struct GitLsFilesTool: FeatureTool {
    struct Input: Decodable, Sendable, GitRepositoryDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let includeUntracked: Bool?
        let maxResults: Int?
        let max_results: Int?
    }

    static let name = "git.lsFiles"
    static let description = "Lists tracked files, optionally including untracked files that are not ignored."
    static let inputSchema = buildInputSchema(
        CommonSchemaProperties.workingDirectory
            + [.boolean("includeUntracked")]
            + CommonSchemaProperties.limit
    )

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        var args = ["ls-files"]
        if input.includeUntracked == true {
            args.append(contentsOf: ["--cached", "--others", "--exclude-standard"])
        }
        let result = try await GitToolsSupport.runGitResult(args, input: input, context: context)
        let maxResults = max(1, min(input.maxResults ?? input.max_results ?? 500, 10_000))
        return GitToolsSupport.renderLimitedStdout(result, maxLines: maxResults)
    }
}

struct GitGrepTool: FeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let pattern: String?
        let paths: [String]?
        let maxResults: Int?
        let max_results: Int?
        let context: Int?
        let filesOnly: Bool?
        let files_only: Bool?
    }

    static let name = "git.grep"
    static let description = "Searches tracked repository files with git grep. Use context for surrounding lines and filesOnly to list only matching file paths."
    static let inputSchema = buildInputSchema(
        [.string("pattern")]
            + CommonSchemaProperties.workingDirectory
            + [.array("paths")]
            + CommonSchemaProperties.limit
            + [.number("context"), .boolean("filesOnly"), .boolean("files_only")],
        required: ["pattern"]
    )

    static func arguments(for input: Input) throws -> [String] {
        guard let pattern = input.pattern?.nilIfBlank else { throw GitToolsFeatureError.missingArgument("pattern") }
        try GitToolsSupport.rejectControlCharacters(pattern, named: "pattern")
        let filesOnly = input.filesOnly ?? input.files_only ?? false
        var args: [String]
        if filesOnly {
            args = ["grep", "-I", "-l"]
        } else {
            // `maxResults` is enforced in `run` as a total cap on MATCH lines
            // (git's own `-m` is a per-file limit and only exists since git 2.38).
            // `-z --column` (git >= 2.19) lets `GitToolsSupport.renderLimitedGrep`
            // tell matches from context lines exactly, whatever the path contains:
            // with `-z` every separator is NUL, and the column is only printed on
            // match lines, so a match is `path\0LINE\0COLUMN\0text` and a context
            // line is `path\0LINE\0text`. The renderer restores the usual
            // `path:LINE:text` / `path-LINE-text` form.
            args = ["grep", "-n", "-I", "-z", "--column"]
            if let contextLines = input.context, contextLines > 0 {
                args.append(contentsOf: ["-C", "\(min(contextLines, 20))"])
            }
        }
        // `-e` keeps a pattern starting with `-` from being parsed as an option.
        args.append(contentsOf: ["-e", pattern])
        let paths = input.paths ?? input.path.map { [$0] } ?? []
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        return args
    }

    static func maxResults(for input: Input) -> Int {
        max(1, min(input.maxResults ?? input.max_results ?? 200, 10_000))
    }

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let result = try await GitToolsSupport.runGitResult(try Self.arguments(for: input), input: input, context: context)
        let maxResults = Self.maxResults(for: input)
        if input.filesOnly ?? input.files_only ?? false {
            return GitToolsSupport.renderLimitedStdout(result, maxLines: maxResults)
        }
        return GitToolsSupport.renderLimitedGrep(result, maxMatches: maxResults)
    }
}

struct GitBlameTool: GitArgumentTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let file: String?
        let file_path: String?
        let startLine: Int?
        let endLine: Int?
    }

    static let name = "git.blame"
    static let description = "Shows git blame for a file, optionally scoped to a line range."
    static let inputSchema = buildInputSchema(
        [.string("file"), .string("path"), .string("file_path"),
         .string("workingDirectory"),
         .number("startLine"), .number("endLine")],
        required: ["file"]
    )

    static func arguments(for input: Input) throws -> [String] {
        guard let file = firstNonBlank(input.file, input.path, input.file_path) else {
            throw GitToolsFeatureError.missingArgument("file")
        }
        var args = ["blame"]
        if let range = try lineRange(startLine: input.startLine, endLine: input.endLine) {
            args.append(contentsOf: ["-L", range])
        }
        args.append("--")
        args.append(file)
        return args
    }

    /// `-L` value for the requested bounds: `start,end`, an open `start,` or
    /// `,end` when only one bound is given, nil when none is. Line numbers are
    /// 1-based; a non-positive bound is rejected instead of being handed to git.
    static func lineRange(startLine: Int?, endLine: Int?) throws -> String? {
        for (name, value) in [("startLine", startLine), ("endLine", endLine)] {
            if let value, value < 1 {
                throw GitToolsFeatureError.permissionDenied("Argument '\(name)' must be a 1-based line number, got \(value).")
            }
        }
        switch (startLine, endLine) {
        case (nil, nil):
            return nil
        case let (start?, end?):
            return "\(start),\(end)"
        case let (start?, nil):
            return "\(start),"
        case let (nil, end?):
            return ",\(end)"
        }
    }
}
