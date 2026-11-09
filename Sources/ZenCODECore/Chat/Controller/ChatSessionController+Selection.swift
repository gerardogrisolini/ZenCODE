//
//  ChatSessionController+Selection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// A menu of the controller as a channel that presents it itself reads it:
/// its entries, or the notice that says why there is none (no current model,
/// no active saved session, ...).
enum ChatChoiceMenuState: Sendable, Equatable {
    case available(ChatChoiceList)
    case unavailable(ChatSessionNotice)
}

/// The selection commands shared by every channel: model, thinking level,
/// agent (with the project's agent association), tools, and prompt skills.
///
/// Each `choose…` operation asks the ``ChatInteractionHost`` with a menu when
/// the host has the capability, and otherwise returns the non-interactive
/// notice (``ChatSessionNotice/requiresInteractiveHost(_:)``). Each `select…`
/// operation applies a choice, keeps the runtime session in step with it, and
/// returns a ``ChatSelectionOutcome`` with the closing notices; notices raised
/// while it runs go to the presenter as they happen. A channel's own steps
/// between the runtime steps run through ``ChatSessionController/channelHooks``.
///
/// Model and thinking choices persist as the user's defaults through
/// ``ChatModelCatalog`` (unless the host supplies its own models); the
/// project's agent association is saved per project; tools and skills are
/// session state.
///
/// The operations live in `ChatSessionController+ModelSelection.swift`,
/// `+ThinkingSelection.swift`, `+AgentSelection.swift`, `+ToolSelection.swift`
/// and `+SkillSelection.swift`; the recreation of the runtime session is in
/// `+SessionRecreation.swift` and the workspace-access request in
/// `+WorkspaceAccess.swift`. This file keeps the session state channels mirror
/// and the steps that apply the selection to the runtime session.
extension ChatSessionController {
    // MARK: - Session state

    /// The selection and the saved-session link, as channels mirror them.
    var sessionState: ChatSessionState {
        ChatSessionState(selection: selection, savedSession: savedSessionState)
    }

    func presentSessionStateChanged() async {
        await effectivePresenter(for: nil).presentSessionStateChanged(sessionState)
    }

    // MARK: - Runtime steps

    /// The channel's response-language section, read where a composition
    /// needs it.
    func channelResponseLanguageSection() -> String? {
        channelHooks?.responseLanguageSection()
    }

    /// The session configuration for the current selection, with the
    /// channel's response-language section read after the tool catalog.
    func composedSessionConfiguration(
        discoverExternalTools: Bool
    ) async -> AgentCoreSessionConfiguration {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        return currentSessionConfiguration(
            allowedToolNames: allowedToolNames,
            responseLanguageSection: channelResponseLanguageSection()
        )
    }

    /// Applies the current selection to the running session in place.
    func updateRuntimeSessionOptions() async throws {
        guard let managementRuntime else {
            return
        }
        let allowedToolNames = await selectedAllowedToolNames()
        try await managementRuntime.updateSessionOptions(
            configuration: currentSessionConfiguration(
                allowedToolNames: allowedToolNames,
                responseLanguageSection: channelResponseLanguageSection()
            )
        )
    }
}
