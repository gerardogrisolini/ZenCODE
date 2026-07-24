//
//  BrowserVisualComparison.swift
//  BrowserToolsFeature
//
//  Deterministic screenshot metadata and comparison for Browser-owned PNG
//  artifacts. This deliberately avoids a model-media bridge and never accepts
//  arbitrary filesystem paths or image bytes from the model.
//

import FeatureKit
import Foundation

/// Legacy encoded-byte metadata. These fields remain part of the public output
/// for compatibility, but they are not used as the visual equivalence result.
struct BrowserScreenshotByteComparison: Codable, Hashable, Sendable {
    let comparedByteCount: Int
    let changedByteCount: Int
    let sizeDeltaBytes: Int
    let encodedBytesIdentical: Bool
    let samePixelDimensions: Bool
}

struct BrowserScreenshotDiffBoundingBox: Codable, Hashable, Sendable {
    /// Left-most changed pixel, zero-based from the image's left edge.
    let x: Int
    /// Top-most changed pixel, zero-based from the image's top edge.
    let y: Int
    let width: Int
    let height: Int
}

struct BrowserScreenshotPixelComparison: Codable, Hashable, Sendable {
    let comparedPixelCount: Int
    let differentPixelCount: Int
    let differentPixelPercentage: Double
    let boundingBox: BrowserScreenshotDiffBoundingBox?
    let thresholdPercent: Double
    let withinThreshold: Bool
}

/// Structured dimensions captured when a pixel comparison is refused because the
/// two artifacts do not share the same pixel grid.
struct BrowserScreenshotDimensionsMismatch: Codable, Hashable, Sendable {
    let baselineWidth: Int
    let baselineHeight: Int
    let candidateWidth: Int
    let candidateHeight: Int
}

