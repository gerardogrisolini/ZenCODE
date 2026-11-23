//  Created by Gerardo Grisolini on 30/05/26.
//
import CoreGraphics
import Foundation

/// Pure sizing rules for point-scale screenshots and native-resolution zooms.
enum DesktopScreenshotGeometry {
    struct PixelSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    /// One image pixel per desktop point for a known covered desktop rect.
    static func pointScaleSize(coveredPoints size: CGSize) -> PixelSize {
        PixelSize(width: atLeastOne(size.width), height: atLeastOne(size.height))
    }

    /// Window with shadow: native pixels divided by the backing scale.
    static func shadowedWindowSize(nativePixels: PixelSize, backingScale: Double?) -> PixelSize {
        let scale = (backingScale.map { $0.isFinite && $0 > 0 ? $0 : 1 }) ?? 1
        return PixelSize(
            width: atLeastOne(Double(nativePixels.width) / scale),
            height: atLeastOne(Double(nativePixels.height) / scale)
        )
    }

    /// Native resolution, uniformly downscaled so the long edge is at most `maximumLongEdge`.
    static func zoomSize(nativePixels: PixelSize, maximumLongEdge: Int) -> PixelSize {
        let native = PixelSize(width: max(1, nativePixels.width), height: max(1, nativePixels.height))
        let longEdge = max(native.width, native.height)
        guard longEdge > maximumLongEdge, maximumLongEdge > 0 else { return native }
        let factor = Double(maximumLongEdge) / Double(longEdge)
        let width = native.width == longEdge ? maximumLongEdge : atLeastOne(Double(native.width) * factor)
        let height = native.height == longEdge ? maximumLongEdge : atLeastOne(Double(native.height) * factor)
        return PixelSize(width: width, height: height)
    }

    static func pointsPerPixel(coveredWidth: Double, pixelWidth: Int) -> Double? {
        guard pixelWidth > 0, coveredWidth.isFinite, coveredWidth > 0 else { return nil }
        return coveredWidth / Double(pixelWidth)
    }

    /// The rect `screencapture -R` really captures for a requested region: the
    /// bounding box of the region's intersections with the attached displays.
    /// Nil when the region intersects no display.
    static func coveredBounds(of region: CGRect, displays: [CGRect]) -> CGRect? {
        displays.reduce(nil as CGRect?) { covered, display in
            let overlap = display.intersection(region)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return covered }
            return covered.map { $0.union(overlap) } ?? overlap
        }
    }

    /// The region captured for an element.
    enum ElementRegion: Equatable {
        /// The part of the element on one display, as whole points (the element's
        /// frame rounded outwards, then limited to that display), the position of
        /// the display in `displays`, and whether the element extends beyond it.
        case region(CGRect, displayIndex: Int, isClipped: Bool)
        /// The element reports no frame, or an empty or non-finite one.
        case noFrame
        /// The frame lies outside every display.
        case offScreen
    }

    /// The region to capture for an element with `frame`, in global points:
    /// the frame rounded outwards to whole points and limited to the display
    /// that holds most of it, so that the capture stays on one display (one
    /// scale). With ties the first display wins.
    static func elementRegion(frame: CGRect?, displays: [CGRect]) -> ElementRegion {
        guard let frame, DesktopElementPolicy.isPositive(frame) else { return .noFrame }
        let wanted = frame.integral
        var best: (index: Int, overlap: CGRect)?
        for (index, display) in displays.enumerated() {
            let overlap = display.intersection(wanted)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            if let current = best, current.overlap.width * current.overlap.height >= overlap.width * overlap.height { continue }
            best = (index, overlap)
        }
        guard let best else { return .offScreen }
        return .region(best.overlap, displayIndex: best.index, isClipped: best.overlap != wanted)
    }

    /// True when the native capture is a uniform scaling of the covered desktop
    /// size (within 2 px at the long edge), so a point mapping is exact.
    static func isUniformScaling(nativePixels: PixelSize, covered: CGSize) -> Bool {
        guard nativePixels.width > 0, nativePixels.height > 0,
              covered.width.isFinite, covered.height.isFinite,
              covered.width > 0, covered.height > 0 else { return false }
        let scaleX = Double(nativePixels.width) / Double(covered.width)
        let scaleY = Double(nativePixels.height) / Double(covered.height)
        return abs(scaleX - scaleY) * Double(max(covered.width, covered.height)) <= 2
    }

    private static func atLeastOne(_ value: Double) -> Int {
        guard value.isFinite else { return 1 }
        return max(1, Int(value.rounded()))
    }
}
