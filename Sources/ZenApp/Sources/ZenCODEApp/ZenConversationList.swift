//
//  ZenConversationList.swift
//  ZenApp
//
//  The scrolling conversation of a window: the closed rows, the block still
//  streaming after them, the welcome view of an empty session, the overview
//  cards pinned after the rows, and the bottom-following scroll with its
//  "jump to latest" button.
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
    var containerHeight: CGFloat
    var bottomInset: CGFloat

    /// How far the visible region ends above the end of the content
    /// (`0` or less at the bottom, or when the content fits).
    var distanceFromBottom: CGFloat {
        contentHeight + bottomInset - containerHeight - offsetY
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

    init(offsetY: CGFloat, contentHeight: CGFloat, containerHeight: CGFloat, bottomInset: CGFloat) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.bottomInset = bottomInset
    }

    init(_ geometry: ScrollGeometry) {
        self.init(
            offsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height,
            bottomInset: geometry.contentInsets.bottom
        )
    }

    /// The layout changed (content or container), not only the offset.
    func hasLayoutChange(from old: ZenScrollMetrics) -> Bool {
        contentHeight != old.contentHeight
            || containerHeight != old.containerHeight
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
/// only when a row closes or changes) and the epoch; the live text, the
/// status, and the overviews are read by the small views that show them. A
/// streamed token runs ``ZenLiveRows`` alone, and the content it grows is
/// followed through the scroll geometry, without work per row.
struct ZenConversationList: View {
    let session: ZenWindowSession
    /// Changes when the view must jump to the bottom and follow it again
    /// (the operator sent a line).
    let followToken: Int

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    @State private var durations = ZenToolDurations()
    @State private var rowCache = ZenConversationRowCache()

    var body: some View {
        let transcript = session.transcript
        let rows = rowCache.rows(for: transcript)
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
        .overlay(alignment: .bottom) {
            if !isFollowing {
                ZenJumpToLatestButton {
                    jumpToLatest(animated: true)
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: isFollowing)
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

/// The "Jump to latest" button of a list that stopped following its bottom:
/// the conversation and the transcript of a sub-agent tab.
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

/// The overview cards after the rows: the task graph, the sub-agents in
/// progress, whose rows open the sub-agent's tab. Their own view, so an
/// overview update does not run the list's body.
struct ZenOverviewCards: View {
    let session: ZenWindowSession

    var body: some View {
        if let taskGraph = session.taskGraph {
            ZenTaskGraphCard(overview: taskGraph)
        }
        if session.subAgents.snapshots.contains(where: \.pending) {
            ZenSubAgentsCard(overview: session.subAgents) { agentID in
                session.openSubAgentTab(agentID)
            }
        }
    }
}