/// Explains, in a machine-readable way, why the optional decoded-pixel result and
/// diff artifact are absent even though the legacy encoded-byte comparison was
/// still produced. It never causes the tool to fail: an artifact accepted by the
/// Browser-owned load path always yields at least the byte comparison.
struct BrowserScreenshotPixelComparisonUnavailable: Codable, Hashable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// The two artifacts do not share identical pixel dimensions.
        case differentDimensions
        /// A PNG shape outside the bounded codec (for example interlaced,
        /// 16-bit, palette/tRNS, or otherwise unsupported).
        case unsupportedFormat
        /// A bounded decode/encode limit (pixel, scanline, or byte size) refused
        /// the comparison or the diff artifact.
        case exceededLimits
        /// A structurally invalid or corrupt PNG body prevented decoding.
        case decodeFailed
        /// Pixel metadata was computed, but the Browser-owned diff artifact could
        /// not be stored.
        case diffArtifactUnavailable
    }

    let reason: Reason
    let message: String
    let dimensions: BrowserScreenshotDimensionsMismatch?

    init(
        reason: Reason,
        message: String,
        dimensions: BrowserScreenshotDimensionsMismatch? = nil
    ) {
        self.reason = reason
        self.message = message
        self.dimensions = dimensions
    }

    /// Classifies a decode/compare failure raised while attempting the pixel
    /// diff. The Browser-owned load boundary already validated the PNG header, so
    /// these failures reflect an unsupported or corrupt image shape rather than an
    /// untrusted path, and they must degrade to byte-only output.
    static func classifyDecodeFailure(_ error: Error) -> BrowserScreenshotPixelComparisonUnavailable {
        if let visualError = error as? BrowserVisualComparisonError {
            switch visualError {
            case let .differentImageDimensions(baselineWidth, baselineHeight, candidateWidth, candidateHeight):
                return BrowserScreenshotPixelComparisonUnavailable(
                    reason: .differentDimensions,
                    message: visualError.errorDescription ?? "Browser screenshots have different dimensions.",
                    dimensions: BrowserScreenshotDimensionsMismatch(
                        baselineWidth: baselineWidth,
                        baselineHeight: baselineHeight,
                        candidateWidth: candidateWidth,
                        candidateHeight: candidateHeight
                    )
                )
            case .invalidThresholdPercent:
                // Threshold is validated before decoding, so this is unreachable
                // here; classify defensively rather than crash.
                return BrowserScreenshotPixelComparisonUnavailable(
                    reason: .decodeFailed,
                    message: visualError.errorDescription ?? "Invalid threshold percentage."
                )
            }
        }
        if let codecError = error as? BrowserPNGCodecError {
            return BrowserScreenshotPixelComparisonUnavailable(
                reason: reason(forDecode: codecError),
                message: codecError.errorDescription ?? "Browser could not decode the PNG artifact."
            )
        }
        return BrowserScreenshotPixelComparisonUnavailable(
            reason: .decodeFailed,
            message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        )
    }

    /// Classifies a failure raised only while storing the diff artifact. The
    /// pixel metadata itself is already available, so the diff artifact is the
    /// single missing piece.
    static func classifyDiffArtifactFailure(_ error: Error) -> BrowserScreenshotPixelComparisonUnavailable {
        if let artifactError = error as? BrowserArtifactError,
           case .artifactTooLarge = artifactError {
            return BrowserScreenshotPixelComparisonUnavailable(
                reason: .exceededLimits,
                message: artifactError.errorDescription ?? "Browser diff artifact exceeded its byte limit."
            )
        }
        if let codecError = error as? BrowserPNGCodecError {
            return BrowserScreenshotPixelComparisonUnavailable(
                reason: reason(forDecode: codecError),
                message: codecError.errorDescription ?? "Browser could not encode the PNG diff artifact."
            )
        }
        return BrowserScreenshotPixelComparisonUnavailable(
            reason: .diffArtifactUnavailable,
            message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        )
    }

    private static func reason(forDecode codecError: BrowserPNGCodecError) -> Reason {
        switch codecError {
        case .unsupportedPNGFormat,
             .invalidPNGHeader,
             .missingPNGHeader,
             .invalidPNGSignature,
             .invalidPNGFilter:
            return .unsupportedFormat
        case .imageTooLarge,
             .compressedDataTooLarge,
             .decompressedDataTooLarge,
             .encodedOutputTooLarge:
            return .exceededLimits
        case .malformedPNGChunk,
             .invalidPNGChunkCRC,
             .missingPNGImageData,
             .missingPNGEnd,
             .trailingPNGData,
             .invalidZlibStream,
             .invalidDeflateStream,
             .unexpectedDecompressedSize,
             .invalidImageBuffer:
            return .decodeFailed
        }
    }
}

enum BrowserVisualComparisonError: LocalizedError, Sendable {
    case invalidThresholdPercent(Double)
    case differentImageDimensions(
        baselineWidth: Int,
        baselineHeight: Int,
        candidateWidth: Int,
        candidateHeight: Int
    )

    var errorDescription: String? {
        switch self {
        case let .invalidThresholdPercent(value):
            "Browser screenshot difference threshold must be a finite percentage from 0 through 100, not \(value)."
        case let .differentImageDimensions(baselineWidth, baselineHeight, candidateWidth, candidateHeight):
            "Browser screenshot pixel comparison requires equal dimensions; baseline is \(baselineWidth)x\(baselineHeight) and candidate is \(candidateWidth)x\(candidateHeight)."
        }
    }
}

enum BrowserVisualComparisonLimits {
    static let defaultThresholdPercent = 0.0
    static let maximumThresholdPercent = 100.0

    static func resolveThresholdPercent(_ requested: Double?) throws -> Double {
        let threshold = requested ?? defaultThresholdPercent
        guard threshold.isFinite,
              threshold >= 0,
              threshold <= maximumThresholdPercent
        else {
            throw BrowserVisualComparisonError.invalidThresholdPercent(threshold)
        }
        return threshold
    }
}

struct BrowserScreenshotVisualDiff: Sendable {
    let comparison: BrowserScreenshotPixelComparison
    let pngData: Data
}

