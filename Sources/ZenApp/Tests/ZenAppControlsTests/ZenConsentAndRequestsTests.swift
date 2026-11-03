//
//  ZenConsentAndRequestsTests.swift
//  ZenApp
//
//  Consent decision mapping and content, and the answer-once bookkeeping of
//  the pending-request presentation.
//

import Foundation
import SwiftUI
import Synchronization
import Testing
import ZenCODECore

@testable import ZenAppControls

@Suite("ZenConsentCard")
struct ZenConsentCardTests {
    private func request(
        toolName: String = "local.exec",
        title: String = "Run a command",
        command: String,
        workingDirectory: String = "/Users/me/Projects/ZenCODE"
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            turnID: nil,
            sessionID: "s",
            toolCallID: "c",
            toolName: toolName,
            title: title,
            kind: "execute",
            command: command,
            workingDirectory: workingDirectory
        )
    }

    @Test("buttons map to the terminal decisions")
    func decisionMapping() {
        #expect(ZenConsentChoice.allCases == [.allowOnce, .allowAlways, .deny])
        #expect(ZenConsentChoice.allowOnce.decision == .allowOnce)
        #expect(ZenConsentChoice.allowAlways.decision == .allowAlways)
        #expect(ZenConsentChoice.deny.decision == .denyOnce)
        #expect(ZenConsentChoice.allCases.map(\.title) == ["Allow once", "Always allow", "Deny"])
    }

    @Test("Return defaults to Allow once like the terminal; Esc denies once")
    func defaults() {
        #expect(ZenConsentChoice.defaultChoice == .allowOnce)
        #expect(ZenConsentChoice.escapeDecision == .denyOnce)
    }

    @Test("arrow keys move the focused button, clamped")
    func focusMoves() {
        #expect(ZenConsentChoice.allowOnce.moved(by: -1) == .allowOnce)
        #expect(ZenConsentChoice.allowOnce.moved(by: 1) == .allowAlways)
        #expect(ZenConsentChoice.allowAlways.moved(by: 1) == .deny)
        #expect(ZenConsentChoice.deny.moved(by: 1) == .deny)
        #expect(ZenConsentChoice.deny.moved(by: -2) == .allowOnce)
    }

    @Test("the command splits into executable and arguments")
    func commandLine() {
        let content = ZenConsentContent(
            request: request(command: "git push --force-with-lease\n  origin main"),
            homeDirectory: "/Users/me"
        )
        #expect(content.title == "Tool consent: local.exec")
        #expect(content.executable == "git")
        #expect(content.arguments == " push --force-with-lease origin main")
        #expect(content.metadata == ["⊙ ~/Projects/ZenCODE", "always · remembered across sessions"])
        #expect(ZenConsentContent.marker == "❯ ")

        let single = ZenConsentContent(request: request(command: "ls"), homeDirectory: "/Users/me")
        #expect(single.executable == "ls")
        #expect(single.arguments == "")
    }

    @Test("without a command the title is a metadata line")
    func noCommand() {
        let content = ZenConsentContent(
            request: request(toolName: "local.delete", title: "Delete Sources/Old", command: "", workingDirectory: ""),
            homeDirectory: "/Users/me"
        )
        #expect(content.executable == nil)
        #expect(content.metadata == ["Delete Sources/Old", "always · this session only"])
    }

    @Test("control characters cannot spoof the card")
    func sanitization() {
        let content = ZenConsentContent(
            request: request(command: "rm\u{1B}[2J -rf\r/", workingDirectory: "/tmp/\u{07}x"),
            homeDirectory: "/Users/me"
        )
        #expect(content.executable == "rm")
        #expect(content.arguments == " [2J -rf /")
        #expect(content.metadata.first == "⊙ /tmp/ x")
        #expect(ZenConsentContent.sanitized("a\tb\nc\u{7F}d\u{85}e") == "a\tb\nc d e")
    }
}

/// A clock the tests move by hand.
private final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

@Suite("ZenConsentGuard")
struct ZenConsentGuardTests {
    private func makeGuard(_ clock: ManualClock) -> ZenConsentGuard {
        ZenConsentGuard(now: { clock.now })
    }

