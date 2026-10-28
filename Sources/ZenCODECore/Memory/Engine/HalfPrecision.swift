//
//  HalfPrecision.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/10/26.
//
//  IEEE-754 binary16 ("half precision") conversion for stored embedding
//  components, written by hand on purpose: Swift's `Float16` is unavailable on
//  macOS x86_64, and the stored bytes must be identical on every platform.
//

import Foundation

/// Converts between `Float` (binary32) and the bit pattern of a binary16 value.
///
/// Binary16 has 1 sign bit, 5 exponent bits (bias 15) and 10 fraction bits.
/// Conversion to binary16 rounds to nearest, ties to even, exactly like an
/// IEEE-754 conversion: values beyond the largest finite half (65504) that do
/// not round down to it become ±infinity, values below half of the smallest
/// subnormal (2⁻²⁴) become a zero of the same sign, and subnormals keep the
/// precision binary16 has for them. Infinities keep their sign. A NaN stays a
/// NaN with its sign and the top ten bits of its payload (a payload that would
/// become zero is replaced by the quiet bit, so the result is never an
/// infinity). Conversion back is exact: every binary16 value, NaN payloads
/// included, round-trips bit for bit through `Float`.
enum HalfPrecision {
    /// The binary16 bit pattern nearest to `value` (ties to even).
    static func bits(from value: Float) -> UInt16 {
        let x = value.bitPattern
        let sign = UInt16(truncatingIfNeeded: (x >> 16) & 0x8000)
        let exponent = Int((x >> 23) & 0xFF)
        let fraction = x & 0x7F_FFFF

        if exponent == 0xFF {
            guard fraction != 0 else { return sign | 0x7C00 }
            let payload = UInt16(truncatingIfNeeded: fraction >> 13)
            return sign | 0x7C00 | (payload == 0 ? 0x0200 : payload)
        }

        // Exponent rebiased from 127 to 15.
        let halfExponent = exponent - 127 + 15
        if halfExponent >= 0x1F {
            return sign | 0x7C00
        }
        if halfExponent >= 1 {
            // Normal: keep 10 of the 23 fraction bits and round on the other 13.
            // A carry out of the fraction increments the exponent, and out of
            // the largest exponent it yields exactly the infinity pattern.
            var half = UInt32(halfExponent) << 10 | (fraction >> 13)
            let remainder = fraction & 0x1FFF
            if remainder > 0x1000 || (remainder == 0x1000 && half & 1 == 1) {
                half += 1
            }
            return sign | UInt16(truncatingIfNeeded: half)
        }
        // Below 2⁻²⁵ (including binary32 zeros and subnormals) everything rounds
        // to zero; exactly 2⁻²⁵ is a tie and goes to the even zero as well.
        guard halfExponent >= -10 else { return sign }
        // Subnormal: value = significand × 2^(halfExponent − 14 − 10), the
        // binary16 subnormal step being 2⁻²⁴.
        let significand = fraction | 0x80_0000
        let shift = UInt32(14 - halfExponent)
        var half = significand >> shift
        let remainder = significand & ((1 << shift) - 1)
        let halfway = UInt32(1) << (shift - 1)
        if remainder > halfway || (remainder == halfway && half & 1 == 1) {
            // A carry to 0x400 is the smallest normal, which is the right result.
            half += 1
        }
        return sign | UInt16(truncatingIfNeeded: half)
    }

    /// The exact `Float` value of a binary16 bit pattern.
    static func value(fromBits bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 0x1F)
        let fraction = UInt32(bits & 0x03FF)
        switch exponent {
        case 0x1F:
            return Float(bitPattern: sign | 0x7F80_0000 | (fraction << 13))
        case 0:
            // Zero or subnormal: fraction × 2⁻²⁴ is exact in binary32.
            let magnitude = Float(fraction) * 0x1p-24
            return Float(bitPattern: sign | magnitude.bitPattern)
        default:
            return Float(bitPattern: sign | ((exponent + 127 - 15) << 23) | (fraction << 13))
        }
    }

    /// `value` rounded to the nearest binary16 value, as a `Float`.
    static func rounded(_ value: Float) -> Float {
        Self.value(fromBits: bits(from: value))
    }

    /// Whether `value` is exactly a binary16 value (bit for bit, NaN payloads
    /// included), so rounding it changes nothing.
    static func isRepresentable(_ value: Float) -> Bool {
        rounded(value).bitPattern == value.bitPattern
    }

    /// Every component rounded to binary16. Returns `values` itself — the same
    /// storage, without a copy — when every component is already representable,
    /// so rounding an already rounded vector is free and keeps array identity.
    static func rounded(_ values: [Float]) -> [Float] {
        guard let first = values.firstIndex(where: { !isRepresentable($0) }) else {
            return values
        }
        var result = values
        for index in first..<result.endIndex {
            result[index] = rounded(result[index])
        }
        return result
    }
}
