import Foundation
import Testing
import ZenAppSession
import ZenCODECore

@testable import ZenCODEApp

@Suite("Transcript search")
struct ZenTranscriptSearchTests {
    private func item(_ id: String, text: String) -> ZenTranscriptItem {
        ZenTranscriptItem(id: id, turnID: 1, content: .assistantText(text, isStreaming: false))
    }

    private func row(_ id: String, text: String) -> ZenConversationRow {
        ZenConversationRow(item: item(id, text: text), showsSeparator: false)
    }

    @Test("visible rows and the live block match case-insensitively")
    func matchesVisibleContent() {
        var search = ZenTranscriptSearchState()
        search.update(rows: [
            row("one", text: "Build the project"),
            row("two", text: "Nothing relevant"),
        ])
        search.update(liveItems: [item("live", text: "Another BUILD result")])
        search.query = "build"
        search.present()
        #expect(search.matchIDs == ["one", "live"])
        #expect(search.selectedMatchID == "one")
        #expect(search.statusText == "1 of 2")

        search.update(liveItems: [])
        #expect(search.matchIDs == ["one"])
        #expect(search.statusText == "1 of 1")
    }

    @Test("next and previous wrap around the results")
    func navigationWraps() {
        var search = ZenTranscriptSearchState()
        search.query = "answer"
        search.update(rows: [
            row("one", text: "answer one"),
            row("two", text: "answer two"),
            row("three", text: "answer three"),
        ], liveItems: [])
        search.present()
        search.move(by: -1)
        #expect(search.selectedMatchID == "three")
        search.move(by: 1)
        #expect(search.selectedMatchID == "one")
        search.move(by: 1)
        #expect(search.selectedMatchID == "two")

        // A refresh keeps the selected row when it still matches.
        search.update(rows: [
            row("one", text: "answer one changed"),
            row("two", text: "answer two changed"),
        ], liveItems: [])
        #expect(search.selectedMatchID == "two")
    }

    @Test("blank and unmatched queries have no selection")
    func emptyStates() {
        var search = ZenTranscriptSearchState()
        search.update(rows: [row("one", text: "text")])
        search.present()
        #expect(search.matchIDs.isEmpty)
        #expect(search.statusText.isEmpty)

        search.query = "missing"
        search.refreshMatches()
        #expect(search.matchIDs.isEmpty)
        #expect(search.selectedIndex == nil)
        #expect(search.statusText == "No results")
        search.move(by: 1)
        #expect(search.selectedIndex == nil)
    }

    @Test("prompt attachment names and tool output are searchable")
    func contentSources() {
        let prompt = ZenTranscriptItem.Content.userPrompt(
            text: "Look at this",
            attachments: [.init(kind: .image, originalFilename: "Login Screen.png")],
            origin: .app
        )
        let call = DirectAgentToolCall(
            id: "call",
            name: "local.exec",
            argumentsObject: ["command": "swift test"],
            argumentsJSON: "{}"
        )
        let tool = ZenTranscriptItem.Content.toolCall(
            call: call,
            result: DirectAgentToolResult(output: "Compiling ZenCODEApp", summary: "ok")
        )
        #expect(ZenTranscriptSearchState.text(for: prompt).localizedStandardContains("login screen"))
        #expect(ZenTranscriptSearchState.text(for: tool).localizedStandardContains("compiling zencodeapp"))
        #expect(ZenTranscriptSearchState.text(for: tool).localizedStandardContains("swift test"))
    }
}
