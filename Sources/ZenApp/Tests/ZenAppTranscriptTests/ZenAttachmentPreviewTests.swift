import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import ZenCODECore

@testable import ZenAppTranscript

/// Images made for the tests.
enum ZenTestImages {
    /// A PNG of `width` × `height` pixels filled with one color.
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@Suite("Attachment previews")
struct ZenAttachmentPreviewTests {
    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ZenAttachmentPreviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("an image shows from its bytes, or else from its file")
    func imageOfAttachment() throws {
        let png = try ZenTestImages.png(width: 300, height: 150)
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "image.png")
        try png.write(to: file)
        let missing = directory.appending(path: "missing.png")

        let fromData = ZenAttachmentPreviewView.image(of: AgentRuntimeAttachment(
            kind: .image, fileURL: missing, data: png, originalFilename: "image.png"
        ))
        #expect(fromData?.size == CGSize(width: 300, height: 150))
        let fromFile = ZenAttachmentPreviewView.image(of: AgentRuntimeAttachment(
            kind: .image, fileURL: file, data: Data([0, 1, 2]), originalFilename: "image.png"
        ))
        #expect(fromFile?.size == CGSize(width: 300, height: 150))
    }

    @Test("nothing to show keeps the chip")
    func nothingToShow() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ZenAttachmentPreviewView.image(of: AgentRuntimeAttachment(
            kind: .image, fileURL: directory.appending(path: "missing.png"), originalFilename: "missing.png"
        )) == nil)
        #expect(ZenAttachmentPreviewView.image(of: AgentRuntimeAttachment(
            kind: .image, originalFilename: "none.png"
        )) == nil)
        #expect(ZenAttachmentPreviewView.image(of: AgentRuntimeAttachment(
            kind: .video, data: try ZenTestImages.png(width: 2, height: 2), originalFilename: "clip.mov"
        )) == nil)
    }

    @Test("only a local file is clickable")
    func fileURL() throws {
        let local = URL(filePath: "/tmp/zen-preview/shot.png")
        let remote = try #require(URL(string: "https://example.com/shot.png"))
        #expect(ZenAttachmentPreviewView.fileURL(of: AgentRuntimeAttachment(
            kind: .image, fileURL: local, originalFilename: "shot.png"
        )) == local)
        #expect(ZenAttachmentPreviewView.fileURL(of: AgentRuntimeAttachment(
            kind: .image, fileURL: remote, originalFilename: "shot.png"
        )) == nil)
        #expect(ZenAttachmentPreviewView.fileURL(of: AgentRuntimeAttachment(
            kind: .video, originalFilename: "clip.mov"
        )) == nil)
    }

    @Test("a preview is scaled down to fit, never up")
    func fittedSize() {
        #expect(ZenAttachmentPreviewView.fittedSize(CGSize(width: 1280, height: 800)) == CGSize(width: 320, height: 200))
        #expect(ZenAttachmentPreviewView.fittedSize(CGSize(width: 640, height: 1280)) == CGSize(width: 100, height: 200))
        #expect(ZenAttachmentPreviewView.fittedSize(CGSize(width: 100, height: 50)) == CGSize(width: 100, height: 50))
        #expect(ZenAttachmentPreviewView.fittedSize(CGSize(width: 4000, height: 10)) == CGSize(width: 320, height: 1))
        #expect(ZenAttachmentPreviewView.fittedSize(.zero) == .zero)
    }
}
