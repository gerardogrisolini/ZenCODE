//
//  ZenCODECommandLineRunnerTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODECommandLineRunnerTests {
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
