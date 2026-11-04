//
//  ZenConversationList.swift
//  ZenApp
//
//  The scrolling conversation of a window: the closed rows, the block still
//  streaming after them, the welcome view of an empty session, the overview
//  cards pinned after the rows, the bottom-following scroll with its "jump
//  to latest" button, and the loading indicator that takes the place of the
//  conversation while the sidebar loads a saved session.
//

import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

/// What the follow logic reads from the scroll view.
struct ZenScrollMetrics: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    /// The height of the whole scroll view, the insets of the bars over its
    /// edges included (the bottom chrome, the tab bar, the toolbar).
    var viewportHeight: CGFloat
    var bottomInset: CGFloat
    var topInset: CGFloat

    /// How far the visible region ends above the end of the content
    /// (`0` or less at the bottom, or when the content fits). At the bottom
    /// the end of the content sits right above the bottom inset, so the last
    /// line stays above the composer.
    var distanceFromBottom: CGFloat {
        contentHeight + bottomInset - viewportHeight - offsetY
    }

    /// The distance under which the view counts as at the bottom.
    static let bottomThreshold: CGFloat = 24
    /// The distance from the bottom a followed layout change leaves without
    /// scrolling: the bottom stays pinned, so a streamed line is never
    /// half-hidden while it grows.
    static let pinTolerance: CGFloat = 1

    var isAtBottom: Bool {
        distanceFromBottom <= Self.bottomThreshold
    }

    /// The height of the chat that shows between the bars: above the bottom
    /// chrome, under the tab bar and the toolbar.
    var visibleHeight: CGFloat {
        max(0, viewportHeight - topInset - bottomInset)
    }

    /// More than a whole visible height of chat is left under the view: the
    /// "Jump to latest" button shows only then (and only while the view does
    /// not follow the bottom).
    var isFarFromBottom: Bool {
        distanceFromBottom > visibleHeight
    }

    init(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat = 0
    ) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.bottomInset = bottomInset
        self.topInset = topInset
    }

    /// The metrics of `geometry`. Its `containerSize` leaves the insets out
    /// (on macOS the scroll view reports the height between the bars), so
    /// the insets are added back: counting the bottom inset only in
    /// ``distanceFromBottom`` keeps the bottom where the scroll view stops.
    init(_ geometry: ScrollGeometry) {
        self.init(
            offsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            viewportHeight: geometry.containerSize.height
                + geometry.contentInsets.top
                + geometry.contentInsets.bottom,
            bottomInset: geometry.contentInsets.bottom,
            topInset: geometry.contentInsets.top
        )
    }

    /// The layout changed (content or viewport), not only the offset.
    func hasLayoutChange(from old: ZenScrollMetrics) -> Bool {
        contentHeight != old.contentHeight
            || viewportHeight != old.viewportHeight
            || bottomInset != old.bottomInset
    }

    /// What following the bottom does after a scroll-geometry change.
    enum FollowStep: Equatable {
        /// Keep following: scroll to the bottom again.
        case scrollToBottom
        /// Set whether the view follows the bottom.
        case setFollowing(Bool)
    }

    /// While following, a layout change that the operator did not scroll
    /// against (the content growing as a block streams, a new row, a resized
    /// window) keeps the bottom pinned; any other change follows the bottom
    /// only when the view is at the bottom, so a scroll up stops the
    /// following and a scroll back down resumes it.
    static func followStep(old: ZenScrollMetrics, new: ZenScrollMetrics, isFollowing: Bool) -> FollowStep {
        if isFollowing, new.hasLayoutChange(from: old), new.offsetY >= old.offsetY - 0.5 {
            return new.distanceFromBottom > pinTolerance ? .scrollToBottom : .setFollowing(true)
        }
        return .setFollowing(new.isAtBottom)
    }
}

