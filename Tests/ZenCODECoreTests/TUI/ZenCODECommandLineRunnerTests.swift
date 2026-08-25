//
//  ZenCODECommandLineRunnerTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODECommandLineRunnerTests {
    /// Inside an app bundle, only recognized CLI options force command-line
    /// routing. `--verbose` is no longer one of them, so a bundle launch that
    /// merely carries the removed flag must not be treated as a CLI run.
    @Test
    func verboseIsNoLongerRecognizedAsACommandLineOptionByTheLauncher() {
        let bundleExecutable = "/Applications/ZenCODE.app/Contents/MacOS/ZenCODE"
        #expect(
            !ZenCODECommandLineRunner.shouldRunAsCommandLine(
                arguments: [bundleExecutable, "--verbose"]
            )
        )
    }

    @Test
    func recognizedCommandLineOptionsStillRouteToTheCommandLine() {
        let bundleExecutable = "/Applications/ZenCODE.app/Contents/MacOS/ZenCODE"
        for option in ["--version", "--doctor", "--acp", "--model", "--max-tool-rounds"] {
            #expect(
                ZenCODECommandLineRunner.shouldRunAsCommandLine(
                    arguments: [bundleExecutable, option]
                )
            )
        }
    }
}
