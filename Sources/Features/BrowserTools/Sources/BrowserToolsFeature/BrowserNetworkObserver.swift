//
//  BrowserNetworkObserver.swift
//  BrowserToolsFeature
//

import Foundation
import Synchronization

// MARK: - Network Observer

struct BrowserNetworkObservation: Sendable {
    let entries: [BrowserNetworkEntry]
    let truncated: Bool
    let captureTruncated: Bool
    let totalCapturedEntries: Int
    let totalMatchingEntries: Int
    let summary: BrowserNetworkSummary

    /// Request identifiers are intentionally only an invocation-local bridge
    /// to Network.getResponseBody. They are not Codable and are discarded
    /// before BrowserNetworkOutput is constructed.
    private let bodyCandidates: [BrowserNetworkBodyCandidate]

    fileprivate init(
        entries: [BrowserNetworkEntry],
        truncated: Bool,
        captureTruncated: Bool,
        totalCapturedEntries: Int,
        totalMatchingEntries: Int,
        summary: BrowserNetworkSummary,
        bodyCandidates: [BrowserNetworkBodyCandidate] = []
    ) {
        self.entries = entries
        self.truncated = truncated
        self.captureTruncated = captureTruncated
        self.totalCapturedEntries = totalCapturedEntries
        self.totalMatchingEntries = totalMatchingEntries
        self.summary = summary
        self.bodyCandidates = bodyCandidates
    }

    /// Preserves the original observation initializer for callers that do not
    /// need the additive filtering, summary, or body-capture metadata.
    init(entries: [BrowserNetworkEntry], truncated: Bool) {
        self.init(
            entries: entries,
            truncated: truncated,
            captureTruncated: truncated,
            totalCapturedEntries: entries.count,
            totalMatchingEntries: entries.count,
            summary: BrowserNetworkSummary.make(
                capturedEntryCount: entries.count,
                matchingEntries: entries,
                returnedEntryCount: entries.count,
                redirectCount: 0
            )
        )
    }

    func capturingBodies(from responseBodyFetcher: any BrowserNetworkResponseBodyFetching) async -> Self {
        guard !bodyCandidates.isEmpty else { return withoutBodyCandidates() }
        let bodies = await BrowserNetworkBodyCapture.capture(
            from: responseBodyFetcher,
            candidates: bodyCandidates
        )
        guard !bodies.isEmpty else { return withoutBodyCandidates() }

        var amendedEntries = entries
        for (index, body) in bodies where amendedEntries.indices.contains(index) {
            amendedEntries[index].responseBody = body
        }
        return Self(
            entries: amendedEntries,
            truncated: truncated,
            captureTruncated: captureTruncated,
            totalCapturedEntries: totalCapturedEntries,
            totalMatchingEntries: totalMatchingEntries,
            summary: summary
        )
    }

    private func withoutBodyCandidates() -> Self {
        Self(
            entries: entries,
            truncated: truncated,
            captureTruncated: captureTruncated,
            totalCapturedEntries: totalCapturedEntries,
            totalMatchingEntries: totalMatchingEntries,
            summary: summary
        )
    }
}
/// Correlates the CDP Network event stream without retaining raw protocol
/// payloads. It is lock-backed because CDP invokes handlers from its WebSocket
/// receive task while the feature invocation reads the completed snapshot.
final class BrowserNetworkObserver: Sendable {
    static let maximumEntries = 200

    private struct StoredEntry: Sendable {
        let requestID: String
        var entry: BrowserNetworkEntry
        var startedTimestamp: Double?
        var completed: Bool
    }

    private struct State: Sendable {
        var entries: [StoredEntry] = []
        var latestIndexByRequestID: [String: Int] = [:]
        var didTruncate = false
        var redirectTransitions = 0
        var capturedHeaderBytes = 0
    }

    private let capturesHeaders: Bool
    private let capturesBodies: Bool
    private let state = Mutex(State())

    init(capturesHeaders: Bool = false, capturesBodies: Bool = false) {
        self.capturesHeaders = capturesHeaders
        self.capturesBodies = capturesBodies
    }

