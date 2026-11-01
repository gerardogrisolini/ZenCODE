//
//  TerminalChat+Generation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ToolCore

extension TerminalChat {
    func generateResponse(
        attempt: TerminalPromptAttempt
    ) async throws -> TerminalChatGenerationSuccess {
        if attempt.locksResponseLanguage {
            lockResponseLanguageIfNeeded()
        }
        await installSubAgentToolEventHandlerIfNeeded()
        let assistantOutput = TerminalAssistantResponseBuffer()
        activeAssistantOutput = assistantOutput
        let request = ChatTurnRequest(
            prompt: attempt.prompt,
            attachments: attempt.attachments,
            purpose: attempt.purpose,
            sessionConfiguration: await turnSessionConfiguration(for: attempt.purpose),
            // Evaluated for every request, so `/voice pause` or `/voice off`
            // while a workflow continues turn by turn takes effect on the
            // next prompt.
            turnInstructionProvider: { @ChatSessionActor [weak self] in
                await self?.voiceTurnInstruction()
            }
        )
        do {
            let result = try await chatSession.runTurn(request)
            let finalAssistantContent: String
            if case .plan = attempt.purpose {
                finalAssistantContent = result.response.text
            } else {
                finalAssistantContent = await assistantOutput.finalContent(
                    fallback: result.response.text
                )
            }
            return TerminalChatGenerationSuccess(
                response: result.response,
                origin: attempt.origin,
                fileChangeSummary: result.fileChangeSummary,
                automaticallyCompletedPlan: result.automaticallyCompletedPlan,
                finalAssistantContent: finalAssistantContent
            )
        } catch let failure as ChatTurnFailure {
            await writeAssistantContent(await assistantOutput.takePending())
            throw TerminalChatGenerationRunError(
                underlying: failure.underlying,
                fileChangeSummary: failure.fileChangeSummary
            )
        }
    }

    /// The configuration of one turn: the session grant plus the purpose's
    /// coordinator tools, recomposed so the system prompt and the profile
    /// tool policy see the final grant (see
    /// ``ChatSessionController/turnSessionConfiguration(for:responseLanguageSection:)``).
    func turnSessionConfiguration(
        for purpose: ChatTurnPurpose
    ) async -> AgentCoreSessionConfiguration {
        await chatSession.turnSessionConfiguration(
            for: purpose,
            responseLanguageSection: responseLanguageSystemPromptSection()
        )
    }

    /// Records a structured plan (with task points) as the active plan **without**
    /// creating its task graph. The graph is created exclusively at plan approval
    /// (see ``handlePlanCommand``) so that changing the plan before approval always
    /// produces a graph that matches the final approved points.
    @discardableResult
    func recordStructuredPlanIfNeeded(
        responseText: String,
        purpose: ChatTurnPurpose,
        createdAt: Date = Date(),
        points: [TerminalSessionPlanPoint]
    ) async throws(ChatPlanGenerationError) -> Bool {
        guard case let .plan(originalGoal) = purpose else {
            return false
        }
        return try chatSession.recordStructuredPlan(
            responseText: responseText,
            originalGoal: originalGoal,
            createdAt: createdAt,
            points: points
        )
    }

    nonisolated static func planID(from points: [TerminalSessionPlanPoint]) -> String {
        PlanningCommandKernel.planID(from: points)
    }

    @discardableResult
    func recordPlanIfNeeded(
        responseText: String,
        purpose: ChatTurnPurpose,
        createdAt: Date = Date(),
        points: [TerminalSessionPlanPoint] = []
    ) -> Bool {
        guard case let .plan(originalGoal) = purpose else {
            return false
        }
        let consolidatedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consolidatedText.isEmpty else {
            return false
        }
        activePlan = TerminalSessionPlan(
            originalGoal: originalGoal,
            consolidatedText: consolidatedText,
            createdAt: createdAt,
            isApproved: false,
            points: points
        )
        return true
    }

    func finishPromptResult(_ result: TerminalChatGenerationResult) async {
        switch result {
        case let .success(success):
            let response = success.response
            // Seal the terminal transcript before publishing the final
            // response. Task/sub-agent observations still refresh, but no
            // automatic terminal overview may overtake the answer (or a
            // model question) below this point.
            await renderCoordinator.beginAssistantTranscriptTail()
            await finishStreamingOutput()
            await printModelIfNeeded(response.modelID)
            if let plan = success.automaticallyCompletedPlan {
                await writeMarkdownMessage(Self.planStatusTable(for: plan))
            }
            let responseText = success.finalAssistantContent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let completionText = responseText.isEmpty ? "Done." : responseText
            await writeAssistantContent(completionText)
            await finishStreamingOutput()
            await writeChatOutput("\n")
            // Quiesce the debounced task-graph observer and publish the
            // latest known section once at the turn boundary; then restart
            // the observer for the next turn, and snapshot once more so
            // mutations that landed during the handoff window are not lost
            // (no event replay).
            await quiesceTaskGraphObserverForTurnBoundary()
            await startTaskGraphObserver()
            await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            if let summary = success.fileChangeSummary {
                await writeFinalFileChangeSummary(summary)
            }
        case let .failure(failure):
            await renderCoordinator.beginAssistantTranscriptTail()
            await finishStreamingOutput()
            if failure.isCancellation {
                await writeChatError("\nStopped.\n")
            } else {
                await writeFailureMessage("ZenCODE: \(failure.message)\n")
            }
            await quiesceTaskGraphObserverForTurnBoundary()
            await startTaskGraphObserver()
            await publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            if let summary = failure.fileChangeSummary {
                await writeFinalFileChangeSummary(summary)
            }
        }
    }
}
