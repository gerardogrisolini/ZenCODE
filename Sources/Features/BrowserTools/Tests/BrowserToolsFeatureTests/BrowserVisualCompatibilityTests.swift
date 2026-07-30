//
//  BrowserVisualCompatibilityTests.swift
//  BrowserToolsFeatureTests
//
//  Covers the compatibility contract of browser.compare_screenshots: the legacy
//  encoded-byte comparison is always returned for any Browser-owned PNG accepted
//  by the old load path, while the decoded-pixel comparison and diff artifact are
//  optional and accompanied by a structured reason when dimensions, format, or
//  bounded codec limits prevent the pixel diff. The full result is preserved on
//  supported PNGs. These tests live in a dedicated file and do not modify the
//  shared BrowserToolsFeatureTests.swift or the central feature catalog.
//

import Foundation
@testable import BrowserToolsFeature
import FeatureKit
import Testing

@Suite
struct BrowserVisualCompatibilityTests {
    // MARK: Supported PNGs keep the full result

    @Test
    func compareScreenshotsPreservesFullResultOnSupportedPNGs() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserVisualCompatFull-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let store = BrowserArtifactStore(environment: environment, maximumArtifactCount: 8)

        let baseline = try store.storeScreenshotPNG(compatBaselineRGBAPNG(), pageID: "baseline")
        let candidate = try store.storeScreenshotPNG(compatCandidateRGBAPNG(), pageID: "candidate")
        let output = try await runCompareTool(
            baselinePath: baseline.path,
            candidatePath: candidate.path,
            thresholdPercent: 34,
            environment: environment
        )

        // Legacy byte comparison is still present alongside the pixel result.
        #expect(output.comparison.samePixelDimensions)
        #expect(!output.comparison.encodedBytesIdentical)

        // Pixel comparison and diff artifact remain fully populated; the
        // structured unavailability reason is absent on the supported path.
        #expect(output.pixelComparisonUnavailable == nil)
        let pixel = try #require(output.pixelComparison as BrowserScreenshotPixelComparison?)
        #expect(pixel.comparedPixelCount == 6)
        #expect(pixel.differentPixelCount == 2)
        #expect(pixel.differentPixelPercentage == 100.0 / 3.0)
        #expect(pixel.boundingBox == BrowserScreenshotDiffBoundingBox(x: 1, y: 0, width: 2, height: 2))
        #expect(pixel.thresholdPercent == 34)
        #expect(pixel.withinThreshold)

        let diff = try #require(output.diffArtifact as BrowserArtifact?)
        #expect(diff.path.hasPrefix(store.rootDirectory.path + "/"))
        #expect(diff.path.hasSuffix(".png"))
        let ownedDiff = try store.loadOwnedScreenshot(at: diff.path)
        let decodedDiff = try BrowserPNGCodec.decode(ownedDiff.data)
        #expect(decodedDiff.width == 3)
        #expect(decodedDiff.height == 2)

