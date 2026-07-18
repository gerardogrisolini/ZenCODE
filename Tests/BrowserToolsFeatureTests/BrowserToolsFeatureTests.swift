import Foundation
@testable import BrowserToolsFeature
@testable import ZenCODECore
import FeatureKit
import Testing

@Suite
struct BrowserToolsFeatureTests {
    @Test
    func browserURLPolicyAllowsPublicAndLoopbackDestinations() throws {
        let policy = BrowserURLPolicy(environment: [:])

        #expect(try policy.validate("https://example.com/path?q=1").host == "example.com")
        #expect(try policy.validate("http://localhost:8080").host == "localhost")
        #expect(try policy.validate("http://127.0.0.1:3000").host == "127.0.0.1")
        #expect(try policy.validate("http://[::1]:8080").host == "::1")
    }

    @Test
    func browserURLPolicyRejectsUnsafeAndAmbiguousDestinations() {
        let policy = BrowserURLPolicy(environment: [:])

        #expect(throws: BrowserURLPolicyError.unsupportedScheme("file")) {
            try policy.validate("file:///tmp/private")
        }
        #expect(throws: BrowserURLPolicyError.credentialsNotAllowed("https://user:secret@example.com")) {
            try policy.validate("https://user:secret@example.com")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validate("http://10.0.0.1")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("169.254.169.254")) {
            try policy.validate("http://169.254.169.254/latest/meta-data")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("0177.0.0.1")) {
            try policy.validate("http://0177.0.0.1")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("service.local")) {
            try policy.validate("https://service.local")
        }
    }

    @Test
    func browserURLPolicyPrivateNetworkOverrideIsHostControlled() throws {
        let policy = BrowserURLPolicy(environment: [
            "ZENCODE_BROWSER_ALLOW_PRIVATE_NETWORK": "true"
        ])

        #expect(try policy.validate("http://10.0.0.1:8080").host == "10.0.0.1")
        #expect(try policy.validate("https://service.local").host == "service.local")
    }

    @Test
    func googleConsentClickIsLimitedToGoogleOwnedOrigin() {
        #expect(BrowserGoogleConsentOriginPolicy.allows(host: "google.com"))
        #expect(BrowserGoogleConsentOriginPolicy.allows(host: "consent.google.com"))
        #expect(!BrowserGoogleConsentOriginPolicy.allows(host: "google.com.evil.example"))
        #expect(!BrowserGoogleConsentOriginPolicy.allows(host: "notgoogle.com"))
        #expect(!BrowserGoogleConsentOriginPolicy.allows(host: "www.google.it"))
    }

    @Test
    func browserOpenValidatesDestinationBeforeLaunchingChrome() async {
        let tool = AnyFeatureTool(BrowserOpenTool())
        let context = FeatureContext(environment: [:])

        await #expect(throws: BrowserURLPolicyError.restrictedHost("10.0.0.1")) {
            try await tool.invoke(
                inputData: Data(#"{"url":"http://10.0.0.1"}"#.utf8),
                context: context
            )
        }
    }

    @Test
    func chromeConfigurationUsesExplicitEnvironmentOverrides() {
        let configuration = ChromeBrowserConfiguration(environment: [
            "HOME": "/tmp/home",
            "ZENCODE_BROWSER_CDP_PORT": "48123",
            "ZENCODE_BROWSER_HEADLESS": "1",
            "ZENCODE_BROWSER_ALLOW_UNSANDBOXED_ROOT": "yes",
        ])

        #expect(configuration.portOverride == 48_123)
        #expect(configuration.profileDirectory.path == "/tmp/home/.zencode/browser")
        #expect(configuration.launchesHeadless)
        #expect(configuration.allowsUnsandboxedRoot)
    }

    @Test
    func cdpSessionConfigurationBoundsHostSideLimits() {
        let configured = CDPSessionConfiguration(environment: [
            "ZENCODE_BROWSER_CDP_COMMAND_TIMEOUT_SECONDS": "12",
            "ZENCODE_BROWSER_CDP_MAX_MESSAGE_BYTES": "1048576",
        ])
        #expect(configured.commandTimeoutNanoseconds == 12_000_000_000)
        #expect(configured.maximumMessageSize == 1_048_576)

        let invalid = CDPSessionConfiguration(environment: [
            "ZENCODE_BROWSER_CDP_COMMAND_TIMEOUT_SECONDS": "0",
            "ZENCODE_BROWSER_CDP_MAX_MESSAGE_BYTES": "1",
        ])
        #expect(invalid.commandTimeoutNanoseconds == 30_000_000_000)
        #expect(invalid.maximumMessageSize == 8 * 1024 * 1024)
    }

    @Test
    func browserReadBudgetTruncatesOnUTF8CharacterBoundaries() {
        let content = String(repeating: "é", count: 100)
        let clipped = BrowserContentBudget.clip(content, maximumBytes: 80)

        #expect(clipped.originalByteCount == 200)
        #expect(clipped.wasTruncated)
        #expect(clipped.content.contains("[Content truncated by Browser read budget.]"))
        #expect(clipped.content.lengthOfBytes(using: .utf8) <= 80)
        #expect(clipped.content.data(using: .utf8) != nil)
    }

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
    func accessibilitySnapshotUsesSemanticRolesAndBoundsInteractiveResults() throws {
        let response: [String: Any] = [
            "result": [
                "nodes": [
                    [
                        "nodeId": "1",
                        "ignored": false,
                        "role": ["value": "RootWebArea"],
                        "name": ["value": "Example"],
                    ],
                    [
                        "nodeId": "2",
                        "backendDOMNodeId": 42,
                        "ignored": false,
                        "role": ["value": "button"],
                        "name": ["value": "Save"],
                        "properties": [
                            ["name": "focusable", "value": ["value": true]],
                            ["name": "disabled", "value": ["value": true]],
                        ],
                    ],
                    [
                        "nodeId": "3",
                        "ignored": true,
                        "role": ["value": "link"],
                    ],
                ],
            ],
        ]

        let allNodes = try BrowserAccessibilitySnapshot.parse(response, interactiveOnly: false)
        #expect(allNodes.totalNodeCount == 2)
        #expect(allNodes.nodes.map(\.ref) == ["ax-1", "ax-2"])

        let interactiveNodes = try BrowserAccessibilitySnapshot.parse(response, interactiveOnly: true)
        let button = try #require(interactiveNodes.nodes.first)
        #expect(interactiveNodes.totalNodeCount == 1)
        #expect(button.role == "button")
        #expect(button.name == "Save")
        #expect(button.interactive)
        #expect(button.states == ["disabled"])
        #expect(interactiveNodes.targets["ax-2"]?.backendDOMNodeID == 42)
    }

    @Test
    func controlledInteractionGuardsSensitiveInputsAndKeys() throws {
        let password = BrowserDOMElementInfo(
            tagName: "input",
            attributes: ["type": "password"]
        )
        let upload = BrowserDOMElementInfo(
            tagName: "input",
            attributes: ["type": "file"]
        )
        let textArea = BrowserDOMElementInfo(
            tagName: "textarea",
            attributes: [:]
        )
        let contentEditable = BrowserDOMElementInfo(
            tagName: "div",
            attributes: ["contenteditable": ""]
        )

        #expect(password.isPasswordLike)
        #expect(!password.isFileInput)
        #expect(upload.isFileInput)
        #expect(upload.isSupportedFillTarget)
        #expect(textArea.isSupportedFillTarget)
        #expect(contentEditable.isSupportedFillTarget)
        #expect(try BrowserActionKind.resolve("CLICK") == .click)
        #expect(try BrowserDialogAction.resolve("dismiss") == .dismiss)
        #expect(try BrowserKeyStroke.resolve("Arrow_Down").key == "ArrowDown")
        #expect(throws: BrowserInteractionError.unsupportedKey("a")) {
            try BrowserKeyStroke.resolve("a")
        }
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
        observer.consume(CDPEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-1",
                "type": "Document",
                "request": ["method": "GET", "url": "https://example.com/"],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-1",
                "type": "Document",
                "response": ["url": "https://example.com/", "status": 200],
            ],
            sessionID: nil
        ))
        observer.consume(CDPEvent(
            method: "Network.loadingFailed",
            params: [
                "requestId": "request-1",
                "type": "Document",
                "errorText": "net::ERR_ABORTED",
            ],
            sessionID: nil
        ))

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

    @Test
    func screenshotArtifactStoreRetainsTheNewFileInsideItsOwnedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserToolsFeatureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserArtifactStore(
            rootDirectory: root,
            maximumArtifactCount: 1,
            retentionAge: 24 * 60 * 60
        )
        let first = try store.storeScreenshotPNG(Data([0x89, 0x50, 0x4E, 0x47]), pageID: "page/unsafe")
        let second = try store.storeScreenshotPNG(Data([0x89, 0x50, 0x4E, 0x47]), pageID: "page-2")

        #expect(first.mimeType == "image/png")
        #expect(second.path.hasPrefix(root.path + "/"))
        #expect(FileManager.default.fileExists(atPath: second.path))
        let retained = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".png") }
        #expect(retained.count == 1)
    }

    @Test
    func pdfArtifactAndPerformanceMetricsUseBoundedSpecialistContracts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserToolsPDFTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserArtifactStore(rootDirectory: root, maximumArtifactCount: 2)
        let pdf = try store.storePDF(Data([0x25, 0x50, 0x44, 0x46]), pageID: "pdf-page")
        #expect(pdf.mimeType == "application/pdf")
        #expect(pdf.path.hasSuffix(".pdf"))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        #expect(try BrowserPDFFormat.resolve("LETTER") == .letter)
        #expect(throws: BrowserSpecialistError.unsupportedPDFFormat("legal")) {
            try BrowserPDFFormat.resolve("legal")
        }

        let metrics = try BrowserPerformanceSnapshot.parse([
            "result": [
                "metrics": [
                    ["name": "ScriptDuration", "value": 1.5],
                    ["name": "UnrelatedMetric", "value": 99],
                    ["name": "Nodes", "value": 42],
                ],
            ],
        ])
        #expect(metrics.map(\.name) == ["Nodes", "ScriptDuration"])
        #expect(metrics.map(\.value) == [42, 1.5])
        #expect(BrowserDownloadPolicy.browserMethod == "Browser.setDownloadBehavior")
        #expect(BrowserDownloadPolicy.pageFallbackMethod == "Page.setDownloadBehavior")
    }

    @Test
    func browserToolCatalogContainsLegacyAndPersistentPageTools() throws {
        let descriptors = BrowserToolsFeatureRunner.tools().map(\.descriptor)
        let expectedNames: Set<String> = [
            "browser.google_search",
            "browser.visit_page",
            "browser.open",
            "browser.pages",
            "browser.goto",
            "browser.read",
            "browser.snapshot",
            "browser.console",
            "browser.network",
            "browser.screenshot",
            "browser.print_pdf",
            "browser.performance",
            "browser.act",
            "browser.dialog",
            "browser.close_page",
        ]

        #expect(Set(descriptors.map(\.name)) == expectedNames)
        for descriptor in descriptors {
            let data = try JSONEncoder().encode(descriptor)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(object?["name"] as? String == descriptor.name)
            #expect(object?["inputSchema"] as? String != nil)
        }
    }

    @Test
    func bundledRuntimeCatalogExposesEveryFeatureTool() {
        let feature = SwiftFeatureRuntime.bundledFeatureDefinitions()
            .first(where: { $0.id == "browser-tools" })
        let runtimeNames = Set(feature?.tools.map(\.name) ?? [])
        let featureNames = Set(BrowserToolsFeatureRunner.tools().map(\.descriptor.name))

        #expect(runtimeNames == featureNames)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CDPEvent] = []

    func append(_ event: CDPEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [CDPEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
