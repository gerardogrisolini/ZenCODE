import Foundation
import Testing
import ZenAppSession
import ZenCODECore

@testable import ZenCODEApp

@Suite("Live transcript coalescing")
@MainActor
struct ZenLiveTranscriptCoalescerTests {
    private func item(_ id: String, _ text: String) -> ZenTranscriptItem {
        ZenTranscriptItem(
            id: id,
            turnID: 1,
            content: .assistantText(text, isStreaming: true)
        )
    }

    /// Waits until `condition` holds, for at most `timeout`; records an issue
    /// when the deadline passes. The deadline only bounds a failure: polling
    /// returns as soon as the condition holds, so it is generous enough for a
    /// loaded parallel run on a small CI runner.
    private func waitUntil(
        timeout: Duration = .seconds(30),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func input(
        _ text: String,
        blockID: String? = "block",
        isGenerating: Bool = true
    ) -> ZenLiveTranscriptInput {
        ZenLiveTranscriptInput(
            items: blockID.map { [item("\($0)-assistant", text)] } ?? [],
            isGenerating: isGenerating,
            blockID: blockID
        )
    }

    @Test("the first block publishes immediately and its tokens coalesce")
    func coalescesOneBlock() async {
        let coalescer = ZenLiveTranscriptCoalescer(interval: .milliseconds(5))
        coalescer.update(input("a"))
        #expect(coalescer.items.map(\.id) == ["block-assistant"])

        coalescer.update(input("ab"))
        coalescer.update(input("abc"))
        #expect(coalescer.items.first?.content == .assistantText("a", isStreaming: true))

        // The deferred publish runs on the main actor after `interval`; under a
        // loaded parallel run that can take longer than any fixed sleep, so
        // wait for it with a generous, bounded deadline.
        await waitUntil { coalescer.items.first?.content == .assistantText("abc", isStreaming: true) }
        #expect(coalescer.items.first?.content == .assistantText("abc", isStreaming: true))
        coalescer.stop()
    }

    @Test("a new block and the final update publish immediately")
    func boundariesFlush() {
        let coalescer = ZenLiveTranscriptCoalescer(interval: .seconds(10))
        coalescer.update(input("a"))
        coalescer.update(input("ab"))
        coalescer.update(input("new", blockID: "other"))
        #expect(coalescer.items.map(\.id) == ["other-assistant"])

        coalescer.update(input("newer", blockID: "other"))
        coalescer.update(input("", blockID: nil, isGenerating: false))
        #expect(coalescer.items.isEmpty)
        coalescer.stop()
    }

    @Test("flush publishes the latest pending text and cancels the timer")
    func flush() async {
        let coalescer = ZenLiveTranscriptCoalescer(interval: .seconds(10))
        coalescer.update(input("a"))
        coalescer.update(input("ab"))
        coalescer.flush()
        #expect(coalescer.items.first?.content == .assistantText("ab", isStreaming: true))
        coalescer.stop()
    }
}
