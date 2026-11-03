//
//  ZenConversationScreen.swift
//  ZenApp
//
//  The detail of a window: the conversation with the floating bottom chrome
//  (consent card, composer, status bar), the artifacts sidebar on its right,
//  the toolbar, and Esc, which denies the tool call a consent card asks about
//  and otherwise stops the turn.
//

import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// What Esc does in a window, as in the terminal: while a consent card shows,
/// it denies the call the card asks about (the card's own Esc answer);
/// otherwise it stops the turn. ⌘. and the stop buttons always stop.
enum ZenEscapeAction: Equatable {
    /// Answer the consent request `requestID` with ``consentAnswer``.
    case denyConsent(requestID: UUID)
    /// Stop the turn (``ZenWindowSession/stop()``).
    case stop

    /// The answer Esc gives a consent request: deny once, as the card's Esc.
    static let consentAnswer: ChatPendingRequest.Answer = .consent(ZenConsentChoice.escapeDecision)

    /// The action for the request the window waits for: its id and kind,
    /// `nil` without one.
    init(pendingRequestID: UUID?, kind: ChatPendingRequest.Kind?) {
        if let pendingRequestID, case .toolConsent? = kind {
            self = .denyConsent(requestID: pendingRequestID)
        } else {
            self = .stop
        }
    }

    init(pendingRequest: ChatPendingRequest?) {
        self.init(pendingRequestID: pendingRequest?.id, kind: pendingRequest?.kind)
    }
}

/// The conversation of a window's session, with the artifacts sidebar as its
/// inspector.
///
/// The body reads the pending request only (for the focus); the status, the
/// draft, the queue, the commands, and the artifacts are read by the
/// subviews that show them, so a status update does not run this body.
struct ZenConversationScreen: View {
    let session: ZenWindowSession

    @FocusState private var isComposerFocused: Bool
    /// Bumped when the operator sends a line: the list follows the bottom.
    @State private var followToken = 0

    var body: some View {
        ZenConversationList(session: session, followToken: followToken)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZenBottomChrome(session: session, focus: $isComposerFocused) {
                    followToken &+= 1
                }
            }
            // After the bottom chrome, so the composer stays in the
            // conversation column; before the toolbar, so the toolbar stays
            // the window's.
            .inspector(isPresented: Bindable(session).isArtifactsSidebarPresented) {
                ZenArtifactsSidebar(session: session)
                    .inspectorColumnWidth(min: 280, ideal: 420, max: 800)
            }
            // The composer's own Esc (dismissing the suggestion list) and the
            // consent card's Esc (deny) handle the key first. The composer
            // ignores any other Esc, which reaches the key press handler;
            // `onExitCommand` covers Esc without a focused field. Neither
            // acts while an input method composes: its Esc cancels the
            // composition.
            .onKeyPress(.escape, phases: .down) { _ in
                guard !ZenComposerLogic.focusedInputHasMarkedText() else { return .ignored }
                handleEscape()
                return .handled
            }
            .onExitCommand {
                guard !ZenComposerLogic.focusedInputHasMarkedText() else { return }
                handleEscape()
            }
            .modifier(ZenWindowToolbarModifier(session: session))
            .defaultFocus($isComposerFocused, true)
            .onAppear {
                isComposerFocused = true
            }
            .onChange(of: session.pendingRequest?.id) { _, requestID in
                if requestID == nil {
                    isComposerFocused = true
                }
            }
    }

    private func handleEscape() {
        switch ZenEscapeAction(pendingRequest: session.pendingRequest) {
        case let .denyConsent(requestID):
            session.answer(requestID, with: ZenEscapeAction.consentAnswer)
        case .stop:
            session.stop()
        }
    }
}

/// The floating chrome under the conversation, in one glass container: the
/// consent card, the composer (which does not add a container of its own),
/// and the status bar.
struct ZenBottomChrome: View {
    let session: ZenWindowSession
    let focus: FocusState<Bool>.Binding
    /// The operator sent a line.
    let didSubmit: @MainActor () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ZenConsentSlot(session: session)
                ZenWindowComposer(session: session, focus: focus, didSubmit: didSubmit)
                ZenWindowStatusBar(session: session)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// The consent card of the tool call the session waits for, when it waits
/// for one.
struct ZenConsentSlot: View {
    let session: ZenWindowSession

    var body: some View {
        if let request = session.pendingRequest,
           case let .toolConsent(consentRequest) = request.kind {
            ZenConsentCard(request: consentRequest) { decision in
                session.answer(request.id, with: decision.map(ChatPendingRequest.Answer.consent))
            }
            // A new card (and a new answer) for every request, even when two
            // requests carry the same command.
            .id(request.id)
        }
    }
}

/// The composer of a window, inside the chrome's glass container.
struct ZenWindowComposer: View {
    @Bindable var session: ZenWindowSession
    let focus: FocusState<Bool>.Binding
    let didSubmit: @MainActor () -> Void

    var body: some View {
        ZenComposer(
            draft: $session.draft,
            isBusy: session.isBusy,
            commands: session.commandDescriptors,
            queued: session.queuedLines.map { ZenComposerQueuedItem(id: $0.id, text: $0.text) },
            focus: focus,
            usesGlassContainer: false,
            actions: actions
        )
    }

    private var actions: ZenComposerActions {
        let session = session
        let didSubmit = didSubmit
        return ZenComposerActions(
            submit: {
                session.submitDraft()
                didSubmit()
            },
            stop: { session.stop() },
            attach: { session.run("/attach") },
            dropFiles: { urls in session.attach(urls) },
            historyPrevious: { session.recallPreviousPrompt() },
            historyNext: { session.recallNextPrompt() },
            removeQueued: { id in session.removeQueuedLine(id) }
        )
    }
}

/// The status bar of a window: the only view of the chrome that reads the
/// status, which changes with every snapshot of a turn.
struct ZenWindowStatusBar: View {
    let session: ZenWindowSession

    var body: some View {
        ZenStatusBar(state: ZenStatusBarState(session.status))
    }
}

/// The toolbar of a window. A modifier, so the busy state it shows is read by
/// its body and not by the screen's; the labels that show the status (model,
/// thinking, agent) read it in their own bodies, so a metrics update does
/// not rebuild the toolbar.
struct ZenWindowToolbarModifier: ViewModifier {
    let session: ZenWindowSession

    func body(content: Content) -> some View {
        content.toolbar {
            ZenWindowToolbar(session: session, isBusy: session.isBusy)
        }
    }
}

extension ZenStatusBarState {
    /// The status bar of a window, field by field.
    init(_ status: ZenWindowStatus) {
        self.init(
            isGenerating: status.isGenerating,
            turnStartedAt: status.turnStartedAt,
            modelID: status.modelID,
            thinking: status.thinking,
            agentName: status.agentName,
            metrics: status.metrics,
            contextWindow: status.contextWindow,
            subscriptionUsage: status.subscriptionUsage,
            gitStatus: status.gitStatus,
            workspace: status.workspace
        )
    }
}
