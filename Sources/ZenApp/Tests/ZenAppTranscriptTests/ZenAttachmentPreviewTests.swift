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

    /// The permission bits of the file or directory at `url`.
    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
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

    @Test("Quick Look shows the file when it exists, else the bytes")
    func quickLookSource() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([1, 2, 3])
        let file = directory.appending(path: "shot.png")
        try bytes.write(to: file)
        let video = directory.appending(path: "clip.mov")
        try bytes.write(to: video)
        let missing = directory.appending(path: "missing.png")
        let remote = try #require(URL(string: "https://example.com/shot.png"))

        // An existing local file, for an image and for a video.
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: file, data: Data([9]), originalFilename: "shot.png"
        )) == .file(file))
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .video, fileURL: video, originalFilename: "clip.mov"
        )) == .file(video))
        // A file that is gone falls back to the bytes, if any.
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: missing, data: bytes, originalFilename: "missing.png"
        )) == .bytes(bytes))
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: missing, originalFilename: "missing.png"
        )) == nil)
        // A directory is not a file to show.
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: directory, data: bytes, originalFilename: "shot.png"
        )) == .bytes(bytes))
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: directory, originalFilename: "shot.png"
        )) == nil)
        // A remote URL is not a local file.
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: remote, data: bytes, originalFilename: "shot.png"
        )) == .bytes(bytes))
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, fileURL: remote, originalFilename: "shot.png"
        )) == nil)
        // Neither a file nor bytes: not clickable.
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .video, originalFilename: "clip.mov"
        )) == nil)
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, data: Data(), originalFilename: "empty.png"
        )) == nil)
        // Bytes alone, for an image and for a video.
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .image, data: bytes, originalFilename: "telegram.png"
        )) == .bytes(bytes))
        #expect(ZenAttachmentPreviewView.quickLookSource(of: AgentRuntimeAttachment(
            kind: .video, data: bytes, originalFilename: "clip.mov"
        )) == .bytes(bytes))
    }

    @Test("a temporary file is private and kept in a directory of its own")
    func temporaryFileWrite() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try ZenTestImages.png(width: 4, height: 4)

        let file = try ZenQuickLookTemporaryFile.write(bytes, filename: "shot.png", under: root)
        let directory = file.deletingLastPathComponent()

        #expect(try Data(contentsOf: file) == bytes)
        #expect(file.lastPathComponent == "shot.png")
        #expect(try Self.permissions(of: file) == 0o600)
        #expect(try Self.permissions(of: directory) == 0o700)
        #expect(directory.lastPathComponent.hasPrefix(ZenQuickLookTemporaryFile.directoryPrefix))
        #expect(directory.deletingLastPathComponent().lastPathComponent == root.lastPathComponent)

        // Each write has a directory of its own, so two files never collide.
        let other = try ZenQuickLookTemporaryFile.write(bytes, filename: "shot.png", under: root)
        #expect(other.deletingLastPathComponent() != directory)
    }

    @Test("a temporary file refuses a name that leaves its directory")
    func temporaryFileInvalidName() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["", ".", "..", "../escape.png", "a/b.png"] {
            #expect(throws: CocoaError.self) {
                try ZenQuickLookTemporaryFile.write(Data([1]), filename: name, under: root)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).isEmpty)
    }

    @Test("removing a temporary file removes its directory")
    func temporaryFileRemove() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try ZenQuickLookTemporaryFile.write(Data([1, 2, 3]), filename: "shot.png", under: root)
        let directory = file.deletingLastPathComponent()

        ZenQuickLookTemporaryFile.remove(file)

        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test("removing never touches a file outside a temporary directory")
    func temporaryFileRemoveOther() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "shot.png")
        try Data([1, 2, 3]).write(to: file)

        ZenQuickLookTemporaryFile.remove(file)

        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test("the name of a temporary file comes from the attachment")
    func temporaryFilename() {
        func filename(_ name: String, contentType: String? = nil) -> String {
            ZenQuickLookTemporaryFile.filename(for: AgentRuntimeAttachment(
                kind: .image, contentType: contentType, originalFilename: name
            ))
        }

        #expect(filename("shot.png") == "shot.png")
        // Quick Look chooses its viewer by the extension.
        #expect(filename("image", contentType: "image/jpeg") == "image.jpg")
        #expect(filename("photo", contentType: "public.png") == "photo.png")
        #expect(filename("shot.png", contentType: "image/jpeg") == "shot.png")
        #expect(filename("image") == "image")
        // Only the last component is kept, and `/` and `:` never are.
        #expect(filename("/Users/me/Desktop/shot.png") == "shot.png")
        #expect(filename("shot: 1.png") == "shot- 1.png")
        #expect(!filename("a:b:c.png").contains(":"))
        #expect(!filename("a:b:c.png").contains("/"))
        #expect(filename("  shot.png  ") == "shot.png")
        #expect(filename("   ") == "attachment")
        #expect(filename("", contentType: "image/png") == "attachment.png")
        #expect(filename("..") == "attachment")
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