    @Test("Return and clicks are ignored for 0.5 s after the card appears")
    func gracePeriod() {
        let clock = ManualClock()
        var consentGuard = makeGuard(clock)
        #expect(consentGuard.gracePeriod == .milliseconds(500))
        #expect(!consentGuard.isArmed)
        #expect(consentGuard.remainingGrace == .milliseconds(500))
        let admitted1 = consentGuard.admit(.key(isRepeat: false))
        #expect(!admitted1)
        let admitted2 = consentGuard.admit(.click)
        #expect(!admitted2)

        clock.advance(by: .milliseconds(499))
        #expect(consentGuard.remainingGrace == .milliseconds(1))
        let admitted3 = consentGuard.admit(.key(isRepeat: false))
        #expect(!admitted3)
        #expect(!consentGuard.hasDecided)

        clock.advance(by: .milliseconds(1))
        #expect(consentGuard.isArmed)
        #expect(consentGuard.remainingGrace == .zero)
        let admitted4 = consentGuard.admit(.key(isRepeat: false))
        #expect(admitted4)
        #expect(consentGuard.hasDecided)
    }

    @Test("the card answers once")
    func answersOnce() {
        let clock = ManualClock()
        var consentGuard = makeGuard(clock)
        clock.advance(by: .seconds(1))
        let admitted5 = consentGuard.admit(.click)
        #expect(admitted5)
        let admitted6 = consentGuard.admit(.click)
        #expect(!admitted6)
        let admitted7 = consentGuard.admit(.key(isRepeat: false))
        #expect(!admitted7)
        let admitted8 = consentGuard.admit(.escape)
        #expect(!admitted8)
    }

    @Test("key repeats never answer, before or after the grace period")
    func keyRepeats() {
        let clock = ManualClock()
        var consentGuard = makeGuard(clock)
        let admitted9 = consentGuard.admit(.key(isRepeat: true))
        #expect(!admitted9)
        clock.advance(by: .seconds(5))
        let admitted10 = consentGuard.admit(.key(isRepeat: true))
        #expect(!admitted10)
        #expect(!consentGuard.hasDecided)
        let admitted11 = consentGuard.admit(.key(isRepeat: false))
        #expect(admitted11)
    }

    @Test("Esc denies at once, even during the grace period")
    func escapeDeniesAtOnce() {
        let clock = ManualClock()
        var consentGuard = makeGuard(clock)
        #expect(!consentGuard.isArmed)
        let admitted12 = consentGuard.admit(.escape)
        #expect(admitted12)
        #expect(ZenConsentChoice.escapeDecision == .denyOnce)
        clock.advance(by: .seconds(1))
        let admitted13 = consentGuard.admit(.key(isRepeat: false))
        #expect(!admitted13)
    }

    @Test("a new request restarts the grace period and allows a new answer")
    func restart() {
        let clock = ManualClock()
        var consentGuard = makeGuard(clock)
        clock.advance(by: .seconds(1))
        let admitted14 = consentGuard.admit(.key(isRepeat: false))
        #expect(admitted14)

        consentGuard.restart()
        #expect(!consentGuard.hasDecided)
        #expect(!consentGuard.isArmed)
        let admitted15 = consentGuard.admit(.key(isRepeat: false))
        #expect(!admitted15)
        let admitted16 = consentGuard.admit(.click)
        #expect(!admitted16)
        clock.advance(by: .milliseconds(500))
        let admitted17 = consentGuard.admit(.click)
        #expect(admitted17)
    }

    @Test("the grace period is injectable")
    func customGracePeriod() {
        let clock = ManualClock()
        var consentGuard = ZenConsentGuard(gracePeriod: .zero, now: { clock.now })
        #expect(consentGuard.isArmed)
        let admitted18 = consentGuard.admit(.key(isRepeat: false))
        #expect(admitted18)
    }

