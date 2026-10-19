import Foundation
@testable import BrowserToolsFeature
import FeatureKit
import Testing

extension BrowserToolsFeatureTests {
    @Test
    func screenshotArtifactStoreRetainsTheNewFileInsideItsOwnedDirectory() throws {
        let root = browserTemporaryRoot("BrowserToolsFeatureTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserArtifactStore(
            rootDirectory: root,
            maximumArtifactCount: 1,
            retentionAge: 24 * 60 * 60
        )
        let first = try store.storeScreenshotPNG(Data([0x89, 0x50, 0x4E, 0x47]), pageID: "page/unsafe")
        let second = try store.storeScreenshotPNG(Data([0x89, 0x50, 0x4E, 0x47]), pageID: "page-2")

        #expect(first.mimeType == "image/png")
        #expect(second.path.hasPrefix(root.path + "/"))
        #expect(FileManager.default.fileExists(atPath: second.path))
        let retained = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".png") }
        #expect(retained.count == 1)
    }

    @Test
    func browserOwnedScreenshotsExposeBoundedMetadataAndCompareSafely() throws {
        let root = browserTemporaryRoot("BrowserVisualComparisonTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserArtifactStore(rootDirectory: root, maximumArtifactCount: 3)
        let baselineData = browserPNGHeader(width: 320, height: 200, suffix: [1, 2, 3])
        let candidateData = browserPNGHeader(width: 320, height: 200, suffix: [1, 2, 4])
        let baseline = try store.storeScreenshotPNG(baselineData, pageID: "baseline")
        let candidate = try store.storeScreenshotPNG(candidateData, pageID: "candidate")

        #expect(baseline.pixelWidth == 320)
        #expect(baseline.pixelHeight == 200)
        #expect(baseline.sha256.count == 64)
        #expect(baseline.sha256 != candidate.sha256)

        let loadedBaseline = try store.loadOwnedScreenshot(at: baseline.path)
        let loadedCandidate = try store.loadOwnedScreenshot(at: candidate.path)
        let comparison = BrowserScreenshotComparison.compare(
            baseline: loadedBaseline,
            candidate: loadedCandidate
        )
        #expect(comparison.comparedByteCount == baselineData.count)
        #expect(comparison.changedByteCount == 1)
        #expect(!comparison.encodedBytesIdentical)
        #expect(comparison.samePixelDimensions)

        #expect(throws: BrowserArtifactError.self) {
            try store.loadOwnedScreenshot(at: "/tmp/not-a-browser-artifact.png")
        }
        #expect(throws: BrowserArtifactError.self) {
            try store.loadOwnedScreenshot(at: "relative.png")
        }
    }

    @Test
    func browserVisualDiffComparesRealPNGPixelsAndStoresOwnedDiffArtifact() async throws {
        let home = browserTemporaryRoot("BrowserVisualPixelDiffTests")
        defer { try? FileManager.default.removeItem(at: home) }

        let environment = ["HOME": home.path]
        let store = BrowserArtifactStore(environment: environment, maximumArtifactCount: 8)
        let baselineData = browserVisualDiffBaselinePNG()
        let candidateData = browserVisualDiffCandidatePNG()

        // These are complete PNG fixtures (signature, CRC-checked chunks and
        // zlib-compressed scanlines), not header-shaped test doubles.
        let decodedBaseline = try BrowserPNGCodec.decode(baselineData)
        #expect(decodedBaseline.width == 3)
        #expect(decodedBaseline.height == 2)
        #expect(decodedBaseline.rgba == [
            10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255,
            100, 110, 120, 255, 130, 140, 150, 255, 160, 170, 180, 255,
        ])

        let baseline = try store.storeScreenshotPNG(baselineData, pageID: "baseline")
        let candidate = try store.storeScreenshotPNG(candidateData, pageID: "candidate")
        let input = try JSONDecoder().decode(
            BrowserCompareScreenshotsTool.Input.self,
            from: Data(
                """
                {
                  "baselinePath":"\(baseline.path)",
                  "candidatePath":"\(candidate.path)",
                  "thresholdPercent":34
                }
                """.utf8
            )
        )
        let output = try await BrowserCompareScreenshotsTool().run(
            input,
            context: FeatureContext(environment: environment)
        )

        // Existing byte metadata remains available alongside the pixel result.
        #expect(!output.comparison.encodedBytesIdentical)
        #expect(output.comparison.samePixelDimensions)
        let pixelComparison = try #require(output.pixelComparison)
        let diffArtifact = try #require(output.diffArtifact)
        #expect(pixelComparison.comparedPixelCount == 6)
        #expect(pixelComparison.differentPixelCount == 2)
        #expect(pixelComparison.differentPixelPercentage == 100.0 / 3.0)
        #expect(pixelComparison.boundingBox == BrowserScreenshotDiffBoundingBox(
            x: 1,
            y: 0,
            width: 2,
            height: 2
        ))
        #expect(pixelComparison.thresholdPercent == 34)
        #expect(pixelComparison.withinThreshold)
        #expect(diffArtifact.path.hasPrefix(store.rootDirectory.path + "/"))
        #expect(diffArtifact.path.hasSuffix(".png"))

        let ownedDiff = try store.loadOwnedScreenshot(at: diffArtifact.path)
        let decodedDiff = try BrowserPNGCodec.decode(ownedDiff.data)
        #expect(decodedDiff.width == 3)
        #expect(decodedDiff.height == 2)
        // Changed pixels are opaque red, including the candidate pixel whose
        // source alpha differs; unchanged pixels retain a dimmed reference.
        #expect(Array(decodedDiff.rgba[4..<8]) == [255, 0, 0, 255])
        #expect(Array(decodedDiff.rgba[20..<24]) == [255, 0, 0, 255])
        #expect(Array(decodedDiff.rgba[0..<4]) == [2, 5, 7, 255])

        let loadedBaseline = try store.loadOwnedScreenshot(at: baseline.path)
        let loadedCandidate = try store.loadOwnedScreenshot(at: candidate.path)
        let strictComparison = try BrowserScreenshotComparison.comparePixels(
            baseline: loadedBaseline,
            candidate: loadedCandidate,
            thresholdPercent: 33
        )
        #expect(!strictComparison.comparison.withinThreshold)

        let small = try store.storeScreenshotPNG(browserVisualDiffSmallPNG(), pageID: "small")
        let loadedSmall = try store.loadOwnedScreenshot(at: small.path)
        #expect(throws: BrowserVisualComparisonError.self) {
            try BrowserScreenshotComparison.comparePixels(
                baseline: loadedBaseline,
                candidate: loadedSmall,
                thresholdPercent: 0
            )
        }
        #expect(throws: BrowserVisualComparisonError.self) {
            try BrowserVisualComparisonLimits.resolveThresholdPercent(-0.01)
        }
        #expect(throws: BrowserVisualComparisonError.self) {
            try BrowserVisualComparisonLimits.resolveThresholdPercent(100.01)
        }

        var corruptBytes = [UInt8](baselineData)
        corruptBytes[20] ^= 0x01
        #expect(throws: BrowserPNGCodecError.self) {
            try BrowserPNGCodec.decode(Data(corruptBytes))
        }
    }

    @Test
    func browserPNGCodecDecodesIndependentlyFilteredRealPNG() throws {
        let image = try BrowserPNGCodec.decode(browserVisualDiffFilteredPNG())
        #expect(image.width == 3)
        #expect(image.height == 5)
        #expect(image.rgba == [
            1, 2, 3, 255, 38, 13, 56, 255, 75, 24, 109, 255,
            20, 45, 10, 238, 57, 56, 63, 238, 94, 67, 116, 238,
            39, 88, 17, 221, 76, 99, 70, 221, 113, 110, 123, 221,
            58, 131, 24, 204, 95, 142, 77, 204, 132, 153, 130, 204,
            77, 174, 31, 187, 114, 185, 84, 187, 151, 196, 137, 187,
        ])

        let rgbImage = try BrowserPNGCodec.decode(browserVisualDiffRGBPNG())
        #expect(rgbImage.width == 2)
        #expect(rgbImage.height == 1)
        #expect(rgbImage.rgba == [12, 34, 56, 255, 78, 90, 123, 255])
    }

    @Test
    func pdfArtifactAndPerformanceMetricsUseBoundedSpecialistContracts() throws {
        let root = browserTemporaryRoot("BrowserToolsPDFTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserArtifactStore(rootDirectory: root, maximumArtifactCount: 2)
        let pdf = try store.storePDF(Data([0x25, 0x50, 0x44, 0x46]), pageID: "pdf-page")
        #expect(pdf.mimeType == "application/pdf")
        #expect(pdf.path.hasSuffix(".pdf"))
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        #expect(try BrowserPDFFormat.resolve("LETTER") == .letter)
        #expect(throws: BrowserSpecialistError.unsupportedPDFFormat("legal")) {
            try BrowserPDFFormat.resolve("legal")
        }

        let metrics = try BrowserPerformanceSnapshot.parse([
            "result": [
                "metrics": [
                    ["name": "ScriptDuration", "value": 1.5],
                    ["name": "UnrelatedMetric", "value": 99],
                    ["name": "Nodes", "value": 42],
                ],
            ],
        ])
        #expect(metrics.map(\.name) == ["Nodes", "ScriptDuration"])
        #expect(metrics.map(\.value) == [42, 1.5])
        #expect(BrowserDownloadPolicy.browserMethod == "Browser.setDownloadBehavior")
        #expect(BrowserDownloadPolicy.pageFallbackMethod == "Page.setDownloadBehavior")
    }
}
