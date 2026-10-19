//
//  BrowserWebDevControls.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Constrained, host-side web-development controls for persistent Browser pages.
//  These tools deliberately expose named presets and semantic conditions only:
//  callers never provide JavaScript, selectors, CDP method names, viewport
//  dimensions, user agents, origins, or storage-type lists.
//

import FeatureKit
import ToolCore
import Foundation
import Synchronization

// MARK: - Viewport presets

struct BrowserViewportConfiguration: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
    let deviceScaleFactor: Double
    let mobile: Bool
}

/// The only viewport shapes Browser accepts from a model. Values are host-side
/// constants rather than tool arguments so a prompt cannot manufacture an
/// arbitrary device fingerprint or use emulation as a transport for raw CDP.
enum BrowserViewportPreset: String, CaseIterable, Codable, Sendable {
    case desktop
    case tablet
    case mobile

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("preset")
        }
        guard let preset = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError(
                "Unsupported viewport preset '\(rawValue)'. Use desktop, tablet, or mobile."
            )
        }
        return preset
    }

    /// A marker is page-controlled data even when Browser wrote it previously.
    /// Only the closed preset enum is accepted; malformed or unknown values
    /// fail safely to the existing desktop default.
    static func resolveUntrustedMarker(_ rawValue: String?) -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let preset = Self(rawValue: rawValue.lowercased())
        else {
            return .desktop
        }
        return preset
    }

    var configuration: BrowserViewportConfiguration {
        switch self {
        case .desktop:
            // Preserve the existing Browser default exactly.
            BrowserViewportConfiguration(width: 1365, height: 900, deviceScaleFactor: 1, mobile: false)
        case .tablet:
            BrowserViewportConfiguration(width: 768, height: 1024, deviceScaleFactor: 2, mobile: true)
        case .mobile:
            BrowserViewportConfiguration(width: 390, height: 844, deviceScaleFactor: 3, mobile: true)
        }
    }
}

/// CDP's `Page.addScriptToEvaluateOnNewDocument` registrations belong to a
/// DevTools session and disappear when this one-shot feature process exits.
/// Keep the selected preset in Browser's private profile instead, keyed by the
/// Chrome-issued page id; every Browser invocation re-applies the closed preset
/// before it observes or acts on the page. Values read from disk are untrusted
/// and pass through `resolveUntrustedMarker(_:)` before use.
struct BrowserViewportStateStore: Sendable {
    private struct State: Codable {
        var presetsByPageID: [String: String]
    }

    static let maximumStoredPages = 100
    /// Serializes concurrent store instances within one feature process;
    /// `flock` on `lockURL` additionally coordinates across processes.
    private static let localLock = Mutex(())
    private let stateURL: URL
    private let lockURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment, stateURL: URL? = nil) {
        let resolvedStateURL = stateURL ?? ChromeBrowserConfiguration(environment: environment)
            .profileDirectory
            .appendingPathComponent("viewport-presets.json", isDirectory: false)
        self.stateURL = resolvedStateURL
        self.lockURL = resolvedStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("viewport-presets.lock", isDirectory: false)
    }

    func preset(for pageID: String) -> BrowserViewportPreset {
        guard let pageID = normalizedPageID(pageID) else { return .desktop }
        do {
            let rawValue = try withExclusiveLock { readState().presetsByPageID[pageID] }
            return BrowserViewportPreset.resolveUntrustedMarker(rawValue)
        } catch {
            return .desktop
        }
    }

    func set(_ preset: BrowserViewportPreset, for pageID: String) throws {
        guard let pageID = normalizedPageID(pageID) else {
            throw BrowserToolsFeatureError.browserError("Browser page id is invalid for viewport state.")
        }
        try withExclusiveLock {
            var state = readState()
            state.presetsByPageID[pageID] = preset.rawValue
            trim(&state, preserving: pageID)
            try writeState(state)
        }
    }

    func remove(pageID: String) {
        guard let pageID = normalizedPageID(pageID) else { return }
        try? withExclusiveLock {
            var state = readState()
            guard state.presetsByPageID.removeValue(forKey: pageID) != nil else { return }
            try writeState(state)
        }
    }

    /// Atomically serializes the read-modify-write transaction. An in-process
    /// `Mutex` prevents two concurrent calls within the same feature process
    /// from racing; an interprocess `flock` on a stable sibling lock file
    /// prevents two one-shot feature processes from clobbering each other.
    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try Self.localLock.withLock { _ in
            let directory = stateURL.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw BrowserToolsFeatureError.browserError("Viewport state directory unavailable.")
            }

            return try BrowserInterprocessLock.withExclusiveLock(
                at: lockURL,
                error: { BrowserToolsFeatureError.browserError("Viewport state lock unavailable.") },
                body: body
            )
        }
    }

    private func readState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else {
            return State(presetsByPageID: [:])
        }
        return state
    }

    private func writeState(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        #if canImport(Darwin) || canImport(Glibc)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        #endif
    }

    private func trim(_ state: inout State, preserving pageID: String) {
        guard state.presetsByPageID.count > Self.maximumStoredPages else { return }
        for candidate in state.presetsByPageID.keys.sorted() where candidate != pageID {
            state.presetsByPageID.removeValue(forKey: candidate)
            if state.presetsByPageID.count <= Self.maximumStoredPages {
                return
            }
        }
    }

    private func normalizedPageID(_ pageID: String) -> String? {
        let value = pageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.count <= 256,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              })
        else {
            return nil
        }
        return value
    }
}

