//
//  ZenAppIcon.swift
//  ZenApp
//
//  The icon of the app. A SwiftPM executable has no bundle and no asset
//  catalog, so the app loads the ZenCODE symbol (`Resources/icon.svg`, a copy
//  of `Assets/icon.svg`) and draws it on a macOS-style rounded tile at launch.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import ZenAppTheme

/// Builds the Dock icon of the app from the ZenCODE symbol.
enum ZenAppIcon {
    /// The name of the resource bundle SwiftPM builds for the ``ZenCODEApp``
    /// target (`<package>_<target>`), without the `.bundle` extension.
    static let resourceBundleName = "ZenApp_ZenCODEApp"

    /// The xterm-256 index of the tile: the dark surface of the terminal UI.
    static let tileColorIndex = 236

    /// Finds `icon.svg` in the resource bundle named `bundleName` inside one
    /// of the `candidates` directories, the first that has it. Returns `nil`
    /// when no candidate holds the bundle or the bundle has no icon.
    ///
    /// This replaces the `Bundle.module` accessor SwiftPM generates, which
    /// calls `fatalError` when the bundle is missing: the icon is cosmetic and
    /// must never crash the app. The candidates are the ones the accessor
    /// tries, so the lookup works for the bare executable and inside a future
    /// `.app` alike.
    static func symbolURL(in candidates: [URL?], bundleName: String) -> URL? {
        for candidate in candidates {
            guard
                let bundleURL = candidate?.appendingPathComponent(bundleName + ".bundle", isDirectory: true),
                let bundle = Bundle(url: bundleURL),
                let url = bundle.url(forResource: "icon", withExtension: "svg")
            else {
                continue
            }
            return url
        }
        return nil
    }

    /// The ZenCODE symbol of the app's resource bundle, or `nil` when the
    /// bundle or the image is missing (the app then keeps the default icon).
    static func loadSymbol(mainBundle: Bundle = .main) -> NSImage? {
        let candidates = [mainBundle.resourceURL, mainBundle.bundleURL]
        guard let url = symbolURL(in: candidates, bundleName: resourceBundleName) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// The rounded tile inside a canvas, following the macOS icon grid: the
    /// canvas inset by 100/1024 of its size on each side (824/1024).
    static func tileRect(in canvas: CGRect) -> CGRect {
        canvas.insetBy(dx: canvas.width * 100 / 1024, dy: canvas.height * 100 / 1024)
    }

    /// The corner radius of the tile in a canvas (185.4/1024 of its width).
    static func cornerRadius(in canvas: CGRect) -> CGFloat {
        canvas.width * 185.4 / 1024
    }

    /// The box of the symbol: the tile inset by 10% of its width on each side.
    static func symbolBox(in canvas: CGRect) -> CGRect {
        let tile = tileRect(in: canvas)
        return tile.insetBy(dx: tile.width * 0.1, dy: tile.width * 0.1)
    }

    /// The icon: the `symbol` centered on a continuous rounded tile filled
    /// with the dark surface of the terminal UI, on a transparent canvas of
    /// `size` points. The image draws itself at the resolution it is shown
    /// at, with no shadow and no gradient.
    static func tile(symbol: NSImage, size: CGFloat = 1024) -> NSImage {
        let color = ZenXTerm256.rgb(tileColorIndex)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { canvas in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            let tile = tileRect(in: canvas)
            let path = RoundedRectangle(cornerRadius: cornerRadius(in: canvas), style: .continuous)
                .path(in: tile)
            context.addPath(path.cgPath)
            context.setFillColor(
                NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).cgColor
            )
            context.fillPath()

            let natural = symbol.size
            guard natural.width > 0, natural.height > 0 else {
                return true
            }
            let box = symbolBox(in: canvas)
            let scale = min(box.width / natural.width, box.height / natural.height)
            let fitted = CGRect(
                x: box.midX - natural.width * scale / 2,
                y: box.midY - natural.height * scale / 2,
                width: natural.width * scale,
                height: natural.height * scale
            )
            symbol.draw(
                in: fitted,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            return true
        }
    }
}