    func consume(_ event: CDPEvent) {
        state.withLock { state in
            switch event.method {
            case "Network.requestWillBeSent":
                recordRequest(event.params, into: &state)
            case "Network.responseReceived":
                recordResponse(event.params, into: &state)
            case "Network.requestServedFromCache":
                recordCacheHit(event.params, into: &state)
            case "Network.loadingFinished":
                recordFinished(event.params, into: &state)
            case "Network.loadingFailed":
                recordFailure(event.params, into: &state)
            default:
                break
            }
            return
        }
    }

    func snapshot(
        filters: BrowserNetworkFilters = .all,
        limit: Int = BrowserNetworkObserver.maximumEntries
    ) -> BrowserNetworkObservation {
        state.withLock { state in
            let matching = state.entries.enumerated().filter { filters.matches($0.element.entry) }
            let returned = Array(matching.prefix(limit))
            let returnedEntries = returned.map(\.element.entry)
            let bodyCandidates: [BrowserNetworkBodyCandidate]
            if capturesBodies {
                bodyCandidates = returned.enumerated().compactMap { outputIndex, item in
                    let stored = item.element
                    guard stored.completed,
                          // Chrome reuses a Network.requestId for every redirect
                          // hop. Network.getResponseBody accepts only that ID, so
                          // a completed older hop could otherwise receive the
                          // current final response body.
                          state.latestIndexByRequestID[stored.requestID] == item.offset,
                          let mimeType = stored.entry.mimeType,
                          let encodedDataLength = stored.entry.encodedDataLength
                    else {
                        return nil
                    }
                    return BrowserNetworkBodyCandidate(
                        outputIndex: outputIndex,
                        requestID: stored.requestID,
                        mimeType: mimeType,
                        encodedDataLength: encodedDataLength
                    )
                }
            } else {
                bodyCandidates = []
            }

            let summary = BrowserNetworkSummary.make(
                capturedEntryCount: state.entries.count,
                matchingEntries: matching.map(\.element.entry),
                returnedEntryCount: returnedEntries.count,
                redirectCount: state.redirectTransitions
            )
            return BrowserNetworkObservation(
                entries: returnedEntries,
                truncated: state.didTruncate || matching.count > returnedEntries.count,
                captureTruncated: state.didTruncate,
                totalCapturedEntries: state.entries.count,
                totalMatchingEntries: matching.count,
                summary: summary,
                bodyCandidates: bodyCandidates
            )
        }
    }

    private func recordRequest(_ params: [String: Any], into state: inout State) {
        guard let requestID = params["requestId"] as? String,
              let request = params["request"] as? [String: Any],
              let rawURL = request["url"] as? String,
              !requestID.isEmpty,
              !rawURL.isEmpty
        else {
            return
        }

        let resourceType = Self.resourceType(params["type"])
        let requestTimestamp = BrowserNetworkValue.double(params["timestamp"])
        var redirectChain: [BrowserNetworkRedirectHop] = []

        if let redirectResponse = params["redirectResponse"] as? [String: Any] {
            state.redirectTransitions += 1
            if let previousIndex = state.latestIndexByRequestID[requestID] {
                finalizeRedirect(
                    at: previousIndex,
                    response: redirectResponse,
                    resourceType: resourceType,
                    completedTimestamp: requestTimestamp,
                    into: &state
                )
                redirectChain = state.entries[previousIndex].entry.redirectChain
                redirectChain.append(redirectHop(from: state.entries[previousIndex].entry))
            } else {
                redirectChain = [redirectHop(from: redirectResponse)]
            }
        }

        let requestHeaderSelection = capturesHeaders
            ? retainHeaders(BrowserNetworkHeaderRedaction.sanitize(request["headers"], direction: .request), into: &state)
            : nil
        let entry = BrowserNetworkEntry(
            method: BrowserNetworkOutputBounds.clipOptional(
                request["method"] as? String,
                maximumBytes: BrowserNetworkOutputBounds.maximumMethodBytes
            ),
            url: BrowserNetworkURLRedaction.apply(to: rawURL),
            status: nil,
            failure: nil,
            resourceType: resourceType,
            initiator: BrowserNetworkInitiator.decode(params["initiator"]),
            redirectChain: redirectChain,
            requestHeaders: requestHeaderSelection?.headers,
            headersTruncated: requestHeaderSelection?.truncated
        )
        append(
            requestID: requestID,
            entry: entry,
            startedTimestamp: requestTimestamp,
            completed: false,
            into: &state
        )
    }