struct BrowserViewportOutput: Codable, Sendable {
    let page: BrowserPage
    let preset: BrowserViewportPreset
    let width: Int
    let height: Int
    let deviceScaleFactor: Double
    let mobile: Bool

    init(page: BrowserPage, preset: BrowserViewportPreset) {
        let configuration = preset.configuration
        self.page = page
        self.preset = preset
        self.width = configuration.width
        self.height = configuration.height
        self.deviceScaleFactor = configuration.deviceScaleFactor
        self.mobile = configuration.mobile
    }
}

struct BrowserViewportTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let preset: String?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.viewport"
    static let description = "Applies a fixed desktop, tablet, or mobile viewport preset to a persistent Browser page. Browser never accepts raw viewport dimensions or user agents from the model."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("preset", enumValues: ["desktop", "tablet", "mobile"], description: "Fixed host-side viewport preset."),
        ],
        required: ["pageId", "preset"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserViewportOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        let preset = try BrowserViewportPreset.resolve(input.preset)
        let stateStore = BrowserViewportStateStore(environment: context.environment)

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            try await session.setViewportPreset(preset)
            try stateStore.set(preset, for: tab.id)
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            return BrowserViewportOutput(page: page, preset: preset)
        }
    }
}

extension CDPSession {
    func setViewportPreset(_ preset: BrowserViewportPreset) async throws {
        try await applyViewportPreset(preset)
    }

    func applyViewportPreset(_ preset: BrowserViewportPreset) async throws {
        let configuration = preset.configuration
        _ = try await send(
            method: "Emulation.setDeviceMetricsOverride",
            params: [
                "width": configuration.width,
                "height": configuration.height,
                "deviceScaleFactor": configuration.deviceScaleFactor,
                "mobile": configuration.mobile,
            ]
        )
        _ = try? await send(
            method: "Emulation.setTouchEmulationEnabled",
            params: [
                "enabled": configuration.mobile,
                "maxTouchPoints": configuration.mobile ? 5 : 1,
            ]
        )
    }

}

// MARK: - State reset

/// Reset defaults to the current page's validated HTTP(S) origin. `profile` is
/// intentionally opt-in because it also clears profile-wide HTTP cache/cookies
/// and resets Browser instrumentation on every managed Browser page.
enum BrowserResetScope: String, CaseIterable, Codable, Sendable {
    case origin
    case profile

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return .origin
        }
        guard let scope = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError("Unsupported reset scope '\(rawValue)'. Use origin or profile.")
        }
        return scope
    }
}

