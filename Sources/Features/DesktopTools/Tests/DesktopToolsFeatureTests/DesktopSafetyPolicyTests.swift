import CoreGraphics
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopSafetyPolicyTests {
    private let frame = CGRect(x: 10, y: 20, width: 600, height: 400)

    @Test(arguments: [0, 1, 500, -1])
    func explicitIDRejectsEverySuppliedIndex(_ index: Int) {
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.validateSelectors(windowID: 42, windowIndex: index)
        }
    }

    @Test
    func independentSelectorsRemainSupported() throws {
        try DesktopSafetyPolicy.validateSelectors(windowID: 42, windowIndex: nil)
        try DesktopSafetyPolicy.validateSelectors(windowID: nil, windowIndex: 1)
        try DesktopSafetyPolicy.validateSelectors(windowID: nil, windowIndex: nil)
    }

    @Test
    func exactAssociationIsIndependentOfCandidateOrder() throws {
        let expected = DesktopSafetyPolicy.WindowIdentity(title: "Document", frame: frame)
        let other = DesktopSafetyPolicy.WindowIdentity(title: "Other", frame: frame)
        #expect(try DesktopSafetyPolicy.uniqueMatch([other, expected], expected: expected) == 1)
        #expect(try DesktopSafetyPolicy.uniqueMatch([expected, other], expected: expected) == 0)
    }

    @Test
    func noAssociationFailsInsteadOfSelectingTheLeastBadCandidate() {
        let expected = DesktopSafetyPolicy.WindowIdentity(title: "Document", frame: frame)
        let candidates: [DesktopSafetyPolicy.WindowIdentity] = [
            .init(title: "Document", frame: nil),
            .init(title: nil, frame: frame),
            .init(title: "Document copy", frame: frame),
            .init(title: "Document", frame: frame.offsetBy(dx: 3, dy: 0)),
            .init(title: "Document", frame: .zero),
            .init(title: "Document", frame: CGRect(x: Double.nan, y: 20, width: 600, height: 400))
        ]
        for candidate in candidates {
            #expect(!DesktopSafetyPolicy.matches(candidate, expected))
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.uniqueMatch(candidates, expected: expected)
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.uniqueMatch([], expected: expected)
        }
    }

    @Test
    func toleranceIsAbsoluteAndDoesNotBreakAmbiguousTies() throws {
        let expected = DesktopSafetyPolicy.WindowIdentity(title: "Document", frame: frame)
        let near = DesktopSafetyPolicy.WindowIdentity(title: "Document", frame: frame.offsetBy(dx: 2, dy: -2))
        #expect(try DesktopSafetyPolicy.uniqueMatch([near], expected: expected) == 0)
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.uniqueMatch([expected, near], expected: expected)
        }
    }

    @Test
    func reverseQuartzAmbiguityFailsEvenWithOneAXElement() throws {
        let ax = DesktopSafetyPolicy.WindowIdentity(title: "Document", frame: frame)
        let quartz = [ax, ax]
        #expect(try DesktopSafetyPolicy.uniqueMatch([ax], expected: quartz[0]) == 0)
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.uniqueMatch(quartz, expected: ax)
        }
    }

    @Test
    func unnamedWindowRequiresUniqueGeometry() throws {
        let unnamed = DesktopSafetyPolicy.WindowIdentity(title: nil, frame: frame)
        #expect(try DesktopSafetyPolicy.uniqueMatch([unnamed], expected: unnamed) == 0)
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.uniqueMatch([unnamed, unnamed], expected: unnamed)
        }
    }

    @Test(arguments: [1e20, Double.infinity, -Double.infinity, Double.nan, Double(Int.max), Double(Int32.max) + 1])
    func unrepresentableRegionValuesThrowWithoutIntegerTraps(_ value: Double) {
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: value, y: 0, width: 10, height: 10)
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: 0, y: 0, width: value, height: 10)
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: 0, y: value, width: 10, height: 10)
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: 0, y: 0, width: 10, height: value)
        }
    }

    @Test(arguments: [0.0, 0.1, 0.49, -1.0])
    func roundedEmptyDimensionsAreRejected(_ value: Double) {
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: 0, y: 0, width: value, height: 10)
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: 0, y: 0, width: 10, height: value)
        }
    }

    @Test
    func roundedRegionAndCommandAgree() throws {
        let region = try DesktopSafetyPolicy.captureRegion(x: -12.5, y: 3.4, width: 0.5, height: 20.8)
        #expect(region.argument == "-R-13,3,1,21")
        #expect(region.rect == CGRect(x: -13, y: 3, width: 1, height: 21))
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.captureRegion(x: Double(Int32.max), y: 0, width: 1, height: 10)
        }
        let edge = try DesktopSafetyPolicy.captureRegion(x: Double(Int32.min), y: 0, width: 1, height: 1)
        #expect(edge.x == Int(Int32.min))
    }

    @Test
    func pointsAndRegionsUseActualDisplaysNotTheirBoundingBox() throws {
        let displays = [CGRect(x: -200, y: 0, width: 100, height: 100),
                        CGRect(x: 0, y: 0, width: 100, height: 100),
                        CGRect(x: 100, y: 150, width: 100, height: 100)]
        #expect(DesktopSafetyPolicy.contains(CGPoint(x: -150, y: 20), displays: displays))
        #expect(!DesktopSafetyPolicy.contains(CGPoint(x: -50, y: 20), displays: displays))
        #expect(!DesktopSafetyPolicy.contains(CGPoint(x: 150, y: 120), displays: displays))
        #expect(!DesktopSafetyPolicy.contains(CGPoint(x: 100, y: 50), displays: displays))
        #expect(!DesktopSafetyPolicy.contains(.zero, displays: []))
        #expect(!DesktopSafetyPolicy.intersects(CGRect(x: -90, y: 0, width: 50, height: 50), displays: displays))
        #expect(!DesktopSafetyPolicy.intersects(CGRect(x: 100, y: 0, width: 10, height: 10), displays: displays))
        // Preserve partial-overlap semantics; a region need not fit one monitor.
        #expect(DesktopSafetyPolicy.intersects(CGRect(x: -110, y: 0, width: 120, height: 50), displays: displays))
        let roundedOutside = try DesktopSafetyPolicy.captureRegion(x: 99.6, y: 0, width: 1, height: 1)
        #expect(!DesktopSafetyPolicy.intersects(roundedOutside.rect, displays: displays))
    }

    @Test
    func typingBudgetChargesEveryCharacterAndReservesMargin() throws {
        try DesktopSafetyPolicy.validateTypingBudget(characterCount: 10_000, interval: 0.01)
        try DesktopSafetyPolicy.validateTypingBudget(characterCount: 10_000, interval: 0)
        try DesktopSafetyPolicy.validateTypingBudget(characterCount: 0, interval: 1)
        try DesktopSafetyPolicy.validateTypingBudget(characterCount: 100, interval: 1)
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.validateTypingBudget(characterCount: 10_000, interval: 1)
        }
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.validateTypingBudget(characterCount: 150, interval: 1)
        }
        let unicode = "👨‍👩‍👧‍👦e\u{301}"
        #expect(unicode.count == 2)
        try DesktopSafetyPolicy.validateTypingBudget(characterCount: unicode.count, interval: 1)
    }

    @Test(arguments: [Double.nan, Double.infinity, -0.01, 1.01])
    func invalidIntervalsAreRejected(_ interval: Double) {
        #expect(throws: DesktopControlError.self) {
            try DesktopSafetyPolicy.validateTypingBudget(characterCount: 1, interval: interval)
        }
    }
}
