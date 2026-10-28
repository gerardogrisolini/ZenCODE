//
//  HalfPrecisionTests.swift
//  ZenCODECoreTests (memory engine)
//
//  The hand-written binary32 ⇄ binary16 conversion used for stored embedding
//  components: known values, round-to-nearest-even, subnormals, signed zeros,
//  overflow to infinity, NaN, and exhaustive properties over every binary16
//  bit pattern.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite struct HalfPrecisionTests {
    @Test func knownValuesConvertToTheirBinary16Patterns() {
        let cases: [(Float, UInt16)] = [
            (0, 0x0000),
            (-0.0, 0x8000),
            (1, 0x3C00),
            (-2, 0xC000),
            (0.5, 0x3800),
            (0.1, 0x2E66),
            (1.0 / 3.0, 0x3555),
            (65504, 0x7BFF),
            (-65504, 0xFBFF),
            (0x1p-14, 0x0400),          // smallest normal
            (0x1p-24, 0x0001),          // smallest subnormal
            (1023 * 0x1p-24, 0x03FF),   // largest subnormal
            (.infinity, 0x7C00),
            (-.infinity, 0xFC00),
        ]
        for (value, expected) in cases {
            #expect(HalfPrecision.bits(from: value) == expected, "\(value)")
        }
    }

    @Test func roundsToNearestWithTiesToEven() {
        // Halfway between 1 (even) and 1 + 2⁻¹⁰ (odd): stays at 1.
        #expect(HalfPrecision.bits(from: 1 + 0x1p-11) == 0x3C00)
        // Halfway between 1 + 2⁻¹⁰ (odd) and 1 + 2⁻⁹ (even): goes up.
        #expect(HalfPrecision.bits(from: 1 + 3 * 0x1p-11) == 0x3C02)
        // Just above and below a tie round to the nearer neighbour.
        #expect(HalfPrecision.bits(from: (1 + 0x1p-11).nextUp) == 0x3C01)
        #expect(HalfPrecision.bits(from: (1 + 3 * 0x1p-11).nextDown) == 0x3C01)
        // A carry out of the fraction moves to the next exponent.
        #expect(HalfPrecision.bits(from: 2 - 0x1p-12) == 0x4000)
    }

    @Test func overflowsToInfinityOnlyPastTheLargestFiniteHalf() {
        // 65520 is halfway between 65504 and 65536 (= 2¹⁶, beyond the range):
        // the tie goes to the even pattern, which is infinity.
        #expect(HalfPrecision.bits(from: 65520) == 0x7C00)
        #expect(HalfPrecision.bits(from: Float(65520).nextDown) == 0x7BFF)
        #expect(HalfPrecision.bits(from: -65520) == 0xFC00)
        #expect(HalfPrecision.bits(from: 1e10) == 0x7C00)
        #expect(HalfPrecision.bits(from: -Float.greatestFiniteMagnitude) == 0xFC00)
    }

    @Test func underflowsToSignedZeroAndRoundsSubnormals() {
        // 2⁻²⁵ is halfway between 0 (even) and the smallest subnormal.
        #expect(HalfPrecision.bits(from: 0x1p-25) == 0x0000)
        #expect(HalfPrecision.bits(from: -0x1p-25) == 0x8000)
        #expect(HalfPrecision.bits(from: Float(0x1p-25).nextUp) == 0x0001)
        #expect(HalfPrecision.bits(from: 1.5 * 0x1p-24) == 0x0002)   // tie, to even
        #expect(HalfPrecision.bits(from: 2.5 * 0x1p-24) == 0x0002)   // tie, to even
        #expect(HalfPrecision.bits(from: 1e-30) == 0x0000)
        #expect(HalfPrecision.bits(from: -1e-30) == 0x8000)
        #expect(HalfPrecision.bits(from: Float.leastNonzeroMagnitude) == 0x0000)
        #expect(HalfPrecision.bits(from: -Float.leastNormalMagnitude) == 0x8000)
        // The largest subnormal plus half a step rounds up to the smallest normal.
        #expect(HalfPrecision.bits(from: 1023.5 * 0x1p-24) == 0x0400)
        #expect(HalfPrecision.value(fromBits: 0x0001) == 0x1p-24)
        #expect(HalfPrecision.value(fromBits: 0x8000).sign == .minus)
        #expect(HalfPrecision.value(fromBits: 0x8000) == 0)
    }

    @Test func nanStaysNaNWithItsSign() {
        let quiet = HalfPrecision.bits(from: .nan)
        #expect(quiet & 0x7C00 == 0x7C00 && quiet & 0x03FF != 0)
        let negative = HalfPrecision.bits(from: -Float.nan)
        #expect(negative & 0x8000 == 0x8000 && negative & 0x03FF != 0)
        // A payload held only in the low 13 bits would vanish: it must not
        // turn the NaN into an infinity.
        let lowPayload = Float(bitPattern: 0x7F80_0001)
        #expect(lowPayload.isNaN)
        #expect(HalfPrecision.bits(from: lowPayload) == 0x7E00)
        #expect(HalfPrecision.rounded(lowPayload).isNaN)
    }

    /// Every binary16 pattern, NaNs included, survives binary16 → binary32 →
    /// binary16 unchanged, and its binary32 value is representable.
    @Test func everyBinary16PatternRoundTripsExactly() {
        var mismatches: [UInt16] = []
        for raw in 0...UInt16.max {
            let value = HalfPrecision.value(fromBits: raw)
            if HalfPrecision.bits(from: value) != raw || !HalfPrecision.isRepresentable(value) {
                mismatches.append(raw)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(8))")
    }

    /// For every pair of adjacent positive finite binary16 values, binary32
    /// values strictly between them go to the nearer one, the exact midpoint
    /// to the even one, and rounding is symmetric in the sign.
    @Test func everyIntervalRoundsToTheNearerEndpoint() {
        var mismatches: [UInt16] = []
        for raw in UInt16(0)..<0x7BFF {
            let low = HalfPrecision.value(fromBits: raw)
            let high = HalfPrecision.value(fromBits: raw + 1)
            let midpoint = (low + high) / 2   // exact: binary32 has 13 more bits
            let even: UInt16 = raw.isMultiple(of: 2) ? raw : raw + 1
            if HalfPrecision.bits(from: midpoint) != even
                || HalfPrecision.bits(from: midpoint.nextDown) != raw
                || HalfPrecision.bits(from: midpoint.nextUp) != raw + 1
                || HalfPrecision.bits(from: -midpoint) != even | 0x8000
                || HalfPrecision.bits(from: low) != raw {
                mismatches.append(raw)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(8))")
    }

    @Test func roundedVectorKeepsRepresentableStorageAndRoundsTheRest() {
        let exact: [Float] = [1, -2.5, 0, 0.125, 65504]
        #expect(HalfPrecision.rounded(exact) == exact)
        let inexact: [Float] = [1, 0.1, -1.0 / 3.0]
        let rounded = HalfPrecision.rounded(inexact)
        #expect(rounded.map(\.bitPattern) == [
            Float(1).bitPattern,
            HalfPrecision.value(fromBits: 0x2E66).bitPattern,
            HalfPrecision.value(fromBits: 0xB555).bitPattern,
        ])
        // Idempotent.
        #expect(HalfPrecision.rounded(rounded) == rounded)
        #expect(HalfPrecision.rounded([Float]()) == [])
    }

    #if arch(arm64)
    /// Where the platform has a native `Float16`, the hand-written conversion
    /// agrees with it bit for bit on every non-NaN binary32 value sampled
    /// across the whole range.
    @Test func matchesTheNativeConversionWhereItExists() {
        var generator = SystemRandomNumberGenerator()
        var samples: [Float] = [0x1p-25, 65520, 1 + 0x1p-11, 1023.5 * 0x1p-24]
        for _ in 0..<200_000 {
            let bits = UInt32.random(in: 0...UInt32.max, using: &generator)
            samples.append(Float(bitPattern: bits))
        }
        for _ in 0..<200_000 {
            samples.append(Float.random(in: -2...2, using: &generator))
        }
        let narrowing = samples.filter { !$0.isNaN && HalfPrecision.bits(from: $0) != Float16($0).bitPattern }
        #expect(narrowing.isEmpty, "first mismatches: \(narrowing.prefix(8))")
        let widening = (0...UInt16.max).filter { raw in
            !Float16(bitPattern: raw).isNaN
                && HalfPrecision.value(fromBits: raw).bitPattern != Float(Float16(bitPattern: raw)).bitPattern
        }
        #expect(widening.isEmpty, "first mismatches: \(widening.prefix(8))")
    }
    #endif
}