    private func recordResponse(_ params: [String: Any], into state: inout State) {
        guard let requestID = params["requestId"] as? String,
              let response = params["response"] as? [String: Any],
              !requestID.isEmpty
        else {
            return
        }
        let resourceType = Self.resourceType(params["type"])
        let responseTimestamp = BrowserNetworkValue.double(params["timestamp"])
        if let index = state.latestIndexByRequestID[requestID] {
            applyResponse(
                at: index,
                response: response,
                resourceType: resourceType,
                completedTimestamp: responseTimestamp,
                completesEntry: false,
                into: &state
            )
            return
        }

        guard let rawURL = response["url"] as? String, !rawURL.isEmpty else { return }
        let responseHeaderSelection = capturesHeaders
            ? retainHeaders(BrowserNetworkHeaderRedaction.sanitize(response["headers"], direction: .response), into: &state)
            : nil
        let cacheFlags = cacheFlags(from: response)
        append(
            requestID: requestID,
            entry: BrowserNetworkEntry(
                method: nil,
                url: BrowserNetworkURLRedaction.apply(to: rawURL),
                status: BrowserNetworkValue.integer(response["status"]),
                failure: nil,
                resourceType: resourceType,
                mimeType: BrowserNetworkOutputBounds.clipOptional(
                    response["mimeType"] as? String,
                    maximumBytes: BrowserNetworkOutputBounds.maximumMIMETypeBytes
                ),
                encodedDataLength: BrowserNetworkValue.nonNegativeInt64(response["encodedDataLength"]),
                timing: BrowserNetworkTiming.decode(response["timing"]),
                fromCache: cacheFlags.fromCache,
                fromDiskCache: cacheFlags.fromDiskCache,
                fromPrefetchCache: cacheFlags.fromPrefetchCache,
                fromServiceWorker: cacheFlags.fromServiceWorker,
                responseHeaders: responseHeaderSelection?.headers,
                headersTruncated: responseHeaderSelection?.truncated
            ),
            startedTimestamp: nil,
            completed: false,
            into: &state
        )
    }

    private func recordCacheHit(_ params: [String: Any], into state: inout State) {
        guard let requestID = params["requestId"] as? String,
              let index = state.latestIndexByRequestID[requestID]
        else {
            return
        }
        state.entries[index].entry.fromCache = true
    }

    private func recordFinished(_ params: [String: Any], into state: inout State) {
        guard let requestID = params["requestId"] as? String,
              let index = state.latestIndexByRequestID[requestID]
        else {
            return
        }
        var stored = state.entries[index]
        if let encodedDataLength = BrowserNetworkValue.nonNegativeInt64(params["encodedDataLength"]) {
            stored.entry.encodedDataLength = encodedDataLength
        }
        finalize(&stored, completedTimestamp: BrowserNetworkValue.double(params["timestamp"]))
        state.entries[index] = stored
    }

    private func recordFailure(_ params: [String: Any], into state: inout State) {
        guard let requestID = params["requestId"] as? String, !requestID.isEmpty else { return }
        let failure = BrowserNetworkSensitiveTextRedaction.redactAndClip(
            params["errorText"] as? String ?? "Network request failed",
            maximumBytes: BrowserNetworkOutputBounds.maximumFailureBytes
        )
        if let index = state.latestIndexByRequestID[requestID] {
            var stored = state.entries[index]
            stored.entry.failure = failure
            finalize(&stored, completedTimestamp: BrowserNetworkValue.double(params["timestamp"]))
            state.entries[index] = stored
        } else {
            append(
                requestID: requestID,
                entry: BrowserNetworkEntry(
                    method: nil,
                    url: "<unknown>",
                    status: nil,
                    failure: failure,
                    resourceType: Self.resourceType(params["type"])
                ),
                startedTimestamp: nil,
                completed: true,
                into: &state
            )
        }
    }

