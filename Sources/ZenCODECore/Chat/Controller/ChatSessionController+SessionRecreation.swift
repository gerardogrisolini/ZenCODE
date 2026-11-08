//
//  ChatSessionController+SessionRecreation.swift
//  ZenCODE
//
//  Recreation of the runtime session for the current selection: creating it,
//  loading its model, and calling the channel hooks between the steps.
//

import Foundation

extension ChatSessionController {
    /// Creates the runtime session for the current selection and hands it the
    /// selected prompt skills.
    func createSessionWithSelectedSkills(
        discoverExternalTools: Bool = true
    ) async throws {
        guard let managementRuntime else {
            return
        }
        try await managementRuntime.createSession(
            configuration: await composedSessionConfiguration(
                discoverExternalTools: discoverExternalTools
            )
        )
        await managementRuntime.updatePromptSkillSelection(
            selectedPromptSkills(),
            sessionID: sessionID
        )
    }

    /// Stops the backend and creates the session anew, then loads the model,
    /// calling the channel hooks between the steps.
    func recreateSession(reason: ChatSessionRecreationReason) async throws {
        await channelHooks?.sessionWillCreate(reason: reason)
        try await createSessionWithSelectedSkills()
        await channelHooks?.sessionDidCreate(reason: reason)
        try await preloadSessionModel(reason: reason)
    }

    /// Loads the session's model. The backend's events go to the channel
    /// hooks, or to the presenter when the channel set none.
    func preloadSessionModel(reason: ChatSessionRecreationReason) async throws {
        guard let managementRuntime else {
            return
        }
        let configuration = await composedSessionConfiguration(discoverExternalTools: false)
        let hooks = channelHooks
        let presenter = effectivePresenter(for: nil)
        let modelID = try await managementRuntime.preloadModel(
            configuration: configuration
        ) { event in
            if let hooks {
                await hooks.modelPreloadDidEmit(event)
            } else {
                await Self.presentPreloadEvent(event, on: presenter)
            }
        }
        await hooks?.modelDidPreload(modelID, reason: reason)
    }

    private static func presentPreloadEvent(
        _ event: DirectAgentEvent,
        on presenter: any ChatSessionPresenter
    ) async {
        switch event {
        case let .modelLoaded(modelID):
            await presenter.presentModelLoaded(modelID)
        case let .status(status):
            await presenter.presentStatus(status)
        case let .diagnostic(diagnostic):
            await presenter.presentDiagnostic(diagnostic)
        case .thought,
             .metrics,
             .contextWindow,
             .subscriptionUsage,
             .content,
             .toolCallStarted,
             .toolCallCompleted,
             .sessionSnapshot,
             .turnEnded:
            break
        }
    }
}
