import Foundation
@testable import BrowserToolsFeature
import Testing

extension BrowserToolsFeatureTests {
    @Test
    func trustedDebuggerURLMustRemainOnExpectedLoopbackPort() {
        #expect(
            ChromeBrowserManager.isTrustedDebuggerURL(
                URL(string: "ws://127.0.0.1:48123/devtools/page/test")!,
                expectedPort: 48_123
            )
        )
        #expect(!ChromeBrowserManager.isTrustedDebuggerURL(
            URL(string: "ws://example.com:48123/devtools/page/test")!,
            expectedPort: 48_123
        ))
        #expect(!ChromeBrowserManager.isTrustedDebuggerURL(
            URL(string: "ws://127.0.0.1:48124/devtools/page/test")!,
            expectedPort: 48_123
        ))
    }

    @Test
    func cdpSessionRoutesUncorrelatedEventsToObservers() {
        let session = CDPSession(
            webSocketURL: URL(string: "ws://127.0.0.1:9/devtools/page/test")!
        )
        let recorder = EventRecorder()
        let token = session.addEventHandler { event in
            recorder.append(event)
        }
        defer { session.removeEventHandler(token) }

        session.handleMessage(Data(#"{"method":"Network.loadingFailed","params":{"requestId":"42"},"sessionId":"child"}"#.utf8))
        session.handleMessage(Data(#"{"id":1,"result":{}}"#.utf8))

        let events = recorder.events
        #expect(events.count == 1)
        #expect(events.first?.method == "Network.loadingFailed")
        #expect(events.first?.sessionID == "child")
        #expect(events.first?.params["requestId"] as? String == "42")
    }

    @Test
    func fetchRequestDecoderAcceptsOnlyCompleteRequestStageEvents() {
        let paused = BrowserFetchPausedRequest.decode(browserCDPEvent("Fetch.requestPaused", [
            "requestId": "fetch-1",
            "request": ["url": "https://example.com/redirect"],
        ]))
        #expect(paused == BrowserFetchPausedRequest(
            requestID: "fetch-1",
            url: "https://example.com/redirect"
        ))
        #expect(BrowserFetchPausedRequest.decode(browserCDPEvent("Network.requestWillBeSent", [:])) == nil)
        #expect(BrowserFetchPausedRequest.decode(browserCDPEvent("Fetch.requestPaused", ["requestId": "missing-url"])) == nil)
    }

    @Test
    func consoleSelectionAppliesSeverityAndHostSideBound() throws {
        let entries = [
            BrowserConsoleEntry(level: "info", text: "started", timestamp: 1),
            BrowserConsoleEntry(level: "warn", text: "slow", timestamp: 2),
            BrowserConsoleEntry(level: "error", text: "failed", timestamp: 3),
        ]

        let selection = BrowserConsoleCapture.select(entries, level: .warn, limit: 1)
        #expect(selection.totalMatchingEntries == 2)
        #expect(selection.truncated)
        #expect(selection.entries.map(\.text) == ["failed"])
        #expect(try BrowserConsoleCapture.resolvedLimit(500) == 100)
    }

    @Test
    func networkObserverCorrelatesRequestResponseAndFailureEvents() throws {
        let observer = BrowserNetworkObserver()
        observer.consume(browserCDPEvent("Network.requestWillBeSent", [
            "requestId": "request-1",
            "type": "Document",
            "request": ["method": "GET", "url": "https://example.com/"],
        ]))
        observer.consume(browserCDPEvent("Network.responseReceived", [
            "requestId": "request-1",
            "type": "Document",
            "response": ["url": "https://example.com/", "status": 200],
        ]))
        observer.consume(browserCDPEvent("Network.loadingFailed", [
            "requestId": "request-1",
            "type": "Document",
            "errorText": "net::ERR_ABORTED",
        ]))

        let entry = try #require(observer.snapshot().entries.first)
        #expect(entry.method == "GET")
        #expect(entry.status == 200)
        #expect(entry.failure == "net::ERR_ABORTED")
        #expect(entry.resourceType == "Document")

        let redacted = BrowserNetworkURLRedaction.apply(
            to: "https://user:password@example.com/path?token=secret&mode=debug#fragment"
        )
        #expect(!redacted.contains("user:password"))
        #expect(!redacted.contains("secret"))
        #expect(!redacted.contains("#fragment"))
        #expect(redacted.contains("mode=debug"))
    }
}
