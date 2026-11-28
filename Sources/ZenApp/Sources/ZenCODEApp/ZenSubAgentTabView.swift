//
//  ZenSubAgentTabView.swift
//  ZenApp
//
//  The content of a sub-agent tab, read-only: the notice of a transcript not
//  available, the last transcript read with the rows of the conversation, and
//  the live activity while the agent works, following the bottom as the
//  conversation does, over the detail card of the agent, fixed at the bottom
//  where the conversation has the composer.
//

import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

/// The tabs of the window's content: the conversation, then every open
/// sub-agent tab, each kept alive while it is open and shown only when
/// selected (``View/zenTabContent(isSelected:)``).
struct ZenSubAgentTabStack: View {
    let session: ZenWindowSession

    var body: some View {
        let selectedTab = session.selectedTab
        ForEach(session.subAgentTabs) { model in
            ZenSubAgentTabView(model: model)
                .zenTabContent(isSelected: selectedTab == .subAgent(model.agentID))
        }
    }
}

extension View {
    /// The content of a tab: shown when selected, otherwise kept alive but
    /// invisible, deaf to the pointer and the keyboard (disabled, so nothing
    /// in it takes the focus), and hidden from accessibility.
    func zenTabContent(isSelected: Bool) -> some View {
        opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .disabled(!isSelected)
            .accessibilityHidden(!isSelected)
    }
}

/// The scrolling, read-only transcript of one sub-agent: the last one its
/// model read, kept while the tab stays open, after the agent ends too.
///
/// Its body reads the rows (``ZenSubAgentTranscriptModel/items``, changed
/// only when the transcript changes); the snapshot, the notice, and the live
/// activity are read by the small views that show them. It follows the
/// bottom as the conversation does (``ZenScrollMetrics``), and shows the tool
/// durations the Core kept for the agent
/// (``ZenSubAgentTranscriptModel/toolDurations``): its rows are rebuilt from
/// the agent's history, whose results carry no time, so a call that ran
/// before the tab opened has its time too.
///
/// The detail card of the agent is not part of the scroll: it is the dock of
/// the tab (`ZenSubAgentDetailDock`), in the bottom safe area where the
/// conversation has its composer, so it stays still while the rows scroll
/// under it and the jump-to-latest button stays above it.
struct ZenSubAgentTabView: View {
    let model: ZenSubAgentTranscriptModel

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    /// ``ZenScrollMetrics/isFarFromBottom``, set only when it changes.
    @State private var isFarFromBottom = false
    @State private var durations = ZenToolDurations()
    @State private var rowCache = ZenConversationRowCache()

    var body: some View {
        let items = model.items
        let rows = rowCache.rows(for: items)
        let showsJumpToLatest = !isFollowing && isFarFromBottom
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ZenSubAgentTranscriptNotice(model: model)
                ZenTranscriptRowList(rows: rows, durations: durations)
                ZenSubAgentLiveSlot(model: model)
            }
            .padding(.horizontal, ZenConversationScreen.contentInset)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollGeometryChange(for: ZenScrollMetrics.self, of: ZenScrollMetrics.init) { old, new in
            follow(old: old, new: new)
        }
        .onChange(of: model.toolDurations, initial: true) { _, new in
            durations.replace(with: new)
        }
        .overlay(alignment: .bottom) {
            if showsJumpToLatest {
                ZenJumpToLatestButton {
                    jumpToLatest()
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsJumpToLatest)
        // Outside the overlay of the button, so it stays above the dock, as
        // above the composer of the conversation.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ZenSubAgentDetailDock(model: model)
        }
    }

    /// Follows the bottom without animation, so a tab that is not shown only
    /// moves its own scroll view.
    private func follow(old: ZenScrollMetrics, new: ZenScrollMetrics) {
        ZenScrollMetrics.follow(
            old: old,
            new: new,
            position: &position,
            isFollowing: &isFollowing,
            isFarFromBottom: &isFarFromBottom
        )
    }

    /// The operator's jump: only a shown tab has a button to click.
    private func jumpToLatest() {
        isFollowing = true
        withAnimation(.easeOut(duration: 0.25)) {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// The dock of the tab, once it has its snapshot: the detail card of the agent
/// with the margins of the composer (``ZenBottomChrome``). It reads the
/// snapshot, so the tab's body does not run for it.
private struct ZenSubAgentDetailDock: View {
    let model: ZenSubAgentTranscriptModel

    var body: some View {
        if let snapshot = model.snapshot {
            ZenSubAgentDetailCard(snapshot: snapshot)
                .padding([.bottom, .horizontal], ZenConversationScreen.contentInset)
                .padding(.top, 6)
        }
    }
}

/// What the tab says about the transcript itself: that it is not available,
/// while no read returned one.
private struct ZenSubAgentTranscriptNotice: View {
    let model: ZenSubAgentTranscriptModel

    @Environment(\.zenPalette) private var palette

    var body: some View {
        if model.availability == .unavailable {
            Label(ZenSubAgentTabText.unavailable, systemImage: "exclamationmark.bubble")
                .font(.callout)
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The live activity after the transcript, while the agent works.
private struct ZenSubAgentLiveSlot: View {
    let model: ZenSubAgentTranscriptModel

    var body: some View {
        ZenSubAgentLiveActivityView(snapshot: model.snapshot)
    }
}

/// The texts of a sub-agent tab.
enum ZenSubAgentTabText {
    /// No read returned a transcript: the agent ended before the tab read its
    /// history, or the session has no such agent or no backend.
    static let unavailable = "The transcript of this sub-agent is not available."
}
