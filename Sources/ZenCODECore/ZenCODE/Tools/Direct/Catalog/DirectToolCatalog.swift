//
//  DirectToolCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct DirectToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: String

    public init(
        name: String,
        description: String,
        inputSchema: String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum DirectToolCatalog {
    private static let taskExecutionSchema = #"{"type":"object","properties":{"executor":{"type":"string","enum":["coordinator","sub_agent"]},"profile":{"type":"string"},"role":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}},"tool_names":{"type":"array","items":{"type":"string"}},"fileScopes":{"type":"array","items":{"type":"string"}},"file_scopes":{"type":"array","items":{"type":"string"}}}}"#

    private static let taskDefinitionSchema = #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"order":{"type":"integer"},"priority":{"type":"string","enum":["low","normal","high"]},"complexity":{"type":"integer","minimum":1,"maximum":10},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"acceptanceCriteria":{"type":"array","items":{"type":"string"}},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"execution":\#(taskExecutionSchema)}}"#

    public static var baseDescriptors: [DirectToolDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        coreLocalFileAndTextDescriptors + coreProcessDescriptors + skillToolDescriptors + featureDescriptors + memoryDescriptors + todoTaskDescriptors + subAgentDescriptors
#else
        coreLocalFileAndTextDescriptors + skillToolDescriptors + featureDescriptors + memoryDescriptors + todoTaskDescriptors + subAgentDescriptors
#endif
    }

    /// Intrinsic, always-on prompt-skill tools (`skills.list`, `skills.read`).
    /// They are not user-selectable from `/tools` and remain available even when
    /// every user tool group is disabled.
    public static var skillToolDescriptors: [DirectToolDescriptor] {
        PromptSkillToolProvider.descriptors
    }

    public static var selectableDescriptors: [DirectToolDescriptor] {
        baseDescriptors
    }

    public static var coreLocalFileAndTextDescriptors: [DirectToolDescriptor] {
        filesystemDescriptors.filter {
            $0.name.hasPrefix("local.")
                || $0.name.hasPrefix("text.")
        }
    }

    public static var localSearchDescriptors: [DirectToolDescriptor] {
        filesystemDescriptors.filter {
            $0.name.hasPrefix("search.")
        }
    }

    public static let filesystemDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "local.pwd",
            description: "Returns the current working directory used by local tools.",
            inputSchema: #"{"type":"object","properties":{}}"#
        ),
        DirectToolDescriptor(
            name: "local.ls",
            description: "Lists files and directories. Paths may be absolute or relative to the working directory.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"includeHidden":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "local.readFile",
            description: "Reads a UTF-8 text file with line numbers. Use offset and limit for focused reads.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "local.readFiles",
            description: "Reads multiple UTF-8 text files in one call. Each file is returned with a header and line numbers. Use offset and limit for focused reads applied to every file.",
            inputSchema: #"{"type":"object","properties":{"paths":{"type":"array","items":{"type":"string"}},"file_paths":{"type":"array","items":{"type":"string"}},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["paths"]}"#
        ),
        DirectToolDescriptor(
            name: "local.inspectFile",
            description: "Returns compact file metadata, suggested read ranges, and symbol-like outline entries without returning the full file contents.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"maxSymbols":{"type":"number"},"max_symbols":{"type":"number"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "search.glob",
            description: "Finds files under a local path. Pass pattern for a glob such as **/*.swift; omit pattern to list files recursively.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "search.locate",
            description: "Locates text matches compactly and returns file:line snippets plus local.readFile suggestions for focused follow-up reads.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"}},"required":["pattern"]}"#
        ),
        DirectToolDescriptor(
            name: "text.head",
            description: "Reads the first lines of a local text file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "text.tail",
            description: "Reads the last lines of a local text file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "text.sort",
            description: "Sorts the lines of a local text file and returns the sorted output.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"unique":{"type":"boolean"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "text.wc",
            description: "Counts lines, words, and characters in a local text file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "local.writeFile",
            description: "Creates or overwrites a UTF-8 text file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"content":{"type":"string"},"createDirectories":{"type":"boolean"}},"required":["path","content"]}"#
        ),
        DirectToolDescriptor(
            name: "local.replace",
            description: "Replaces all occurrences of oldString with newString in a UTF-8 text file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"}},"required":["path","oldString","newString"]}"#
        ),
        DirectToolDescriptor(
            name: "local.editFile",
            description: "Applies a targeted string replacement in a file. By default exactly one occurrence must match; set replaceAll=true to update every occurrence.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}},"required":["path","oldString","newString"]}"#
        ),
        DirectToolDescriptor(
            name: "local.multiEdit",
            description: "Applies multiple targeted edits to the same file in order.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}}}}},"required":["path","edits"]}"#
        ),
        DirectToolDescriptor(
            name: "local.append",
            description: "Appends UTF-8 text to a file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#
        ),
        DirectToolDescriptor(
            name: "local.mkdir",
            description: "Creates a directory.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"createIntermediateDirectories":{"type":"boolean"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "local.delete",
            description: "Deletes a file or directory. Directories require recursive=true.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "local.move",
            description: "Moves or renames a file or directory.",
            inputSchema: #"{"type":"object","properties":{"sourcePath":{"type":"string"},"destinationPath":{"type":"string"},"overwriteExisting":{"type":"boolean"}},"required":["sourcePath","destinationPath"]}"#
        ),
        DirectToolDescriptor(
            name: "local.applyPatch",
            description: "Applies a unified diff that may span multiple files. All hunks are validated in memory first and written atomically: if any hunk fails to match, no file is changed.",
            inputSchema: #"{"type":"object","properties":{"patch":{"type":"string"},"diff":{"type":"string"}},"required":["patch"]}"#
        )
    ]

    public static let memoryDescriptors: [DirectToolDescriptor] = MemoryTool.toolDescriptors.map(DirectToolDescriptor.init)

    public static let webDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "web.search",
            description: "Searches the public web and returns matching results with titles, URLs, and snippets.",
            inputSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"number"},"domains":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#
        ),
        DirectToolDescriptor(
            name: "web.fetch",
            description: "Opens an HTTP or HTTPS URL. On Apple platforms it renders the page in a silent in-process WebKit view (JavaScript executed) and returns extracted Markdown; on other platforms it falls back to a raw HTTP fetch preview.",
            inputSchema: #"{"type":"object","properties":{"url":{"type":"string"},"maxBytes":{"type":"number"},"timeoutSeconds":{"type":"number"}},"required":["url"]}"#
        )
    ]

    public static let swiftDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "swift.build",
            description: "Builds a SwiftPM package with `swift build` and returns a structured summary of errors and warnings instead of raw output.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"target":{"type":"string"},"product":{"type":"string"},"configuration":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "swift.test",
            description: "Runs SwiftPM tests with `swift test` and returns a structured summary of failing tests and build errors instead of raw output.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"filter":{"type":"string"},"target":{"type":"string"},"configuration":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "swift.run",
            description: "Builds if needed and runs an executable product of a SwiftPM package with `swift run`. Pass executable and optional arguments. Returns build diagnostics plus the program output.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"executable":{"type":"string"},"product":{"type":"string"},"configuration":{"type":"string"},"arguments":{"type":"array","items":{"type":"string"}},"args":{"type":"array","items":{"type":"string"}},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "swift.package",
            description: "Runs `swift package` subcommands. action is one of: resolve, update, clean, reset, describe, dump-package. describe and dump-package report targets, products, and dependencies without reading Package.swift by hand.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"action":{"type":"string","enum":["resolve","update","clean","reset","describe","dump-package"]},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "swift.outline",
            description: "Returns a compact outline of Swift declarations in a source file without returning the full file contents.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"maxSymbols":{"type":"number"},"max_symbols":{"type":"number"}},"required":["path"]}"#
        )
    ]

    public static let featureDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "feature.list",
            description: "Lists Swift feature bundles known to the kernel, including bundled and generated features plus enabled status.",
            inputSchema: #"{"type":"object","properties":{"includeTools":{"type":"boolean"},"include_tools":{"type":"boolean"},"includeDisabled":{"type":"boolean"},"include_disabled":{"type":"boolean"},"discoverRuntimeTools":{"type":"boolean"},"discover_runtime_tools":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "feature.enable",
            description: "Enables a Swift feature bundle by id and reloads the feature runtime.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "feature.disable",
            description: "Disables a Swift feature bundle by id and reloads the feature runtime.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "feature.delete",
            description: "Deletes a generated Swift feature package by id and reloads the feature runtime. Bundled features cannot be deleted directly.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "feature.edit",
            description: "Prepares an editable Swift feature package context. Generated features are opened directly; bundled features are copied into the generated feature root first.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"overwrite":{"type":"boolean"},"enabled":{"type":"boolean"},"sourcePath":{"type":"string"},"source_path":{"type":"string"},"zenPackagePath":{"type":"string"},"zen_package_path":{"type":"string"},"dependencyPath":{"type":"string"},"dependency_path":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "feature.reload",
            description: "Reloads Swift feature bundles from bundled executables and generated feature manifests.",
            inputSchema: #"{"type":"object","properties":{"includeTools":{"type":"boolean"},"include_tools":{"type":"boolean"},"includeDisabled":{"type":"boolean"},"include_disabled":{"type":"boolean"},"discoverRuntimeTools":{"type":"boolean"},"discover_runtime_tools":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "feature.validate",
            description: "Validates a generated Swift feature manifest, tool names, executable state, and SwiftPM package tools version.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "feature.build",
            description: "Builds a generated Swift feature package with SwiftPM and reloads the feature runtime when the executable is produced.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "feature.scaffold",
            description: "Creates a Swift 6.3 SwiftPM feature package scaffold under the generated features directory. Use template=mcp-bridge for MCP service bridges. Pass build=true and/or enable=true to validate, build, and enable the package in one call.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"template":{"type":"string","enum":["basic","mcp-bridge"]},"kind":{"type":"string"},"displayName":{"type":"string"},"display_name":{"type":"string"},"serviceName":{"type":"string"},"service_name":{"type":"string"},"description":{"type":"string"},"toolName":{"type":"string"},"tool_name":{"type":"string"},"toolPrefix":{"type":"string"},"tool_prefix":{"type":"string"},"prefix":{"type":"string"},"endpointURL":{"type":"string"},"endpoint_url":{"type":"string"},"url":{"type":"string"},"executablePath":{"type":"string"},"executable_path":{"type":"string"},"command":{"type":"string"},"arguments":{"type":["array","string"],"items":{"type":"string"}},"args":{"type":["array","string"],"items":{"type":"string"}},"environment":{"type":"object","additionalProperties":{"type":"string"}},"env":{"type":"object","additionalProperties":{"type":"string"}},"dependencyPath":{"type":"string"},"dependency_path":{"type":"string"},"path":{"type":"string"},"directory":{"type":"string"},"directoryPath":{"type":"string"},"directory_path":{"type":"string"},"enabled":{"type":"boolean"},"overwrite":{"type":"boolean"},"build":{"type":"boolean"},"enable":{"type":"boolean"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "feature.install",
            description: "Installs a generated Swift feature package into the ZenCODE feature root, optionally building and enabling it.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"directory":{"type":"string"},"directoryPath":{"type":"string"},"directory_path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"},"overwrite":{"type":"boolean"},"build":{"type":"boolean"},"enable":{"type":"boolean"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        )
    ]

