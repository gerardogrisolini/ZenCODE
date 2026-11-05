//
//  ZenConsentSheetLayoutTests.swift
//  ZenApp
//
//  The height of the consent sheet: the command shrinks to its text and
//  scrolls past eight lines, so a command of any length leaves the sheet
//  shorter than the smallest window.
//

import AppKit
import Foundation
import SwiftUI
import Testing
import ZenCODECore

@testable import ZenAppControls

@Suite("Consent sheet layout")
@MainActor
struct ZenConsentSheetLayoutTests {
    private func request(command: String) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            turnID: nil,
            sessionID: "s",
            toolCallID: "c",
            toolName: "local.exec",
            title: "Run a command",
            kind: "execute",
            command: command,
            workingDirectory: "/Users/me/Projects/ZenCODE"
        )
    }

    /// The fitting height of the sheet in a window, once the command has
    /// measured itself: its height follows its scroll geometry, a pass after
    /// the first layout.
    private func fittingHeight(command: String, scheme: ColorScheme) async -> CGFloat {
        let host = NSHostingView(rootView: ZenConsentSheet(request: request(command: command)) { _ in }
            .environment(\.colorScheme, scheme))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        var height = host.fittingSize.height
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
            height = host.fittingSize.height
        }
        window.contentView = nil
        return height
    }

    @Test("the command grows to eight lines and scrolls the rest", arguments: [ColorScheme.light, .dark])
    func commandIsCapped(scheme: ColorScheme) async {
        let oneLine = await fittingHeight(command: "ls -la", scheme: scheme)
        // Heredocs collapsed to one line (the content joins the lines, as
        // the terminal does): thousands of points of text, then ten times
        // more.
        let long = await fittingHeight(
            command: "cat > notes.txt <<'EOF' " + String(repeating: "a long line of the heredoc body ", count: 200),
            scheme: scheme
        )
        let huge = await fittingHeight(
            command: "cat > notes.txt <<'EOF' " + String(repeating: "a long line of the heredoc body ", count: 2_000),
            scheme: scheme
        )

        // From one line the command grows by seven lines of 16 points, to
        // eight lines, and stops there: the rest scrolls.
        #expect(abs((long - oneLine) - 7 * 16) <= 1)
        #expect(abs(huge - long) <= 1)
        // Shorter than the smallest window (480 points of content).
        #expect(huge < 480)
    }
}