    private func finalizeRedirect(
        at index: Int,
        response: [String: Any],
        resourceType: String,
        completedTimestamp: Double?,
        into state: inout State
    ) {
        applyResponse(
            at: index,
            response: response,
            resourceType: resourceType,
            completedTimestamp: completedTimestamp,
            completesEntry: true,
            into: &state
        )
    }

    private func applyResponse(
        at index: Int,
        response: [String: Any],
        resourceType: String,
        completedTimestamp: Double?,
        completesEntry: Bool,
        into state: inout State
    ) {
        guard state.entries.indices.contains(index) else { return }
        var stored = state.entries[index]
        if let rawURL = response["url"] as? String, !rawURL.isEmpty {
            stored.entry.url = BrowserNetworkURLRedaction.apply(to: rawURL)
        }
        stored.entry.status = BrowserNetworkValue.integer(response["status"])
        stored.entry.failure = nil
        stored.entry.resourceType = resourceType
        stored.entry.mimeType = BrowserNetworkOutputBounds.clipOptional(
            response["mimeType"] as? String,
            maximumBytes: BrowserNetworkOutputBounds.maximumMIMETypeBytes
        )
        if let encodedDataLength = BrowserNetworkValue.nonNegativeInt64(response["encodedDataLength"]) {
            stored.entry.encodedDataLength = encodedDataLength
        }
        if let timing = BrowserNetworkTiming.decode(response["timing"]) {
            stored.entry.timing = timing
        }

        let flags = cacheFlags(from: response)
        stored.entry.fromDiskCache = flags.fromDiskCache
        stored.entry.fromPrefetchCache = flags.fromPrefetchCache
        stored.entry.fromServiceWorker = flags.fromServiceWorker
        stored.entry.fromCache = stored.entry.fromCache == true || flags.fromCache == true

        if capturesHeaders {
            let responseHeaders = retainHeaders(BrowserNetworkHeaderRedaction.sanitize(
                response["headers"],
                direction: .response
            ), into: &state)
            stored.entry.responseHeaders = responseHeaders.headers
            stored.entry.headersTruncated = (stored.entry.headersTruncated ?? false)
                || responseHeaders.truncated
        }
        if completesEntry {
            finalize(&stored, completedTimestamp: completedTimestamp)
        }
        state.entries[index] = stored
    }

    private func finalize(_ stored: inout StoredEntry, completedTimestamp: Double?) {
        if let startedTimestamp = stored.startedTimestamp,
           let completedTimestamp,
           completedTimestamp >= startedTimestamp
        {
            stored.entry.durationMilliseconds = (completedTimestamp - startedTimestamp) * 1_000
        }
        stored.completed = true
    }

    private func append(
        requestID: String,
        entry: BrowserNetworkEntry,
        startedTimestamp: Double?,
        completed: Bool,
        into state: inout State
    ) {
        guard state.entries.count < Self.maximumEntries else {
            state.didTruncate = true
            // A redirect can arrive after the retained-entry budget is full.
            // Do not leave its previous hop marked as current, or it could
            // become a response-body candidate for the omitted final hop.
            state.latestIndexByRequestID.removeValue(forKey: requestID)
            return
        }
        state.entries.append(StoredEntry(
            requestID: requestID,
            entry: entry,
            startedTimestamp: startedTimestamp,
            completed: completed
        ))
        state.latestIndexByRequestID[requestID] = state.entries.count - 1
    }

    private func retainHeaders(
        _ selection: BrowserNetworkHeaderSelection,
        into state: inout State
    ) -> BrowserNetworkHeaderSelection {
        let remaining = max(
            0,
            BrowserNetworkHeaderRedaction.maximumTotalCapturedBytes - state.capturedHeaderBytes
        )
        guard remaining > 0 else {
            return BrowserNetworkHeaderSelection(headers: [], truncated: !selection.headers.isEmpty || selection.truncated)
        }

        var retained: [BrowserNetworkHeader] = []
        var usedBytes = 0
        for header in selection.headers {
            let headerBytes = header.name.lengthOfBytes(using: .utf8)
                + header.value.lengthOfBytes(using: .utf8)
            guard usedBytes + headerBytes <= remaining else { continue }
            retained.append(header)
            usedBytes += headerBytes
        }
        state.capturedHeaderBytes += usedBytes
        return BrowserNetworkHeaderSelection(
            headers: retained,
            truncated: selection.truncated || retained.count < selection.headers.count
        )
    }

