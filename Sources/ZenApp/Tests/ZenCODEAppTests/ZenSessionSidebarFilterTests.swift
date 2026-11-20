import Foundation
import Testing
import ZenCODECore

@testable import ZenCODEApp

@Suite("Saved session filtering")
@MainActor
struct ZenSessionSidebarFilterTests {
    private func summary(
        _ name: String,
        model: String? = nil,
        day: Int
    ) -> ChatSavedSessionSummary {
        ChatSavedSessionSummary(
            name: name,
            modelID: model,
            messageCount: 1,
            contextUsedTokens: nil,
            savedAt: Date(timeIntervalSince1970: TimeInterval(day))
        )
    }

    @Test("a blank query keeps every session, most recent first")
    func blankQuery() {
        let sessions = [
            summary("old", day: 1),
            summary("new", day: 2),
        ]
        #expect(ZenSessionSidebar.filteredSavedSessions(sessions, query: " \n").map(\.name) == ["new", "old"])
    }

    @Test("the query filters names and models case-insensitively")
    func nameAndModel() {
        let sessions = [
            summary("Fix login", model: "openai/gpt-5", day: 1),
            summary("Documentation", model: "anthropic/claude", day: 2),
            summary("Release", model: nil, day: 3),
        ]
        #expect(ZenSessionSidebar.filteredSavedSessions(sessions, query: "LOGIN").map(\.name) == ["Fix login"])
        #expect(ZenSessionSidebar.filteredSavedSessions(sessions, query: "Claude").map(\.name) == ["Documentation"])
        #expect(ZenSessionSidebar.filteredSavedSessions(sessions, query: "missing").isEmpty)
    }
}
