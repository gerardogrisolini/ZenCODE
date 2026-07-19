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

struct BrowserScreenshotByteComparison: Codable, Hashable, Sendable {
    let comparedByteCount: Int
    let changedByteCount: Int
    let sizeDeltaBytes: Int
    let encodedBytesIdentical: Bool
    let samePixelDimensions: Bool
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
}

struct BrowserCompareScreenshotsOutput: Codable, Sendable {
    let baseline: BrowserArtifact
    let candidate: BrowserArtifact
    let comparison: BrowserScreenshotByteComparison
    let note: String

    init(
        baseline: BrowserArtifact,
        candidate: BrowserArtifact,
        comparison: BrowserScreenshotByteComparison
    ) {
        self.baseline = baseline
        self.candidate = candidate
        self.comparison = comparison
        self.note = "Comparison reads only Browser-owned PNG artifacts and compares their encoded bytes deterministically. A changed byte count proves the captures differ, but it is not a perceptual or pixel-equivalence claim. Image bytes are not embedded in the model transcript."
    }
}

struct BrowserCompareScreenshotsTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let baselinePath: String?
        let baseline_path: String?
        let candidatePath: String?
        let candidate_path: String?

        var resolvedBaselinePath: String? {
            baselinePath?.nilIfBlank ?? baseline_path?.nilIfBlank
        }

        var resolvedCandidatePath: String? {
            candidatePath?.nilIfBlank ?? candidate_path?.nilIfBlank
        }
    }

    static let name = "browser.compare_screenshots"
    static let description = "Compares two PNG screenshots previously produced by Browser. Both paths must be Browser-owned artifact paths; Browser returns bounded metadata and deterministic encoded-byte differences, never image bytes."
    static let inputSchema = buildInputSchema(
        [
            .string("baselinePath", description: "Artifact path returned by an earlier browser.screenshot call."),
            .string("baseline_path", description: "Snake-case alias for baselinePath."),
            .string("candidatePath", description: "Artifact path returned by a later browser.screenshot call."),
            .string("candidate_path", description: "Snake-case alias for candidatePath."),
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

        let store = BrowserArtifactStore(environment: context.environment)
        let baseline = try store.loadOwnedScreenshot(at: baselinePath)
        let candidate = try store.loadOwnedScreenshot(at: candidatePath)
        let comparison = BrowserScreenshotComparison.compare(
            baseline: baseline,
            candidate: candidate
        )
        return BrowserCompareScreenshotsOutput(
            baseline: baseline.artifact,
            candidate: candidate.artifact,
            comparison: comparison
        )
    }
}
