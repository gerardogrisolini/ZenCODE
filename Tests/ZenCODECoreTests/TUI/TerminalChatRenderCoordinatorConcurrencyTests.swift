//
//  TerminalChatRenderCoordinatorConcurrencyTests.swift
//  ZenCODETests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal chat writer serialization")
struct TerminalChatRenderCoordinatorConcurrencyTests {
    @Test
    func concurrentChannelWritesReceiveOneContiguousSequence() async {
        let renderer = TerminalChatRenderCoordinator(
            stdinIsTerminal: false,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: false,
            standardErrorIsTerminal: false,
            capturesWrites: true
        )
        let writeCount = 40

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<writeCount {
                group.addTask {
                    let marker = "[\(index)]"
                    if index.isMultiple(of: 2) {
                        await renderer.writeOutput(marker, preservesSpacing: true)
                    } else {
                        await renderer.writeError(marker, preservesSpacing: true)
                    }
                }
            }
        }

        let events = await renderer.capturedWriteEvents()
        let combined = events.map(\.text).joined()

        #expect(events.count == writeCount)
        #expect(events.map(\.sequence) == Array(0..<UInt64(writeCount)))
        #expect(events.filter { $0.channel == .standardOutput }.count == writeCount / 2)
        #expect(events.filter { $0.channel == .standardError }.count == writeCount / 2)
        for index in 0..<writeCount {
            #expect(combined.components(separatedBy: "[\(index)]").count == 2)
        }
    }
}
