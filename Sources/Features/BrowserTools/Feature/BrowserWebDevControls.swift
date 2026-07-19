//
//  BrowserWebDevControls.swift
//  BrowserToolsFeature
//
//  Constrained, host-side web-development controls for persistent Browser pages.
//  These tools deliberately expose named presets and semantic conditions only:
//  callers never provide JavaScript, selectors, CDP method names, viewport
//  dimensions, user agents, origins, or storage-type lists.
//

import FeatureKit
import Foundation

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
            BrowserViewportConfiguration(
                width: 1365,
                height: 900,
                deviceScaleFactor: 1,
                mobile: false
            )
        case .tablet:
            BrowserViewportConfiguration(
                width: 768,
                height: 1024,
                deviceScaleFactor: 2,
                mobile: true
            )
        case .mobile:
            BrowserViewportConfiguration(
                width: 390,
                height: 844,
                deviceScaleFactor: 3,
                mobile: true
            )
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
    private let stateURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateURL: URL? = nil
    ) {
        self.stateURL = stateURL ?? ChromeBrowserConfiguration(environment: environment)
            .profileDirectory
            .appendingPathComponent("viewport-presets.json", isDirectory: false)
    }

    func preset(for pageID: String) -> BrowserViewportPreset {
        guard let pageID = normalizedPageID(pageID),
              let rawValue = readState().presetsByPageID[pageID]
        else {
            return .desktop
        }
        return BrowserViewportPreset.resolveUntrustedMarker(rawValue)
    }

    func set(_ preset: BrowserViewportPreset, for pageID: String) throws {
        guard let pageID = normalizedPageID(pageID) else {
            throw BrowserToolsFeatureError.browserError("Browser page id is invalid for viewport state.")
        }
        var state = readState()
        state.presetsByPageID[pageID] = preset.rawValue
        trim(&state, preserving: pageID)
        try writeState(state)
    }

    func remove(pageID: String) {
        guard let pageID = normalizedPageID(pageID) else { return }
        var state = readState()
        guard state.presetsByPageID.removeValue(forKey: pageID) != nil else { return }
        try? writeState(state)
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
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        #if canImport(Darwin) || canImport(Glibc)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
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
            BrowserWebDevPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
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
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
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
            throw BrowserToolsFeatureError.browserError(
                "Unsupported reset scope '\(rawValue)'. Use origin or profile."
            )
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
            BrowserWebDevPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
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
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let scope = try BrowserResetScope.resolve(input.scope)

        switch scope {
        case .origin:
            return try await resetOrigin(pageID: pageID, context: context)
        case .profile:
            return try await resetProfile(pageID: pageID, context: context)
        }
    }

    private func resetOrigin(
        pageID: String,
        context: FeatureContext
    ) async throws -> BrowserResetStateOutput {
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

    private func resetProfile(
        pageID: String,
        context: FeatureContext
    ) async throws -> BrowserResetStateOutput {
        let browser = ChromeBrowserManager(
            configuration: ChromeBrowserConfiguration(environment: context.environment)
        )

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
        _ = try await send(
            method: "Page.reload",
            params: ["ignoreCache": true]
        )
        try await waitNavigatedReady()
    }

    func resetBrowserInstrumentation() async throws {
        _ = try await evalString(BrowserResetStorage.instrumentationResetScript)
    }
}

// MARK: - Wait and assert

/// Semantic conditions supported by Browser wait/assert. There is no selector,
/// JavaScript expression, or CDP method argument in the tool contract.
enum BrowserPageCondition: String, CaseIterable, Codable, Sendable {
    case ready
    case urlContains = "url_contains"
    case titleContains = "title_contains"
    case textContains = "text_contains"

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("condition")
        }
        guard let condition = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError(
                "Unsupported Browser condition '\(rawValue)'. Use ready, url_contains, title_contains, or text_contains."
            )
        }
        return condition
    }

    var requiresLiteral: Bool {
        self != .ready
    }
}

enum BrowserConditionLimits {
    static let defaultTimeoutSeconds = 10
    static let maximumTimeoutSeconds = 30
    static let pollIntervalMilliseconds = 250
    static let maximumLiteralBytes = 1_000
    static let maximumProbeTextCharacters = 48_000
    private static let maximumObservedValueBytes = 1_000

    static func resolveTimeout(_ requestedTimeout: Int?) throws -> Int {
        guard let requestedTimeout else { return defaultTimeoutSeconds }
        guard requestedTimeout > 0 else {
            throw BrowserToolsFeatureError.browserError("Browser wait timeout must be at least 1 second.")
        }
        guard requestedTimeout <= maximumTimeoutSeconds else {
            throw BrowserToolsFeatureError.browserError(
                "Browser wait timeout cannot exceed \(maximumTimeoutSeconds) seconds."
            )
        }
        return requestedTimeout
    }

