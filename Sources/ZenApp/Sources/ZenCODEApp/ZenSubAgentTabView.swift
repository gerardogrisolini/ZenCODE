//
//  ZenSubAgentTabView.swift
//  ZenApp
//
//  The content of a sub-agent tab, read-only: the detail card of the agent,
//  the notice of a transcript not available, the last transcript read with
//  the rows of the conversation, and the live activity while the agent
//  works, following the bottom as the conversation does.
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
/// bottom as the conversation does (``ZenScrollMetrics``), and measures its
/// own tool durations.
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
                ZenSubAgentDetailSlot(model: model)
                ZenSubAgentTranscriptNotice(model: model)
                ZenTranscriptRowList(rows: rows, durations: durations)
                ZenSubAgentLiveSlot(model: model)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollGeometryChange(for: ZenScrollMetrics.self, of: ZenScrollMetrics.init) { old, new in
            follow(old: old, new: new)
        }
        .onChange(of: items, initial: true) { _, items in
            durations.observe(items)
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
    }

    /// Follows the bottom without animation, so a tab that is not shown only
    /// moves its own scroll view.
    private func follow(old: ZenScrollMetrics, new: ZenScrollMetrics) {
        switch ZenScrollMetrics.followStep(old: old, new: new, isFollowing: isFollowing) {
        case .scrollToBottom:
            position.scrollTo(edge: .bottom)
        case let .setFollowing(following):
            if isFollowing != following {
                isFollowing = following
            }
        }
        if isFarFromBottom != new.isFarFromBottom {
            isFarFromBottom = new.isFarFromBottom
        }
    }

    /// The operator's jump: only a shown tab has a button to click.
    private func jumpToLatest() {
        isFollowing = true
        withAnimation(.easeOut(duration: 0.25)) {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// The detail card of the agent, once the tab has its snapshot.
private struct ZenSubAgentDetailSlot: View {
    let model: ZenSubAgentTranscriptModel

    var body: some View {
        if let snapshot = model.snapshot {
            ZenSubAgentDetailCard(snapshot: snapshot)
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
