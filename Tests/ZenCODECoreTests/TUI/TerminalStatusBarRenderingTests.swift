//
//  TerminalStatusBarRenderingTests.swift
//  ZenCODE
//
//  Tests for the status bar render cache and cursor-hide optimisation.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Thread-safe buffer that captures all text written to the injected output sink.
private final class CapturedOutput: Sendable {
    private let items = Mutex<[String]>([])

    func append(_ text: String) {
        items.withLock { $0.append(text) }
    }

    var writes: [String] {
        items.withLock { $0 }
    }

    var combined: String {
        writes.joined()
    }

    var count: Int {
        items.withLock { $0.count }
    }

    func clear() {
        items.withLock { $0.removeAll() }
    }
}

@Suite(.serialized, TerminalBlockingTestScope())
struct TerminalStatusBarRenderingTests {

    // MARK: - Cursor-hide placement

    @Test
    func startEmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }

        let started = await bar.start()
        #expect(started)

        // start() emits cursor-hide explicitly before the first full render.
        let cursorHide = "\u{1B}[?25l"
        #expect(captured.combined.contains(cursorHide))

        await bar.stop()
    }

}
