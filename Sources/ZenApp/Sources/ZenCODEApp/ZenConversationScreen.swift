//
//  ZenConversationScreen.swift
//  ZenApp
//
//  The detail of a window: the tab bar, the conversation with the floating
//  bottom chrome (shared-chat panel, composer, status bar) and the open
//  sub-agent tabs, the artifacts sidebar on their right, the toolbar, and
//  Esc, which in the conversation denies a waiting tool consent (its sheet
//  answers Esc itself) and otherwise stops the turn and voice mode's reading
//  aloud, and in a sub-agent tab does nothing. While the shared-chat reader
//  is open in the conversation, the unmodified ← → Home End move between its
//  messages and ↑ ↓ scroll the one shown, even from the composer, as in the
//  terminal.
//

import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// What Esc does in a window, as in the terminal: while a tool consent waits,
/// it denies the call (the answer of the consent sheet's own Esc, which
/// handles the key while it shows); otherwise it stops the turn and the
/// reading aloud of voice mode, and never clears the draft. ⌘. and the stop
/// buttons always stop the turn only. Esc acts only in the conversation: a
/// sub-agent tab consumes it and does nothing.
enum ZenEscapeAction: Equatable {
    /// Answer the consent request `requestID` with ``consentAnswer``.
    case denyConsent(requestID: UUID)
    /// Stop the turn and, in the window voice mode follows, the reading
    /// aloud (``ZenWindowSession/handleEscape()``).
    case stop
    /// Do nothing, and keep Esc from other responders (the system beep
    /// included): a sub-agent tab.
    case consume

    /// The answer Esc gives a consent request: deny once, as the sheet's Esc.
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
/// position, its draft), hidden and inert
/// (``View/zenTabContent(isSelected:)``), and so does every open sub-agent
/// tab. The body reads the selected tab and the pending request only (for the
/// focus); the status, the draft, the queue, the commands, the tabs, the
/// artifacts, and the shared chat are read by the subviews that show them, so
/// a status update does not run this body.
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
        // The composer's own Esc (dismissing the suggestion list) handles
        // the key first. The composer
        // ignores any other Esc, which reaches the key press handler;
        // `onExitCommand` covers Esc without a focused field. Neither acts
        // while an input method composes: its Esc cancels the composition.
        // A sub-agent tab consumes Esc and does nothing; the window's sheets
        // (the consent sheet's Esc denies) handle their own Esc.
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
        // unless a request waits: its sheet has it.
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
            session.handleEscape()
        case .consume:
            break
        }
    }
}

/// The floating chrome under the conversation, in one glass container: the
/// shared-chat panel (``ZenSharedChatPanel``), the composer (which does not
/// add a container of its own), and the status bar. A tool consent is a sheet
/// of the window (``ZenConsentSheet``), so it never changes the height of the
/// chrome.
///
/// It owns the window's reader keys: the composer and the panel hand them
/// over (``ZenComposerActions/readerKey``), and while the reader is open in
/// the conversation they move its selection or scroll its message
/// (``ZenSharedChatPanelLogic/handle(_:isReaderOpen:selectedTab:navigate:scroll:)``).
struct ZenBottomChrome: View {
    let session: ZenWindowSession
    let focus: FocusState<Bool>.Binding
    /// The operator sent a line.
    let didSubmit: @MainActor () -> Void

    /// The panel's scroll requests; read by the message view alone.
    @State private var scroller = ZenSharedChatScroller()

    var body: some View {
        let readerKey = readerKeyHandler
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                ZenSharedChatPanel(session: session, scroller: scroller, readerKey: readerKey)
                ZenWindowComposer(session: session, focus: focus, didSubmit: didSubmit, readerKey: readerKey)
                ZenWindowStatusBar(session: session)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// The window's reader keys. The reader's state is read when a key
    /// arrives, not by this body.
    private var readerKeyHandler: @MainActor (ZenReaderKey) -> Bool {
        let session = session
        let scroller = scroller
        return { key in
            ZenSharedChatPanelLogic.handle(
                key,
                isReaderOpen: session.sharedChat.isReaderOpen,
                selectedTab: session.selectedTab,
                navigate: { session.navigateSharedChat($0) },
                scroll: { scroller.scroll($0) }
            )
        }
    }
}

/// The composer of a window, inside the chrome's glass container, with the
/// live `@mentions` of the session's shared chat and the window's reader
/// keys. Voice mode's reading aloud shows in its key hint only in the window
/// voice mode follows, the one where Esc stops it, and its cursor follows the
/// voice dictation (``ZenDictationCursor``).
struct ZenWindowComposer: View {
    @Bindable var session: ZenWindowSession
    let focus: FocusState<Bool>.Binding
    let didSubmit: @MainActor () -> Void
    let readerKey: @MainActor (ZenReaderKey) -> Bool

    var body: some View {
        ZenComposer(
            draft: $session.draft,
            isBusy: session.isBusy,
            isSpeaking: session.voiceState.isSpeaking && session.isVoiceWindow,
            commands: session.commandDescriptors,
            mentions: session.mentionSuggestions,
            queued: session.queuedLines.map { ZenComposerQueuedItem(id: $0.id, text: $0.text) },
            draftUpdate: ZenDictationCursor.draftUpdate(of: session),
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
            removeQueued: { id in session.removeQueuedLine(id) },
            refreshMentions: { session.refreshMentionSuggestions() },
            readerKey: readerKey,
            cursorAfterDraftUpdate: { cursor, previous, current, draftCount in
                ZenDictationCursor.cursor(
                    cursor,
                    from: previous,
                    to: current,
                    latest: session.voiceDictationUpdate?.change,
                    draftCount: draftCount
                )
            }
        )
    }
}

/// The status bar of a window: the only view of the chrome that reads the
/// status, which changes with every snapshot of a turn, and voice mode's
/// state, the app's, which every window shows.
struct ZenWindowStatusBar: View {
    let session: ZenWindowSession

    var body: some View {
        ZenStatusBar(state: ZenStatusBarState(session.status, voice: session.voiceState))
    }
}

/// The toolbar of a window. The labels that show the status (model, thinking,
/// agent) read it in their own bodies, so a metrics update does not rebuild
/// the toolbar.
struct ZenWindowToolbarModifier: ViewModifier {
    let session: ZenWindowSession

    func body(content: Content) -> some View {
        content.toolbar {
            ZenWindowToolbar(session: session)
        }
    }
}

extension ZenStatusBarState {
    /// The status bar of a window, field by field, with the app's voice mode.
    init(_ status: ZenWindowStatus, voice: VoiceModeSessionState) {
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
            localExecAccessMode: status.localExecAccessMode,
            voice: voice
        )
    }
}
