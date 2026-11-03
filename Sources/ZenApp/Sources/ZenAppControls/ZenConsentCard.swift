//
//  ZenConsentCard.swift
//  ZenApp
//
//  The inline tool-consent card: the content of the terminal consent card
//  (`LocalExecPermissionDialog`) with the run once / always / cancel choices.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// A button of the consent card.
public enum ZenConsentChoice: CaseIterable, Sendable, Identifiable {
    /// Run this call only (the terminal's `[R]un once`).
    case allowOnce
    /// Run this call and later calls with the same consent identity (the
    /// terminal's `[A]lways`).
    case allowAlways
    /// Refuse this call (the terminal's `[C]ancel`).
    case deny

    /// The focused choice when the card appears: like the terminal, Return
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

/// What a key does on the consent card. Like the terminal card, only Return
/// chooses: Space is typing, as any other key the card does not handle.
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

/// The text of a consent card, built from the request like the terminal
/// consent card: untrusted fields are stripped of control characters and
/// collapsed to one line.
struct ZenConsentContent: Equatable {
    /// `"Tool consent: <toolName>"`.
    let title: String
    /// The executable token of the command, `nil` without a command.
    let executable: String?
    /// The rest of the command after the executable, with its leading
    /// whitespace.
    let arguments: String
    /// Muted lines: the request title (without a command), the working
    /// directory (`⊙ ~/path`), and the scope of "Always".
    let metadata: [String]

    /// The marker before the command.
    static let marker = "❯ "

    init(request: AgentToolAuthorizationRequest, homeDirectory: String = NSHomeDirectory()) {
        title = "Tool consent: \(Self.singleLined(Self.sanitized(request.toolName)))"

        let command = Self.singleLined(Self.sanitized(request.command))
        if command.isEmpty {
            executable = nil
            arguments = ""
        } else if let boundary = command.firstIndex(where: \.isWhitespace) {
            executable = String(command[..<boundary])
            arguments = String(command[boundary...])
        } else {
            executable = command
            arguments = ""
        }

        var metadata: [String] = []
        if command.isEmpty {
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
    /// a crafted command cannot spoof the card.
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

/// The inline tool-consent card, tinted with the permission border color.
///
/// It shows the tool, the command (`❯` marker, bold executable, plain
/// arguments) or the request title, the working directory and the scope of
/// "Always", then Allow once / Always allow / Deny. Allow once is focused
/// when the card appears, like the terminal's default; ←/→ move the focus,
/// Return chooses the focused button, Esc denies. Space does not choose, as
/// in the terminal. The card answers once.
///
/// Return and clicks are ignored for 0.5 s after the card appears, after
/// its request changes, and after any key it does not handle (a typist must
/// pause before Return answers), and key repeats always are, so a keystroke
/// meant for the composer cannot approve a call; the focused button looks
/// disabled meanwhile. Esc denies at once (``ZenConsentGuard``).
public struct ZenConsentCard: View {
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
        VStack(alignment: .leading, spacing: 10) {
            Text(content.title)
                .font(.headline)
                .foregroundStyle(palette.permissionTitle)

            VStack(alignment: .leading, spacing: 4) {
                if let executable = content.executable {
                    commandLine(executable: executable, arguments: content.arguments)
                }
                ForEach(Array(content.metadata.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(ZenFonts.monoSmall)
                        .foregroundStyle(palette.permissionMetadata)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 8) {
                ForEach(ZenConsentChoice.allCases) { choice in
                    choiceButton(choice)
                }
                Spacer(minLength: 0)
                Text("Return: \(focusedChoice.title) · Esc: Deny")
                    .font(.caption)
                    .foregroundStyle(palette.permissionMetadata)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zenGlassCard(tint: palette.permissionBorder, cornerRadius: 16, padding: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(palette.permissionBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
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

    private func commandLine(executable: String, arguments: String) -> some View {
        var line = AttributedString(ZenConsentContent.marker)
        line.foregroundColor = palette.permissionMarker
        var executablePart = AttributedString(executable)
        executablePart.foregroundColor = palette.permissionChoice
        executablePart.inlinePresentationIntent = .stronglyEmphasized
        line.append(executablePart)
        var argumentsPart = AttributedString(arguments)
        argumentsPart.foregroundColor = palette.textPrimary
        line.append(argumentsPart)
        return Text(line)
            .font(ZenFonts.mono)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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

#Preview("Consent – local.exec") {
    ZenConsentCard(
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
    .padding()
    .frame(width: 640)
}

#Preview("Consent – direct tool") {
    ZenConsentCard(
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
    .padding()
    .frame(width: 640)
}
