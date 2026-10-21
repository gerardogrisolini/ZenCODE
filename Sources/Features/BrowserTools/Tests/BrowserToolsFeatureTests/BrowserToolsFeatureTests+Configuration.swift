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
    func automationLaunchArgumentsAvoidNonStandardBrowserSignals() {
        let configuration = ChromeBrowserConfiguration(environment: ["HOME": "/tmp/home"])
        let arguments = ChromeBrowserManager.automationLaunchArguments(configuration: configuration)

        #expect(arguments.contains("--remote-debugging-address=127.0.0.1"))
        #expect(arguments.contains("--remote-debugging-port=0"))
        #expect(arguments.contains("--user-data-dir=/tmp/home/.zencode/browser"))
        #expect(!arguments.contains("--disable-sync"))
        #expect(!arguments.contains("--use-mock-keychain"))
        #expect(!arguments.contains("--headless=new"))
        #if os(macOS)
        #expect(!arguments.contains("--password-store=basic"))
        #else
        #expect(arguments.contains("--password-store=basic"))
        #endif
        #expect(arguments.last == "about:blank")
    }

    @Test
    func loginLaunchArgumentsShareTheProfileWithoutAutomation() throws {
        let configuration = ChromeBrowserConfiguration(environment: ["HOME": "/tmp/home"])
        let url = try #require(URL(string: "https://accounts.example.com/signin"))
        let arguments = ChromeBrowserManager.loginLaunchArguments(configuration: configuration, url: url)

        #expect(!arguments.contains { $0.hasPrefix("--remote-debugging") })
        #expect(!arguments.contains("--headless=new"))
        #expect(arguments.last == "https://accounts.example.com/signin")
        // Credential storage must match the automated instance so cookies
        // saved during the manual login remain readable.
        let shared = ChromeBrowserManager.profileLaunchArguments(configuration: configuration)
        #expect(Array(arguments.dropLast()) == shared)
        #expect(shared.allSatisfy { ChromeBrowserManager.automationLaunchArguments(configuration: configuration).contains($0) })
        #expect(ChromeBrowserManager.loginLaunchArguments(configuration: configuration, url: nil).last == "about:blank")
    }

    @Test
    func profileLockOwnerRequiresAWellFormedLiveProcess() {
        #expect(ChromeBrowserManager.profileLockOwnerPID(lockTarget: "my-mac.local-4242") { $0 == 4242 } == 4242)
        #expect(ChromeBrowserManager.profileLockOwnerPID(lockTarget: "my-mac.local-4242") { _ in false } == nil)
        #expect(ChromeBrowserManager.profileLockOwnerPID(lockTarget: "host-notapid") { _ in true } == nil)
        #expect(ChromeBrowserManager.profileLockOwnerPID(lockTarget: "host-0") { _ in true } == nil)
        #expect(ChromeBrowserManager.profileLockOwnerPID(lockTarget: "nodash") { _ in true } == nil)

        let root = browserTemporaryRoot("BrowserProfileLockTests")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ChromeBrowserManager.profileLockOwnerPID(profileDirectory: root) == nil)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("SingletonLock").path,
            withDestinationPath: "host-\(ProcessInfo.processInfo.processIdentifier)"
        )
        #expect(ChromeBrowserManager.profileLockOwnerPID(profileDirectory: root) == ProcessInfo.processInfo.processIdentifier)
    }

    @Test
    func browserLoginRefusesHeadlessConfiguration() async {
        let root = browserTemporaryRoot("BrowserLoginHeadlessTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ChromeBrowserManager(configuration: ChromeBrowserConfiguration(
            environment: ["HOME": root.path, "ZENCODE_BROWSER_HEADLESS": "1"],
            profileDirectory: root
        ))
        await #expect(throws: ChromeBrowserError.self) {
            try await manager.launchLoginSession(url: nil)
        }
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
            "browser.login",
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
