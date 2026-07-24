//
//  TerminalConsentInputOwnershipTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

/// Uses dedicated arbiter instances rather than the process-wide `shared` one,
/// so these expectations stay deterministic while other suites run in parallel.
@Suite
struct TerminalConsentInputOwnershipTests {
    @Test
    func backgroundReadsAreRefusedWhileConsentOwnsTheTerminal() async {
        let ownership = TerminalConsentInputOwnership()
        #expect(!ownership.isConsentActive)
        #expect(ownership.beginBackgroundRead())
        ownership.endBackgroundRead()

        await ownership.beginConsent()
        defer { ownership.endConsent() }

        #expect(ownership.isConsentActive)
        // The Esc-to-stop monitor must not consume the operator's r/a/c answer.
        #expect(!ownership.beginBackgroundRead())
        #expect(ownership.withBackgroundRead { true } == nil)
    }

    @Test
    func backgroundReadsResumeAfterConsentEnds() async {
        let ownership = TerminalConsentInputOwnership()
        await ownership.beginConsent()
        #expect(!ownership.beginBackgroundRead())
        ownership.endConsent()

        #expect(!ownership.isConsentActive)
        #expect(ownership.withBackgroundRead { true } == true)
    }

    @Test
    func nestedConsentClaimsKeepTheTerminalOwnedUntilTheLastRelease() async {
        // Retry rounds and queued dialogs must not hand the terminal back early.
        let ownership = TerminalConsentInputOwnership()
        await ownership.beginConsent()
        await ownership.beginConsent()

        ownership.endConsent()
        #expect(ownership.isConsentActive)
        #expect(!ownership.beginBackgroundRead())

        ownership.endConsent()
        #expect(!ownership.isConsentActive)
        #expect(ownership.withBackgroundRead { true } == true)
    }

    @Test
    func consentWaitsForAnInFlightBackgroundRead() async {
        let ownership = TerminalConsentInputOwnership()
        #expect(ownership.beginBackgroundRead())

        let claim = Task {
            await ownership.beginConsent()
            return true
        }

        // The claim is registered immediately (blocking further background
        // reads) but only completes once the in-flight read reports completion.
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(!ownership.beginBackgroundRead())

        ownership.endBackgroundRead()
        #expect(await claim.value)
        ownership.endConsent()
        #expect(!ownership.isConsentActive)
    }
}
