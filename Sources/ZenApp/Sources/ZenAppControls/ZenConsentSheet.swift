//
//  ZenConsentSheet.swift
//  ZenApp
//
//  The tool-consent sheet of a window: the content of the terminal consent
//  card (`LocalExecPermissionDialog`) with the run once / always / cancel
//  choices.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// A button of the consent sheet.
public enum ZenConsentChoice: CaseIterable, Sendable, Identifiable {
    /// Run this call only (the terminal's `[R]un once`).
    case allowOnce
    /// Run this call and later calls with the same consent identity (the
    /// terminal's `[A]lways`).
    case allowAlways
    /// Refuse this call (the terminal's `[C]ancel`).
    case deny

    /// The focused choice when the sheet appears: like the terminal, Return
    /// runs the call once.
    public static let defaultChoice: ZenConsentChoice = .allowOnce

    /// The decision Esc sends: a refusal of this call only.
    public static let escapeDecision: ChatConsentDecision = .denyOnce

    public var id: Self { self }

    /// The button title.
    public var title: String {
        switch self {
        case .allowOnce: "Allow once"
        case .allowAlways: "Always allow"
        case .deny: "Deny"
        }
    }

    /// The decision the button sends. The terminal card has no "never"
    /// choice, so there is no deny-always.
    public var decision: ChatConsentDecision {
        switch self {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .deny: .denyOnce
        }
    }

    /// The neighbouring choice in reading order, clamped at the ends.
    func moved(by delta: Int) -> ZenConsentChoice {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[min(max(index + delta, 0), all.count - 1)]
    }
}

/// What a key does on the consent sheet. Like the terminal card, only Return
/// chooses: Space is typing, as any other key the sheet does not handle.
enum ZenConsentKeyAction: Equatable {
    /// Return: chooses the focused button.
    case choose
    /// Esc: denies.
    case deny
    /// ← or →: moves the focus by `delta`.
    case moveFocus(by: Int)
    /// Any other key, Space included: typing meant for the composer. It
    /// restarts the grace period (``ZenConsentGuard/noteTyping()``) and is
    /// not handled.
    case typing

    init(_ key: KeyEquivalent) {
        switch key {
        case .return: self = .choose
        case .escape: self = .deny
        case .leftArrow: self = .moveFocus(by: -1)
        case .rightArrow: self = .moveFocus(by: 1)
        default: self = .typing
        }
    }
}

/// The text of a consent sheet, built from the request like the terminal
/// consent card: untrusted fields are stripped of control characters and
/// collapsed to one line.
struct ZenConsentContent: Equatable {
    /// `"Tool consent: <toolName>"`.
    let title: String
    /// The question under the title: about the command, or about the tool
    /// without one.
    let question: String
    /// The command on one line, its runs marking every executable the
    /// consent covers (the first word for a tool other than `local.exec`);
    /// `nil` without a command.
    let command: ChatConsentCommandLine?
    /// Muted lines: the request title (without a command), the working
    /// directory (`⊙ ~/path`), and the scope of "Always".
    let metadata: [String]

    /// The marker before the command.
    static let marker = "❯ "

    /// The lines of the command the sheet shows at most; a longer command
    /// scrolls inside the sheet, so the sheet never grows taller than the
    /// window (a heredoc collapsed to one line can be thousands of points).
    static let maximumVisibleCommandLines = 8

    /// The height of the command's scroll view: the command's, at least one
    /// line and at most ``maximumVisibleCommandLines``.
    static func commandHeight(contentHeight: CGFloat, lineHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, lineHeight), lineHeight * CGFloat(maximumVisibleCommandLines))
    }

    init(request: AgentToolAuthorizationRequest, homeDirectory: String = NSHomeDirectory()) {
        title = "Tool consent: \(Self.singleLined(Self.sanitized(request.toolName)))"

        let command = ChatConsentCommandLine(request: request)
        self.command = command.runs.isEmpty ? nil : command
        question = self.command == nil
            ? "Allow the agent to use this tool?"
            : "Allow the agent to run this command?"

        var metadata: [String] = []
        if self.command == nil {
            let requestTitle = Self.singleLined(Self.sanitized(request.title))
            if !requestTitle.isEmpty {
                metadata.append(requestTitle)
            }
        }
        let directory = Self.singleLined(Self.sanitized(request.workingDirectory))
        if !directory.isEmpty {
            metadata.append("⊙ " + ZenStatusFormatting.abbreviatedPath(directory, homeDirectory: homeDirectory))
        }
        metadata.append(Self.alwaysHint(forToolName: request.toolName))
        self.metadata = metadata
    }

    /// The one-line scope of "Always" of the terminal card.
    static func alwaysHint(forToolName toolName: String) -> String {
        toolName == "local.exec"
            ? "always · remembered across sessions"
            : "always · this session only"
    }

    /// Collapses newlines, tabs and repeated whitespace into single spaces.
    static func singleLined(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Replaces control characters (except newlines and tabs) with spaces, so
    /// a crafted command cannot spoof the sheet.
    static func sanitized(_ text: String) -> String {
        String(text.map { character -> Character in
            guard let scalar = character.unicodeScalars.first else {
                return " "
            }
            if character == "\n" || character == "\t" {
                return character
            }
            let value = scalar.value
            if value < 0x20 || (value > 0x7E && value < 0xA0) {
                return " "
            }
            return character
        })
    }
}

