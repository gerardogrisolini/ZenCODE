//
//  DirectToolExecutor+Execution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectToolExecutor {
    public func executeThrowing(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> String {
        if toolCall.name == "local.exec" {
#if canImport(Darwin) || canImport(Glibc)
            return try await executeLocalExec(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        }
        if let output = try await executeCoreLocalFileOrTextTool(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) {
            return output
        }
        if await mcpRuntime.canExecute(
            toolName: toolCall.name,
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: workingDirectory
        ) {
            return try await mcpRuntime.execute(toolCall: toolCall)
        }
        if DirectMCPToolRuntime.isXcodeToolName(toolCall.name) {
            throw DirectToolError.permissionDenied(
                "Xcode MCP is not connected for this session. Re-enable Xcode from /tools, approve Xcode's MCP prompt once, then retry."
            )
        }
        if let toolExecutor = toolProviderRegistry.executor(for: toolCall.name) {
            return try await toolExecutor(
                AgentToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        }
        if SwiftFeatureRuntime.isFeatureManagementToolName(toolCall.name) {
            return try await swiftFeatureRuntime.executeManagementTool(
                toolCall: toolCall
            )
        }
        if let output = try await swiftFeatureRuntime.executeIfAvailable(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) {
            return output
        }
        if let borrowedOrchestrationToolExecutor,
           Self.isOrchestrationToolName(toolCall.name) {
            return try await borrowedOrchestrationToolExecutor(
                AgentBorrowedToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        }
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            return try await subAgentRuntime.execute(
                toolCall: toolCall,
                workingDirectory: workingDirectory,
                allowedToolNames: allowedToolNames
            )
        }
        if DirectOrchestrationRuntime.isTodoOrTaskToolName(toolCall.name) {
            return try await orchestrationRuntime.execute(
                sessionID: sessionID,
                toolCall: toolCall
            )
        }
        if MemoryTool.isMemoryToolName(toolCall.name) {
            let request = ToolRequest(
                name: toolCall.name,
                arguments: Self.toolArguments(from: toolCall.argumentsJSON)
            )
            return try MemoryTool.execute(
                request,
                context: MemoryToolContext(workingDirectory: workingDirectory)
            ).text
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
            return deniedOutput
        }
        let timeout = TimeInterval(arguments.int("timeoutSeconds", "timeout") ?? 120)
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
