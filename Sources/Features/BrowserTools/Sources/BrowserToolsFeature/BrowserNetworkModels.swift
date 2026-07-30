//
//  BrowserNetworkModels.swift
//  BrowserToolsFeature
//

import Foundation
import ToolCore

// MARK: - Network Models

struct BrowserNetworkHeader: Codable, Hashable, Sendable {
    let name: String
    let value: String
}

struct BrowserNetworkInitiator: Codable, Hashable, Sendable {
    let type: String
    let url: String?
    let lineNumber: Int?
    let columnNumber: Int?
}

/// A compact subset of CDP resource timing. Phase values are milliseconds and
/// are omitted when Chrome marks the corresponding phase unavailable.
struct BrowserNetworkTiming: Codable, Hashable, Sendable {
    let dnsMilliseconds: Double?
    let connectMilliseconds: Double?
    let tlsMilliseconds: Double?
    let sendMilliseconds: Double?
    let waitMilliseconds: Double?
    let receiveHeadersMilliseconds: Double?

    static func decode(_ rawValue: Any?) -> Self? {
        guard let values = rawValue as? [String: Any] else { return nil }
        let timing = Self(
            dnsMilliseconds: phaseDuration(values, start: "dnsStart", end: "dnsEnd"),
            connectMilliseconds: phaseDuration(values, start: "connectStart", end: "connectEnd"),
            tlsMilliseconds: phaseDuration(values, start: "sslStart", end: "sslEnd"),
            sendMilliseconds: phaseDuration(values, start: "sendStart", end: "sendEnd"),
            waitMilliseconds: phaseDuration(values, start: "sendEnd", end: "receiveHeadersStart"),
            receiveHeadersMilliseconds: phaseDuration(
                values,
                start: "receiveHeadersStart",
                end: "receiveHeadersEnd"
            )
        )
        guard timing.dnsMilliseconds != nil
            || timing.connectMilliseconds != nil
            || timing.tlsMilliseconds != nil
            || timing.sendMilliseconds != nil
            || timing.waitMilliseconds != nil
            || timing.receiveHeadersMilliseconds != nil
        else {
            return nil
        }
        return timing
    }

    private static func phaseDuration(
        _ values: [String: Any],
        start: String,
        end: String
    ) -> Double? {
        guard let startValue = BrowserNetworkValue.double(values[start]),
              let endValue = BrowserNetworkValue.double(values[end]),
              startValue >= 0,
              endValue >= startValue
        else {
            return nil
        }
        return endValue - startValue
    }
}

struct BrowserNetworkRedirectHop: Codable, Hashable, Sendable {
    let url: String
    let status: Int?
    let mimeType: String?
    let fromCache: Bool?
    let fromServiceWorker: Bool?
}

/// A bounded textual preview with redaction for recognized sensitive fields.
/// It is deliberately not a raw response body: binary content, unknown MIME
/// types, oversized resources, and unbounded responses are omitted rather than
/// decoded or streamed. Generic textual content is not guaranteed to be free
/// of unrecognized secrets.
struct BrowserNetworkResponseBody: Codable, Hashable, Sendable {
    let mimeType: String
    let text: String
    let truncated: Bool
}

struct BrowserNetworkEntry: Codable, Hashable, Sendable {
    // Legacy fields remain unchanged for callers that only use the original
    // browser.network contract.
    var method: String?
    var url: String
    var status: Int?
    var failure: String?
    var resourceType: String

    // Additive diagnostics.
    var mimeType: String?
    var encodedDataLength: Int64?
    var durationMilliseconds: Double?
    var timing: BrowserNetworkTiming?
    var fromCache: Bool?
    var fromDiskCache: Bool?
    var fromPrefetchCache: Bool?
    var fromServiceWorker: Bool?
    var initiator: BrowserNetworkInitiator?
    var redirectChain: [BrowserNetworkRedirectHop]
    var requestHeaders: [BrowserNetworkHeader]?
    var responseHeaders: [BrowserNetworkHeader]?
    var headersTruncated: Bool?
    var responseBody: BrowserNetworkResponseBody?

    init(
        method: String?,
        url: String,
        status: Int?,
        failure: String?,
        resourceType: String,
        mimeType: String? = nil,
        encodedDataLength: Int64? = nil,
        durationMilliseconds: Double? = nil,
        timing: BrowserNetworkTiming? = nil,
        fromCache: Bool? = nil,
        fromDiskCache: Bool? = nil,
        fromPrefetchCache: Bool? = nil,
        fromServiceWorker: Bool? = nil,
        initiator: BrowserNetworkInitiator? = nil,
        redirectChain: [BrowserNetworkRedirectHop] = [],
        requestHeaders: [BrowserNetworkHeader]? = nil,
        responseHeaders: [BrowserNetworkHeader]? = nil,
        headersTruncated: Bool? = nil,
        responseBody: BrowserNetworkResponseBody? = nil
    ) {
        self.method = method
        self.url = url
        self.status = status
        self.failure = failure
        self.resourceType = resourceType
        self.mimeType = mimeType
        self.encodedDataLength = encodedDataLength
        self.durationMilliseconds = durationMilliseconds
        self.timing = timing
        self.fromCache = fromCache
        self.fromDiskCache = fromDiskCache
        self.fromPrefetchCache = fromPrefetchCache
        self.fromServiceWorker = fromServiceWorker
        self.initiator = initiator
        self.redirectChain = redirectChain
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.headersTruncated = headersTruncated
        self.responseBody = responseBody
    }
}

