//
//  BrowserNetworkCapture.swift
//  BrowserToolsFeature
//

import Foundation

// MARK: - Network Capture

enum BrowserNetworkBodyCapture {
    // These are intentionally constants rather than tool parameters. They cap
    // Chrome's response buffer and the resulting model-visible text even when
    // a page attempts to create a large response during an observation.
    static let maximumBodyCandidates = 3
    static let maximumResourceBufferBytes = 48 * 1_024
    static let maximumTotalBufferBytes = 192 * 1_024
    static let maximumBodyPreviewBytes = 8 * 1_024
    private static let maximumBase64BodyBytes = ((maximumResourceBufferBytes + 2) / 3) * 4

    static var networkEnableParameters: [String: Any] {
        [
            "maxResourceBufferSize": maximumResourceBufferBytes,
            "maxTotalBufferSize": maximumTotalBufferBytes,
        ]
    }

    static func capture(
        from responseBodyFetcher: any BrowserNetworkResponseBodyFetching,
        candidates: [BrowserNetworkBodyCandidate]
    ) async -> [Int: BrowserNetworkResponseBody] {
        var previews: [Int: BrowserNetworkResponseBody] = [:]
        for candidate in candidates.prefix(maximumBodyCandidates) {
            guard candidate.encodedDataLength <= Int64(maximumResourceBufferBytes),
                  isTextual(mimeType: candidate.mimeType)
            else {
                continue
            }
            let response: BrowserNetworkResponseBodyPayload?
            do {
                response = try await responseBodyFetcher.responseBody(for: candidate.requestID)
            } catch {
                continue
            }
            guard let response,
                  let preview = preview(
                      body: response.body,
                      isBase64Encoded: response.isBase64Encoded,
                      mimeType: candidate.mimeType
                  )
            else {
                continue
            }
            previews[candidate.outputIndex] = preview
        }
        return previews
    }

    static func preview(
        body: String,
        isBase64Encoded: Bool,
        mimeType: String
    ) -> BrowserNetworkResponseBody? {
        guard isTextual(mimeType: mimeType) else { return nil }
        let sourceText: String
        if isBase64Encoded {
            guard body.lengthOfBytes(using: .utf8) <= maximumBase64BodyBytes else {
                return nil
            }
            guard let data = Data(base64Encoded: body),
                  data.count <= maximumResourceBufferBytes,
                  let decoded = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            sourceText = decoded
        } else {
            guard body.lengthOfBytes(using: .utf8) <= maximumResourceBufferBytes else {
                return nil
            }
            sourceText = body
        }

        let redacted = BrowserNetworkSensitiveTextRedaction.redact(sourceText)
        let clipped = BrowserNetworkOutputBounds.clipWithMetadata(
            redacted,
            maximumBytes: maximumBodyPreviewBytes
        )
        return BrowserNetworkResponseBody(
            mimeType: BrowserNetworkOutputBounds.clip(
                mimeType,
                maximumBytes: BrowserNetworkOutputBounds.maximumMIMETypeBytes
            ),
            text: clipped.value,
            truncated: clipped.truncated
                || sourceText.lengthOfBytes(using: .utf8) > maximumBodyPreviewBytes
        )
    }

    static func isTextual(mimeType: String) -> Bool {
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? ""
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("text/")
            || normalized == "application/json"
            || normalized.hasSuffix("+json")
            || normalized == "application/xml"
            || normalized.hasSuffix("+xml")
            || normalized == "application/javascript"
            || normalized == "application/x-javascript"
            || normalized == "application/graphql"
            || normalized == "application/x-www-form-urlencoded"
    }
}

// MARK: - Capture Models

extension BrowserNetworkSummary {
    static func make(
        capturedEntryCount: Int,
        matchingEntries: [BrowserNetworkEntry],
        returnedEntryCount: Int,
        redirectCount: Int
    ) -> BrowserNetworkSummary {
        var resourceTypeCounts: [String: Int] = [:]
        var statusCounts: [String: Int] = [:]
        var failedEntryCount = 0
        var cacheHitCount = 0
        var serviceWorkerResponseCount = 0
        var totalEncodedDataLength: Int64?

        for entry in matchingEntries {
            resourceTypeCounts[entry.resourceType, default: 0] += 1
            if let status = entry.status {
                statusCounts[String(status), default: 0] += 1
            }
            if entry.failure != nil {
                failedEntryCount += 1
            }
            if entry.fromCache == true {
                cacheHitCount += 1
            }
            if entry.fromServiceWorker == true {
                serviceWorkerResponseCount += 1
            }
            if let encodedDataLength = entry.encodedDataLength {
                let current = totalEncodedDataLength ?? 0
                totalEncodedDataLength = current > Int64.max - encodedDataLength
                    ? Int64.max
                    : current + encodedDataLength
            }
        }

        return BrowserNetworkSummary(
            capturedEntryCount: capturedEntryCount,
            matchingEntryCount: matchingEntries.count,
            returnedEntryCount: returnedEntryCount,
            failedEntryCount: failedEntryCount,
            redirectCount: redirectCount,
            cacheHitCount: cacheHitCount,
            serviceWorkerResponseCount: serviceWorkerResponseCount,
            totalEncodedDataLength: totalEncodedDataLength,
            resourceTypeCounts: resourceTypeCounts,
            statusCounts: statusCounts
        )
    }
}

enum BrowserNetworkCapture {
    static let maximumDurationSeconds = 30
    static let maximumReturnedEntries = BrowserNetworkObserver.maximumEntries
    static let maximumResourceTypeFilters = 10
    static let maximumResourceTypeBytes = 64
    static let maximumURLSubstringBytes = 256

    static func resolvedDuration(_ requestedDuration: Int?) throws -> Int {
        guard let requestedDuration else { return 3 }
        guard (1...maximumDurationSeconds).contains(requestedDuration) else {
            throw BrowserToolsFeatureError.browserError(
                "Network observation duration must be between 1 and \(maximumDurationSeconds) seconds."
            )
        }
        return requestedDuration
    }

    static func resolvedLimit(_ requestedLimit: Int?) throws -> Int {
        guard let requestedLimit else { return maximumReturnedEntries }
        guard requestedLimit > 0 else {
            throw BrowserToolsFeatureError.browserError("Network limit must be at least 1.")
        }
        return min(requestedLimit, maximumReturnedEntries)
    }
}
