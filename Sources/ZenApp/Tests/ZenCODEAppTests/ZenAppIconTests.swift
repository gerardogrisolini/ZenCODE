//
//  ZenAppIconTests.swift
//  ZenApp
//
//  The icon resource, the tile drawn from it, and the lookup of its bundle.
//

import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import ZenCODEApp

/// Locations in the checkout, found from this file.
private enum IconPaths {
    /// The root of the `ZenApp` package (`Sources/ZenApp`).
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ZenCODEAppTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // ZenApp
    /// The copy of the icon that the app loads.
    static let resource = package.appendingPathComponent("Sources/ZenCODEApp/Resources/icon.svg")
    /// The source of truth, at the root of the repository.
    static let asset = package
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Assets/icon.svg")
}

/// A temporary directory that is removed with the value.
private struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenAppIconTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The pixels of an `NSImage` drawn into an sRGB bitmap, read back as bytes
/// so that no color conversion alters them.
private struct RenderedPixels {
    let width: Int
    private let bytes: [UInt8]
    private let bytesPerRow: Int

    /// Draws `image` over a transparent `pixels` x `pixels` bitmap.
    @MainActor
    init(drawing image: NSImage, pixels: Int) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(context.data)
        width = pixels
        bytesPerRow = context.bytesPerRow
        bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * pixels))
    }

    /// The color of a pixel, each component in `0...1` (the origin is the top
    /// left). The color is not premultiplied.
    subscript(x: Int, y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let offset = y * bytesPerRow + x * 4
        let alpha = Double(bytes[offset + 3]) / 255
        guard alpha > 0 else {
            return (0, 0, 0, 0)
        }
        func component(_ index: Int) -> Double {
            min(Double(bytes[offset + index]) / 255 / alpha, 1)
        }
        return (component(0), component(1), component(2), alpha)
    }
}

@Suite("App icon resource")
struct ZenAppIconResourceTests {
    @Test("the bundled icon is byte-identical to Assets/icon.svg")
    func bundledCopyMatchesTheAsset() throws {
        let resource = try Data(contentsOf: IconPaths.resource)
        let asset = try Data(contentsOf: IconPaths.asset)
        #expect(!resource.isEmpty)
        #expect(resource == asset)
    }
}

@Suite("App icon tile")
@MainActor
struct ZenAppIconTileTests {
    @Test("the tile is a dark rounded square with the orange symbol in it")
    func tileIsDrawnOnATransparentCanvas() throws {
        let symbol = try #require(NSImage(contentsOf: IconPaths.resource))
        let bitmap = try RenderedPixels(drawing: ZenAppIcon.tile(symbol: symbol), pixels: 256)

        // Outside the tile: the margin and the rounded corner stay clear.
        let outside = bitmap[2, 2]
        #expect(outside.alpha < 0.01)
        let corner = bitmap[26, 26]
        #expect(corner.alpha < 0.01)

        // The ring of the symbol is transparent in the middle: the tile shows.
        let center = bitmap[128, 128]
        #expect(center.alpha > 0.99)
        let gray = 48.0 / 255
        #expect(abs(center.red - gray) < 0.02)
        #expect(abs(center.green - gray) < 0.02)
        #expect(abs(center.blue - gray) < 0.02)

        // The tile edge sits at 100/1024 of the canvas: 25 of 256 pixels.
        let inside = bitmap[128, 27]
        #expect(inside.alpha > 0.99)
        let margin = bitmap[128, 23]
        #expect(margin.alpha < 0.01)

        var orange = 0
        for y in 0..<256 {
            for x in 0..<256 {
                let value = bitmap[x, y]
                if value.alpha > 0.99, value.red > 0.9, value.green > 0.4, value.green < 0.65, value.blue < 0.15 {
                    orange += 1
                }
            }
        }
        #expect(orange > 100)
    }

    @Test("the tile is resolution independent")
    func tileScalesWithTheCanvas() throws {
        let symbol = try #require(NSImage(contentsOf: IconPaths.resource))
        let icon = ZenAppIcon.tile(symbol: symbol)
        #expect(icon.size == NSSize(width: 1024, height: 1024))
        let small = try RenderedPixels(drawing: icon, pixels: 64)
        let large = try RenderedPixels(drawing: icon, pixels: 512)
        #expect(small[1, 1].alpha < 0.01)
        #expect(large[4, 4].alpha < 0.01)
        let smallCenter = small[32, 32]
        let largeCenter = large[256, 256]
        #expect(abs(smallCenter.red - largeCenter.red) < 0.02)
        #expect(smallCenter.alpha > 0.99 && largeCenter.alpha > 0.99)
    }

    @Test("the icon grid follows the macOS template")
    func gridGeometry() {
        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        #expect(ZenAppIcon.tileRect(in: canvas) == CGRect(x: 100, y: 100, width: 824, height: 824))
        #expect(abs(ZenAppIcon.cornerRadius(in: canvas) - 185.4) < 0.0001)
        let box = ZenAppIcon.symbolBox(in: canvas)
        #expect(abs(box.width - 824 * 0.8) < 0.0001)
        #expect(abs(box.midX - 512) < 0.0001 && abs(box.midY - 512) < 0.0001)
    }
}

@Suite("App icon lookup")
struct ZenAppIconLookupTests {
    private static let bundleName = "ZenApp_ZenCODEApp"

    /// A resource bundle with an `icon.svg`, laid out the shallow way.
    private func makeBundle(in directory: URL, name: String) throws {
        let bundle = directory.appendingPathComponent(name + ".bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
            .write(to: bundle.appendingPathComponent("icon.svg"))
    }

    @Test("a directory without the bundle has no icon")
    func missingBundle() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let empty = try TemporaryDirectory()
        #expect(ZenAppIcon.symbolURL(in: [missing], bundleName: Self.bundleName) == nil)
        #expect(ZenAppIcon.symbolURL(in: [empty.url], bundleName: Self.bundleName) == nil)
        #expect(ZenAppIcon.symbolURL(in: [nil, nil], bundleName: Self.bundleName) == nil)
        #expect(ZenAppIcon.symbolURL(in: [], bundleName: Self.bundleName) == nil)
    }

    @Test("a bundle without the icon is skipped")
    func bundleWithoutIcon() throws {
        let directory = try TemporaryDirectory()
        let bundle = directory.url.appendingPathComponent(Self.bundleName + ".bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(ZenAppIcon.symbolURL(in: [directory.url], bundleName: Self.bundleName) == nil)
    }

    @Test("the icon is found in the bundle of the first candidate that has it")
    func foundInBundle() throws {
        let empty = try TemporaryDirectory()
        let directory = try TemporaryDirectory()
        try makeBundle(in: directory.url, name: Self.bundleName)
        let url = ZenAppIcon.symbolURL(in: [nil, empty.url, directory.url], bundleName: Self.bundleName)
        #expect(url?.lastPathComponent == "icon.svg")
        #expect(url.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(url?.path.contains(Self.bundleName + ".bundle") == true)
        // Another bundle name in the same directory is not this bundle.
        #expect(ZenAppIcon.symbolURL(in: [directory.url], bundleName: "Other_Bundle") == nil)
    }

    @Test("the SwiftPM resource bundle name is the one the build produces")
    func bundleNameIsStable() {
        #expect(ZenAppIcon.resourceBundleName == Self.bundleName)
    }
}