#if canImport(Darwin) || canImport(Glibc)
    public static var coreProcessDescriptors: [DirectToolDescriptor] {
        macOSProcessDescriptors.filter {
            $0.name == "local.exec" || $0.name == "exec.job"
        }
    }

    public static let macOSProcessDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "search.grep",
            description: "Searches text with grep from a local path. Use context for surrounding lines and filesOnly to list only matching file paths. VCS and build directories (.git, .build, .swiftpm, node_modules, DerivedData) are skipped.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"},"filesOnly":{"type":"boolean"},"files_only":{"type":"boolean"}},"required":["pattern"]}"#
        ),
        DirectToolDescriptor(
            name: "local.exec",
            description: "Runs a shell command in the working directory and returns stdout, stderr, and exit code. Set background=true to start a long-running command (dev server, watcher, tail) as a background job and return its job id immediately; manage it with exec.job. Reserve this for commands not covered by dedicated file, text, search, Git, web, Xcode, Figma, memory, or feature tools.",
            inputSchema: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"workingDirectory":{"type":"string"},"background":{"type":"boolean","description":"Start the command as a background job and return a job id immediately."},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}},"required":["command"]}"#
        ),
        DirectToolDescriptor(
            name: "exec.job",
            description: "Manages background jobs started by local.exec with background=true. action=poll returns job status plus new output since offset; action=kill terminates a job; action=list lists known jobs.",
            inputSchema: #"{"type":"object","properties":{"action":{"type":"string","enum":["poll","kill","list"]},"id":{"type":"string"},"jobID":{"type":"string"},"job_id":{"type":"string"},"offset":{"type":"number","description":"Byte offset returned by the previous poll; only newer output is returned."}},"required":["action"]}"#
        ),
        DirectToolDescriptor(
            name: "git.status",
            description: "Runs git status --short --branch in the working directory.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.diff",
            description: "Runs git diff. Pass staged=true for --staged.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"staged":{"type":"boolean"},"cached":{"type":"boolean"},"file":{"type":"string"},"file_path":{"type":"string"},"baseRevision":{"type":"string"},"base_revision":{"type":"string"},"base":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.show",
            description: "Runs git show for a revision or object.",
            inputSchema: #"{"type":"object","properties":{"revision":{"type":"string"},"rev":{"type":"string"},"commit":{"type":"string"},"path":{"type":"string"},"file_path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.log",
            description: "Runs git log --oneline.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"limit":{"type":"number"},"n":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.branch",
            description: "Lists local, remote, or all branches.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"all":{"type":"boolean"},"remotes":{"type":"boolean"},"contains":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.remote",
            description: "Lists configured remotes and URLs.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.lsFiles",
            description: "Lists tracked files, optionally including untracked files that are not ignored.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"includeUntracked":{"type":"boolean"},"maxResults":{"type":"number"},"max_results":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.grep",
            description: "Searches tracked repository files with git grep. Use context for surrounding lines and filesOnly to list only matching file paths.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"},"filesOnly":{"type":"boolean"},"files_only":{"type":"boolean"}},"required":["pattern"]}"#
        ),
        DirectToolDescriptor(
            name: "git.blame",
            description: "Shows git blame for a file, optionally scoped to a line range.",
            inputSchema: #"{"type":"object","properties":{"file":{"type":"string"},"path":{"type":"string"},"file_path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"startLine":{"type":"number"},"endLine":{"type":"number"}},"required":["file"]}"#
        ),
        DirectToolDescriptor(
            name: "git.add",
            description: "Stages files for commit. Pass paths or all=true.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"all":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.restore",
            description: "Unstages files with staged=true, or discards worktree changes only when worktree=true and discardChanges=true.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"staged":{"type":"boolean"},"worktree":{"type":"boolean"},"discardChanges":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.commit",
            description: "Creates a git commit from staged changes. Pass message for the commit message.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"message":{"type":"string"},"all":{"type":"boolean"}},"required":["message"]}"#
        ),
        DirectToolDescriptor(
            name: "git.push",
            description: "Pushes commits to a remote. Supports remote, branch/refspec, setUpstream, forceWithLease, tags, and dryRun.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"remote":{"type":"string"},"branch":{"type":"string"},"refspec":{"type":"string"},"setUpstream":{"type":"boolean"},"set_upstream":{"type":"boolean"},"forceWithLease":{"type":"boolean"},"force_with_lease":{"type":"boolean"},"tags":{"type":"boolean"},"dryRun":{"type":"boolean"},"dry_run":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.fetch",
            description: "Fetches objects and refs from a remote without merging. Supports remote, branch/refspec, all, prune, and tags.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"remote":{"type":"string"},"branch":{"type":"string"},"refspec":{"type":"string"},"all":{"type":"boolean"},"prune":{"type":"boolean"},"tags":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.pull",
            description: "Fetches and integrates changes from a remote. Defaults to --ff-only for safety; set rebase=true to rebase or ffOnly=false to allow a merge commit.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"remote":{"type":"string"},"branch":{"type":"string"},"refspec":{"type":"string"},"rebase":{"type":"boolean"},"ffOnly":{"type":"boolean"},"ff_only":{"type":"boolean"},"allowUnrelatedHistories":{"type":"boolean"},"allow_unrelated_histories":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.stash",
            description: "Runs git stash list/show/push/apply/pop/drop with structured arguments.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"action":{"type":"string"},"message":{"type":"string"},"stash":{"type":"string"},"includeUntracked":{"type":"boolean"},"paths":{"type":"array","items":{"type":"string"}}}}"#
        ),
        DirectToolDescriptor(
            name: "git.switch",
            description: "Switches branches, optionally creating the branch when create=true.",
            inputSchema: #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"branch":{"type":"string"},"create":{"type":"boolean"}},"required":["branch"]}"#
        )
    ]
