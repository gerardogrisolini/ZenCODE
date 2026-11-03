//
//  ZenAppLauncherArgumentsTests.swift
//  ZenApp
//
//  The arguments the launcher hands to the runtime, and the failure a window
//  shows when one of them has no value.
//

import Foundation
import Testing
import ZenAppSession

@testable import ZenCODEApp

@Suite("Launcher arguments")
@MainActor
struct ZenAppLauncherArgumentsTests {
    @Test("the launcher reads the forwarded options of its command line")
    func theForwardedOptions() throws {
        let arguments = try ZenAppLauncher.launchArguments(from: [
            "/Users/me/.zencode/app/current/ZenCODE",
            "--agent", "Developer",
            "-NSDocumentRevisionsDebugMode", "YES",
            "--working-directory", "/tmp/project"
        ]).get()
        #expect(arguments == ["ZenCODE", "--agent", "Developer", "--working-directory", "/tmp/project"])
        #expect(try ZenAppLauncher.launchArguments(from: ["/path/ZenCODE"]).get() == [ZenAppLauncher.executableName])
    }

    @Test("an option without its value fails the launch with the error alone")
    func aMissingValue() {
        let result = ZenAppLauncher.launchArguments(from: ["/path/ZenCODE", "--model"])
        #expect(result == .failure(.invalidArguments("Missing value for --model.")))
        guard case let .failure(failure) = result else { return }
        #expect(failure.message == "ZenCODE: Missing value for --model.")
    }
}
