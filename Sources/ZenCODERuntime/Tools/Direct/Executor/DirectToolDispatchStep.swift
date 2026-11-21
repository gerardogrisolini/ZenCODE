//
//  DirectToolDispatchStep.swift
//  ZenCODE
//

/// One step of the dispatch chain of `DirectToolExecutor.executeThrowingResult`.
///
/// The declaration order is the precedence: the chain runs the admissible
/// steps in this order, the first step that handles the call returns its
/// output, a gate step may throw, and a call that no step handles is an
/// unknown tool.
enum DirectToolDispatchStep: CaseIterable, Sendable {
    /// `local.exec`, which keeps its own command-level gate.
    case localExec
    /// `exec.job`, on processes already authorized through `local.exec`.
    case execJob
    /// Operator consent for a destructive name, before any step can run it.
    case destructiveGate
    /// The in-process Files, Search, and Text tools.
    case coreLocalTool
    /// Tools of the session's (or the global) provider registry.
    case providerRegistry
    /// The kernel feature-management commands.
    case featureManagement
    /// Tools of an installed Swift feature.
    case feature
    /// Tools of an installed MCP server.
    case mcp
    /// Rejects a coordination name whose canonical catalog name is not granted.
    case coreCoordinationGrant
    /// The parent's agent-runtime surface borrowed by a child executor.
    case borrowedSubAgent
    /// The sub-agent runtime (`agent.*`).
    case subAgent
    /// The todo runtime (`todo.*`).
    case todo
    /// The task adapter (`tasks.*`).
    case task
    /// The memory tools (`memory.*`).
    case memory

    /// The steps whose preconditions over immutable inputs hold, in
    /// precedence order.
    ///
    /// Only the arguments and constant name catalogs filter here. Every part
    /// of a step's condition that awaits, has effects, reads actor state, or
    /// resolves a coordination alias stays in the step and is evaluated only
    /// when the chain reaches it.
    static func admissibleSteps(
        toolName: String,
        directlyAllowed: Bool,
        featureAllowed: Bool,
        canonicalCoreCoordinationToolName: String?
    ) -> [DirectToolDispatchStep] {
        allCases.filter { step in
            switch step {
            case .localExec:
                return directlyAllowed && toolName == "local.exec"
            case .execJob:
                return directlyAllowed && DirectExecJobRuntime.isExecJobToolName(toolName)
            case .destructiveGate:
                return (directlyAllowed || featureAllowed)
                    && DirectToolExecutor.destructiveGatedToolNames.contains(toolName)
            case .coreLocalTool, .providerRegistry, .mcp:
                return directlyAllowed
            case .featureManagement:
                return directlyAllowed && SwiftFeatureRuntime.isFeatureManagementToolName(toolName)
            case .feature:
                return featureAllowed
            case .coreCoordinationGrant, .borrowedSubAgent, .subAgent, .todo, .task:
                return canonicalCoreCoordinationToolName != nil
            case .memory:
                return directlyAllowed && MemoryTool.isMemoryToolName(toolName)
            }
        }
    }
}
