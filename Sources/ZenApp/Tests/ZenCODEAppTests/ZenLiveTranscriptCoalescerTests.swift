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

        try? await Task.sleep(for: .milliseconds(40))
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
