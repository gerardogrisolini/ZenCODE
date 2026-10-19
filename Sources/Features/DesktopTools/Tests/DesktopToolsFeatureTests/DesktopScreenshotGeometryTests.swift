import CoreGraphics
import Testing
@testable import desktop_tools_feature

@Suite
struct DesktopScreenshotGeometryTests {
    typealias Size = DesktopScreenshotGeometry.PixelSize

    @Test
    func retinaDisplayMapsOnePixelPerPoint() {
        let target = DesktopScreenshotGeometry.pointScaleSize(coveredPoints: CGSize(width: 2048, height: 1152))
        #expect(target == Size(width: 2048, height: 1152))
        #expect(DesktopScreenshotGeometry.pointsPerPixel(coveredWidth: 2048, pixelWidth: target.width) == 1)
    }

    @Test
    func regionAtOneXIsUnchangedAndFractionsRound() {
        #expect(DesktopScreenshotGeometry.pointScaleSize(coveredPoints: CGSize(width: 300, height: 200)) == Size(width: 300, height: 200))
        #expect(DesktopScreenshotGeometry.pointScaleSize(coveredPoints: CGSize(width: 100.6, height: 50.4)) == Size(width: 101, height: 50))
    }

    @Test
    func shadowedWindowDividesByBackingScale() {
        let target = DesktopScreenshotGeometry.shadowedWindowSize(nativePixels: Size(width: 1300, height: 900), backingScale: 2)
        #expect(target == Size(width: 650, height: 450))
        #expect(DesktopScreenshotGeometry.shadowedWindowSize(nativePixels: Size(width: 10, height: 10), backingScale: nil) == Size(width: 10, height: 10))
    }

    @Test
    func zoomKeepsNativeResolutionUpToLongEdgeLimit() {
        let small = DesktopScreenshotGeometry.zoomSize(nativePixels: Size(width: 1000, height: 600), maximumLongEdge: 2000)
        #expect(small == Size(width: 1000, height: 600))
        #expect(DesktopScreenshotGeometry.pointsPerPixel(coveredWidth: 500, pixelWidth: small.width) == 0.5)

        let large = DesktopScreenshotGeometry.zoomSize(nativePixels: Size(width: 3000, height: 2000), maximumLongEdge: 2000)
        #expect(large == Size(width: 2000, height: 1333))
        #expect(DesktopScreenshotGeometry.pointsPerPixel(coveredWidth: 1500, pixelWidth: large.width) == 0.75)
    }

    @Test
    func minimumSideIsOne() {
        #expect(DesktopScreenshotGeometry.pointScaleSize(coveredPoints: CGSize(width: 0.2, height: 0.4)) == Size(width: 1, height: 1))
        #expect(DesktopScreenshotGeometry.zoomSize(nativePixels: Size(width: 10_000, height: 2), maximumLongEdge: 2000) == Size(width: 2000, height: 1))
    }

    /// Expected boxes match what screencapture -R captured live on a Retina
    /// pair: display 1 (0,0,2048,1152) and display 2 (-1920,-178,1920,1080).
    private let displayPair = [
        CGRect(x: 0, y: 0, width: 2048, height: 1152),
        CGRect(x: -1920, y: -178, width: 1920, height: 1080)
    ]

    @Test
    func coveredBoundsMatchesWhatScreencaptureCaptures() {
        func covered(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect? {
            DesktopScreenshotGeometry.coveredBounds(of: CGRect(x: x, y: y, width: width, height: height), displays: displayPair)
        }
        #expect(covered(0, 0, 200, 100) == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(covered(1948, 0, 200, 100) == CGRect(x: 1948, y: 0, width: 100, height: 100))
        #expect(covered(-2020, 0, 200, 100) == CGRect(x: -1920, y: 0, width: 100, height: 100))
        #expect(covered(-100, 0, 200, 100) == CGRect(x: -100, y: 0, width: 200, height: 100))
        #expect(covered(-100, -50, 200, 100) == CGRect(x: -100, y: -50, width: 200, height: 100))
        #expect(covered(-100, -150, 200, 100) == CGRect(x: -100, y: -150, width: 100, height: 100))
        #expect(covered(1948, -50, 200, 100) == CGRect(x: 1948, y: 0, width: 100, height: 50))
        #expect(covered(0, -300, 200, 100) == nil)
        #expect(DesktopScreenshotGeometry.coveredBounds(of: CGRect(x: 0, y: 0, width: 10, height: 10), displays: []) == nil)
    }

    @Test
    func uniformScalingGuardsTheCoordinateMapping() {
        #expect(DesktopScreenshotGeometry.isUniformScaling(nativePixels: Size(width: 200, height: 200), covered: CGSize(width: 100, height: 100)))
        #expect(!DesktopScreenshotGeometry.isUniformScaling(nativePixels: Size(width: 200, height: 200), covered: CGSize(width: 200, height: 100)))
        #expect(DesktopScreenshotGeometry.isUniformScaling(nativePixels: Size(width: 401, height: 200), covered: CGSize(width: 200, height: 100)))
        #expect(DesktopScreenshotGeometry.isUniformScaling(nativePixels: Size(width: 2048, height: 1152), covered: CGSize(width: 2048, height: 1152)))
        #expect(!DesktopScreenshotGeometry.isUniformScaling(nativePixels: Size(width: 0, height: 10), covered: CGSize(width: 10, height: 10)))
        #expect(!DesktopScreenshotGeometry.isUniformScaling(nativePixels: Size(width: 10, height: 10), covered: CGSize(width: 0, height: 10)))
    }
}
