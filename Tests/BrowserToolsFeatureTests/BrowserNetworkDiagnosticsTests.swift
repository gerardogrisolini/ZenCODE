import Foundation
@testable import BrowserToolsFeature
import Testing

@Suite
struct BrowserNetworkDiagnosticsTests {
    @Test
    func networkObserverAddsDiagnosticsFiltersRedirectsAndSafeHeaders() throws {
        let observer = BrowserNetworkObserver(capturesHeaders: true, capturesBodies: true)
        let requestHeaders: [String: Any] = [
            "Accept": "application/json",
            "Authorization": "Bearer request-secret",
            "Cookie": "session=request-cookie",
            "Referer": "https://referrer.example/page?token=referer-secret",
            "X-Api-Key": "api-key-secret",
        ]
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-id-must-not-be-serialized",
                "timestamp": 10.0,
                "type": "XHR",
                "initiator": [
                    "type": "script",
                    "url": "https://app.example/script.js?token=initiator-secret",
                    "lineNumber": 12,
                    "columnNumber": 4,
                ],
                "request": [
                    "method": "GET",
                    "url": "https://api.example/v1/items?token=url-secret&mode=debug",
                    "headers": requestHeaders,
                ] as [String: Any],
            ],
            sessionID: nil
        ))

        let responseHeaders: [String: Any] = [
            "Content-Type": "application/json",
            "Location": "https://app.example/next?token=location-secret",
            "Set-Cookie": "session=response-cookie",
            "X-Api-Key": "response-api-key-secret",
        ]
        observer.consume(CDPEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-id-must-not-be-serialized",
                "timestamp": 10.2,
                "type": "XHR",
                "response": [
                    "url": "https://api.example/v1/items?token=url-secret&mode=debug",
                    "status": 200,
                    "mimeType": "application/json",
                    "encodedDataLength": 25,
                    "fromDiskCache": true,
                    "fromServiceWorker": true,
                    "headers": responseHeaders,
                    "timing": [
                        "dnsStart": 0,
                        "dnsEnd": 2,
                        "connectStart": 2,
                        "connectEnd": 5,
                        "sslStart": 3,
                        "sslEnd": 5,
                        "sendStart": 6,
                        "sendEnd": 7,
                        "receiveHeadersStart": 12,
                        "receiveHeadersEnd": 13,
                    ] as [String: Any],
                ] as [String: Any],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-id-must-not-be-serialized",
                "timestamp": 10.25,
                "encodedDataLength": 512,
            ],
            sessionID: nil
        ))

        // The same CDP requestId represents successive redirect hops. The
        // observer retains that identifier only internally and exposes a
        // redacted chain on the later entry.
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "redirect-internal-id",
                "timestamp": 20.0,
                "type": "Document",
                "request": [
                    "method": "GET",
                    "url": "https://example.com/start?token=redirect-secret",
                ] as [String: Any],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "redirect-internal-id",
                "timestamp": 20.1,
                "type": "Document",
                "redirectResponse": [
                    "url": "https://example.com/start?token=redirect-secret",
                    "status": 302,
                    "mimeType": "text/html",
                ] as [String: Any],
                "request": [
                    "method": "GET",
                    "url": "https://example.com/next?token=next-secret",
                ] as [String: Any],
            ],
            sessionID: nil
        ))

        let filters = try BrowserNetworkFilters(
            resourceTypes: ["xhr"],
            status: 200,
            urlContains: "API"
        )
        let observation = observer.snapshot(filters: filters, limit: 1)
        let entry = try #require(observation.entries.first)

        #expect(observation.entries.count == 1)
        #expect(observation.totalCapturedEntries == 3)
        #expect(observation.totalMatchingEntries == 1)
        #expect(!observation.truncated)
        #expect(entry.method == "GET")
        #expect(entry.resourceType == "XHR")
        #expect(entry.status == 200)
        #expect(entry.mimeType == "application/json")
        #expect(entry.encodedDataLength == 512)
        #expect(entry.durationMilliseconds == 250)
        #expect(entry.timing?.dnsMilliseconds == 2)
        #expect(entry.timing?.connectMilliseconds == 3)
        #expect(entry.timing?.waitMilliseconds == 5)
        #expect(entry.fromCache == true)
        #expect(entry.fromDiskCache == true)
        #expect(entry.fromServiceWorker == true)
        #expect(entry.initiator?.type == "script")
        #expect(entry.initiator?.lineNumber == 12)
        let initiatorURL = entry.initiator?.url ?? ""
        #expect(!initiatorURL.contains("initiator-secret"))
        #expect(entry.url.contains("mode=debug"))
        #expect(!entry.url.contains("url-secret"))
        #expect((entry.requestHeaders ?? []).map(\.name) == ["accept", "referer"])
        #expect((entry.responseHeaders ?? []).map(\.name) == ["content-type", "location"])
        #expect((entry.requestHeaders ?? []).allSatisfy { !$0.name.contains("authorization") && !$0.name.contains("cookie") && !$0.name.contains("key") })
        #expect((entry.responseHeaders ?? []).allSatisfy { !$0.name.contains("cookie") && !$0.name.contains("key") })
        let referer = entry.requestHeaders?.first(where: { $0.name == "referer" })?.value ?? ""
        let location = entry.responseHeaders?.first(where: { $0.name == "location" })?.value ?? ""
        #expect(!referer.contains("referer-secret"))
        #expect(!location.contains("location-secret"))
        #expect(observation.summary.redirectCount == 1)
        #expect(observation.summary.resourceTypeCounts == ["XHR": 1])
        #expect(observation.summary.statusCounts == ["200": 1])
        #expect(observation.summary.totalEncodedDataLength == 512)

        let encodedEntry = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        #expect(!encodedEntry.contains("request-id-must-not-be-serialized"))
        #expect(!encodedEntry.contains("request-secret"))
        #expect(!encodedEntry.contains("request-cookie"))
        #expect(!encodedEntry.contains("response-cookie"))
        #expect(!encodedEntry.contains("api-key-secret"))
    }

    @Test
    func networkRedirectChainsAndBoundsRemainHostControlled() throws {
        let decodedInput = try JSONDecoder().decode(
            BrowserNetworkTool.Input.self,
            from: Data(
                #"{"pageId":"page","resourceTypes":["XHR"],"resource_type":"Fetch","status_code":404,"url_contains":"api","limit":7,"include_headers":true,"include_body":true}"#.utf8
            )
        )
        #expect(decodedInput.resolvedResourceTypes == ["XHR", "Fetch"])
        #expect(decodedInput.resolvedStatus == 404)
        #expect(decodedInput.resolvedURLContains == "api")
        #expect(decodedInput.resolvesHeaders)
        #expect(decodedInput.resolvesBody)

        let schemaData = try #require(BrowserNetworkTool.inputSchema.data(using: .utf8))
        let schemaObject = try JSONSerialization.jsonObject(with: schemaData)
        let schema = try #require(schemaObject as? [String: Any])
        let schemaProperties = try #require(schema["properties"] as? [String: Any])
        #expect(schemaProperties["resourceType"] != nil)
        #expect(schemaProperties["status"] != nil)
        #expect(schemaProperties["urlContains"] != nil)
        #expect(schemaProperties["includeHeaders"] != nil)
        #expect(schemaProperties["includeBody"] != nil)
        let includeHeadersSchema = try #require(schemaProperties["includeHeaders"] as? [String: Any])
        let includeHeadersDescription = try #require(includeHeadersSchema["description"] as? String)
        let includeBodySchema = try #require(schemaProperties["includeBody"] as? [String: Any])
        let includeBodyDescription = try #require(includeBodySchema["description"] as? String)
        #expect(BrowserNetworkTool.description.contains("raw Authorization and Cookie headers"))
        #expect(BrowserNetworkTool.description.contains("not guaranteed to be secret-free"))
        #expect(includeHeadersDescription.contains("raw Authorization and Cookie headers are omitted"))
        #expect(includeBodyDescription.lowercased().contains("recognized sensitive fields are redacted"))
        #expect(includeBodyDescription.contains("not guaranteed to be secret-free"))

        let observer = BrowserNetworkObserver()
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "redirect-id",
                "timestamp": 1.0,
                "type": "Document",
                "request": ["method": "GET", "url": "https://example.com/one?token=one"] as [String: Any],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "redirect-id",
                "timestamp": 1.1,
                "type": "Document",
                "redirectResponse": [
                    "url": "https://example.com/one?token=one",
                    "status": 301,
                    "mimeType": "text/html",
                ] as [String: Any],
                "request": ["method": "GET", "url": "https://example.com/two?token=two"] as [String: Any],
            ],
            sessionID: nil
        ))

        let entries = observer.snapshot().entries
        #expect(entries.count == 2)
        let finalEntry = try #require(entries.last)
        #expect(finalEntry.redirectChain.count == 1)
        #expect(finalEntry.redirectChain.first?.status == 301)
        let redirectURL = finalEntry.redirectChain.first?.url ?? ""
        #expect(!redirectURL.contains("token=one"))
        let output = BrowserNetworkOutput(
            page: BrowserPage(pageID: "page", title: "Example", url: "https://example.com/two"),
            observation: observer.snapshot(),
            durationSeconds: 1
        )
        #expect(output.nonGoalNotice.contains("raw Authorization or Cookie headers"))
        #expect(output.nonGoalNotice.lowercased().contains("recognized sensitive fields are redacted"))
        #expect(output.nonGoalNotice.contains("not guaranteed to be secret-free"))

        #expect(try BrowserNetworkCapture.resolvedLimit(9_999) == BrowserNetworkObserver.maximumEntries)
        #expect(throws: BrowserToolsFeatureError.self) {
            _ = try BrowserNetworkCapture.resolvedLimit(0)
        }
        #expect(throws: BrowserToolsFeatureError.self) {
            _ = try BrowserNetworkFilters(resourceTypes: ["not-a-cdp-resource"], status: nil, urlContains: nil)
        }
        #expect(throws: BrowserToolsFeatureError.self) {
            _ = try BrowserNetworkFilters(resourceTypes: ["XHR"], status: 99, urlContains: nil)
        }
        #expect(throws: BrowserToolsFeatureError.self) {
            _ = try BrowserNetworkFilters(
                resourceTypes: Array(repeating: "XHR", count: BrowserNetworkCapture.maximumResourceTypeFilters + 1),
                status: nil,
                urlContains: nil
            )
        }
    }

    @Test
    func networkBodyCaptureUsesOnlyTheCurrentFinalRedirectEntry() async throws {
        let observer = BrowserNetworkObserver(capturesBodies: true)
        let requestID = "redirect-chain-internal-id"

        // CDP reuses one requestId for each hop in this navigation. The first
        // completed entry is a 302, while Network.getResponseBody for this ID
        // would yield the JSON body of the final 200 response.
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": requestID,
                "timestamp": 1.0,
                "type": "Document",
                "request": [
                    "method": "GET",
                    "url": "https://login.example/start?state=redirect-state",
                ] as [String: Any],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": requestID,
                "timestamp": 1.1,
                "type": "Document",
                "redirectResponse": [
                    "url": "https://login.example/start?state=redirect-state",
                    "status": 302,
                    "mimeType": "text/html",
                    "encodedDataLength": 48,
                ] as [String: Any],
                "request": [
                    "method": "GET",
                    "url": "https://app.example/callback?code=authorization-code",
                ] as [String: Any],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": requestID,
                "timestamp": 1.2,
                "type": "Document",
                "response": [
                    "url": "https://app.example/callback?code=authorization-code",
                    "status": 200,
                    "mimeType": "application/json",
                    "encodedDataLength": 64,
                ] as [String: Any],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": requestID,
                "timestamp": 1.3,
                "encodedDataLength": 64,
            ],
            sessionID: nil
        ))

        let responseBodyFetcher = RedirectResponseBodyFetcher(
            body: #"{"profile":"safe","token":"final-token-secret"}"#
        )
        let redirectOnly = observer.snapshot(filters: try BrowserNetworkFilters(
            resourceTypes: ["Document"],
            status: 302,
            urlContains: nil
        ))
        let redirectOnlyWithBodies = await redirectOnly.capturingBodies(from: responseBodyFetcher)
        #expect(redirectOnlyWithBodies.entries.count == 1)
        #expect(redirectOnlyWithBodies.entries.first?.status == 302)
        #expect(redirectOnlyWithBodies.entries.first?.responseBody == nil)
        let fetchesAfterRedirectFilter = await responseBodyFetcher.requestIDs()
        #expect(fetchesAfterRedirectFilter.isEmpty)

        let allEntriesWithBodies = await observer.snapshot().capturingBodies(from: responseBodyFetcher)
        #expect(allEntriesWithBodies.entries.map(\.status) == [302, 200])
        #expect(allEntriesWithBodies.entries.first?.responseBody == nil)
        let finalBody = try #require(allEntriesWithBodies.entries.last?.responseBody)
        #expect(finalBody.text.contains("safe"))
        #expect(!finalBody.text.contains("final-token-secret"))
        let requestedBodyIDs = await responseBodyFetcher.requestIDs()
        #expect(requestedBodyIDs == [requestID])
    }

    @Test
    func networkBodyPreviewIsTextOnlyBoundedAndRedactsSensitiveValues() throws {
        let jsonPreview = try #require(BrowserNetworkBodyCapture.preview(
            body: #"{"safe":"value","token":"top-secret","nested":{"apiKey":"key-secret"}}"#,
            isBase64Encoded: false,
            mimeType: "application/json"
        ))
        #expect(jsonPreview.text.contains("value"))
        #expect(!jsonPreview.text.contains("top-secret"))
        #expect(!jsonPreview.text.contains("key-secret"))

        let encoded = Data("cookie=cookie-secret&mode=debug&token=token-secret".utf8).base64EncodedString()
        let textPreview = try #require(BrowserNetworkBodyCapture.preview(
            body: encoded,
            isBase64Encoded: true,
            mimeType: "text/plain; charset=utf-8"
        ))
        #expect(!textPreview.text.contains("cookie-secret"))
        #expect(!textPreview.text.contains("token-secret"))
        #expect(textPreview.text.contains("mode=debug"))
        #expect(BrowserNetworkBodyCapture.preview(
            body: "not textual",
            isBase64Encoded: false,
            mimeType: "image/png"
        ) == nil)

        let oversized = try #require(BrowserNetworkBodyCapture.preview(
            body: String(repeating: "x", count: BrowserNetworkBodyCapture.maximumBodyPreviewBytes + 100),
            isBase64Encoded: false,
            mimeType: "text/plain"
        ))
        #expect(oversized.truncated)
        #expect(oversized.text.lengthOfBytes(using: .utf8) <= BrowserNetworkBodyCapture.maximumBodyPreviewBytes)
    }
}

private actor RedirectResponseBodyFetcher: BrowserNetworkResponseBodyFetching {
    private let payload: BrowserNetworkResponseBodyPayload
    private var capturedRequestIDs: [String] = []

    init(body: String, isBase64Encoded: Bool = false) {
        payload = BrowserNetworkResponseBodyPayload(
            body: body,
            isBase64Encoded: isBase64Encoded
        )
    }

    func responseBody(for requestID: String) async throws -> BrowserNetworkResponseBodyPayload? {
        capturedRequestIDs.append(requestID)
        return payload
    }

    func requestIDs() -> [String] {
        capturedRequestIDs
    }
}