/// The tool-consent sheet of a window, in the colors of the terminal consent
/// card.
///
/// A header with the tool and the question, then the command (`❯` marker,
/// every executable the consent covers in bold, the rest plain) in a code
/// box, whole and selectable and
/// scrolling past ``ZenConsentContent/maximumVisibleCommandLines`` lines, or
/// the request title; under it the working directory and the scope of
/// "Always", and the Allow once / Always allow / Deny buttons. Allow once is
/// focused when the sheet appears, like the terminal's default; ←/→ move the
/// focus, Return chooses the focused button, Esc denies. Space does not
/// choose, as in the terminal. The sheet answers once.
///
/// Return and clicks are ignored for 0.5 s after the sheet appears, after
/// its request changes, and after any key it does not handle (a typist must
/// pause before Return answers), and key repeats always are, so a keystroke
/// meant for the composer cannot approve a call; the focused button looks
/// disabled meanwhile. Esc denies at once (``ZenConsentGuard``).
public struct ZenConsentSheet: View {
    @Environment(\.zenPalette) private var palette
    private let request: AgentToolAuthorizationRequest
    private let onDecision: @MainActor (ChatConsentDecision?) -> Void

    @State private var focusedChoice = ZenConsentChoice.defaultChoice
    @State private var consentGuard = ZenConsentGuard()
    /// Mirrors `consentGuard.isArmed` for the look of the focused button.
    @State private var isArmed = false
    /// Restarts the arming task whenever the grace period starts again.
    @State private var graceGeneration = 0
    @FocusState private var isFocused: Bool

    public init(
        request: AgentToolAuthorizationRequest,
        onDecision: @escaping @MainActor (ChatConsentDecision?) -> Void
    ) {
        self.request = request
        self.onDecision = onDecision
    }

    public var body: some View {
        let content = ZenConsentContent(request: request)
        VStack(alignment: .leading, spacing: 16) {
            header(content)

            VStack(alignment: .leading, spacing: 8) {
                if let command = content.command {
                    commandBox(command)
                }
                ForEach(Array(content.metadata.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(ZenFonts.monoSmall)
                        .foregroundStyle(palette.permissionMetadata)
                        .textSelection(.enabled)
                }
            }

            footer
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600, maxWidth: 760, alignment: .leading)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return, phases: [.down, .repeat]) { press in
            decide(focusedChoice.decision, trigger: .key(isRepeat: press.phase == .repeat))
            return .handled
        }
        .onKeyPress(.escape, phases: .down) { _ in
            decide(ZenConsentChoice.escapeDecision, trigger: .escape)
            return .handled
        }
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
            focusedChoice = focusedChoice.moved(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
            focusedChoice = focusedChoice.moved(by: 1)
            return .handled
        }
        // Any other key, Space included, is typing: the grace period starts
        // again and the key goes on unhandled.
        .onKeyPress(phases: [.down, .repeat]) { press in
            if ZenConsentKeyAction(press.key) == .typing {
                noteTyping()
            }
            return .ignored
        }
        // Esc when no view of the sheet has the focus (a click in the
        // command's text, for example).
        .onExitCommand {
            decide(ZenConsentChoice.escapeDecision, trigger: .escape)
        }
        .onAppear {
            restartGracePeriod()
            isFocused = true
        }
        .onChange(of: request) { _, _ in
            restartGracePeriod()
            focusedChoice = .defaultChoice
            isFocused = true
        }
        .task(id: graceGeneration) {
            isArmed = consentGuard.isArmed
            guard !isArmed else { return }
            try? await Task.sleep(for: consentGuard.remainingGrace)
            guard !Task.isCancelled else { return }
            isArmed = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.title)
    }

