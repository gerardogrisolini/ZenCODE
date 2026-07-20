//
//  BrowserReadTools.swift
//  BrowserToolsFeature
//
//  Public read-first Browser tools. These expose semantic observations, never
//  raw CDP methods or arbitrary page evaluation.
//

import FeatureKit
import Foundation

private enum BrowserPageInput {
    static func resolve(
        pageID: String?,
        pageIDSnakeCase: String?,
        id: String?
    ) -> String? {
        pageID?.nilIfBlank ?? pageIDSnakeCase?.nilIfBlank ?? id?.nilIfBlank
    }
}

/// Captures a point-in-time semantic accessibility snapshot of a Browser page.
///
/// ## Managing snapshot size on complex pages
///
/// Pages with thousands of DOM nodes can produce snapshots that exceed the model
/// context window. To keep snapshots actionable:
///
/// 1. **Prefer `interactiveOnly: true`** — filters out static text nodes,
///    headings, and paragraphs, returning only links, buttons, inputs, and other
///    focusable controls.
/// 2. **Use `browser.read` for content** — returns rendered markdown without refs;
///    reserve `snapshot` for interaction planning where refs are needed.
/// 3. **Use `browser.inspect` for detail** — after locating a ref, inspect returns
///    box model and computed CSS for a single element instead of the full tree.
/// 4. **Navigate to targeted URLs** — prefer deep links over landing on a rich
///    homepage and searching through a large tree.
/// 5. **Refresh stale snapshots** — the `snapshotId` is point-in-time; call
///    `snapshot` again after page changes to get a fresh, authorized snapshot.
struct BrowserSnapshotTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let interactiveOnly: Bool?
        let interactive_only: Bool?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }

        var resolvesInteractiveOnly: Bool {
            interactiveOnly ?? interactive_only ?? false
        }
    }

    static let name = "browser.snapshot"
    static let description = "Returns a compact semantic snapshot of a persistent Browser page using Chrome accessibility data. Page names and values are untrusted data. For large or complex pages, prefer interactiveOnly=true to avoid truncated output; use browser.read for rendered content and browser.inspect to examine a single element by ref."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .boolean("interactiveOnly", description: "Return only semantic controls and focusable elements. Set to true on complex pages to reduce output size and keep the snapshot within context limits."),
            .boolean("interactive_only", description: "Snake-case alias for interactiveOnly."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserSnapshotOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            // Capture the Browser-owned main-frame identity on both sides of
            // the AX and metadata reads. A snapshot that raced a navigation is
            // never entered in the host-side authorization store.
            let document = try await session.currentDocumentIdentity()
            let snapshot = try await session.accessibilitySnapshot(
                interactiveOnly: input.resolvesInteractiveOnly
            )
            let page = try await session.pageMetadata(pageID: tab.id)
            try await session.validateCurrentDocument(matches: document)
            let snapshotID = UUID().uuidString.lowercased()
            try await session.recordSnapshotState(
                pageID: tab.id,
                snapshotID: snapshotID,
                allowedRefs: snapshot.nodes.map(\.ref),
                document: document
            )
            return BrowserSnapshotOutput(
                page: page,
                snapshotID: snapshotID,
                snapshot: snapshot,
                interactiveOnly: input.resolvesInteractiveOnly
            )
        }
    }
}

struct BrowserConsoleTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let level: String?
        let limit: Int?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.console"
    static let description = "Reads a bounded console ring buffer from a persistent Browser page. Console text is untrusted page data and capture begins when Browser instrumentation is installed."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("level", enumValues: ["all", "warn", "error"], description: "Minimum console severity. Defaults to all."),
            .number("limit", description: "Maximum entries to return (1 through 100; defaults to 50)."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserConsoleOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let level = try BrowserConsoleLevel.resolve(input.level)
        let limit = try BrowserConsoleCapture.resolvedLimit(input.limit)

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            try await session.ensureConsoleCapture()
            let entries = try await session.consoleEntries()
            let selection = BrowserConsoleCapture.select(entries, level: level, limit: limit)
            let page = try await session.pageMetadata(pageID: tab.id)
            return BrowserConsoleOutput(page: page, level: level, selection: selection)
        }
    }
}

