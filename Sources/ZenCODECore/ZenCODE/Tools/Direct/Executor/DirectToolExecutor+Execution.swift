//
//  DirectToolExecutor+Execution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

struct DirectToolExecutionOutput: Sendable {
    let output: String
    let attachments: [AgentRuntimeAttachment]

    init(
        output: String,
        attachments: [AgentRuntimeAttachment] = []
    ) {
        self.output = output
        self.attachments = attachments
    }
}

extension DirectToolExecutor {
    public func executeThrowing(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> String {
        try await executeThrowingResult(
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        ).output
    }

    func executeThrowingResult(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> DirectToolExecutionOutput {
        let directlyAllowed = Self.isAllowed(
            toolCall.name,
            allowedToolNames: allowedToolNames
        )
        let canonicalCoreCoordinationToolName = Self.canonicalCoreCoordinationToolName(
            for: toolCall.name
        )
        let featureAllowed = await swiftFeatureRuntime.featureToolIsAllowed(
            toolName: toolCall.name,
            allowedToolNames: allowedToolNames
        )

        if directlyAllowed, toolCall.name == "local.exec" {
#if canImport(Darwin) || canImport(Glibc)
            return DirectToolExecutionOutput(
                output: try await executeLocalExec(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory
                )
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        }
        if directlyAllowed, DirectExecJobRuntime.isExecJobToolName(toolCall.name) {
            // Job management only inspects or stops processes that were already
            // authorized at launch through local.exec, so it is not gated.
            return DirectToolExecutionOutput(
                output: try await execJobRuntime.execute(toolCall: toolCall)
            )
        }
        if directlyAllowed, let deniedOutput = await deniedDestructiveToolOutputIfNeeded(
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) {
            throw DirectToolExecutorError.authorizationDenied(deniedOutput)
        }
        if directlyAllowed, let output = try await executeCoreLocalFileOrTextTool(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) {
            return DirectToolExecutionOutput(output: output)
        }
        if directlyAllowed, let toolExecutor = toolProviderRegistry(
            forSessionID: sessionID
        ).executor(for: toolCall.name) {
            return DirectToolExecutionOutput(
                output: try await toolExecutor(
                    AgentToolCall(
                        id: toolCall.id,
                        name: toolCall.name,
                        argumentsJSON: toolCall.argumentsJSON
                    )
                )
            )
        }
        if directlyAllowed, SwiftFeatureRuntime.isFeatureManagementToolName(toolCall.name) {
            return DirectToolExecutionOutput(
                output: try await swiftFeatureRuntime.executeManagementTool(
                    toolCall: toolCall
                )
            )
        }
        if featureAllowed, let result = try await swiftFeatureRuntime.executeResultIfAvailable(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) {
            return DirectToolExecutionOutput(
                output: result.output,
                attachments: result.attachments
            )
        }
        if directlyAllowed, await mcpRuntime.canExecute(
            toolName: toolCall.name,
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: workingDirectory
        ) {
            return DirectToolExecutionOutput(
                output: try await mcpRuntime.execute(toolCall: toolCall)
            )
        }
        if canonicalCoreCoordinationToolName != nil,
           !Self.isCoreCoordinationToolAllowed(
               toolCall.name,
               allowedToolNames: allowedToolNames
           ) {
            throw DirectToolExecutorError.toolNotAllowed(toolCall.name)
        }
        if canonicalCoreCoordinationToolName != nil,
           let borrowedSubAgentToolExecutor,
           Self.isBorrowedSubAgentToolName(toolCall.name) {
            return DirectToolExecutionOutput(
                output: try await borrowedSubAgentToolExecutor(
                    AgentBorrowedToolCall(
                        id: toolCall.id,
                        name: toolCall.name,
                        argumentsJSON: toolCall.argumentsJSON
                    )
                )
            )
        }
        if canonicalCoreCoordinationToolName != nil,
           DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            return DirectToolExecutionOutput(
                output: try await subAgentRuntime.execute(
                    rootSessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory,
                    allowedToolNames: allowedToolNames
                )
            )
        }
        if canonicalCoreCoordinationToolName != nil,
           DirectTodoRuntime.isTodoToolName(toolCall.name) {
            return DirectToolExecutionOutput(
                output: try await todoRuntime.execute(
                    sessionID: sessionID,
                    toolCall: toolCall
                )
            )
        }
        if canonicalCoreCoordinationToolName != nil,
           DirectTaskToolAdapter.isTaskToolName(toolCall.name) {
            let output = try await taskToolAdapter.execute(
                sessionID: sessionID,
                toolCall: toolCall
            )
            let request = DirectTodoRuntime.normalizedToolRequest(for: toolCall)
            if request.name == "tasks.cancel",
               let taskID = DirectTodoRuntime.firstString(["id"], in: request.arguments) {
                _ = await subAgentRuntime.closeAgentAssigned(
                    to: taskID,
                    rootSessionID: sessionID?.nilIfBlank ?? "default"
                )
            }
            return DirectToolExecutionOutput(output: output)
        }
        if directlyAllowed, MemoryTool.isMemoryToolName(toolCall.name) {
            let request = ToolRequest(
                name: toolCall.name,
                arguments: Self.toolArguments(from: toolCall.argumentsJSON)
            )
            let output = try await MemoryTool.executeAsync(
                request,
                context: MemoryToolContext(workingDirectory: workingDirectory)
            ).text
            return DirectToolExecutionOutput(output: output)
        }

        throw DirectToolError.unknownTool(toolCall.name)
    }

#if canImport(Darwin) || canImport(Glibc)
    public func executeLocalExec(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> String {
        let arguments = toolCall.argumentsObject
        guard let command = arguments.string("command")?.nilIfBlank else {
            throw DirectToolError.missingArgument("command")
        }
        let cwd = resolvePath(
            arguments.string("cwd", "workingDirectory") ?? ".",
            cwd: workingDirectory
        )
        if let deniedOutput = await deniedLocalExecOutputIfNeeded(
            sessionID: sessionID,
            toolCall: toolCall,
            command: command,
            cwd: cwd
        ) {
            throw DirectToolExecutorError.authorizationDenied(deniedOutput)
        }
        // Clamp so a mistyped timeout can neither block the session for hours
        // nor drop below one second. Background jobs manage their own lifetime.
        let timeout = min(max(TimeInterval(arguments.int("timeoutSeconds", "timeout") ?? 120), 1), 3_600)
        if arguments.bool("background") == true {
            return try await execJobRuntime.startBackgroundJob(
                command: command,
                shellPath: Self.defaultShellPath(),
                workingDirectory: cwd,
                environment: DeveloperToolEnvironment.processEnvironment(),
                timeout: arguments.int("timeoutSeconds", "timeout").map(TimeInterval.init)
            )
        }
        let result = await runProcess(
            executable: Self.defaultShellPath(),
            arguments: ["-lc", command],
            cwd: cwd,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: timeout
        )
        return renderProcessResult(result)
    }

    private static func defaultShellPath() -> String {
        #if os(Linux)
        return ProcessInfo.processInfo.environment["SHELL"]?.nilIfBlank ?? "/bin/sh"
        #else
        return ProcessInfo.processInfo.environment["SHELL"]?.nilIfBlank ?? "/bin/zsh"
        #endif
    }
#endif
}
