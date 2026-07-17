//
//  TerminalStatusBarRenderingTests.swift
//  ZenCODE
//
//  Tests for the status bar render cache and cursor-hide optimisation.
//

import Foundation
import Testing
@testable import ZenCODECore

/// Thread-safe buffer that captures all text written to the injected output sink.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ text: String) {
        lock.lock()
        items.append(text)
        lock.unlock()
    }

    var writes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var combined: String {
        writes.joined()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }
}

@Suite struct TerminalStatusBarRenderingTests {

    // MARK: - Render cache

    @Test
    func identicalStatusRendersAreSuppressedByCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // First status-only render: cache is empty → writes.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Second identical render: cache hit → suppressed.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // A third call is still suppressed.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)
    }

    @Test
    func changedStatusContentTriggersWrite() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "model-a")

        // Prime the cache.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Change model to produce a different visible status.
        await bar.configureForTesting(row: 24, columns: 100, modelID: "model-b")

        await bar.renderStatusOverlay()
        #expect(captured.count == 2) // different content → writes
    }

    @Test
    func changedGeometryTriggersWriteEvenWithSameText() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "same-model")

        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Different geometry → different positioning codes in the sequence.
        await bar.configureForTesting(row: 40, columns: 120, modelID: "same-model")

        await bar.renderStatusOverlay()
        #expect(captured.count == 2)
    }

    // MARK: - Cache invalidation

    @Test
    func fullRenderUpdatesStatusCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // Prime the status cache with a status-only render.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // A full render (input panel + status) writes and updates the cache.
        await bar.renderOverlay()
        #expect(captured.count == 2)

        // Subsequent status-only render is a cache hit → suppressed.
        await bar.renderStatusOverlay()
        #expect(captured.count == 2)
    }

    @Test
    func stopClearsStatusRenderCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // Prime and verify cache is populated.
        await bar.renderStatusOverlay()
        #expect(await bar.state.lastStatusRender != nil)

        await bar.stop()

        // stop() must clear the cache so the next render is not suppressed.
        #expect(await bar.state.lastStatusRender == nil)
    }

    // MARK: - Cursor-hide placement

    @Test
    func statusOnlyRenderOmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        await bar.renderStatusOverlay()

        // ESC[?25l (cursor hide) must NOT appear in status-only updates.
        let cursorHide = "\u{1B}[?25l"
        #expect(!captured.combined.contains(cursorHide))
    }

    @Test
    func fullRenderEmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        await bar.renderOverlay()

        // ESC[?25l (cursor hide) MUST appear in full renders.
        let cursorHide = "\u{1B}[?25l"
        #expect(captured.combined.contains(cursorHide))
    }

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

    @Test
    func ordinaryStatusUpdateViaPublicAPIOmitsCursorHide() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }

        _ = await bar.start()
        await bar.stop()

        // Re-configure without signal-handler side effects.
        await bar.configureForTesting(row: 24, columns: 100, modelID: "first-model")

        captured.clear()
        // update(modelID:) triggers renderStatusLocked internally.
        _ = await bar.update(modelID: "second-model")

        let cursorHide = "\u{1B}[?25l"
        #expect(!captured.combined.contains(cursorHide))
    }

    // MARK: - Spinner animation

    @Test
    func spinnerTicksContinueToWriteDespiteCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(
            row: 24,
            columns: 100,
            modelID: "test-model",
            isProcessing: true
        )

        // First status render includes spinner frame index 0.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // Each spinner tick advances the frame → different status text →
        // cache miss → write. This guarantees animation is not frozen.
        await bar.advanceSpinner(generation: 0)
        #expect(captured.count == 2)

        await bar.advanceSpinner(generation: 0)
        #expect(captured.count == 3)
    }

    @Test
    func identicalMetricUpdateIsSuppressedByCache() async {
        let captured = CapturedOutput()
        let bar = TerminalStatusBar(isEnabled: true) { captured.append($0) }
        await bar.configureForTesting(row: 24, columns: 100, modelID: "test-model")

        // Prime the cache with a status-only render.
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // An identical status-only render is suppressed (no visible change).
        await bar.renderStatusOverlay()
        #expect(captured.count == 1)

        // A full render updates the cache; the subsequent identical status
        // render is still suppressed.
        await bar.renderOverlay()
        let countAfterFullRender = captured.count
        #expect(countAfterFullRender == 2)

        await bar.renderStatusOverlay()
        #expect(captured.count == countAfterFullRender)
    }
}
