import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopFrontmostPolicyTests {
    // MARK: Source of the frontmost app

    @Test
    func accessibilityWinsOverTheFallback() {
        let choice = DesktopFrontmostPolicy.choose(accessibilityPID: 100, fallback: 200)
        #expect(choice == DesktopFrontmostPolicy.Choice(pid: 100, source: .accessibility))
    }

    @Test
    func theFallbackIsUsedWhenAccessibilityGivesNothing() {
        let choice = DesktopFrontmostPolicy.choose(accessibilityPID: nil, fallback: 200)
        #expect(choice == DesktopFrontmostPolicy.Choice(pid: 200, source: .workspace))
    }

    @Test
    func nothingIsChosenWhenNeitherSourceNamesAnApp() {
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: nil, fallback: nil) == nil)
    }

    @Test
    func aNonPositivePidCountsAsNoAnswer() {
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: 0, fallback: 7)
            == DesktopFrontmostPolicy.Choice(pid: 7, source: .workspace))
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: -1, fallback: nil) == nil)
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: nil, fallback: 0) == nil)
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: 5, fallback: 0)?.pid == 5)
    }

    @Test
    func theFallbackIsReadOnlyWhenAccessibilityFails() {
        var reads = 0
        func fallback() -> pid_t? {
            reads += 1
            return 9
        }
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: 3, fallback: fallback())?.pid == 3)
        #expect(reads == 0)
        #expect(DesktopFrontmostPolicy.choose(accessibilityPID: nil, fallback: fallback())?.pid == 9)
        #expect(reads == 1)
    }

    @Test
    func sourcesAreNamedInMessages() {
        #expect(DesktopFrontmostPolicy.Source.accessibility.label == "Accessibility")
        #expect(DesktopFrontmostPolicy.Source.workspace.label == "NSWorkspace")
    }

    // MARK: Observations

    private let target: pid_t = 100
    private let other: pid_t = 200

    private func observation(
        frontmost: pid_t?, source: DesktopFrontmostPolicy.Source = .accessibility, probe: Bool? = nil,
        top: pid_t? = nil, ownsWindow: Bool = false
    ) -> DesktopActivationPolicy.Observation {
        DesktopActivationPolicy.Observation(
            frontmost: frontmost.map { DesktopFrontmostPolicy.Choice(pid: $0, source: source) },
            probeActive: probe, topWindowPID: top, targetOwnsVisibleWindow: ownsWindow
        )
    }

    @Test
    func accessibilityDecidesAloneWhenItNamedTheFrontmostApp() {
        #expect(DesktopActivationPolicy.isFrontmost(observation(frontmost: target), target: target))
        // The probe says active, but Accessibility names another app: the app is not frontmost.
        #expect(!DesktopActivationPolicy.isFrontmost(observation(frontmost: other, probe: true), target: target))
        // The probe says inactive, but Accessibility names the app: it is.
        #expect(DesktopActivationPolicy.isFrontmost(observation(frontmost: target, probe: false), target: target))
    }

    @Test
    func theProbeDecidesWhenOnlyTheWorkspaceFallbackAnswered() {
        // NSWorkspace can be stale in this worker, so it does not outweigh a fresh probe.
        #expect(DesktopActivationPolicy.isFrontmost(observation(frontmost: other, source: .workspace, probe: true), target: target))
        #expect(!DesktopActivationPolicy.isFrontmost(observation(frontmost: other, source: .workspace, probe: false), target: target))
        #expect(!DesktopActivationPolicy.isFrontmost(observation(frontmost: other, source: .workspace), target: target))
        #expect(DesktopActivationPolicy.isFrontmost(observation(frontmost: target, source: .workspace), target: target))
        #expect(!DesktopActivationPolicy.isFrontmost(observation(frontmost: target, source: .workspace, probe: false), target: target))
        // No source named an app at all: the probe is all there is.
        #expect(DesktopActivationPolicy.isFrontmost(observation(frontmost: nil, probe: true), target: target))
        #expect(!DesktopActivationPolicy.isFrontmost(observation(frontmost: nil), target: target))
    }

    @Test
    func theWaitIsOverOnlyWhenTheFirstVisibleWindowIsTheApps() {
        // Frontmost, and no window on screen to wait for.
        #expect(DesktopActivationPolicy.isSettled(observation(frontmost: target, top: other), target: target))
        // Frontmost, with a window on screen that is first in Z order.
        #expect(DesktopActivationPolicy.isSettled(observation(frontmost: target, top: target, ownsWindow: true), target: target))
        // Frontmost, but another app's window is still in front.
        #expect(!DesktopActivationPolicy.isSettled(observation(frontmost: target, top: other, ownsWindow: true), target: target))
        #expect(!DesktopActivationPolicy.isSettled(observation(frontmost: target, top: nil, ownsWindow: true), target: target))
        // A window in front is not enough without the frontmost app.
        #expect(!DesktopActivationPolicy.isSettled(observation(frontmost: other, top: target, ownsWindow: true), target: target))
    }

    @Test
    func theAccessibilityFallbackStartsAfterOneSecondOrHalfAShortTimeout() {
        #expect(DesktopActivationPolicy.accessibilityFallbackDelay(timeout: 5) == 1)
        #expect(DesktopActivationPolicy.accessibilityFallbackDelay(timeout: 2) == 1)
        #expect(DesktopActivationPolicy.accessibilityFallbackDelay(timeout: 1) == 0.5)
        #expect(DesktopActivationPolicy.accessibilityFallbackDelay(timeout: 0) == 0)
        #expect(DesktopActivationPolicy.accessibilityFallbackDelay(timeout: -3) == 0)
    }

    // MARK: Outcome

    private func outcome(_ observation: DesktopActivationPolicy.Observation) -> DesktopActivationPolicy.Outcome {
        DesktopActivationPolicy.outcome(
            observation, target: target, targetName: "Calculator", frontmostName: "Safari", topWindowName: "Safari"
        )
    }

    @Test
    func aSettledAppIsConfirmed() {
        #expect(outcome(observation(frontmost: target, probe: true, top: target, ownsWindow: true)) == .confirmed)
        #expect(outcome(observation(frontmost: target)) == .confirmed)
    }

    @Test
    func theProbeSayingActiveWhileAccessibilityNamesAnotherAppIsADiscrepancyNotAnError() throws {
        let result = outcome(observation(frontmost: other, probe: true))
        guard case let .unconfirmed(note) = result else {
            Issue.record("expected an unconfirmed outcome, got \(result)")
            return
        }
        #expect(note.contains("application-state probe reports Calculator as active"))
        #expect(note.contains("Accessibility reports Safari as the frontmost app"))
        #expect(note.contains("list_windows or a screenshot"))
    }

    @Test
    func aFrontmostAppWhoseWindowsAreStillBehindIsAnUnconfirmedActivation() throws {
        let result = outcome(observation(frontmost: target, top: other, ownsWindow: true))
        guard case let .unconfirmed(note) = result else {
            Issue.record("expected an unconfirmed outcome, got \(result)")
            return
        }
        #expect(note.contains("Calculator is reported as the frontmost app"))
        #expect(note.contains("first window in the on-screen order belongs to Safari"))
    }

    @Test
    func anAppThatNoSourceReportsActiveIsNotActive() {
        #expect(outcome(observation(frontmost: other, probe: false)) == .notActive)
        #expect(outcome(observation(frontmost: other)) == .notActive)
        #expect(outcome(observation(frontmost: nil)) == .notActive)
        #expect(outcome(observation(frontmost: other, source: .workspace, probe: false)) == .notActive)
    }

    @Test
    func theDiscrepancyNoteNamesTheMissingFrontmostApp() throws {
        let result = DesktopActivationPolicy.outcome(
            observation(frontmost: other, probe: true), target: target, targetName: "Calculator",
            frontmostName: nil, topWindowName: nil
        )
        guard case let .unconfirmed(note) = result else {
            Issue.record("expected an unconfirmed outcome, got \(result)")
            return
        }
        #expect(note.contains("reports no frontmost app"))
    }

    @Test
    func theSummaryDoesNotClaimMoreThanIsKnown() {
        #expect(DesktopActivationPolicy.summary(.confirmed, name: "Calculator") == "Activated Calculator.")
        let unconfirmed = DesktopActivationPolicy.summary(.unconfirmed(note: "x"), name: "Calculator")
        #expect(unconfirmed.contains("not confirmed as the frontmost app"))
        #expect(!unconfirmed.hasPrefix("Activated"))
    }

    @Test
    func activationDefaultsMatchTheDocumentedTimeout() {
        #expect(DesktopActivationPolicy.defaultTimeout == 5)
        #expect(DesktopActivationPolicy.timeoutRange == 0...30)
    }
}