    private func redirectHop(from entry: BrowserNetworkEntry) -> BrowserNetworkRedirectHop {
        BrowserNetworkRedirectHop(
            url: entry.url,
            status: entry.status,
            mimeType: entry.mimeType,
            fromCache: entry.fromCache,
            fromServiceWorker: entry.fromServiceWorker
        )
    }

    private func redirectHop(from response: [String: Any]) -> BrowserNetworkRedirectHop {
        let flags = cacheFlags(from: response)
        return BrowserNetworkRedirectHop(
            url: BrowserNetworkURLRedaction.apply(to: response["url"] as? String ?? "<unknown>"),
            status: BrowserNetworkValue.integer(response["status"]),
            mimeType: BrowserNetworkOutputBounds.clipOptional(
                response["mimeType"] as? String,
                maximumBytes: BrowserNetworkOutputBounds.maximumMIMETypeBytes
            ),
            fromCache: flags.fromCache,
            fromServiceWorker: flags.fromServiceWorker
        )
    }

    private func cacheFlags(from response: [String: Any]) -> BrowserNetworkCacheFlags {
        let fromDiskCache = BrowserNetworkValue.bool(response["fromDiskCache"]) ?? false
        let fromPrefetchCache = BrowserNetworkValue.bool(response["fromPrefetchCache"]) ?? false
        let fromServiceWorker = BrowserNetworkValue.bool(response["fromServiceWorker"]) ?? false
        return BrowserNetworkCacheFlags(
            fromCache: fromDiskCache || fromPrefetchCache,
            fromDiskCache: fromDiskCache,
            fromPrefetchCache: fromPrefetchCache,
            fromServiceWorker: fromServiceWorker
        )
    }

    private static func resourceType(_ rawValue: Any?) -> String {
        guard let rawValue = rawValue as? String else { return "Other" }
        let bounded = BrowserNetworkOutputBounds.clip(
            rawValue,
            maximumBytes: BrowserNetworkOutputBounds.maximumResourceTypeBytes
        )
        return BrowserNetworkFilters.canonicalResourceType(bounded) ?? bounded
    }
}

private struct BrowserNetworkCacheFlags {
    let fromCache: Bool
    let fromDiskCache: Bool
    let fromPrefetchCache: Bool
    let fromServiceWorker: Bool
}

struct BrowserNetworkBodyCandidate: Sendable {
    let outputIndex: Int
    let requestID: String
    let mimeType: String
    let encodedDataLength: Int64
}

struct BrowserNetworkResponseBodyPayload: Sendable {
    let body: String
    let isBase64Encoded: Bool
}

/// Keeps CDP transport details out of the observation so redirect/body
/// association can be tested with the same request-ID semantics as production.
protocol BrowserNetworkResponseBodyFetching: Sendable {
    func responseBody(for requestID: String) async throws -> BrowserNetworkResponseBodyPayload?
}

extension CDPSession: BrowserNetworkResponseBodyFetching {
    func responseBody(for requestID: String) async throws -> BrowserNetworkResponseBodyPayload? {
        let response = try await send(
            method: "Network.getResponseBody",
            params: ["requestId": requestID]
        )
        guard let result = response["result"] as? [String: Any],
              let body = result["body"] as? String
        else {
            return nil
        }
        return BrowserNetworkResponseBodyPayload(
            body: body,
            isBase64Encoded: BrowserNetworkValue.bool(result["base64Encoded"]) ?? false
        )
    }
}

