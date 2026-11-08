//
//  ZenLaunchFailureViewTests.swift
//  ZenApp
//
//  The text of the window when the runtime could not launch: the message of
//  the failure, and the hint under it only when the start itself failed.
//

import Testing
import ZenAppSession

@testable import ZenCODEApp

@Suite("Launch failure view")
struct ZenLaunchFailureViewTests {
    @Test("only a failed start shows the hint to run zen")
    func theHintOfAFailedStart() {
        #expect(ZenLaunchFailureView.hint(for: .startFailed("The sessions cannot be read."))
            == "Run `zen --setup` in a terminal to set up ZenCODE, or `zen --doctor` to check it, then start the app again.")
        #expect(ZenLaunchFailureView.hint(for: .startFailed("")) == ZenLaunchFailureView.startFailedHint)
    }

    @Test("a missing setup is not told twice to run zen")
    func noHintWhenNotConfigured() {
        let failure = ZenAppLaunchFailure.notConfigured(
            "\(ZenAppLaunchFailure.notConfiguredMessage)\nThe settings file is missing."
        )
        #expect(ZenLaunchFailureView.hint(for: failure) == nil)
        #expect(failure.message.hasPrefix(ZenAppLaunchFailure.notConfiguredMessage))
    }

    @Test("a wrong argument is shown without the setup hint")
    func noHintForAWrongArgument() {
        let failure = ZenAppLaunchFailure.invalidArguments("Unknown agent 'Nobody'.")
        #expect(ZenLaunchFailureView.hint(for: failure) == nil)
        #expect(failure.message == "ZenCODE: Unknown agent 'Nobody'.")
    }
}