enum BrowserScreenshotComparison {
    static func compare(
        baseline: BrowserOwnedScreenshot,
        candidate: BrowserOwnedScreenshot
    ) -> BrowserScreenshotByteComparison {
        let commonByteCount = min(baseline.data.count, candidate.data.count)
        let mismatchedCommonBytes = zip(baseline.data, candidate.data)
            .reduce(into: 0) { count, pair in
                if pair.0 != pair.1 {
                    count += 1
                }
            }
        let sizeDelta = candidate.data.count - baseline.data.count
        let changedByteCount = mismatchedCommonBytes + abs(sizeDelta)
        let sameDimensions = baseline.artifact.pixelWidth == candidate.artifact.pixelWidth
            && baseline.artifact.pixelHeight == candidate.artifact.pixelHeight
        return BrowserScreenshotByteComparison(
            comparedByteCount: commonByteCount,
            changedByteCount: changedByteCount,
            sizeDeltaBytes: sizeDelta,
            encodedBytesIdentical: baseline.data == candidate.data,
            samePixelDimensions: sameDimensions
        )
    }

    static func comparePixels(
        baseline: BrowserOwnedScreenshot,
        candidate: BrowserOwnedScreenshot,
        thresholdPercent: Double
    ) throws -> BrowserScreenshotVisualDiff {
        let baselineImage = try BrowserPNGCodec.decode(baseline.data)
        let candidateImage = try BrowserPNGCodec.decode(candidate.data)
        guard baselineImage.width == candidateImage.width,
              baselineImage.height == candidateImage.height
        else {
            throw BrowserVisualComparisonError.differentImageDimensions(
                baselineWidth: baselineImage.width,
                baselineHeight: baselineImage.height,
                candidateWidth: candidateImage.width,
                candidateHeight: candidateImage.height
            )
        }

        let width = baselineImage.width
        let height = baselineImage.height
        let pixelCount = width * height
        var diffRGBA = [UInt8](repeating: 0, count: baselineImage.rgba.count)
        var differentPixelCount = 0
        var minimumX = width
        var minimumY = height
        var maximumX = -1
        var maximumY = -1

        // The pixel diff is CPU-bound across up to `maximumPixelCount` pixels.
        // Observe cooperative cancellation before the loop and every 4096
        // pixels within it. checkCancellation never alters the comparison output.
        try Task.checkCancellation()
        for pixel in 0..<pixelCount {
            if pixel.isMultiple(of: 4096) {
                try Task.checkCancellation()
            }
            let offset = pixel * 4
            let changed = baselineImage.rgba[offset] != candidateImage.rgba[offset]
                || baselineImage.rgba[offset + 1] != candidateImage.rgba[offset + 1]
                || baselineImage.rgba[offset + 2] != candidateImage.rgba[offset + 2]
                || baselineImage.rgba[offset + 3] != candidateImage.rgba[offset + 3]
            if changed {
                differentPixelCount += 1
                let x = pixel % width
                let y = pixel / width
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
                // Red is intentionally independent from source alpha so even a
                // transparent-pixel change remains visible in the artifact.
                diffRGBA[offset] = 255
                diffRGBA[offset + 1] = 0
                diffRGBA[offset + 2] = 0
                diffRGBA[offset + 3] = 255
            } else {
                // Preserve a dimmed visual reference for unchanged pixels.
                diffRGBA[offset] = baselineImage.rgba[offset] / 4
                diffRGBA[offset + 1] = baselineImage.rgba[offset + 1] / 4
                diffRGBA[offset + 2] = baselineImage.rgba[offset + 2] / 4
                diffRGBA[offset + 3] = 255
            }
        }

        let percentage = Double(differentPixelCount) * 100 / Double(pixelCount)
        let boundingBox: BrowserScreenshotDiffBoundingBox?
        if differentPixelCount == 0 {
            boundingBox = nil
        } else {
            boundingBox = BrowserScreenshotDiffBoundingBox(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX + 1,
                height: maximumY - minimumY + 1
            )
        }
        let comparison = BrowserScreenshotPixelComparison(
            comparedPixelCount: pixelCount,
            differentPixelCount: differentPixelCount,
            differentPixelPercentage: percentage,
            boundingBox: boundingBox,
            thresholdPercent: thresholdPercent,
            withinThreshold: percentage <= thresholdPercent
        )
        return BrowserScreenshotVisualDiff(
            comparison: comparison,
            pngData: try BrowserPNGCodec.encodeRGBA(width: width, height: height, rgba: diffRGBA)
        )
    }
}