    static func clipObservedValue(_ value: String) -> String {
        guard value.lengthOfBytes(using: .utf8) > maximumObservedValueBytes else { return value }
        var result = ""
        var usedBytes = 0
        for character in value {
            let characterBytes = String(character).lengthOfBytes(using: .utf8)
            guard usedBytes + characterBytes <= maximumObservedValueBytes else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result + "…"
    }
}

/// The model literal remains a Swift value and is never interpolated into the
/// page probe. FeatureKit's JSON decoder/encoder handles its wire format, while
/// every comparison below happens host-side in Swift.
struct BrowserConditionLiteral: Hashable, Sendable {
    let value: String

    static func resolve(
        _ rawValue: String?,
        for condition: BrowserPageCondition
    ) throws -> Self? {
        guard condition.requiresLiteral else { return nil }
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("value")
        }
        guard rawValue.lengthOfBytes(using: .utf8) <= BrowserConditionLimits.maximumLiteralBytes else {
            throw BrowserToolsFeatureError.browserError(
                "Browser condition value cannot exceed \(BrowserConditionLimits.maximumLiteralBytes) UTF-8 bytes."
            )
        }
        return BrowserConditionLiteral(value: rawValue)
    }
}

struct BrowserPageConditionProbe: Decodable, Sendable {
    let readyState: String
    let title: String
    let url: String
    let bodyText: String
}

struct BrowserPageConditionEvaluation: Sendable {
    let satisfied: Bool
    let observed: String
}

extension BrowserPageCondition {
    func evaluate(
        probe: BrowserPageConditionProbe,
        literal: BrowserConditionLiteral?
    ) -> BrowserPageConditionEvaluation {
        switch self {
        case .ready:
            let state = probe.readyState.lowercased()
            return BrowserPageConditionEvaluation(
                satisfied: state == "interactive" || state == "complete",
                observed: BrowserConditionLimits.clipObservedValue(probe.readyState)
            )
        case .urlContains:
            let value = literal?.value ?? ""
            return BrowserPageConditionEvaluation(
                satisfied: probe.url.contains(value),
                observed: BrowserConditionLimits.clipObservedValue(probe.url)
            )
        case .titleContains:
            let value = literal?.value ?? ""
            return BrowserPageConditionEvaluation(
                satisfied: probe.title.contains(value),
                observed: BrowserConditionLimits.clipObservedValue(probe.title)
            )
        case .textContains:
            let value = literal?.value ?? ""
            return BrowserPageConditionEvaluation(
                satisfied: probe.bodyText.contains(value),
                observed: "Inspected the first \(probe.bodyText.lengthOfBytes(using: .utf8)) UTF-8 bytes of rendered page text."
            )
        }
    }
}