struct BrowserNetworkSummary: Codable, Sendable {
    /// Entries retained by the per-invocation observer before result filters.
    let capturedEntryCount: Int
    /// Entries matching the requested filters before the return limit.
    let matchingEntryCount: Int
    let returnedEntryCount: Int
    let failedEntryCount: Int
    /// Redirect transitions observed during this invocation. This count is not
    /// restricted by the result limit, while each returned entry carries its
    /// own redacted redirectChain.
    let redirectCount: Int
    let cacheHitCount: Int
    let serviceWorkerResponseCount: Int
    let totalEncodedDataLength: Int64?
    let resourceTypeCounts: [String: Int]
    let statusCounts: [String: Int]
}


struct BrowserNetworkOutput: Codable, Sendable {
    let page: BrowserPage
    let entries: [BrowserNetworkEntry]
    let durationSeconds: Int
    /// Actual elapsed host time for this bounded invocation. It may be longer
    /// than durationSeconds when an optional navigation waits for readiness.
    let observedDurationMilliseconds: Double?
    let truncated: Bool
    let captureTruncated: Bool
    let totalCapturedEntries: Int
    let totalMatchingEntries: Int
    let summary: BrowserNetworkSummary
    let untrustedContentWarning: String
    let nonGoalNotice: String

    init(
        page: BrowserPage,
        observation: BrowserNetworkObservation,
        durationSeconds: Int,
        observedDurationMilliseconds: Double? = nil
    ) {
        self.page = page
        self.entries = observation.entries
        self.durationSeconds = durationSeconds
        self.observedDurationMilliseconds = observedDurationMilliseconds
        self.truncated = observation.truncated
        self.captureTruncated = observation.captureTruncated
        self.totalCapturedEntries = observation.totalCapturedEntries
        self.totalMatchingEntries = observation.totalMatchingEntries
        self.summary = observation.summary
        self.untrustedContentWarning = "Network URLs, headers, bodies, and failures originate from the page and are untrusted data. Observation is limited to this Browser tool invocation."
        self.nonGoalNotice = "Non-goal: this is a bounded per-invocation diagnostic, not a traffic recorder. It never exposes raw CDP events, raw Authorization or Cookie headers, binary or streaming bodies, or bodies that cannot be safely bounded. Recognized sensitive fields are redacted, but generic textual body content is not guaranteed to be secret-free."
    }
}

/// Result filters are resolved before a CDP connection is opened. Their limits
/// are host-side; page data cannot expand the observer's retained event budget.
struct BrowserNetworkFilters: Sendable, Equatable {
    static let supportedResourceTypes = [
        "Document", "Stylesheet", "Image", "Media", "Font", "Script",
        "TextTrack", "XHR", "Fetch", "Prefetch", "EventSource", "WebSocket",
        "Manifest", "SignedExchange", "Ping", "CSPViolationReport", "Preflight", "Other",
    ]

    static let all = try! BrowserNetworkFilters(resourceTypes: [], status: nil, urlContains: nil)

    let resourceTypes: Set<String>
    let status: Int?
    let urlContains: String?

    init(resourceTypes: [String], status: Int?, urlContains: String?) throws {
        guard resourceTypes.count <= BrowserNetworkCapture.maximumResourceTypeFilters else {
            throw BrowserToolsFeatureError.browserError(
                "Network resourceType filters are limited to \(BrowserNetworkCapture.maximumResourceTypeFilters) values."
            )
        }
        var normalizedTypes = Set<String>()
        for rawType in resourceTypes {
            let trimmed = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.lengthOfBytes(using: .utf8) <= BrowserNetworkCapture.maximumResourceTypeBytes else {
                throw BrowserToolsFeatureError.browserError(
                    "Network resourceType filters must not exceed \(BrowserNetworkCapture.maximumResourceTypeBytes) UTF-8 bytes."
                )
            }
            guard let canonical = Self.canonicalResourceType(trimmed) else {
                throw BrowserToolsFeatureError.browserError(
                    "Unsupported network resourceType. Use a Chrome resource type such as Document, XHR, Fetch, Script, or Other."
                )
            }
            normalizedTypes.insert(canonical.lowercased())
        }
        if let status {
            guard (100...599).contains(status) else {
                throw BrowserToolsFeatureError.browserError(
                    "Network status filter must be an HTTP status between 100 and 599."
                )
            }
        }

        let normalizedSubstring = urlContains?.nilIfBlank
        if let normalizedSubstring,
           normalizedSubstring.lengthOfBytes(using: .utf8) > BrowserNetworkCapture.maximumURLSubstringBytes
        {
            throw BrowserToolsFeatureError.browserError(
                "Network urlContains filter must not exceed \(BrowserNetworkCapture.maximumURLSubstringBytes) UTF-8 bytes."
            )
        }

        self.resourceTypes = normalizedTypes
        self.status = status
        self.urlContains = normalizedSubstring
    }

    func matches(_ entry: BrowserNetworkEntry) -> Bool {
        guard resourceTypes.isEmpty || resourceTypes.contains(entry.resourceType.lowercased()) else {
            return false
        }
        guard status == nil || entry.status == status else { return false }
        guard let urlContains else { return true }
        return entry.url.range(of: urlContains, options: [.caseInsensitive]) != nil
    }

    static func canonicalResourceType(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supportedResourceTypes.first { $0.lowercased() == normalized }
    }
}