#endif

    public static let todoTaskDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "todo.read",
            description: "Returns the session todo list.",
            inputSchema: #"{"type":"object","properties":{}}"#
        ),
        DirectToolDescriptor(
            name: "todo.write",
            description: "Creates or updates the session todo list. Supports replace, append, and upsert modes.",
            inputSchema: #"{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}}},"required":["content"]}},"items":{"type":"array","items":{"type":"object"}},"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"mode":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "tasks.create",
            description: "Atomically creates one or more tasks in the session task graph. Dependencies must reference tasks in the same graph. Model true prerequisites as edges, leave independent tasks dependency-free, and prefer safe, useful parallelism over list-order sequencing. In a /workflow graph, every task must declare execution.executor as sub_agent and is then claimed atomically through agent.create(taskID:).",
            inputSchema: #"{"type":"object","properties":{"graphID":{"type":"string"},"graph_id":{"type":"string"},"id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"order":{"type":"integer"},"priority":{"type":"string","enum":["low","normal","high"]},"complexity":{"type":"integer","minimum":1,"maximum":10,"description":"Task difficulty 1-10. \#(TaskRecord.complexityRubric). Agent selection policy: \#(TaskRecord.agentSelectionPolicy)"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"acceptanceCriteria":{"type":"array","items":{"type":"string"}},"acceptance_criteria":{"type":"array","items":{"type":"string"}},"execution":\#(taskExecutionSchema),"tasks":{"type":"array","items":\#(taskDefinitionSchema)},"items":{"type":"array","items":\#(taskDefinitionSchema)}}}"#
        ),
        DirectToolDescriptor(
            name: "tasks.list",
            description: "Lists task graph records with derived runnable and dependency state.",
            inputSchema: #"{"type":"object","properties":{"graphID":{"type":"string"},"graph_id":{"type":"string"},"status":{"type":"string"},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"agentID":{"type":"string"},"agent_id":{"type":"string"},"runnableOnly":{"type":"boolean"},"runnable_only":{"type":"boolean"},"includeTerminal":{"type":"boolean"},"include_terminal":{"type":"boolean"},"limit":{"type":"integer"}}}"#
        ),
        DirectToolDescriptor(
            name: "tasks.get",
            description: "Returns one task with dependencies, dependents, attempts, results, evidence, and runnable reason.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "tasks.update",
            description: "Updates task metadata, progress, result, evidence, or an allowed lifecycle transition. Use tasks.retry and tasks.cancel for those operations.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":["string","null"]},"description":{"type":["string","null"]},"status":{"type":"string"},"statusReason":{"type":"string"},"status_reason":{"type":"string"},"priority":{"type":"string"},"complexity":{"type":"integer","minimum":1,"maximum":10,"description":"Task difficulty 1-10. \#(TaskRecord.complexityRubric). Agent selection policy: \#(TaskRecord.agentSelectionPolicy)"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"output":{"type":"string"},"progress":{"type":"string"},"error":{"type":"string"},"evidence":{"type":"array","items":{}},"expectedRevision":{"type":"integer"},"expected_revision":{"type":"integer"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "tasks.retry",
            description: "Retries a failed or blocked task while preserving all prior attempts and outputs. A retried /workflow task must be claimed through a new agent.create(taskID:); do not reopen its completed attempt with agent.message.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"expectedRevision":{"type":"integer"},"expected_revision":{"type":"integer"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "tasks.cancel",
            description: "Cancels a task and its active attempt.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"graphID":{"type":"string"},"graph_id":{"type":"string"},"reason":{"type":"string"}},"required":["id"]}"#
        )
    ]

    public static let subAgentDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "agent.create",
            description: "Creates up to 8 delegated sub-agents; independent sub-agents run in parallel. For coordinated work, define the session task graph first and pass taskID to atomically claim each runnable task and record a fenced execution attempt. A taskID is required while a task graph is active and for parallel or concurrent delegation when task workflow tools are available. A single self-contained delegation may omit taskID. Agent selection policy: \(TaskRecord.agentSelectionPolicy) Pass profile (or agent) to run the sub-agent with one of the agent profiles from agents.json, matched by name, role, or profile. When a profile has model bindings, pass model/modelID only to select one of that profile's authorized bindings; an unbound model is rejected. Otherwise the sub-agent uses the session's model. Give each sub-agent an explicit role and scope. A resolved profile grants its configured tools to the sub-agent, and toolNames can only narrow that grant. Only when no profile resolves does the sub-agent inherit the parent session's enabled tools, again narrowed by toolNames. Task-bound children also receive intrinsic tasks.list, tasks.get, and tasks.update tools for attempt reporting.",
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"model":{"type":"string"},"modelID":{"type":"string"},"model_id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}},"agents":{"type":"array","maxItems":8,"items":{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"model":{"type":"string"},"modelID":{"type":"string"},"model_id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}}}}},"items":{"type":"array","items":{"type":"object"}}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.list",
            description: "Lists delegated sub-agents, optionally filtered by status.",
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.get",
            description: "Returns status and latest output for delegated sub-agents. Reference an agent by id, name, task_id, or ids.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.message",
            description: "Queues a follow-up prompt for one or more delegated sub-agents. Reference an agent by id, name, task_id, or ids. Do not use it to reopen a completed /workflow task: record negative validation as failure, call tasks.retry, then use a new agent.create(taskID:).",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"message":{"type":"string"},"prompt":{"type":"string"},"input":{"type":"string"}},"required":["message"]}"#
        ),
        DirectToolDescriptor(
            name: "agent.wait",
            description: "Waits until delegated sub-agents finish their pending work or a timeout elapses.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"timeoutSeconds":{"type":"number"},"pollIntervalSeconds":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.close",
            description: "Closes a delegated sub-agent and cancels pending work.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"}}}"#
        )
    ]

}

extension DirectToolDescriptor {
    public init(toolDescriptor: ToolDescriptor) {
        self.init(
            name: toolDescriptor.name,
            description: toolDescriptor.description,
            inputSchema: toolDescriptor.inputSchema
        )
    }

    public var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
    }

    public var schemaObject: Any? {
        guard let data = inputSchema.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data).jsonObject
    }
}

public struct AgentToolProviderRegistry: Sendable {
    public var providers: [AgentToolProvider] = []

    public mutating func update(_ providers: [AgentToolProvider]) {
        self.providers = providers
    }

    public var descriptors: [DirectToolDescriptor] {
        ToolDescriptor.canonicalized(providers.flatMap(\.tools)).map(DirectToolDescriptor.init)
    }

    public func executor(for toolName: String) -> AgentToolExecutor? {
        for provider in providers where provider.tools.contains(where: { $0.name == toolName }) {
            return provider.executor
        }
        return nil
    }
}