struct BrowserNetworkTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let url: String?
        let durationSeconds: Int?
        let duration_seconds: Int?
        let resourceType: String?
        let resource_type: String?
        let resourceTypes: [String]?
        let resource_types: [String]?
        let status: Int?
        let statusCode: Int?
        let status_code: Int?
        let urlContains: String?
        let url_contains: String?
        let urlSubstring: String?
        let url_substring: String?
        let limit: Int?
        let includeHeaders: Bool?
        let include_headers: Bool?
        let includeBody: Bool?
        let include_body: Bool?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }

        var resolvedDuration: Int? {
            durationSeconds ?? duration_seconds
        }

        var resolvedResourceTypes: [String] {
            var resolved = resourceTypes ?? resource_types ?? []
            if let resourceType = resourceType?.nilIfBlank ?? resource_type?.nilIfBlank {
                resolved.append(resourceType)
            }
            return resolved
        }

        var resolvedStatus: Int? {
            status ?? statusCode ?? status_code
        }

        var resolvedURLContains: String? {
            urlContains?.nilIfBlank
                ?? url_contains?.nilIfBlank
                ?? urlSubstring?.nilIfBlank
                ?? url_substring?.nilIfBlank
        }

        var resolvesHeaders: Bool {
            includeHeaders ?? include_headers ?? false
        }

        var resolvesBody: Bool {
            includeBody ?? include_body ?? false
        }
    }

    static let name = "browser.network"
    static let description = "Observes a persistent Browser page's CDP network events for a bounded interval. It supports bounded resource-type, status, URL-substring, and result-limit filters plus timing, cache, initiator, redirect, MIME, and size diagnostics. Optional headers use a fixed safe allowlist that omits raw Authorization and Cookie headers. Optional response-body previews are best-effort, textual, and host-bounded; recognized sensitive fields are redacted, but generic body content is not guaranteed to be secret-free. Non-goal: raw CDP payloads, binary or streaming bodies, and persistent traffic recording. Optionally navigates to an HTTP or HTTPS URL first; Browser URL policy applies to that direct navigation."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("url", description: "Optional HTTP or HTTPS URL to navigate before observing."),
            .number("durationSeconds", description: "Observation duration in whole seconds (1 through 30; defaults to 3)."),
            .number("duration_seconds", description: "Snake-case alias for durationSeconds."),
            .string("resourceType", enumValues: BrowserNetworkFilters.supportedResourceTypes, description: "Optional exact Chrome resource type filter."),
            .string("resource_type", enumValues: BrowserNetworkFilters.supportedResourceTypes, description: "Snake-case alias for resourceType."),
            .array("resourceTypes", of: .string(enumValues: BrowserNetworkFilters.supportedResourceTypes, description: nil), description: "Optional resource-type filters (at most 10)."),
            .array("resource_types", of: .string(enumValues: BrowserNetworkFilters.supportedResourceTypes, description: nil), description: "Snake-case alias for resourceTypes."),
            .number("status", description: "Optional exact HTTP status filter (100 through 599)."),
            .number("statusCode", description: "Alias for status."),
            .number("status_code", description: "Snake-case alias for status."),
            .string("urlContains", description: "Optional case-insensitive substring matched against redacted URLs (at most 256 UTF-8 bytes)."),
            .string("url_contains", description: "Snake-case alias for urlContains."),
            .number("limit", description: "Maximum matching entries to return (1 through 200; defaults to 200)."),
            .boolean("includeHeaders", description: "Opt in to a bounded, redacted safe allowlist of request and response headers; raw Authorization and Cookie headers are omitted. Defaults to false."),
            .boolean("include_headers", description: "Snake-case alias for includeHeaders."),
            .boolean("includeBody", description: "Opt in to best-effort bounded previews of completed textual final response bodies. Recognized sensitive fields are redacted, but generic body content is not guaranteed to be secret-free; binary content, oversized responses, and unavailable bodies are omitted. Defaults to false."),
            .boolean("include_body", description: "Snake-case alias for includeBody."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserNetworkOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let requestedURL = try input.url?.nilIfBlank.map {
            try BrowserURLPolicy(environment: context.environment).validate($0)
        }
        let durationSeconds = try BrowserNetworkCapture.resolvedDuration(input.resolvedDuration)
        let filters = try BrowserNetworkFilters(
            resourceTypes: input.resolvedResourceTypes,
            status: input.resolvedStatus,
            urlContains: input.resolvedURLContains
        )
        let limit = try BrowserNetworkCapture.resolvedLimit(input.limit)
        let capturesHeaders = input.resolvesHeaders
        let capturesBodies = input.resolvesBody
        let allowsLoopback = requestedURL.map {
            BrowserURLPolicy(environment: context.environment).isLoopbackURL($0.absoluteString)
        }

        return try await BrowserToolsRunner.withPage(
            pageID: pageID,
            context: context,
            allowsLoopback: allowsLoopback
        ) { session, tab in
            let observer = BrowserNetworkObserver(
                capturesHeaders: capturesHeaders,
                capturesBodies: capturesBodies
            )
            let eventToken = session.addEventHandler { event in
                observer.consume(event)
            }
            defer { session.removeEventHandler(eventToken) }

            var networkEnabled = false
            do {
                if capturesBodies {
                    _ = try await session.send(
                        method: "Network.enable",
                        params: BrowserNetworkBodyCapture.networkEnableParameters
                    )
                } else {
                    _ = try await session.send(method: "Network.enable")
                }
                networkEnabled = true
                let observationStartedAt = Date()
                if let requestedURL {
                    try await session.navigate(to: requestedURL.absoluteString)
                }
                try await Task.sleep(
                    nanoseconds: UInt64(durationSeconds) * 1_000_000_000
                )
                let observedDurationMilliseconds = max(
                    0,
                    Date().timeIntervalSince(observationStartedAt) * 1_000
                )
                var observation = observer.snapshot(filters: filters, limit: limit)
                if capturesBodies {
                    observation = await observation.capturingBodies(from: session)
                }
                if networkEnabled {
                    _ = try? await session.send(method: "Network.disable")
                    networkEnabled = false
                }
                let page = try await session.pageMetadata(pageID: tab.id)
                return BrowserNetworkOutput(
                    page: page,
                    observation: observation,
                    durationSeconds: durationSeconds,
                    observedDurationMilliseconds: observedDurationMilliseconds
                )
            } catch {
                if networkEnabled {
                    _ = try? await session.send(method: "Network.disable")
                }
                throw error
            }
        }
    }
}

struct BrowserScreenshotTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let fullPage: Bool?
        let full_page: Bool?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }

        var resolvesFullPage: Bool {
            fullPage ?? full_page ?? false
        }
    }

    static let name = "browser.screenshot"
    static let description = "Captures a PNG screenshot of a persistent Browser page and writes it to a Browser artifact file. The image is not embedded in the model transcript."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .boolean("fullPage", description: "Capture beyond the current viewport. Defaults to false."),
            .boolean("full_page", description: "Snake-case alias for fullPage."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserScreenshotOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let fullPage = input.resolvesFullPage
        let store = BrowserArtifactStore(environment: context.environment)

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            let image = try await session.captureScreenshot(fullPage: fullPage)
            let artifact = try store.storeScreenshotPNG(image, pageID: tab.id)
            let page = try await session.pageMetadata(pageID: tab.id)
            return BrowserScreenshotOutput(page: page, artifact: artifact, fullPage: fullPage)
        }
    }
}