struct BrowserCompareScreenshotsOutput: Codable, Sendable {
    let baseline: BrowserArtifact
    let candidate: BrowserArtifact
    /// Existing encoded-byte comparison retained for compatibility. It is always
    /// present for any artifact accepted by the Browser-owned load path.
    let comparison: BrowserScreenshotByteComparison
    /// Bounded decoded-pixel comparison. Absent when dimensions, format, or
    /// codec limits prevent the pixel diff.
    let pixelComparison: BrowserScreenshotPixelComparison?
    /// Browser-owned PNG diff artifact. Absent for the same reasons as
    /// `pixelComparison`, and additionally absent if only the diff artifact could
    /// not be stored.
    let diffArtifact: BrowserArtifact?
    /// Structured explanation present only when `pixelComparison`/`diffArtifact`
    /// are absent. Nil on the fully supported path.
    let pixelComparisonUnavailable: BrowserScreenshotPixelComparisonUnavailable?
    let note: String

    init(
        baseline: BrowserArtifact,
        candidate: BrowserArtifact,
        comparison: BrowserScreenshotByteComparison,
        pixelComparison: BrowserScreenshotPixelComparison,
        diffArtifact: BrowserArtifact
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.comparison = comparison
        self.pixelComparison = pixelComparison
        self.diffArtifact = diffArtifact
        self.pixelComparisonUnavailable = nil
        self.note = "Comparison reads only Browser-owned PNG artifacts. It preserves deterministic encoded-byte metadata for compatibility, performs a bounded decoded-pixel comparison, and stores a Browser-owned PNG diff artifact. Image bytes are not embedded in the model transcript."
    }

    /// Byte-only fallback: the artifacts were accepted by the Browser-owned load
    /// path and the legacy encoded-byte comparison is preserved, but a bounded
    /// decoded-pixel diff could not be produced. The structured reason explains
    /// whether dimensions, format, or limits prevented it.
    init(
        baseline: BrowserArtifact,
        candidate: BrowserArtifact,
        comparison: BrowserScreenshotByteComparison,
        pixelComparisonUnavailable: BrowserScreenshotPixelComparisonUnavailable
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.comparison = comparison
        self.pixelComparison = nil
        self.diffArtifact = nil
        self.pixelComparisonUnavailable = pixelComparisonUnavailable
        self.note = "Comparison reads only Browser-owned PNG artifacts. It preserves deterministic encoded-byte metadata for compatibility. A bounded decoded-pixel diff was unavailable for this pair; see pixelComparisonUnavailable. Image bytes are not embedded in the model transcript."
    }

    /// Partial fallback: the decoded-pixel comparison succeeded, but only the
    /// Browser-owned PNG diff artifact could not be stored. The pixel metadata is
    /// preserved while the structured reason explains the single missing piece.
    init(
        baseline: BrowserArtifact,
        candidate: BrowserArtifact,
        comparison: BrowserScreenshotByteComparison,
        pixelComparison: BrowserScreenshotPixelComparison,
        diffArtifactUnavailable: BrowserScreenshotPixelComparisonUnavailable
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.comparison = comparison
        self.pixelComparison = pixelComparison
        self.diffArtifact = nil
        self.pixelComparisonUnavailable = diffArtifactUnavailable
        self.note = "Comparison reads only Browser-owned PNG artifacts. It preserves deterministic encoded-byte metadata for compatibility and a bounded decoded-pixel comparison. The Browser-owned PNG diff artifact was unavailable; see pixelComparisonUnavailable. Image bytes are not embedded in the model transcript."
    }
}

struct BrowserCompareScreenshotsTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let baselinePath: String?
        let baseline_path: String?
        let candidatePath: String?
        let candidate_path: String?
        let thresholdPercent: Double?
        let threshold_percent: Double?

        var resolvedBaselinePath: String? {
            baselinePath?.nilIfBlank ?? baseline_path?.nilIfBlank
        }

        var resolvedCandidatePath: String? {
            candidatePath?.nilIfBlank ?? candidate_path?.nilIfBlank
        }

        var resolvedThresholdPercent: Double? {
            thresholdPercent ?? threshold_percent
        }
    }

    static let name = "browser.compare_screenshots"
    static let description = "Compares two Browser-owned PNG screenshots and always returns deterministic encoded-byte metadata. When both images have compatible dimensions and a supported bounded format, it also returns decoded RGBA pixel-difference metadata and a Browser-owned PNG diff artifact; otherwise it returns a structured unavailability reason. Image bytes are never embedded in the model transcript."
    static let inputSchema = buildInputSchema(
        [
            .string("baselinePath", description: "Artifact path returned by an earlier browser.screenshot call."),
            .string("baseline_path", description: "Snake-case alias for baselinePath."),
            .string("candidatePath", description: "Artifact path returned by a later browser.screenshot call."),
            .string("candidate_path", description: "Snake-case alias for candidatePath."),
            .number("thresholdPercent", description: "Maximum allowed different-pixel percentage, from 0 through 100. Defaults to 0."),
            .number("threshold_percent", description: "Snake-case alias for thresholdPercent."),
        ],
        required: ["baselinePath", "candidatePath"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserCompareScreenshotsOutput {
        guard let baselinePath = input.resolvedBaselinePath else {
            throw BrowserToolsFeatureError.missingArgument("baselinePath")
        }
        guard let candidatePath = input.resolvedCandidatePath else {
            throw BrowserToolsFeatureError.missingArgument("candidatePath")
        }
        let thresholdPercent = try BrowserVisualComparisonLimits.resolveThresholdPercent(
            input.resolvedThresholdPercent
        )

        let store = BrowserArtifactStore(environment: context.environment)
        let baseline = try store.loadOwnedScreenshot(at: baselinePath)
        let candidate = try store.loadOwnedScreenshot(at: candidatePath)
        // The legacy encoded-byte comparison is always produced for any pair the
        // Browser-owned load path accepted, preserving the original contract.
        let byteComparison = BrowserScreenshotComparison.compare(
            baseline: baseline,
            candidate: candidate
        )

        // Attempt the bounded decoded-pixel diff. If dimensions, format, or codec
        // limits prevent it, degrade to byte-only output with a structured reason
        // instead of failing the whole tool.
        let visualDiff: BrowserScreenshotVisualDiff
        do {
            visualDiff = try BrowserScreenshotComparison.comparePixels(
                baseline: baseline,
                candidate: candidate,
                thresholdPercent: thresholdPercent
            )
        } catch is CancellationError {
            // Cooperative cancellation must propagate rather than degrade to a
            // byte-only "decode failed" result.
            throw CancellationError()
        } catch {
            return BrowserCompareScreenshotsOutput(
                baseline: baseline.artifact,
                candidate: candidate.artifact,
                comparison: byteComparison,
                pixelComparisonUnavailable: BrowserScreenshotPixelComparisonUnavailable
                    .classifyDecodeFailure(error)
            )
        }

        // Pixel metadata succeeded; only the diff artifact may still be refused
        // by a bounded storage limit. Preserve the pixel result and explain the
        // single missing piece rather than discarding the whole comparison.
        let diffArtifact: BrowserArtifact
        do {
            diffArtifact = try store.storeVisualDiffPNG(visualDiff.pngData)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return BrowserCompareScreenshotsOutput(
                baseline: baseline.artifact,
                candidate: candidate.artifact,
                comparison: byteComparison,
                pixelComparison: visualDiff.comparison,
                diffArtifactUnavailable: BrowserScreenshotPixelComparisonUnavailable
                    .classifyDiffArtifactFailure(error)
            )
        }

        return BrowserCompareScreenshotsOutput(
            baseline: baseline.artifact,
            candidate: candidate.artifact,
            comparison: byteComparison,
            pixelComparison: visualDiff.comparison,
            diffArtifact: diffArtifact
        )
    }
}
