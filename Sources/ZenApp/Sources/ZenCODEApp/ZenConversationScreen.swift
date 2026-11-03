//
//  ZenConversationScreen.swift
//  ZenApp
//
//  The detail of a window: the tab bar, the conversation with the floating
//  bottom chrome (consent card, composer, status bar) and the open sub-agent
//  tabs, the artifacts sidebar on their right, the toolbar, and Esc, which in
//  the conversation denies the tool call a consent card asks about and
//  otherwise stops the turn, and in a sub-agent tab does nothing.
//

import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// What Esc does in a window, as in the terminal: while a consent card shows,
/// it denies the call the card asks about (the card's own Esc answer);
/// otherwise it stops the turn. ⌘. and the stop buttons always stop. Esc acts
/// only in the conversation: a sub-agent tab consumes it and does nothing.
enum ZenEscapeAction: Equatable {
    /// Answer the consent request `requestID` with ``consentAnswer``.
    case denyConsent(requestID: UUID)
    /// Stop the turn (``ZenWindowSession/stop()``).
    case stop
    /// Do nothing, and keep Esc from other responders (the system beep
    /// included): a sub-agent tab.
    case consume

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

    /// The action of Esc in `selectedTab`: in the conversation, the one of
    /// the request the window waits for; in a sub-agent tab, ``consume``.
    init(selectedTab: ZenWindowTab, pendingRequestID: UUID?, kind: ChatPendingRequest.Kind?) {
        guard selectedTab == .chat else {
            self = .consume
            return
        }
        self.init(pendingRequestID: pendingRequestID, kind: kind)
    }
}

/// The content of a window's session, with the tab bar above it and the
/// artifacts sidebar as its inspector.
///
/// The conversation stays alive while a sub-agent tab shows (its scroll
/// position, its draft, its consent card), hidden and inert
/// (``View/zenTabContent(isSelected:)``), and so does every open sub-agent
/// tab. The body reads the selected tab and the pending request only (for the
/// focus); the status, the draft, the queue, the commands, the tabs, and the
/// artifacts are read by the subviews that show them, so a status update does
/// not run this body.
struct ZenConversationScreen: View {
    let session: ZenWindowSession

    @FocusState private var isComposerFocused: Bool
    /// Bumped when the operator sends a line: the list follows the bottom.
    @State private var followToken = 0

    var body: some View {
        let isChatSelected = session.selectedTab == .chat
        ZStack {
            ZenConversationList(session: session, followToken: followToken)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ZenBottomChrome(session: session, focus: $isComposerFocused) {
                        followToken &+= 1
                    }
                }
                .zenTabContent(isSelected: isChatSelected)
            ZenSubAgentTabStack(session: session)
        }
        // A bar of the content: under the toolbar, above the tabs, which
        // scroll under it.
        .safeAreaBar(edge: .top, spacing: 0) {
            ZenWindowTabBar(session: session)
        }
        // After the bottom chrome and the tab bar, so they stay in the
        // conversation column; before the toolbar, so the toolbar stays the
        // window's.
        .inspector(isPresented: Bindable(session).isArtifactsSidebarPresented) {
            ZenArtifactsSidebar(session: session)
                .inspectorColumnWidth(min: 280, ideal: 420, max: 800)
        }
        // The composer's own Esc (dismissing the suggestion list) and the
        // consent card's Esc (deny) handle the key first. The composer
        // ignores any other Esc, which reaches the key press handler;
        // `onExitCommand` covers Esc without a focused field. Neither acts
        // while an input method composes: its Esc cancels the composition.
        // A sub-agent tab consumes Esc and does nothing; the window's sheets
        // handle their own Esc.
        .onKeyPress(.escape, phases: .down) { _ in
            guard !ZenComposerLogic.focusedInputHasMarkedText() else { return .ignored }
            perform(escapeAction)
            return .handled
        }
        .onExitCommand {
            guard !ZenComposerLogic.focusedInputHasMarkedText() else { return }
            perform(escapeAction)
        }
        .modifier(ZenWindowToolbarModifier(session: session))
        .defaultFocus($isComposerFocused, true)
        .onAppear {
            isComposerFocused = true
        }
        .onChange(of: session.pendingRequest?.id) { _, requestID in
            if requestID == nil, session.selectedTab == .chat {
                isComposerFocused = true
            }
        }
        // Back in the conversation the composer takes the focus again,
        // unless a request waits: its consent card (shown again) or its
        // sheet takes it.
        .onChange(of: session.selectedTab) { _, tab in
            if tab == .chat, session.pendingRequest == nil {
                isComposerFocused = true
            }
        }
    }

    /// What Esc does now; ``ZenEscapeAction/consume`` in a sub-agent tab.
    private var escapeAction: ZenEscapeAction {
        ZenEscapeAction(
            selectedTab: session.selectedTab,
            pendingRequestID: session.pendingRequest?.id,
            kind: session.pendingRequest?.kind
        )
    }

    private func perform(_ action: ZenEscapeAction) {
        switch action {
        case let .denyConsent(requestID):
            session.answer(requestID, with: ZenEscapeAction.consentAnswer)
        case .stop:
            session.stop()
        case .consume:
            break
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
/// for one and the conversation shows: back from a sub-agent tab the card
/// appears again, so it takes the focus and its grace period starts over.
struct ZenConsentSlot: View {
    let session: ZenWindowSession

    var body: some View {
        if session.selectedTab == .chat,
           let request = session.pendingRequest,
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