    @Test("typing restarts the grace period: Return answers only after a 0.5 s pause")
    func typingRestartsTheGracePeriod() {
        let clock = ManualClock()
        var consentGuard = makeGuard(clock)
        clock.advance(by: .seconds(1))
        #expect(consentGuard.isArmed)

        // A key the card does not handle disarms it again.
        consentGuard.noteTyping()
        #expect(!consentGuard.isArmed)
        #expect(consentGuard.remainingGrace == .milliseconds(500))
        clock.advance(by: .milliseconds(400))
        let early = consentGuard.admit(.key(isRepeat: false))
        #expect(!early)

        // Each key starts the pause over.
        consentGuard.noteTyping()
        clock.advance(by: .milliseconds(499))
        let stillTyping = consentGuard.admit(.click)
        #expect(!stillTyping)
        #expect(!consentGuard.hasDecided)

        clock.advance(by: .milliseconds(1))
        let afterPause = consentGuard.admit(.key(isRepeat: false))
        #expect(afterPause)
        #expect(consentGuard.hasDecided)
    }

    @Test("typing never re-opens an answered card, and Esc still denies at once")
    func typingKeepsTheAnswerAndEscape() {
        let clock = ManualClock()
        var answered = makeGuard(clock)
        clock.advance(by: .seconds(1))
        let first = answered.admit(.key(isRepeat: false))
        #expect(first)
        answered.noteTyping()
        #expect(answered.hasDecided)
        clock.advance(by: .seconds(1))
        let second = answered.admit(.key(isRepeat: false))
        #expect(!second)

        var typing = makeGuard(clock)
        clock.advance(by: .seconds(1))
        typing.noteTyping()
        let escape = typing.admit(.escape)
        #expect(escape)
    }
}

@Suite("ZenConsentKeyAction")
struct ZenConsentKeyActionTests {
    @Test("only Return chooses; Space and the other keys are typing")
    func keys() {
        #expect(ZenConsentKeyAction(.return) == .choose)
        #expect(ZenConsentKeyAction(.escape) == .deny)
        #expect(ZenConsentKeyAction(.leftArrow) == .moveFocus(by: -1))
        #expect(ZenConsentKeyAction(.rightArrow) == .moveFocus(by: 1))
        #expect(ZenConsentKeyAction(.space) == .typing)
        #expect(ZenConsentKeyAction(KeyEquivalent("a")) == .typing)
        #expect(ZenConsentKeyAction(.tab) == .typing)
        #expect(ZenConsentKeyAction(.upArrow) == .typing)
    }
}

