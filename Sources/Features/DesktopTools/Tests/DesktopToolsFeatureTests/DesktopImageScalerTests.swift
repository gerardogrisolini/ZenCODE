import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import desktop_tools_feature

@Suite @MainActor
struct DesktopImageScalerTests {
    private func makePNG(in directory: URL, width: Int, height: Int) throws -> URL {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent("source.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test
    func resamplesToTargetSizeKeepingPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makePNG(in: directory, width: 40, height: 20)

        try DesktopImageScaler.resample(pngAt: url, width: 20, height: 10)

        let data = try Data(contentsOf: url)
        let size = try #require(DesktopController.pngDimensions(data))
        #expect(size.width == 20 && size.height == 10)
        #expect(try permissions(url) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test
    func sameSizeLeavesFileValid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makePNG(in: directory, width: 40, height: 20)
        let before = try Data(contentsOf: url)

        try DesktopImageScaler.resample(pngAt: url, width: 40, height: 20)

        #expect(try Data(contentsOf: url) == before)
        let size = try #require(DesktopController.pngDimensions(before))
        #expect(size.width == 40 && size.height == 20)
    }
}