/// The scrolling transcript of a window.
///
/// Its body reads the closed rows (``ZenWindowSession/transcript``, changed
/// only when a row closes or changes), the epoch, and whether the sidebar
/// loads a saved session; the live text, the status, the overviews, and the
/// step of a load are read by the small views that show them. A streamed
/// token runs ``ZenLiveRows`` alone, and the content it grows is followed
/// through the scroll geometry, without work per row.
///
/// While the sidebar loads a saved session
/// (``ZenWindowSession/loadingSavedSessionName``) the scroll view stays, so
/// its position and its following go on as usual, but hidden and inert: the
/// loading indicator (``ZenSavedSessionLoadingSlot``) shows in its place,
/// centered between the bars, until the window shows how the load ended.
struct ZenConversationList: View {
    let session: ZenWindowSession
    /// Changes when the view must jump to the bottom and follow it again
    /// (the operator sent a line).
    let followToken: Int

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    /// ``ZenScrollMetrics/isFarFromBottom``, set only when it changes.
    @State private var isFarFromBottom = false
    @State private var durations = ZenToolDurations()
    @State private var rowCache = ZenConversationRowCache()

    var body: some View {
        let transcript = session.transcript
        let rows = rowCache.rows(for: transcript)
        let isLoadingSavedSession = session.loadingSavedSessionName != nil
        let showsJumpToLatest = !isFollowing && isFarFromBottom && !isLoadingSavedSession
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if transcript.isEmpty {
                    ZenWelcomeSlot(session: session)
                }
                ZenTranscriptRowList(rows: rows, durations: durations)
                ZenLiveRows(session: session)
                ZenOverviewCards(session: session)
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
        // The closed rows only: a streamed token does not reach the timer.
        .onChange(of: transcript, initial: true) { _, transcript in
            durations.observe(transcript)
        }
        .onChange(of: followToken) { _, _ in
            jumpToLatest(animated: false)
        }
        // A new or loaded session starts at its latest row.
        .onChange(of: session.epoch) { _, _ in
            jumpToLatest(animated: false)
        }
        .opacity(isLoadingSavedSession ? 0 : 1)
        .allowsHitTesting(!isLoadingSavedSession)
        .accessibilityHidden(isLoadingSavedSession)
        .overlay {
            ZenSavedSessionLoadingSlot(session: session)
        }
        .overlay(alignment: .bottom) {
            if showsJumpToLatest {
                ZenJumpToLatestButton {
                    jumpToLatest(animated: true)
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsJumpToLatest)
    }

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

    private func jumpToLatest(animated: Bool) {
        isFollowing = true
        if animated {
            withAnimation(.easeOut(duration: 0.25)) {
                position.scrollTo(edge: .bottom)
            }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// The "Jump to latest" button of a list that stopped following its bottom
/// and has more than a visible height of content left under the view
/// (``ZenScrollMetrics/isFarFromBottom``): the conversation and the
/// transcript of a sub-agent tab.
struct ZenJumpToLatestButton: View {
    let action: @MainActor () -> Void

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button {
            action()
        } label: {
            Label("Jump to latest", systemImage: "arrow.down")
                .font(.callout.weight(.medium))
        }
        .buttonStyle(.glass)
        .tint(palette.accent)
        .help("Scroll to the latest message")
    }
}

/// The welcome view of an empty session, until a block streams. Its own
/// view, so only it reads the live block id and the status.
struct ZenWelcomeSlot: View {
    let session: ZenWindowSession

    var body: some View {
        if session.liveBlockID == nil {
            ZenWelcomeView(workspace: session.workspace, modelID: session.status.modelID)
                .frame(maxWidth: .infinity)
                .padding(.top, 72)
        }
    }
}

/// The loading indicator of a saved session the sidebar loads
/// (``ZenWindowSession/loadingSavedSessionName``), with the step the load is
/// at (``ZenWindowSession/loadingSavedSessionStep``), over the conversation
/// it takes the place of. Its own view, so only it reads the step.
struct ZenSavedSessionLoadingSlot: View {
    let session: ZenWindowSession

    var body: some View {
        if let name = session.loadingSavedSessionName {
            ZenSessionLoadingView(name: name, step: session.loadingSavedSessionStep?.text)
        }
    }
}

/// The overview card after the rows: the sub-agents in progress, whose rows
/// open the sub-agent's tab. Its own view, so an overview update does not run
/// the list's body. The task graph is not here: its cards are rows of the
/// conversation (``ZenTranscriptItem/Content/taskGraph(_:)``).
struct ZenOverviewCards: View {
    let session: ZenWindowSession

    var body: some View {
        if session.subAgents.snapshots.contains(where: \.pending) {
            ZenSubAgentsCard(overview: session.subAgents) { agentID in
                session.openSubAgentTab(agentID)
            }
        }
    }
}
