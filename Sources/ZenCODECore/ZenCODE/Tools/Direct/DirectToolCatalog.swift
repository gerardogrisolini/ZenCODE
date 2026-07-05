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
    public static var baseDescriptors: [DirectToolDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        coreLocalFileAndTextDescriptors + coreProcessDescriptors + featureDescriptors + memoryDescriptors + orchestrationDescriptors + subAgentDescriptors
#else
        coreLocalFileAndTextDescriptors + featureDescriptors + memoryDescriptors + orchestrationDescriptors + subAgentDescriptors
#endif
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
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"content":{"type":"string"},"createDirectories":{"type":"boolean"}},"required":["file_path","content"]}"#
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

    public static let memoryDescriptors: [DirectToolDescriptor] = MemoryTool.toolDescriptors.map {
        DirectToolDescriptor(
            name: $0.name,
            description: $0.description,
            inputSchema: $0.inputSchema
        )
    }

    public static let webDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "web.search",
            description: "Searches the public web and returns matching results with titles, URLs, and snippets.",
            inputSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"number"},"domains":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#
        ),
        DirectToolDescriptor(
            name: "web.fetch",
            description: "Fetches an HTTP or HTTPS URL and returns response metadata plus a UTF-8 text preview.",
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
            description: "Creates a Swift 6.3 SwiftPM feature package scaffold under the generated features directory. Use template=mcp-bridge for MCP service bridges.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"template":{"type":"string","enum":["basic","mcp-bridge"]},"kind":{"type":"string"},"displayName":{"type":"string"},"display_name":{"type":"string"},"serviceName":{"type":"string"},"service_name":{"type":"string"},"description":{"type":"string"},"toolName":{"type":"string"},"tool_name":{"type":"string"},"toolPrefix":{"type":"string"},"tool_prefix":{"type":"string"},"prefix":{"type":"string"},"endpointURL":{"type":"string"},"endpoint_url":{"type":"string"},"url":{"type":"string"},"executablePath":{"type":"string"},"executable_path":{"type":"string"},"command":{"type":"string"},"arguments":{"type":["array","string"],"items":{"type":"string"}},"args":{"type":["array","string"],"items":{"type":"string"}},"environment":{"type":"object","additionalProperties":{"type":"string"}},"env":{"type":"object","additionalProperties":{"type":"string"}},"mlxServerPackagePath":{"type":"string"},"mlx_server_package_path":{"type":"string"},"dependencyPath":{"type":"string"},"dependency_path":{"type":"string"},"path":{"type":"string"},"directory":{"type":"string"},"directoryPath":{"type":"string"},"directory_path":{"type":"string"},"enabled":{"type":"boolean"},"overwrite":{"type":"boolean"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "feature.install",
            description: "Installs a generated Swift feature package into the ZenCODE feature root, optionally building and enabling it.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"featureID":{"type":"string"},"feature_id":{"type":"string"},"name":{"type":"string"},"path":{"type":"string"},"directory":{"type":"string"},"directoryPath":{"type":"string"},"directory_path":{"type":"string"},"manifestPath":{"type":"string"},"manifest_path":{"type":"string"},"overwrite":{"type":"boolean"},"build":{"type":"boolean"},"enable":{"type":"boolean"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}}}"#
        )
    ]

#if canImport(Darwin) || canImport(Glibc)
    public static var coreProcessDescriptors: [DirectToolDescriptor] {
        macOSProcessDescriptors.filter { $0.name == "local.exec" }
    }

    public static let macOSProcessDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "search.grep",
            description: "Searches text with grep from a local path. Use context for surrounding lines and filesOnly to list only matching file paths.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"},"filesOnly":{"type":"boolean"},"files_only":{"type":"boolean"}},"required":["pattern"]}"#
        ),
        DirectToolDescriptor(
            name: "local.exec",
            description: "Runs a shell command in the working directory and returns stdout, stderr, and exit code. Reserve this for commands not covered by dedicated file, text, search, Git, web, Xcode, Figma, memory, or feature tools.",
            inputSchema: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"workingDirectory":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}},"required":["command"]}"#
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

    public static let orchestrationDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "todo.read",
            description: "Returns the session todo list.",
            inputSchema: #"{"type":"object","properties":{}}"#
        ),
        DirectToolDescriptor(
            name: "todo.write",
            description: "Creates or updates the session todo list. Supports replace, append, and upsert modes.",
            inputSchema: #"{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"}},"required":["content"]}},"items":{"type":"array","items":{"type":"object"}},"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"mode":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "task.create",
            description: "Creates one or more session tasks. Prefer a single call with a tasks array when creating multiple tasks.",
            inputSchema: #"{"type":"object","properties":{"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"status":{"type":"string"},"priority":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"output":{"type":"string"},"tasks":{"type":"array","items":{"type":"object"}},"items":{"type":"array","items":{"type":"object"}}}}"#
        ),
        DirectToolDescriptor(
            name: "task.list",
            description: "Lists session tasks, optionally filtered by status or assignee.",
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string"},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"agentID":{"type":"string"},"agent_id":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "task.get",
            description: "Returns a single session task by id.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "task.update",
            description: "Updates fields on a session task by id.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"status":{"type":"string"},"priority":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"output":{"type":"string"}},"required":["id"]}"#
        )
    ]

    public static let subAgentDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "agent.create",
            description: "Creates one or more delegated sub-agents. Each sub-agent inherits the parent session's enabled tools by default. If name, role, or profile matches an agent profile in agents.json, that profile's model is used. Use isolationMode=report for read-only investigation and isolationMode=implementation for scoped code changes.",
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"isolationMode":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}},"agents":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"profile":{"type":"string"},"agent":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"isolationMode":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}}}}},"items":{"type":"array","items":{"type":"object"}}}}"#
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
            description: "Queues a follow-up prompt for one or more delegated sub-agents. Reference an agent by id, name, task_id, or ids.",
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
        ToolDescriptor.canonicalized(providers.flatMap(\.tools)).map {
            DirectToolDescriptor(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }

    public func executor(for toolName: String) -> AgentToolExecutor? {
        for provider in providers where provider.tools.contains(where: { $0.name == toolName }) {
            return provider.executor
        }
        return nil
    }
}
