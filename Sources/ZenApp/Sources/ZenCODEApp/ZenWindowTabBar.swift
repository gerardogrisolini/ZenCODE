//
//  ZenWindowTabBar.swift
//  ZenApp
//
//  The tab bar of a window, under the toolbar and above the conversation:
//  the Chat tab, with a badge while the session waits for an answer from
//  another tab, then one tab per open sub-agent with its status color, its
//  name, and a close button. It shows only while a sub-agent tab is open.
//

import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

/// What the tab bar decides, apart from the views.
enum ZenWindowTabBarLogic {
    /// The longest title of a sub-agent tab, in characters: a longer name is
    /// cut with an ellipsis (the bar scrolls, so the view cannot truncate it
    /// to a width).
    static let titleLimit = 24

    /// The bar shows while at least one sub-agent tab is open.
    static func showsBar(subAgentTabCount: Int) -> Bool {
        subAgentTabCount > 0
    }

    /// The Chat tab carries a badge while the session waits for an answer
    /// (a consent, a menu, a text) and another tab is selected: the window
    /// never switches to the conversation by itself.
    static func showsChatBadge(hasPendingRequest: Bool, selectedTab: ZenWindowTab) -> Bool {
        hasPendingRequest && selectedTab != .chat
    }

    /// The title of a sub-agent tab: the agent's name on one line, at most
    /// ``titleLimit`` characters, else the agent's id.
    static func title(name: String?, agentID: String) -> String {
        name.flatMap { ZenTranscriptText.inline($0, limit: titleLimit) } ?? agentID
    }
}

/// The tab bar of a window. It reads the tabs, the selection, and whether a
/// request waits; each sub-agent tab reads its own model.
struct ZenWindowTabBar: View {
    let session: ZenWindowSession

    var body: some View {
        let models = session.subAgentTabs
        if ZenWindowTabBarLogic.showsBar(subAgentTabCount: models.count) {
            let selectedTab = session.selectedTab
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ZenChatTabItem(
                                isSelected: selectedTab == .chat,
                                showsBadge: ZenWindowTabBarLogic.showsChatBadge(
                                    hasPendingRequest: session.pendingRequest != nil,
                                    selectedTab: selectedTab
                                )
                            ) {
                                session.selectTab(.chat)
                            }
                            .id(ZenWindowTab.chat)
                            ForEach(models) { model in
                                ZenSubAgentTabItem(
                                    model: model,
                                    isSelected: selectedTab == .subAgent(model.agentID),
                                    select: { session.selectTab(.subAgent(model.agentID)) },
                                    close: { session.closeSubAgentTab(model.agentID) }
                                )
                                .id(ZenWindowTab.subAgent(model.agentID))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
                .scrollIndicators(.never)
                // The selected tab scrolls into view, a new one included.
                .onChange(of: selectedTab) { _, tab in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(tab)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tabs"))
        }
    }
}

/// The glass capsule of a tab, tinted with the accent when selected.
private struct ZenTabCapsule: ViewModifier {
    let isSelected: Bool

    @Environment(\.zenPalette) private var palette

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(
                isSelected ? .regular.tint(palette.accent.opacity(0.22)) : .regular,
                in: .capsule
            )
    }
}

/// The Chat tab: always first, never closed.
private struct ZenChatTabItem: View {
    let isSelected: Bool
    let showsBadge: Bool
    let select: @MainActor () -> Void

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button {
            select()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(isSelected ? palette.accent : palette.textSecondary)
                Text("Chat")
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                if showsBadge {
                    Circle()
                        .fill(palette.permissionMarker)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ZenTabCapsule(isSelected: isSelected))
        .help(showsBadge ? "Show the conversation: the session waits for an answer" : "Show the conversation")
        .accessibilityLabel(Text("Chat"))
        .accessibilityValue(Text(showsBadge ? "Waiting for an answer" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Shows the conversation"))
    }
}

/// The tab of one sub-agent: its status color, its name, and the close
/// button. It reads its model in its own body.
private struct ZenSubAgentTabItem: View {
    let model: ZenSubAgentTranscriptModel
    let isSelected: Bool
    let select: @MainActor () -> Void
    let close: @MainActor () -> Void

    @Environment(\.zenPalette) private var palette

    var body: some View {
        let snapshot = model.snapshot
        let title = ZenWindowTabBarLogic.title(name: snapshot?.name, agentID: model.agentID)
        let statusColor = snapshot.map { ZenTranscriptStatus.role(for: $0).color(in: palette) } ?? palette.statusInactive
        HStack(spacing: 6) {
            Button {
                select()
            } label: {
                HStack(spacing: 6) {
                    Text("●")
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                    Text(title)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? palette.textPrimary : palette.textSecondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the transcript of \(title)")
            .accessibilityLabel(Text("Sub-agent \(title)"))
            .accessibilityValue(Text(snapshot.map(ZenTranscriptStatus.displayStatus(for:)) ?? ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(Text("Shows the sub-agent transcript"))

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the tab")
            .accessibilityLabel(Text("Close \(title)"))
        }
        .modifier(ZenTabCapsule(isSelected: isSelected))
    }
}
