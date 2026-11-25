//
//  ZenAppIconExport.swift
//  ZenApp
//
//  `ZenCODE --write-app-icon PATH`: writes the icon of the `ZenCODE.app`
//  bundle that `zen --ui` adds to /Applications, then exits without starting
//  the app. The icon is the tile of the Dock icon (``ZenAppIcon``), so the
//  bundle and the running app show the same image.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the `.icns` icon of the app bundle.
enum ZenAppIconExport {
    /// The option, followed by the path of the icon to write. Keep in sync
    /// with `ZenAppInstallation.writeIconOption` of ZenCODECore
    /// (`Sources/ZenCODERuntime/Support/App/ZenAppApplicationBundle.swift`),
    /// which runs the installed app with it.
    static let option = "--write-app-icon"

    /// The images of the icon, in points and scale: the sizes of a macOS app
    /// icon, each at 1x and 2x (`icon_16x16` to `icon_512x512@2x`).
    static let representations: [(points: Int, scale: Int)] = [16, 32, 128, 256, 512]
        .flatMap { points in [(points, 1), (points, 2)] }

    /// Why the icon could not be written.
    enum ExportError: LocalizedError, Equatable {
        case missingSymbol
        case renderingFailed(pixels: Int)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .missingSymbol:
                "The icon resource icon.svg was not found next to the app."
            case let .renderingFailed(pixels):
                "The icon could not be drawn at \(pixels) pixels."
            case .encodingFailed:
                "The icon could not be encoded as .icns."
            }
        }
    }

    /// The exit status of the export when `arguments` (the process
    /// arguments) ask for it, `<executable> --write-app-icon PATH`; `nil`
    /// otherwise, and the app starts. The option is read only right after the
    /// executable, where `zen --ui` passes it.
    @MainActor
    static func run(
        arguments: [String],
        loadSymbol: () -> NSImage? = { ZenAppIcon.loadSymbol() },
        writeError: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) -> Int32? {
        guard arguments.count > 1, arguments[1] == option else {
            return nil
        }
        guard arguments.count == 3, !arguments[2].isEmpty else {
            writeError("usage: ZenCODE \(option) PATH\n")
            return 2
        }
        do {
            guard let symbol = loadSymbol() else {
                throw ExportError.missingSymbol
            }
            let data = try icnsData(icon: ZenAppIcon.tile(symbol: symbol))
            try data.write(to: URL(fileURLWithPath: arguments[2], isDirectory: false), options: .atomic)
            return 0
        } catch {
            writeError("ZenCODE: \(error.localizedDescription)\n")
            return 1
        }
    }

    /// `icon` as `.icns` data, with every image of ``representations``.
    @MainActor
    static func icnsData(icon: NSImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.icns.identifier as CFString,
            representations.count,
            nil
        ) else {
            throw ExportError.encodingFailed
        }
        for representation in representations {
            let pixels = representation.points * representation.scale
            // The resolution tells a 2x image from the 1x one of the same
            // pixel size (`icon_32x32` and `icon_16x16@2x`).
            let resolution = 72 * representation.scale
            let properties = [
                kCGImagePropertyDPIWidth: resolution,
                kCGImagePropertyDPIHeight: resolution
            ] as CFDictionary
            CGImageDestinationAddImage(destination, try image(of: icon, pixels: pixels), properties)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed
        }
        return data as Data
    }

    /// `icon` drawn over a transparent sRGB square of `pixels` pixels.
    @MainActor
    static func image(of icon: NSImage, pixels: Int) throws -> CGImage {
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ExportError.renderingFailed(pixels: pixels)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else {
            throw ExportError.renderingFailed(pixels: pixels)
        }
        return image
    }
}
