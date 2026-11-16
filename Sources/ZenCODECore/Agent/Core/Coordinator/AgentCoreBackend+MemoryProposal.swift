//
//  AgentCoreBackend+MemoryProposal.swift
//  ZenCODE
//
//  Isolated, same-backend conservative memory proposals: a throwaway session
//  that bypasses runner snapshots and is always closed before the turn ends.
//

import Foundation
import ToolCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AgentCoreBackend {
    /// Bypasses runner snapshots, seeds, skills, graph registration and recall.
    /// Structured children are always joined; no losing request survives a turn.
    func proposeMemory(
        parentSessionID: String,
        prompt: String,
        systemPrompt: String,
        permit: MemoryLearningPermit,
        timeout: Duration = .seconds(8)
    ) async throws -> String {
        guard let runtime = activeBackend, let parent = sessions[parentSessionID], permit.canPropose else {
            throw CancellationError()
        }
        let generation = backendGeneration
        let id = "memory-proposal-\(UUID().uuidString.lowercased())"
        let result = MemoryProposalEvents()
        memoryProposalSessions[parentSessionID] = id
        defer {
            if memoryProposalSessions[parentSessionID] == id { memoryProposalSessions.removeValue(forKey: parentSessionID) }
        }
        return try await MemoryConsolidationContext.$isIsolated.withValue(true) {
            try await MemoryTurnContext.$currentTurnMemoryBlock.withValue(nil) {
                try await AgentTurnInstructionContext.$currentTurnInstruction.withValue(nil) {
                    await runtime.createSession(id: id, cwd: parent.cwd, systemPrompt: systemPrompt,
                        history: [], cacheKey: nil, allowedToolNames: [],
                        thinkingSelection: parent.thinkingSelection, preserveThinking: false)
                    do {
                        try verifyBackendGeneration(generation)
                        try Task.checkCancellation()
                        guard permit.canPropose, memoryProposalSessions[parentSessionID] == id else { throw CancellationError() }
                        let text = try await withThrowingTaskGroup(of: String.self) { group in
                            group.addTask {
                                try Task.checkCancellation()
                                guard permit.canPropose else { throw CancellationError() }
                                let response = try await runtime.sendPrompt(sessionID: id, prompt: prompt,
                                    attachments: [], onEvent: { await result.record($0) })
                                guard await result.acceptsResponse(), response.text.count <= 4000,
                                      !["length", "max_tokens", "tool_calls", "tool_use"].contains(response.stopReason) else {
                                    throw CancellationError()
                                }
                                return response.text
                            }
                            group.addTask {
                                // Cancellation also closes the transport before the
                                // group joins its request child (no detached cleanup).
                                let clock = ContinuousClock()
                                let deadline = clock.now.advanced(by: timeout)
                                while !Task.isCancelled, permit.canPropose, clock.now < deadline {
                                    try? await Task.sleep(for: .milliseconds(20))
                                }
                                await runtime.closeSession(id: id)
                                throw CancellationError()
                            }
                            defer { group.cancelAll() }
                            return try await group.next() ?? "null"
                        }
                        await runtime.closeSession(id: id)
                        try verifyBackendGeneration(generation)
                        guard permit.canPropose else { throw CancellationError() }
                        return text
                    } catch {
                        await runtime.closeSession(id: id)
                        throw error
                    }
                }
            }
        }
    }
}

private actor MemoryProposalEvents {
    private var attemptedTool = false
    private var characters = 0
    func record(_ event: DirectAgentEvent) {
        switch event {
        case .toolCallStarted, .toolCallCompleted: attemptedTool = true
        case .content(let text): characters += text.count
        default: break
        }
    }
    func acceptsResponse() -> Bool { !attemptedTool && characters <= 4000 }
}