        // The full-result JSON carries the optional fields and omits the reason.
        let json = try encodedJSONObject(output)
        #expect(json["comparison"] != nil)
        #expect(json["pixelComparison"] != nil)
        #expect(json["diffArtifact"] != nil)
        #expect(json["pixelComparisonUnavailable"] == nil)
    }

    // MARK: Fallback — different dimensions

    @Test
    func compareScreenshotsFallsBackToByteOnlyOnDifferentDimensions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserVisualCompatDims-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let store = BrowserArtifactStore(environment: environment, maximumArtifactCount: 8)

        let baseline = try store.storeScreenshotPNG(compatBaselineRGBAPNG(), pageID: "baseline")
        // A decodable but differently sized (2x2) candidate.
        let candidate = try store.storeScreenshotPNG(compatSmallRGBAPNG(), pageID: "candidate")
        let output = try await runCompareTool(
            baselinePath: baseline.path,
            candidatePath: candidate.path,
            thresholdPercent: 0,
            environment: environment
        )

        // Legacy encoded-byte comparison is always produced for accepted pairs.
        #expect(!output.comparison.samePixelDimensions)
        #expect(output.comparison.comparedByteCount >= 0)

        // The pixel diff and its artifact are absent and carry a structured
        // reason with the mismatched dimensions.
        #expect(output.pixelComparison == nil)
        #expect(output.diffArtifact == nil)
        let unavailable = try #require(output.pixelComparisonUnavailable)
        #expect(unavailable.reason == .differentDimensions)
        let dimensions = try #require(unavailable.dimensions)
        #expect(dimensions.baselineWidth == 3)
        #expect(dimensions.baselineHeight == 2)
        #expect(dimensions.candidateWidth == 2)
        #expect(dimensions.candidateHeight == 2)

        // The byte-only JSON omits the optional pixel fields and includes reason.
        let json = try encodedJSONObject(output)
        #expect(json["comparison"] != nil)
        #expect(json["pixelComparison"] == nil)
        #expect(json["diffArtifact"] == nil)
        #expect(json["pixelComparisonUnavailable"] != nil)
    }

    // MARK: Fallback — unsupported PNG format

    @Test
    func compareScreenshotsFallsBackToByteOnlyOnUnsupportedFormat() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserVisualCompatFormat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["HOME": home.path]
        let store = BrowserArtifactStore(environment: environment, maximumArtifactCount: 8)

        let baseline = try store.storeScreenshotPNG(compatBaselineRGBAPNG(), pageID: "baseline")
        // A palette (color type 3) PNG: a valid header that passes the
        // Browser-owned load boundary but is refused by the bounded codec.
        let palette = compatPalettePNG()
        #expect(BrowserPNGHeader.dimensions(in: palette) != nil)
        #expect(throws: BrowserPNGCodecError.self) {
            try BrowserPNGCodec.decode(palette)
        }
        let candidate = try store.storeScreenshotPNG(palette, pageID: "candidate")
        let output = try await runCompareTool(
            baselinePath: baseline.path,
            candidatePath: candidate.path,
            thresholdPercent: 0,
            environment: environment
        )

        // Byte comparison remains available even though the pixel diff cannot run.
        #expect(output.comparison.comparedByteCount >= 0)
        #expect(output.pixelComparison == nil)
        #expect(output.diffArtifact == nil)
        let unavailable = try #require(output.pixelComparisonUnavailable)
        #expect(unavailable.reason == .unsupportedFormat)
        #expect(unavailable.dimensions == nil)
        #expect(!unavailable.message.isEmpty)
    }

    // MARK: Partial fallback — pixel metadata present, only diff artifact absent

    @Test
    func compareOutputPartialFallbackKeepsPixelMetadataWhenDiffArtifactAbsent() throws {
        // The tool's own storage failures are rare and environment-bound; the
        // output contract itself must still express "pixel metadata available,
        // diff artifact absent" so callers can rely on the partial result.
        let artifact = BrowserArtifact(
            path: "/tmp/x.png",
            mimeType: "image/png",
            sizeBytes: 10,
            sha256: String(repeating: "0", count: 64),
            pixelWidth: 3,
            pixelHeight: 2
        )
        let byteComparison = BrowserScreenshotByteComparison(
            comparedByteCount: 10,
            changedByteCount: 1,
            sizeDeltaBytes: 0,
            encodedBytesIdentical: false,
            samePixelDimensions: true
        )
        let pixel = BrowserScreenshotPixelComparison(
            comparedPixelCount: 6,
            differentPixelCount: 2,
            differentPixelPercentage: 100.0 / 3.0,
            boundingBox: BrowserScreenshotDiffBoundingBox(x: 1, y: 0, width: 2, height: 2),
            thresholdPercent: 34,
            withinThreshold: true
        )
        let output = BrowserCompareScreenshotsOutput(
            baseline: artifact,
            candidate: artifact,
            comparison: byteComparison,
            pixelComparison: pixel,
            diffArtifactUnavailable: BrowserScreenshotPixelComparisonUnavailable(
                reason: .exceededLimits,
                message: "diff artifact exceeded its byte limit"
            )
        )

        // Byte comparison and pixel metadata are both preserved; only the diff
        // artifact is missing, with a structured reason.
        #expect(output.comparison.samePixelDimensions)
        let keptPixel = try #require(output.pixelComparison as BrowserScreenshotPixelComparison?)
        #expect(keptPixel.differentPixelCount == 2)
        #expect(output.diffArtifact == nil)
        let reason = try #require(output.pixelComparisonUnavailable)
        #expect(reason.reason == .exceededLimits)

        // The JSON keeps pixelComparison and the reason but omits diffArtifact.
        let json = try encodedJSONObject(output)
        #expect(json["pixelComparison"] != nil)
        #expect(json["diffArtifact"] == nil)
        #expect(json["pixelComparisonUnavailable"] != nil)
    }

    // MARK: Structured reason classification

    @Test
    func pixelComparisonUnavailableClassifiesDecodeAndArtifactFailures() {
        // Dimension mismatch carries the structured dimensions payload.
        let dimensionMismatch = BrowserScreenshotPixelComparisonUnavailable.classifyDecodeFailure(
            BrowserVisualComparisonError.differentImageDimensions(
                baselineWidth: 4,
                baselineHeight: 8,
                candidateWidth: 5,
                candidateHeight: 9
            )
        )
        #expect(dimensionMismatch.reason == .differentDimensions)
        #expect(dimensionMismatch.dimensions == BrowserScreenshotDimensionsMismatch(
            baselineWidth: 4,
            baselineHeight: 8,
            candidateWidth: 5,
            candidateHeight: 9
        ))

        // Unsupported codec shapes map to .unsupportedFormat.
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDecodeFailure(BrowserPNGCodecError.unsupportedPNGFormat).reason == .unsupportedFormat
        )
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDecodeFailure(BrowserPNGCodecError.invalidPNGHeader).reason == .unsupportedFormat
        )

        // Bounded-limit codec errors map to .exceededLimits.
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDecodeFailure(BrowserPNGCodecError.imageTooLarge).reason == .exceededLimits
        )
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDecodeFailure(BrowserPNGCodecError.compressedDataTooLarge).reason == .exceededLimits
        )

        // Structural corruption maps to .decodeFailed.
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDecodeFailure(BrowserPNGCodecError.invalidPNGChunkCRC).reason == .decodeFailed
        )

        // A too-large diff artifact is attributed to the bounded limit.
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDiffArtifactFailure(BrowserArtifactError.artifactTooLarge(20 * 1024 * 1024))
                .reason == .exceededLimits
        )
        // Any other storage failure is attributed to the diff artifact only.
        #expect(
            BrowserScreenshotPixelComparisonUnavailable
                .classifyDiffArtifactFailure(BrowserArtifactError.artifactIsNotPNG)
                .reason == .diffArtifactUnavailable
        )
    }

    // MARK: Codable round-trips of both output shapes

    @Test
    func compareScreenshotsOutputCodableRoundTripsBothShapes() throws {
        let artifact = BrowserArtifact(
            path: "/tmp/x.png",
            mimeType: "image/png",
            sizeBytes: 10,
            sha256: String(repeating: "0", count: 64),
            pixelWidth: 3,
            pixelHeight: 2
        )
        let byteComparison = BrowserScreenshotByteComparison(
            comparedByteCount: 10,
            changedByteCount: 1,
            sizeDeltaBytes: 0,
            encodedBytesIdentical: false,
            samePixelDimensions: true
        )
        let pixel = BrowserScreenshotPixelComparison(
            comparedPixelCount: 6,
            differentPixelCount: 2,
            differentPixelPercentage: 100.0 / 3.0,
            boundingBox: BrowserScreenshotDiffBoundingBox(x: 1, y: 0, width: 2, height: 2),
            thresholdPercent: 34,
            withinThreshold: true
        )

        // Full shape survives an encode/decode round-trip with both optionals.
        let full = BrowserCompareScreenshotsOutput(
            baseline: artifact,
            candidate: artifact,
            comparison: byteComparison,
            pixelComparison: pixel,
            diffArtifact: artifact
        )
        let decodedFull = try JSONDecoder().decode(
            BrowserCompareScreenshotsOutput.self,
            from: try JSONEncoder().encode(full)
        )
        #expect(decodedFull.pixelComparison != nil)
        #expect(decodedFull.diffArtifact != nil)
        #expect(decodedFull.pixelComparisonUnavailable == nil)
        #expect(decodedFull.comparison.samePixelDimensions)

        // Fallback shape survives too, preserving the structured reason and
        // leaving the optional fields absent.
        let fallback = BrowserCompareScreenshotsOutput(
            baseline: artifact,
            candidate: artifact,
            comparison: byteComparison,
            pixelComparisonUnavailable: BrowserScreenshotPixelComparisonUnavailable(
                reason: .differentDimensions,
                message: "dimensions differ",
                dimensions: BrowserScreenshotDimensionsMismatch(
                    baselineWidth: 3,
                    baselineHeight: 2,
                    candidateWidth: 2,
                    candidateHeight: 2
                )
            )
        )
        let decodedFallback = try JSONDecoder().decode(
            BrowserCompareScreenshotsOutput.self,
            from: try JSONEncoder().encode(fallback)
        )
        #expect(decodedFallback.pixelComparison == nil)
        #expect(decodedFallback.diffArtifact == nil)
        let reason = try #require(decodedFallback.pixelComparisonUnavailable)
        #expect(reason.reason == .differentDimensions)
        #expect(reason.dimensions?.candidateWidth == 2)
    }
}

