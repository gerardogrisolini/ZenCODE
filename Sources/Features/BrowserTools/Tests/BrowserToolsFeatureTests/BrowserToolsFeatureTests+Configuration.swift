import Foundation
@testable import BrowserToolsFeature
import FeatureKit
import Testing
import ToolCore

extension BrowserToolsFeatureTests {
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
    func browserViewportPresetsAreFixedAndUntrustedStoredValuesFailClosed() throws {
        let desktop = BrowserViewportPreset.desktop.configuration
        #expect(desktop.width == 1365)
        #expect(desktop.height == 900)
        #expect(desktop.deviceScaleFactor == 1)
        #expect(!desktop.mobile)

        let tablet = BrowserViewportPreset.tablet.configuration
        #expect(tablet.width == 768)
        #expect(tablet.height == 1024)
        #expect(tablet.mobile)

        let mobile = try BrowserViewportPreset.resolve("MOBILE").configuration
        #expect(mobile.width == 390)
        #expect(mobile.height == 844)
        #expect(mobile.deviceScaleFactor == 3)
        #expect(mobile.mobile)
        #expect(BrowserViewportPreset.resolveUntrustedMarker("tablet") == .tablet)
        #expect(BrowserViewportPreset.resolveUntrustedMarker("999x999") == .desktop)
        #expect(BrowserViewportPreset.resolveUntrustedMarker(nil) == .desktop)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserViewportPreset.resolve("custom")
        }

        let root = browserTemporaryRoot("BrowserViewportStateTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("viewport-presets.json")
        let store = BrowserViewportStateStore(stateURL: stateURL)
        try store.set(.mobile, for: "page-1")
        #expect(store.preset(for: "page-1") == .mobile)

        try Data(#"{"presetsByPageID":{"page-1":"not-a-preset"}}"#.utf8)
            .write(to: stateURL, options: .atomic)
        #expect(store.preset(for: "page-1") == .desktop)
        #expect(throws: BrowserToolsFeatureError.self) {
            try store.set(.desktop, for: "../../not-a-page")
        }
    }

    @Test
    func browserResetScopeAndOriginAreHostControlled() throws {
        #expect(try BrowserResetScope.resolve(nil) == .origin)
        #expect(try BrowserResetScope.resolve("PROFILE") == .profile)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserResetScope.resolve("all")
        }

        #expect(BrowserStorageOrigin.resolve("https://example.com/path?x=1") == "https://example.com")
        #expect(BrowserStorageOrigin.resolve("http://localhost:3000/app") == "http://localhost:3000")
        #expect(BrowserStorageOrigin.resolve("chrome://settings") == nil)
        #expect(BrowserStorageOrigin.resolve("about:blank") == nil)
        #expect(BrowserStorageOrigin.resolve("https://user:secret@example.com") == nil)
        #expect(BrowserResetStorage.storageTypes == "all")
        #expect(!BrowserResetStorage.instrumentationResetScript.contains("__zencodeBrowserViewportPreset"))
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
            "browser.viewport",
            "browser.reset_state",
            "browser.wait",
            "browser.assert",
            "browser.snapshot",
            "browser.inspect",
            "browser.wait_element",
            "browser.assert_element",
            "browser.console",
            "browser.network",
            "browser.screenshot",
            "browser.compare_screenshots",
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
    func browserFeatureToolsHaveSemanticallyValidPresentations() {
        #expect(BrowserToolsFeatureRunner.tools().allSatisfy {
            $0.descriptor.presentation?.isSemanticallyValid == true
        })
    }
}