private extension BrowserNetworkInitiator {
    static func decode(_ rawValue: Any?) -> BrowserNetworkInitiator? {
        guard let values = rawValue as? [String: Any] else { return nil }
        let directURL = values["url"] as? String
        let stackFrame = ((values["stack"] as? [String: Any])?["callFrames"] as? [[String: Any]])?.first
        let rawURL = directURL ?? (stackFrame?["url"] as? String)
        let type = BrowserNetworkOutputBounds.clip(
            values["type"] as? String ?? "other",
            maximumBytes: BrowserNetworkOutputBounds.maximumResourceTypeBytes
        )
        let lineNumber = BrowserNetworkValue.integer(
            values["lineNumber"] ?? stackFrame?["lineNumber"]
        )
        let columnNumber = BrowserNetworkValue.integer(
            values["columnNumber"] ?? stackFrame?["columnNumber"]
        )
        guard rawURL != nil || values["type"] != nil || lineNumber != nil || columnNumber != nil else {
            return nil
        }
        return BrowserNetworkInitiator(
            type: type,
            url: rawURL.map { BrowserNetworkURLRedaction.apply(to: $0) },
            lineNumber: lineNumber,
            columnNumber: columnNumber
        )
    }
}

// MARK: - Header Redaction

private enum BrowserNetworkHeaderDirection {
    case request
    case response
}

private struct BrowserNetworkHeaderSelection {
    let headers: [BrowserNetworkHeader]
    let truncated: Bool
}

private enum BrowserNetworkHeaderRedaction {
    static let maximumHeaders = 12
    static let maximumTotalCapturedBytes = 24 * 1_024
    private static let maximumHeaderSourceBytes = 512
    private static let maximumHeaderValueBytes = 256

    private static let allowedRequestHeaders: Set<String> = [
        "accept", "accept-charset", "accept-encoding", "accept-language", "cache-control",
        "content-length", "content-type", "origin", "pragma", "range", "referer",
        "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "sec-fetch-dest",
        "sec-fetch-mode", "sec-fetch-site", "sec-fetch-user",
    ]
    private static let allowedResponseHeaders: Set<String> = [
        "accept-ranges", "access-control-allow-credentials", "access-control-allow-headers",
        "access-control-allow-methods", "access-control-allow-origin", "access-control-expose-headers",
        "access-control-max-age", "age", "cache-control", "content-disposition", "content-encoding",
        "content-language", "content-length", "content-location", "content-range", "content-type",
        "cross-origin-embedder-policy", "cross-origin-opener-policy", "cross-origin-resource-policy",
        "date", "expires", "last-modified", "location", "pragma", "referrer-policy", "retry-after",
        "server", "strict-transport-security", "timing-allow-origin", "vary", "via",
        "x-content-type-options", "x-frame-options", "x-xss-protection",
    ]

    static func sanitize(
        _ rawHeaders: Any?,
        direction: BrowserNetworkHeaderDirection
    ) -> BrowserNetworkHeaderSelection {
        guard let rawHeaders = rawHeaders as? [String: Any] else {
            return BrowserNetworkHeaderSelection(headers: [], truncated: false)
        }
        let allowed: Set<String>
        switch direction {
        case .request:
            allowed = allowedRequestHeaders
        case .response:
            allowed = allowedResponseHeaders
        }

        var candidates: [BrowserNetworkHeader] = []
        var seenNames = Set<String>()
        for (rawName, rawValue) in rawHeaders {
            guard rawName.lengthOfBytes(using: .utf8) <= 128 else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty,
                  allowed.contains(name),
                  !BrowserNetworkSensitiveTextRedaction.isSensitiveName(name),
                  seenNames.insert(name).inserted,
                  let stringValue = BrowserNetworkValue.headerString(rawValue)
            else {
                continue
            }

            let boundedSource = BrowserNetworkOutputBounds.clip(
                stringValue,
                maximumBytes: maximumHeaderSourceBytes
            )
            let redactedValue: String
            if name == "location" || name == "content-location" || name == "origin" || name == "referer" {
                redactedValue = BrowserNetworkSensitiveTextRedaction.redactHeaderValue(
                    BrowserNetworkURLRedaction.apply(to: boundedSource)
                )
            } else {
                redactedValue = BrowserNetworkSensitiveTextRedaction.redactHeaderValue(boundedSource)
            }
            candidates.append(BrowserNetworkHeader(
                name: name,
                value: BrowserNetworkOutputBounds.clip(
                    redactedValue,
                    maximumBytes: maximumHeaderValueBytes
                )
            ))
        }
        candidates.sort { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return BrowserNetworkHeaderSelection(
            headers: Array(candidates.prefix(maximumHeaders)),
            truncated: candidates.count > maximumHeaders
        )
    }
}