    /// The tool and the question, beside a symbol of the request: a terminal
    /// for a command, a shield for another tool.
    private func header(_ content: ZenConsentContent) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: content.command == nil ? "lock.shield" : "terminal")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.permissionTitle)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(palette.permissionTitle.opacity(0.15)), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(palette.permissionTitle)
                Text(content.question)
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
            }
        }
    }

    /// The command in a box of the code colors, framed in the permission
    /// border color: the executables in the choice color and bold, the rest
    /// in the code color.
    private func commandBox(_ command: ChatConsentCommandLine) -> some View {
        var line = AttributedString(ZenConsentContent.marker)
        line.foregroundColor = palette.permissionMarker
        for run in command.runs {
            var part = AttributedString(run.text)
            if run.isExecutable {
                part.foregroundColor = palette.permissionChoice
                part.inlinePresentationIntent = .stronglyEmphasized
            } else {
                part.foregroundColor = palette.codeForeground
            }
            line.append(part)
        }
        return ZenConsentCommandText(line: line)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.codeBackground, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(palette.permissionBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// The key hint, then the buttons in the terminal's order.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Return: \(focusedChoice.title) · Esc: Deny")
                .font(.caption)
                .foregroundStyle(palette.permissionMetadata)
            Spacer(minLength: 12)
            ForEach(ZenConsentChoice.allCases) { choice in
                choiceButton(choice)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func choiceButton(_ choice: ZenConsentChoice) -> some View {
        let label = Text(choice.title).fontWeight(choice == focusedChoice ? .semibold : .regular)
        if choice == focusedChoice {
            // Disabled-looking (and deaf to clicks) during the grace period.
            Button { decide(choice.decision, trigger: .click) } label: { label }
                .buttonStyle(.glassProminent)
                .tint(palette.permissionChoice)
                .disabled(!isArmed)
        } else {
            Button { decide(choice.decision, trigger: .click) } label: { label }
                .buttonStyle(.glass)
                .foregroundStyle(palette.permissionChoice)
        }
    }

    private func restartGracePeriod() {
        consentGuard.restart()
        disarmForGracePeriod()
    }

    private func noteTyping() {
        consentGuard.noteTyping()
        disarmForGracePeriod()
    }

    /// Shows the focused button disabled and restarts the arming task.
    private func disarmForGracePeriod() {
        isArmed = false
        graceGeneration &+= 1
    }

    private func decide(_ decision: ChatConsentDecision?, trigger: ZenConsentTrigger) {
        guard consentGuard.admit(trigger) else { return }
        onDecision(decision)
    }
}

/// The command line of the sheet: the whole command, selectable, in a scroll
/// view that shrinks to it up to ``ZenConsentContent/maximumVisibleCommandLines``
/// lines and scrolls the rest. Its own view, so a geometry change does not run
/// the sheet's body.
private struct ZenConsentCommandText: View {
    let line: AttributedString

    /// The line height of ``ZenFonts/mono`` (16 points at the body size).
    @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 16
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            Text(line)
                .font(ZenFonts.mono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: ZenConsentContent.commandHeight(contentHeight: contentHeight, lineHeight: lineHeight))
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, height in
            contentHeight = height
        }
    }
}

#Preview("Consent – local.exec") {
    ZenConsentSheet(
        request: AgentToolAuthorizationRequest(
            sessionID: "preview",
            toolCallID: "call-1",
            toolName: "local.exec",
            title: "Run a shell command",
            kind: "execute",
            command: "git push --force-with-lease origin main",
            workingDirectory: NSHomeDirectory() + "/Projects/ZenCODE"
        ),
        onDecision: { _ in }
    )
}

#Preview("Consent – long command") {
    ZenConsentSheet(
        request: AgentToolAuthorizationRequest(
            sessionID: "preview",
            toolCallID: "call-3",
            toolName: "local.exec",
            title: "Run a shell command",
            kind: "execute",
            command: "cat > notes.txt <<'EOF'\n" + String(repeating: "a long line of the heredoc body\n", count: 80) + "EOF",
            workingDirectory: NSHomeDirectory() + "/Projects/ZenCODE"
        ),
        onDecision: { _ in }
    )
}

#Preview("Consent – direct tool") {
    ZenConsentSheet(
        request: AgentToolAuthorizationRequest(
            sessionID: "preview",
            toolCallID: "call-2",
            toolName: "local.delete",
            title: "Delete Sources/Old",
            kind: "delete",
            command: "",
            workingDirectory: "/tmp/project"
        ),
        onDecision: { _ in }
    )
}
