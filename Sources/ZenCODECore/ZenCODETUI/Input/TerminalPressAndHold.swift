//
//  TerminalPressAndHold.swift
//  ZenCODE
//

/// Timing thresholds and accent catalogue for the terminal press-and-hold
/// fallback.
///
/// Terminal input exposes key presses but no matching key-up event, so the live
/// prompt uses these values only as a conservative heuristic. The reducer owns
/// the state machine; this type deliberately contains no clock or I/O.
enum TerminalPressAndHold {
    struct Candidate: Equatable, Sendable {
        let base: Character
        var insertionIndex: Int
        var insertedCount: Int
        var firstTimestampMilliseconds: UInt64
        var lastTimestampMilliseconds: UInt64
        var isRepeating: Bool
        var repeatIntervalCount: Int

        init(
            base: Character,
            insertionIndex: Int,
            timestampMilliseconds: UInt64
        ) {
            self.base = base
            self.insertionIndex = insertionIndex
            self.insertedCount = 1
            self.firstTimestampMilliseconds = timestampMilliseconds
            self.lastTimestampMilliseconds = timestampMilliseconds
            self.isRepeating = false
            self.repeatIntervalCount = 0
        }
    }

    struct Menu: Equatable, Sendable {
        let base: Character
        let replacementIndex: Int
        let variants: [Character]
        var selectedIndex: Int
        var lastRepeatTimestampMilliseconds: UInt64

        var selectedVariant: Character {
            variants[min(max(0, selectedIndex), variants.count - 1)]
        }

        func isVisuallyEqual(to other: Menu) -> Bool {
            base == other.base
                && replacementIndex == other.replacementIndex
                && variants == other.variants
                && selectedIndex == other.selectedIndex
        }
    }

    struct Suppression: Equatable, Sendable {
        let base: Character
        var lastRepeatTimestampMilliseconds: UInt64
    }

    static let initialDelayRange: ClosedRange<UInt64> = 250...1_500
    static let repeatIntervalRange: ClosedRange<UInt64> = 8...150
    static let minimumRepeatIntervalCount = 3
    static let minimumHoldDurationMilliseconds: UInt64 = 450
    static let residualRepeatWindowMilliseconds: UInt64 = 220

    private static let variantCatalogue: [Character: [Character]] = [
        "a": Array("àáâäæãåā"),
        "e": Array("èéêëēėę"),
        "i": Array("ìíîïīį"),
        "o": Array("òóôöœøōõ"),
        "u": Array("ùúûüū"),
        "c": Array("çćč"),
        "n": Array("ñń"),
        "s": Array("ßśš"),
        "y": Array("ýÿ"),
        "z": Array("žźż"),
        "A": Array("ÀÁÂÄÆÃÅĀ"),
        "E": Array("ÈÉÊËĒĖĘ"),
        "I": Array("ÌÍÎÏĪĮ"),
        "O": Array("ÒÓÔÖŒØŌÕ"),
        "U": Array("ÙÚÛÜŪ"),
        "C": Array("ÇĆČ"),
        "N": Array("ÑŃ"),
        "S": Array("ẞŚŠ"),
        "Y": Array("ÝŸ"),
        "Z": Array("ŽŹŻ")
    ]

    static func variants(for base: Character) -> [Character]? {
        variantCatalogue[base]
    }

    static var supportedBases: [Character] {
        Array(variantCatalogue.keys)
    }
}