@Suite("ZenPendingRequests")
struct ZenPendingRequestsTests {
    @Test("each kind has its presentation")
    func presentationMapping() throws {
        let items = [ChatChoiceItem(id: "a", title: "A")]
        let menuKinds: [ChatPendingRequest.Kind] = [
            .chooseOne(title: "T", items: items, selectedID: nil),
            .chooseMany(title: "T", items: items, selectedIDs: []),
            .chooseManyWithFocus(title: "T", items: items, selectedIDs: [], focusedID: nil, toggleLabel: "x", confirmLabel: "y")
        ]
        for kind in menuKinds {
            let state = try #require(ZenChoiceMenuState(kind: kind))
            #expect(ZenPendingRequestPresentation(kind: kind) == .menu(state))
        }
        #expect(ZenPendingRequestPresentation(kind: .readLine(prompt: "Name:")) == .textLine(prompt: "Name:"))
        let directory = URL(filePath: "/tmp/pictures")
        #expect(ZenPendingRequestPresentation(kind: .pickAttachment(startingAt: directory)) == .attachmentPicker(startingAt: directory))
        #expect(
            ZenPendingRequestPresentation(kind: .workspaceAccess(
                ChatWorkspaceAccessRequest(workspaceURL: directory, toolTitles: ["Files"])
            )) == .grantWorkspaceAccess
        )
        let consent = AgentToolAuthorizationRequest(
            turnID: nil,
            sessionID: nil,
            toolCallID: "c",
            toolName: "local.exec",
            title: "",
            kind: "",
            command: "ls",
            workingDirectory: "/tmp"
        )
        #expect(ZenPendingRequestPresentation(kind: .toolConsent(consent)) == .inlineConsent)
    }

    @Test("workspace access is granted and an unknown kind refused without asking")
    func automaticAnswers() throws {
        #expect(
            ZenPendingRequestPresentation.grantWorkspaceAccess.automaticAnswer
                == ZenAutomaticAnswer(answer: .workspaceAccess(granted: true))
        )
        // A kind newer than the app is answered nil, so the command never hangs.
        #expect(ZenPendingRequestPresentation.unsupported.automaticAnswer == ZenAutomaticAnswer(answer: nil))

        let state = try #require(ZenChoiceMenuState(kind: .chooseOne(title: "T", items: [], selectedID: nil)))
        let waiting: [ZenPendingRequestPresentation] = [
            .menu(state),
            .textLine(prompt: "Name:"),
            .attachmentPicker(startingAt: URL(filePath: "/tmp")),
            .inlineConsent
        ]
        for presentation in waiting {
            #expect(presentation.automaticAnswer == nil)
        }
    }

    @Test("an automatic answer is sent once per request")
    func automaticAnswerOnce() {
        var gate = ZenPendingRequestGate()
        let id = UUID()
        var answers: [ChatPendingRequest.Answer?] = []
        // The modifier answers on appearance and again on every id change;
        // the gate keeps it to one answer.
        for _ in 0..<3 {
            if let automatic = ZenPendingRequestPresentation.unsupported.automaticAnswer, gate.claim(id) {
                answers.append(automatic.answer)
            }
        }
        #expect(answers.count == 1)
        #expect(answers.first == .some(nil))
    }

    @Test("the importer answers the picked file, nil otherwise")
    func attachmentAnswer() {
        struct Failure: Error {}
        let file = URL(filePath: "/tmp/a.png")
        #expect(ZenPendingRequestPresentation.attachmentAnswer(.success([file])) == .attachment(file))
        #expect(ZenPendingRequestPresentation.attachmentAnswer(.success([])) == nil)
        #expect(ZenPendingRequestPresentation.attachmentAnswer(.failure(Failure())) == nil)
    }

    @Test("a request is claimed once")
    func claimOnce() {
        var gate = ZenPendingRequestGate()
        let id = UUID()
        #expect(gate.isOpen(id))
        let claimed1 = gate.claim(id)
        #expect(claimed1)
        #expect(!gate.isOpen(id))
        let claimed2 = gate.claim(id)
        #expect(!claimed2)
    }

    @Test("dismissing the sheet answers nil once, and only for the request on screen")
    func sheetDismissal() {
        var gate = ZenPendingRequestGate()
        let first = UUID()
        let second = UUID()

        // Nothing on screen yet.
        #expect(gate.sheetDismissalTarget(currentRequestID: first) == nil)

        gate.sheetDidAppear(first)
        #expect(gate.sheetDismissalTarget(currentRequestID: first) == first)
        // The request was withdrawn or replaced: nothing to answer.
        #expect(gate.sheetDismissalTarget(currentRequestID: nil) == nil)
        #expect(gate.sheetDismissalTarget(currentRequestID: second) == nil)

        // Answered (by a choice or by the dismissal itself): never again.
        let claimed3 = gate.claim(first)
        #expect(claimed3)
        #expect(gate.sheetDismissalTarget(currentRequestID: first) == nil)

        gate.sheetDidAppear(second)
        #expect(gate.sheetDismissalTarget(currentRequestID: second) == second)
    }

    @Test("the importer closes once dismissed or answered")
    func importerPresentation() {
        var gate = ZenPendingRequestGate()
        let id = UUID()
        #expect(gate.presentsImporter(for: id))
        gate.importerDidDismiss(id)
        #expect(!gate.presentsImporter(for: id))
        // The completion still answers it, once.
        let claimed4 = gate.claim(id)
        #expect(claimed4)
        let claimed5 = gate.claim(id)
        #expect(!claimed5)

        let next = UUID()
        #expect(gate.presentsImporter(for: next))
        let claimed6 = gate.claim(next)
        #expect(claimed6)
        #expect(!gate.presentsImporter(for: next))
    }
}
