//
//  DirectToolExecutor+Execution.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureKit
import Foundation
import LocalToolsSupport
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

        // Only predicates over immutable inputs select the admissible steps.
        // Each step evaluates the rest of its original condition, with its
        // effects and awaits, when the chain reaches it, so the steps keep
        // both their precedence and the order of their effects.
        let steps = DirectToolDispatchStep.admissibleSteps(
            toolName: toolCall.name,
            directlyAllowed: directlyAllowed,
            featureAllowed: featureAllowed,
            canonicalCoreCoordinationToolName: canonicalCoreCoordinationToolName
        )
        for step in steps {
            let outcome: DirectToolDispatchOutcome
            switch step {
            case .localExec:
                outcome = try await dispatchLocalExec(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory
                )
            case .execJob:
                outcome = try await dispatchExecJob(toolCall: toolCall)
            case .destructiveGate:
                outcome = try await enforceDestructiveGate(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory
                )
            case .coreLocalTool:
                outcome = try await dispatchCoreLocalTool(
                    toolCall: toolCall,
                    workingDirectory: workingDirectory
                )
            case .providerRegistry:
                outcome = try await dispatchProviderRegistry(
                    sessionID: sessionID,
                    toolCall: toolCall
                )
            case .featureManagement:
                outcome = try await dispatchFeatureManagement(toolCall: toolCall)
            case .feature:
                outcome = try await dispatchFeature(
                    toolCall: toolCall,
                    workingDirectory: workingDirectory
                )
            case .mcp:
                outcome = try await dispatchMCP(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory,
                    allowedToolNames: allowedToolNames
                )
            case .coreCoordinationGrant:
                outcome = try enforceCoreCoordinationGrant(
                    toolCall: toolCall,
                    allowedToolNames: allowedToolNames
                )
            case .borrowedSubAgent:
                outcome = try await dispatchBorrowedSubAgent(toolCall: toolCall)
            case .subAgent:
                outcome = try await dispatchSubAgent(
                    sessionID: sessionID,
                    toolCall: toolCall,
                    workingDirectory: workingDirectory,
                    allowedToolNames: allowedToolNames
                )
            case .todo:
                outcome = try await dispatchTodo(sessionID: sessionID, toolCall: toolCall)
            case .task:
                outcome = try await dispatchTask(sessionID: sessionID, toolCall: toolCall)
            case .memory:
                outcome = try await dispatchMemory(
                    toolCall: toolCall,
                    workingDirectory: workingDirectory
                )
            }
            if case let .handled(output) = outcome {
                return output
            }
        }

        throw DirectToolError.unknownTool(toolCall.name)
    }

    private func dispatchLocalExec(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> DirectToolDispatchOutcome {
#if canImport(Darwin) || canImport(Glibc)
        return .handled(DirectToolExecutionOutput(
            output: try await executeLocalExec(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory
            )
        ))
#else
        throw DirectToolError.unknownTool(toolCall.name)
#endif
    }

    private func dispatchExecJob(
        toolCall: DirectAgentToolCall
    ) async throws -> DirectToolDispatchOutcome {
        // Job management only inspects or stops processes that were already
        // authorized at launch through local.exec, so it is not gated.
        .handled(DirectToolExecutionOutput(
            output: try await execJobRuntime.execute(toolCall: toolCall)
        ))
    }

    /// Destructive names are gated independently of the dispatch owner. A
    /// feature manifest may advertise a core-looking name as an alias, and a
    /// programmatic allowlist may enable that feature without making the raw
    /// name `directlyAllowed`; neither route may bypass operator consent.
    private func enforceDestructiveGate(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> DirectToolDispatchOutcome {
        if let deniedOutput = await deniedDestructiveToolOutputIfNeeded(
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) {
            throw DirectToolExecutorError.authorizationDenied(deniedOutput)
        }
        return .notHandled
    }

    private func dispatchCoreLocalTool(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> DirectToolDispatchOutcome {
        guard let output = try await executeCoreLocalFileOrTextTool(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) else {
            return .notHandled
        }
        return .handled(DirectToolExecutionOutput(output: output))
    }

    private func dispatchProviderRegistry(
        sessionID: String?,
        toolCall: DirectAgentToolCall
    ) async throws -> DirectToolDispatchOutcome {
        guard let toolExecutor = toolProviderRegistry(
            forSessionID: sessionID
        ).executor(for: toolCall.name) else {
            return .notHandled
        }
        return .handled(DirectToolExecutionOutput(
            output: try await toolExecutor(
                AgentToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        ))
    }

    private func dispatchFeatureManagement(
        toolCall: DirectAgentToolCall
    ) async throws -> DirectToolDispatchOutcome {
        .handled(DirectToolExecutionOutput(
            output: try await swiftFeatureRuntime.executeManagementTool(
                toolCall: toolCall
            )
        ))
    }

    private func dispatchFeature(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> DirectToolDispatchOutcome {
        guard let result = try await swiftFeatureRuntime.executeResultIfAvailable(
            toolCall: toolCall,
            workingDirectory: workingDirectory
        ) else {
            return .notHandled
        }
        for change in result.fileChanges {
            ExternalFileChangeEvidence.record(
                path: URL(fileURLWithPath: change.path),
                oldText: change.oldText,
                newText: change.newText,
                explanation: change.explanation
            )
        }
        return .handled(DirectToolExecutionOutput(
            output: result.output,
            attachments: result.attachments
        ))
    }

    private func dispatchMCP(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> DirectToolDispatchOutcome {
        guard await mcpRuntime.canExecute(
            toolName: toolCall.name,
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: workingDirectory,
            sessionID: sharedChatRootSessionID ?? sessionID
        ) else {
            return .notHandled
        }
        return .handled(DirectToolExecutionOutput(
            output: try await mcpRuntime.execute(
                toolCall: toolCall,
                sessionID: sharedChatRootSessionID ?? sessionID
            )
        ))
    }

    /// Provider, feature, and MCP dispatch have already declined the raw
    /// name, so it reaches a core coordination runtime only through its
    /// canonical catalog grant.
    private func enforceCoreCoordinationGrant(
        toolCall: DirectAgentToolCall,
        allowedToolNames: Set<String>?
    ) throws -> DirectToolDispatchOutcome {
        guard Self.isCoreCoordinationToolAllowed(
            toolCall.name,
            allowedToolNames: allowedToolNames
        ) else {
            throw DirectToolExecutorError.toolNotAllowed(toolCall.name)
        }
        return .notHandled
    }

    /// A child executor borrows only its parent's agent-runtime surface. Todo
    /// storage and task orchestration stay local to the child executor, which
    /// has the shared `SessionTaskOrchestrator` installed separately.
    private func dispatchBorrowedSubAgent(
        toolCall: DirectAgentToolCall
    ) async throws -> DirectToolDispatchOutcome {
        guard let borrowedSubAgentToolExecutor,
              DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) else {
            return .notHandled
        }
        return .handled(DirectToolExecutionOutput(
            output: try await borrowedSubAgentToolExecutor(
                AgentBorrowedToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        ))
    }

    private func dispatchSubAgent(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> DirectToolDispatchOutcome {
        guard DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) else {
            return .notHandled
        }
        return .handled(DirectToolExecutionOutput(
            output: try await subAgentRuntime.execute(
                rootSessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory,
                allowedToolNames: allowedToolNames
            )
        ))
    }

    private func dispatchTodo(
        sessionID: String?,
        toolCall: DirectAgentToolCall
    ) async throws -> DirectToolDispatchOutcome {
        guard DirectTodoRuntime.isTodoToolName(toolCall.name) else {
            return .notHandled
        }
        return .handled(DirectToolExecutionOutput(
            output: try await todoRuntime.execute(
                sessionID: sessionID,
                toolCall: toolCall
            )
        ))
    }

    private func dispatchTask(
        sessionID: String?,
        toolCall: DirectAgentToolCall
    ) async throws -> DirectToolDispatchOutcome {
        guard DirectTaskToolAdapter.isTaskToolName(toolCall.name) else {
            return .notHandled
        }
        let output = try await taskToolAdapter.execute(
            sessionID: sessionID,
            toolCall: toolCall
        )
        let request = DirectTodoRuntime.normalizedToolRequest(for: toolCall)
        if request.name == "tasks.cancel",
           let rootSessionID = sessionID?.nilIfBlank,
           let taskID = DirectTodoRuntime.firstString(["id"], in: request.arguments) {
            _ = await subAgentRuntime.closeAgentAssigned(
                to: taskID,
                rootSessionID: rootSessionID
            )
        }
        return .handled(DirectToolExecutionOutput(output: output))
    }

    private func dispatchMemory(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> DirectToolDispatchOutcome {
        let request = ToolRequest(
            name: toolCall.name,
            arguments: Self.toolArguments(from: toolCall.argumentsJSON)
        )
        // The executing agent's profile role selects the graph: organizer
        // addresses the global graph, every other role its workspace graph.
        let output = try await MemoryTool.executeAsync(
            request,
            context: MemoryToolContext(
                graphTarget: MemoryGraphTarget.resolved(
                    profileRole: toolExecutionContext.profileRole,
                    workingDirectory: workingDirectory
                )
            )
        ).text
        return .handled(DirectToolExecutionOutput(output: output))
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
            arguments.string("workingDirectory") ?? ".",
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

/// The result of one step of the dispatch chain: the step handled the call,
/// or the chain continues with the next admissible step.
private enum DirectToolDispatchOutcome {
    case handled(DirectToolExecutionOutput)
    case notHandled
}