// MARK: - Helpers

private func runCompareTool(
    baselinePath: String,
    candidatePath: String,
    thresholdPercent: Double,
    environment: [String: String]
) async throws -> BrowserCompareScreenshotsOutput {
    let input = try JSONDecoder().decode(
        BrowserCompareScreenshotsTool.Input.self,
        from: Data(
            """
            {
              "baselinePath":"\(baselinePath)",
              "candidatePath":"\(candidatePath)",
              "thresholdPercent":\(thresholdPercent)
            }
            """.utf8
        )
    )
    return try await BrowserCompareScreenshotsTool().run(
        input,
        context: FeatureContext(environment: environment)
    )
}

private func encodedJSONObject(_ output: BrowserCompareScreenshotsOutput) throws -> [String: Any] {
    let data = try JSONEncoder().encode(output)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw NSError(
            domain: "BrowserVisualCompatibilityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Encoded output is not a JSON object"]
        )
    }
    return dictionary
}

// Complete, independently precomputed PNG fixtures for this file. Their IDAT
// chunks use ordinary zlib compression rather than the BrowserPNGCodec encoder
// so coverage does not depend on round-tripping through the implementation.

/// 3x2 opaque RGBA baseline.
private func compatBaselineRGBAPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAI0lEQVR42mPgEpH7r2Fk898tIOo/Q0pexf+mnmn/F6za8h8AhFkMqfbuxhAAAAAASUVORK5CYII=")!
}

/// 3x2 RGBA candidate differing from the baseline in exactly two pixels.
private func compatCandidateRGBAPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAI0lEQVR42mPgEpH7f8LG5r9bQNR/hpS8iv9NPdP+c3JyNgAAjC0K8ZpnYPYAAAAASUVORK5CYII=")!
}

/// A decodable 2x2 RGBA image used to trigger the different-dimensions fallback.
private func compatSmallRGBAPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAGklEQVR42mNgZGL+z8LK9p+BnYPzPxc3z38AIAsES4oxhygAAAAASUVORK5CYII=")!
}

/// A palette (color type 3) PNG: a valid header accepted by the Browser-owned
/// load boundary but refused by the bounded codec, triggering the unsupported
/// format fallback.
private func compatPalettePNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAMAAABFaP0WAAAACVBMVEX/AAAA/wAAAP8tSs2KAAAADklEQVR42mNgYGRgYgAAAA4ABNvgMo4AAAAASUVORK5CYII=")!
}
