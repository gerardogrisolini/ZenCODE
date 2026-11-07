//
//  RemoteGenerationRoundTextTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Testing
@testable import ZenCODECore

@Suite
struct RemoteGenerationRoundTextTests {
    @Test(arguments: [
        ("", "Hello", "Hello"),
        ("Hello", "", "Hello"),
        ("", "", ""),
        ("A.", "## B", "A.\n## B"),
        ("A.\n", "## B", "A.\n## B"),
        ("A.", "\n## B", "A.\n## B"),
        ("A.\r\n", "## B", "A.\r\n## B")
    ])
    func gluedRoundsAreSeparatedByLineBreak(
        accumulated: String,
        round: String,
        expected: String
    ) {
        var text = accumulated
        RemoteGenerationClient.appendRoundText(round, to: &text)
        #expect(text == expected)
    }
}
