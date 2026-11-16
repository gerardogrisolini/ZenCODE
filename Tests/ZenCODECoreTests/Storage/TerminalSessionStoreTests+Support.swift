//
//  TerminalSessionStoreTests+Support.swift
//  ZenCODE
//
//  Fixtures of the terminal session store tests: a sample saved session and a
//  temporary support directory.
//

import Foundation
@testable import ZenCODECore
import Testing

extension TerminalSessionStoreTests {
    func sampleSession(
        name: String,
        workingDirectory: URL,
        transcriptHistory: [AgentRuntimeMessage]? = nil,
        activePlan: TerminalSessionPlan? = nil,
        queuedPlans: [TerminalSessionPlan]? = nil,
        taskGraph: TaskGraphSnapshot? = nil
    ) -> TerminalSavedSession {
        TerminalSavedSession(
            name: name,
            sessionID: "terminal-test",
            cacheKey: "cache-test",
            workingDirectoryPath: workingDirectory.path,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 20),
            modelID: "model-test",
            agentID: "developer",
            agentName: "Developer",
            selectedTools: [
                "shell",
                TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
            ],
            selectedSkillNames: ["skill-a"],
            thinkingSelection: "on",
            contextWindow: TerminalSavedSessionContextWindow(
                usedTokens: 2_048,
                maxTokens: 65_536,
                modelID: "model-test",
                isApproximate: false
            ),
            systemPrompt: "System",
            history: [
                AgentRuntimeMessage(role: .user, content: "ciao"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_1",
                            name: "local.exec",
                            argumentsJSON: #"{"command":"pwd"}"#
                        )
                    ]
                ),
                AgentRuntimeMessage(
                    role: .tool,
                    content: "/tmp",
                    toolCallID: "call_1"
                )
            ],
            transcriptHistory: transcriptHistory,
            activePlan: activePlan,
            queuedPlans: queuedPlans,
            taskGraph: taskGraph,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(
                transcriptHistory ?? [
                    AgentRuntimeMessage(role: .user, content: "ciao"),
                ],
                sessionID: "terminal-test"
            )
        )
    }

    func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "terminal-session-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
    }
}