/// Converts a page's current URL into a valid security origin. No origin is
/// accepted from a tool argument, and a missing/unsupported page origin is not
/// widened into a profile reset.
enum BrowserStorageOrigin {
    static func resolve(_ pageURL: String) -> String? {
        guard let components = URLComponents(string: pageURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else {
            return nil
        }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        return origin.url?.absoluteString
    }

    static func require(_ pageURL: String) throws -> String {
        guard let origin = resolve(pageURL) else {
            throw BrowserToolsFeatureError.browserError(
                "The persistent page does not have a resettable HTTP or HTTPS origin. Navigate it to a web page before using the default origin reset."
            )
        }
        return origin
    }
}

enum BrowserResetStorage {
    /// CDP's fixed `all` storage type is deliberately not model-configurable.
    static let storageTypes = "all"

    /// The console ring buffer is the only persistent in-page instrumentation
    /// state. Snapshot authorization is Browser-owned host state, and viewport
    /// configuration remains in Browser's private profile.
    static let instrumentationResetScript = #"""
    (() => {
      try {
        if (Array.isArray(globalThis.__zencodeConsole)) {
          globalThis.__zencodeConsole.length = 0;
        }
      } catch (_) {}
      return 'reset';
    })()
    """#
}

struct BrowserResetStateOutput: Codable, Sendable {
    let page: BrowserPage
    let scope: BrowserResetScope
    let origin: String?
    let clearedOrigins: [String]
    let resetPageCount: Int
    let reloadedSelectedPage: Bool
    let destructiveForOtherBrowserPages: Bool
    let note: String

    init(
        page: BrowserPage,
        scope: BrowserResetScope,
        origin: String?,
        clearedOrigins: [String],
        resetPageCount: Int,
        reloadedSelectedPage: Bool
    ) {
        self.page = page
        self.scope = scope
        self.origin = origin
        self.clearedOrigins = clearedOrigins
        self.resetPageCount = resetPageCount
        self.reloadedSelectedPage = reloadedSelectedPage
        self.destructiveForOtherBrowserPages = scope == .profile
        self.note = switch scope {
        case .origin:
            "Cleared the fixed Browser storage set for the validated current origin, reset Browser instrumentation, and reloaded the selected page without cache."
        case .profile:
            "Destructive profile reset: cleared profile-wide Browser cache and cookies, cleared the fixed Browser storage set for origins open in all managed Browser pages, reset Browser instrumentation on those pages, and reloaded the selected page without cache. The Browser profile directory was not deleted."
        }
    }
}

private struct BrowserProfileResetPageState: Sendable {
    let origin: String?
}

struct BrowserResetStateTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let scope: String?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.reset_state"
    static let description = "Resets Browser state for the current page's validated origin by default. Set scope to profile only for a destructive reset that also affects other managed Browser pages; Browser never deletes the profile directory."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("scope", enumValues: ["origin", "profile"], description: "Defaults to origin. profile is destructive for other managed Browser pages."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserResetStateOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        let scope = try BrowserResetScope.resolve(input.scope)

        switch scope {
        case .origin:
            return try await resetOrigin(pageID: pageID, context: context)
        case .profile:
            return try await resetProfile(pageID: pageID, context: context)
        }
    }

    private func resetOrigin(pageID: String, context: FeatureContext) async throws -> BrowserResetStateOutput {
        try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            // A missing origin fails closed here. It is never converted into a
            // global/profile wipe merely because the default scope could not be
            // resolved.
            let origin = try await session.requiredBrowserStorageOrigin()
            try await session.clearBrowserStorage(for: origin)
            try session.snapshotStateStore.remove(pageID: tab.id)
            try await session.resetBrowserInstrumentation()
            try await session.reloadIgnoringCache()
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            return BrowserResetStateOutput(
                page: page,
                scope: .origin,
                origin: origin,
                clearedOrigins: [origin],
                resetPageCount: 1,
                reloadedSelectedPage: true
            )
        }
    }

    private func resetProfile(pageID: String, context: FeatureContext) async throws -> BrowserResetStateOutput {
        let browser = ChromeBrowserManager(configuration: ChromeBrowserConfiguration(environment: context.environment))

        do {
            try await browser.ensureRunning()
            let selectedTab = try await browser.tab(id: pageID)
            let tabs = try await browser.listTabs()
            var pageStates: [BrowserProfileResetPageState] = []

            for tab in tabs {
                let state = try await BrowserToolsRunner.withTab(
                    tab,
                    context: context,
                    preparePage: false,
                    enforceNetworkPolicy: false
                ) { session, managedTab in
                    try await session.enablePageAndRuntime()
                    let origin = try await session.browserStorageOrigin()
                    try session.snapshotStateStore.remove(pageID: managedTab.id)
                    try await session.resetBrowserInstrumentation()
                    return BrowserProfileResetPageState(origin: origin)
                }
                pageStates.append(state)
            }

            let origins = Array(Set(pageStates.compactMap(\.origin))).sorted()
            try await BrowserToolsRunner.withTab(
                selectedTab,
                context: context,
                preparePage: false,
                validateCurrentDocument: false
            ) { session, _ in
                try await session.enablePageAndRuntime()
                try await session.clearBrowserProfileNetworkState()
                for origin in origins {
                    try await session.clearBrowserStorage(for: origin)
                }
                try await session.reloadIgnoringCache()
            }

            return BrowserResetStateOutput(
                page: BrowserPage(tab: selectedTab),
                scope: .profile,
                origin: nil,
                clearedOrigins: origins,
                resetPageCount: pageStates.count,
                reloadedSelectedPage: true
            )
        } catch let error as CDPError {
            throw BrowserToolsFeatureError.browserError(error.localizedDescription)
        } catch let error as ChromeBrowserError {
            throw BrowserToolsFeatureError.browserError(error.localizedDescription)
        }
    }
}

extension CDPSession {
    func enablePageAndRuntime() async throws {
        _ = try await send(method: "Page.enable")
        _ = try await send(method: "Runtime.enable")
    }

    /// Returns nil only for an unsupported/non-web current document. Transport
    /// and runtime failures still surface to callers rather than becoming a
    /// misleading profile-wide fallback.
    func browserStorageOrigin() async throws -> String? {
        let href = try await evalString("location.href || ''")
        return BrowserStorageOrigin.resolve(href)
    }

    func requiredBrowserStorageOrigin() async throws -> String {
        let href = try await evalString("location.href || ''")
        return try BrowserStorageOrigin.require(href)
    }

    func clearBrowserStorage(for origin: String) async throws {
        _ = try await send(
            method: "Storage.clearDataForOrigin",
            params: [
                "origin": origin,
                "storageTypes": BrowserResetStorage.storageTypes,
            ]
        )
    }

    func clearBrowserProfileNetworkState() async throws {
        _ = try await send(method: "Network.clearBrowserCache")
        _ = try await send(method: "Network.clearBrowserCookies")
    }

    /// State reset must affect the live document as well as on-disk storage;
    /// otherwise a SPA can continue exposing stale authenticated state from
    /// memory. The reload is fixed host behavior, not model-controlled CDP.
    func reloadIgnoringCache() async throws {
        _ = try await send(method: "Page.reload", params: ["ignoreCache": true])
        try await waitNavigatedReady()
    }

    func resetBrowserInstrumentation() async throws {
        _ = try await evalString(BrowserResetStorage.instrumentationResetScript)
    }
}

// MARK: - Shared input resolution

enum BrowserPageInput {
    static func resolve(pageID: String?, pageIDSnakeCase: String?, id: String? = nil) -> String? {
        pageID?.nilIfBlank ?? pageIDSnakeCase?.nilIfBlank ?? id?.nilIfBlank
    }
}

// MARK: - Semantic presentation

extension BrowserViewportTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser viewport", action: "Set", kind: .manage, targetKeyPaths: ["pageId", "page_id", "preset"])
    }
}

extension BrowserResetStateTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser state", action: "Reset", kind: .delete, targetKeyPaths: ["pageId", "page_id", "scope"])
    }
}

extension BrowserWaitTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser condition", action: "Wait", kind: .read, targetKeyPaths: ["condition", "value", "pageId", "page_id"])
    }
}

extension BrowserAssertTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser condition", action: "Assert", kind: .inspect, targetKeyPaths: ["condition", "value", "pageId", "page_id"])
    }
}
