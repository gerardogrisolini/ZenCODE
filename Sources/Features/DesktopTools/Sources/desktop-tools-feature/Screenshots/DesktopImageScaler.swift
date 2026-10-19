//  Created by Gerardo Grisolini on 30/05/26.
//
import CoreGraphics
import Foundation
import ImageIO

/// In-process PNG resampling with ImageIO/CoreGraphics.
enum DesktopImageScaler {
    static func resample(pngAt url: URL, width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw DesktopControlError.operationFailed("Invalid screenshot target size \(width)x\(height).")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DesktopControlError.operationFailed("Could not decode the captured screenshot for resampling.")
        }
        if image.width == width, image.height == height { return }

        let colorSpace: CGColorSpace
        if let source = image.colorSpace, source.model == .rgb {
            colorSpace = source
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            colorSpace = srgb
        } else {
            throw DesktopControlError.operationFailed("Could not create an sRGB color space.")
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DesktopControlError.operationFailed("Could not create a \(width)x\(height) bitmap context.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw DesktopControlError.operationFailed("Could not render the resampled screenshot.")
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
            throw DesktopControlError.operationFailed("Could not create a PNG encoder for the resampled screenshot.")
        }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DesktopControlError.operationFailed("Could not encode the resampled screenshot as PNG.")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw DesktopControlError.operationFailed("Could not replace the screenshot with its resampled version: \(error.localizedDescription)")
        }
    }
}