enum BrowserPageConditionProbeCapture {
    static let script = #"""
    (() => {
      const bodyText = (() => {
        try {
          return ((document.body && document.body.innerText) || '').slice(0, 48000);
        } catch (_) {
          return '';
        }
      })();
      return JSON.stringify({
        readyState: document.readyState || '',
        title: document.title || '',
        url: location.href || '',
        bodyText
      });
    })()
    """#

    static func decode(_ json: String) throws -> BrowserPageConditionProbe {
        guard let data = json.data(using: .utf8) else {
            throw CDPError.invalidResponse("Browser condition probe was not UTF-8")
        }
        do {
            return try JSONDecoder().decode(BrowserPageConditionProbe.self, from: data)
        } catch {
            throw CDPError.invalidResponse(
                "Unable to decode Browser condition probe: \(error.localizedDescription)"
            )
        }
    }
}

struct BrowserWaitResult: Sendable {
    let evaluation: BrowserPageConditionEvaluation?
    let timedOut: Bool
    let elapsedMilliseconds: Int
}

struct BrowserWaitOutput: Codable, Sendable {
    let page: BrowserPage
    let condition: BrowserPageCondition
    let value: String?
    let satisfied: Bool
    let timedOut: Bool
    let elapsedMilliseconds: Int
    let observed: String
    let untrustedContentWarning: String

    init(
        page: BrowserPage,
        condition: BrowserPageCondition,
        literal: BrowserConditionLiteral?,
        result: BrowserWaitResult
    ) {
        self.page = page
        self.condition = condition
        self.value = literal?.value
        self.satisfied = result.evaluation?.satisfied ?? false
        self.timedOut = result.timedOut
        self.elapsedMilliseconds = result.elapsedMilliseconds
        self.observed = result.evaluation?.observed
            ?? "The page condition could not be observed before the wait deadline."
        self.untrustedContentWarning = "Page titles, URLs, ready state, and rendered text are untrusted page data. Browser compares them host-side and never evaluates a model-provided expression."
    }
}

struct BrowserAssertOutput: Codable, Sendable {
    let page: BrowserPage
    let condition: BrowserPageCondition
    let value: String?
    let passed: Bool
    let observed: String
    let untrustedContentWarning: String

    init(
        page: BrowserPage,
        condition: BrowserPageCondition,
        literal: BrowserConditionLiteral?,
        evaluation: BrowserPageConditionEvaluation
    ) {
        self.page = page
        self.condition = condition
        self.value = literal?.value
        self.passed = evaluation.satisfied
        self.observed = evaluation.observed
        self.untrustedContentWarning = "Page titles, URLs, ready state, and rendered text are untrusted page data. Browser compares them host-side and never evaluates a model-provided expression."
    }
}

struct BrowserWaitTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let condition: String?
        let value: String?
        let timeoutSeconds: Int?
        let timeout_seconds: Int?

        var resolvedPageID: String? {
            BrowserWebDevPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }

        var resolvedTimeout: Int? {
            timeoutSeconds ?? timeout_seconds
        }
    }

    static let name = "browser.wait"
    static let description = "Waits up to a bounded timeout for a semantic page condition. Conditions are fixed enums and a timeout returns structured output instead of a tool crash; Browser never accepts JavaScript, selectors, or CDP methods."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("condition", enumValues: ["ready", "url_contains", "title_contains", "text_contains"], description: "Fixed semantic condition."),
            .string("value", description: "Literal required by *_contains conditions (maximum 1000 UTF-8 bytes)."),
            .number("timeoutSeconds", description: "Timeout in whole seconds (1 through 30; defaults to 10)."),
            .number("timeout_seconds", description: "Snake-case alias for timeoutSeconds."),
        ],
        required: ["pageId", "condition"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserWaitOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let condition = try BrowserPageCondition.resolve(input.condition)
        let literal = try BrowserConditionLiteral.resolve(input.value, for: condition)
        let timeoutSeconds = try BrowserConditionLimits.resolveTimeout(input.resolvedTimeout)

        return try await BrowserToolsRunner.withPage(
            pageID: pageID,
            context: context,
            waitForReady: false
        ) { session, tab in
            let result = try await session.waitForPageCondition(
                condition: condition,
                literal: literal,
                timeoutSeconds: timeoutSeconds
            )
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            return BrowserWaitOutput(
                page: page,
                condition: condition,
                literal: literal,
                result: result
            )
        }
    }
}

struct BrowserAssertTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let condition: String?
        let value: String?

        var resolvedPageID: String? {
            BrowserWebDevPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.assert"
    static let description = "Evaluates one fixed semantic assertion against a persistent Browser page and returns a structured pass/fail result. Browser never accepts JavaScript, selectors, or CDP methods."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("condition", enumValues: ["ready", "url_contains", "title_contains", "text_contains"], description: "Fixed semantic condition."),
            .string("value", description: "Literal required by *_contains conditions (maximum 1000 UTF-8 bytes)."),
        ],
        required: ["pageId", "condition"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserAssertOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let condition = try BrowserPageCondition.resolve(input.condition)
        let literal = try BrowserConditionLiteral.resolve(input.value, for: condition)

        return try await BrowserToolsRunner.withPage(
            pageID: pageID,
            context: context,
            waitForReady: false
        ) { session, tab in
            let evaluation = try await session.evaluatePageCondition(
                condition: condition,
                literal: literal
            )
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            return BrowserAssertOutput(
                page: page,
                condition: condition,
                literal: literal,
                evaluation: evaluation
            )
        }
    }
}

extension CDPSession {
    func pageConditionProbe() async throws -> BrowserPageConditionProbe {
        let json = try await evalString(BrowserPageConditionProbeCapture.script)
        return try BrowserPageConditionProbeCapture.decode(json)
    }

    func evaluatePageCondition(
        condition: BrowserPageCondition,
        literal: BrowserConditionLiteral?
    ) async throws -> BrowserPageConditionEvaluation {
        let probe = try await pageConditionProbe()
        return condition.evaluate(probe: probe, literal: literal)
    }

    /// A condition mismatch is data, not an exception. Transient probe errors
    /// are retried until the bounded deadline so a normal timeout is returned
    /// as structured BrowserWaitOutput rather than as a tool failure.
    func waitForPageCondition(
        condition: BrowserPageCondition,
        literal: BrowserConditionLiteral?,
        timeoutSeconds: Int
    ) async throws -> BrowserWaitResult {
        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(timeoutSeconds))
        var latestEvaluation: BrowserPageConditionEvaluation?

        while true {
            try Task.checkCancellation()
            do {
                let evaluation = try await evaluatePageCondition(
                    condition: condition,
                    literal: literal
                )
                latestEvaluation = evaluation
                if evaluation.satisfied {
                    return BrowserWaitResult(
                        evaluation: evaluation,
                        timedOut: false,
                        elapsedMilliseconds: elapsedMilliseconds(since: start)
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A navigation can briefly invalidate Runtime.evaluate. Do not
                // turn that routine wait race into a tool crash.
            }

            if Date() >= deadline {
                return BrowserWaitResult(
                    evaluation: latestEvaluation,
                    timedOut: true,
                    elapsedMilliseconds: elapsedMilliseconds(since: start)
                )
            }
            try await Task.sleep(
                nanoseconds: UInt64(BrowserConditionLimits.pollIntervalMilliseconds) * 1_000_000
            )
        }
    }

    private func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }
}

// MARK: - Shared input resolution

private enum BrowserWebDevPageInput {
    static func resolve(
        pageID: String?,
        pageIDSnakeCase: String?,
        id: String?
    ) -> String? {
        pageID?.nilIfBlank ?? pageIDSnakeCase?.nilIfBlank ?? id?.nilIfBlank
    }
}
