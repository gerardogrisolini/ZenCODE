// MARK: - Character references

/// Single-pass, byte-level HTML character reference decoder (no regular
/// expressions). Named references require the trailing `;`; numeric ones
/// accept a missing `;` like browsers do.
enum WebHTMLEntities {
    /// `keepingInvalidNumericReferences` leaves numeric references that are not
    /// meaningful text (NUL, surrogates, out-of-range values, control
    /// characters) as written instead of applying the WHATWG replacement.
    static func decode(_ text: String, keepingInvalidNumericReferences: Bool = false) -> String {
        guard text.utf8.contains(Byte.ampersand) else { return text }
        var copy = text
        return copy.withUTF8 { decodedString($0, keepingInvalidNumericReferences: keepingInvalidNumericReferences) }
    }

    static func decodedString(
        _ input: UnsafeBufferPointer<UInt8>,
        keepingInvalidNumericReferences: Bool = false
    ) -> String {
        guard input.contains(Byte.ampersand) else {
            return String(decoding: input, as: UTF8.self)
        }
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        appendDecoded(input, to: &output, keepingInvalidNumericReferences: keepingInvalidNumericReferences)
        return String(decoding: output, as: UTF8.self)
    }

    static func appendDecoded(
        _ input: UnsafeBufferPointer<UInt8>,
        to output: inout [UInt8],
        keepingInvalidNumericReferences: Bool = false
    ) {
        let count = input.count
        var index = 0
        var runStart = 0
        while index < count {
            guard input[index] == Byte.ampersand,
                  let reference = parseReference(
                      input, at: index, keepingInvalidNumericReferences: keepingInvalidNumericReferences
                  ) else {
                index += 1
                continue
            }
            if index > runStart {
                output.append(contentsOf: UnsafeBufferPointer(rebasing: input[runStart..<index]))
            }
            if let scalar = reference.scalar {
                appendUTF8(scalar, to: &output)
            }
            index = reference.end
            runStart = index
        }
        if count > runStart {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: input[runStart..<count]))
        }
    }

    /// Returns the decoded scalar (nil when the reference decodes to nothing)
    /// and the index after the reference, or nil when `&` starts no reference.
    private static func parseReference(
        _ input: UnsafeBufferPointer<UInt8>,
        at index: Int,
        keepingInvalidNumericReferences: Bool
    ) -> (scalar: UInt32?, end: Int)? {
        let count = input.count
        var cursor = index + 1
        guard cursor < count else { return nil }

        if input[cursor] == UInt8(ascii: "#") {
            cursor += 1
            var hexadecimal = false
            if cursor < count, input[cursor] | 0x20 == UInt8(ascii: "x") {
                hexadecimal = true
                cursor += 1
            }
            let digitsStart = cursor
            var value: UInt32 = 0
            while cursor < count, let digit = digitValue(input[cursor], hexadecimal: hexadecimal) {
                if value <= 0x10FFFF {
                    value = value * (hexadecimal ? 16 : 10) + digit
                }
                cursor += 1
            }
            guard cursor > digitsStart else { return nil }
            if cursor < count, input[cursor] == UInt8(ascii: ";") {
                cursor += 1
            }
            let scalar = numericScalar(value)
            if keepingInvalidNumericReferences, scalar == nil || (scalar == 0xFFFD && value != 0xFFFD) {
                return nil
            }
            return (scalar, cursor)
        }

        let nameStart = cursor
        while cursor < count, cursor - nameStart < 32, isAlphanumeric(input[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart, cursor < count, input[cursor] == UInt8(ascii: ";") else { return nil }
        let name = String(decoding: UnsafeBufferPointer(rebasing: input[nameStart..<cursor]), as: UTF8.self)
        guard let value = namedEntities[name] else { return nil }
        return (value, cursor + 1)
    }

    private static func digitValue(_ byte: UInt8, hexadecimal: Bool) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where hexadecimal:
            return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F") where hexadecimal:
            return UInt32(byte - UInt8(ascii: "A") + 10)
        default:
            return nil
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        Byte.isAlpha(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    /// WHATWG numeric reference fix-ups; C0 controls (other than whitespace)
    /// decode to nothing because they are never meaningful page text.
    private static func numericScalar(_ value: UInt32) -> UInt32? {
        switch value {
        case 0, 0xD800...0xDFFF, 0x110000...:
            return 0xFFFD
        case 0x09, 0x0A, 0x0C, 0x0D:
            return value
        case 0x01...0x1F, 0x7F:
            return nil
        case 0x80...0x9F:
            return windows1252[value]
        default:
            return value
        }
    }

    private static func appendUTF8(_ value: UInt32, to output: inout [UInt8]) {
        switch value {
        case 0..<0x80:
            output.append(UInt8(value))
        case 0x80..<0x800:
            output.append(UInt8(0xC0 | (value >> 6)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        case 0x800..<0x10000:
            output.append(UInt8(0xE0 | (value >> 12)))
            output.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        default:
            output.append(UInt8(0xF0 | (value >> 18)))
            output.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
            output.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        }
    }

    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
        0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
        0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    /// Latin-1 supplement names for U+00A0...U+00FF, in code point order.
    private static let latin1Names = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo",
        "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
        "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc",
        "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute",
        "Icirc", "Iuml", "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash",
        "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde",
        "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc",
        "iuml", "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave",
        "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
    ]

    private static let otherEntities: [String: UInt32] = [
        // Markup-significant and ASCII punctuation.
        "quot": 0x22, "QUOT": 0x22, "amp": 0x26, "AMP": 0x26, "apos": 0x27, "lt": 0x3C, "LT": 0x3C,
        "gt": 0x3E, "GT": 0x3E, "Tab": 0x09, "NewLine": 0x0A, "excl": 0x21, "num": 0x23, "dollar": 0x24,
        "percnt": 0x25, "lpar": 0x28, "rpar": 0x29, "ast": 0x2A, "plus": 0x2B, "comma": 0x2C,
        "period": 0x2E, "sol": 0x2F, "colon": 0x3A, "semi": 0x3B, "equals": 0x3D, "quest": 0x3F,
        "commat": 0x40, "lsqb": 0x5B, "lbrack": 0x5B, "bsol": 0x5C, "rsqb": 0x5D, "rbrack": 0x5D,
        "Hat": 0x5E, "lowbar": 0x5F, "grave": 0x60, "lcub": 0x7B, "lbrace": 0x7B, "verbar": 0x7C,
        "vert": 0x7C, "rcub": 0x7D, "rbrace": 0x7D, "COPY": 0xA9, "REG": 0xAE, "half": 0xBD,
        "centerdot": 0xB7,
        // Latin Extended and spacing modifiers.
        "OElig": 0x152, "oelig": 0x153, "Scaron": 0x160, "scaron": 0x161, "Yuml": 0x178, "fnof": 0x192,
        "circ": 0x2C6, "tilde": 0x2DC,
        // Greek.
        "Alpha": 0x391, "Beta": 0x392, "Gamma": 0x393, "Delta": 0x394, "Epsilon": 0x395, "Zeta": 0x396,
        "Eta": 0x397, "Theta": 0x398, "Iota": 0x399, "Kappa": 0x39A, "Lambda": 0x39B, "Mu": 0x39C,
        "Nu": 0x39D, "Xi": 0x39E, "Omicron": 0x39F, "Pi": 0x3A0, "Rho": 0x3A1, "Sigma": 0x3A3,
        "Tau": 0x3A4, "Upsilon": 0x3A5, "Phi": 0x3A6, "Chi": 0x3A7, "Psi": 0x3A8, "Omega": 0x3A9,
        "alpha": 0x3B1, "beta": 0x3B2, "gamma": 0x3B3, "delta": 0x3B4, "epsilon": 0x3B5, "zeta": 0x3B6,
        "eta": 0x3B7, "theta": 0x3B8, "iota": 0x3B9, "kappa": 0x3BA, "lambda": 0x3BB, "mu": 0x3BC,
        "nu": 0x3BD, "xi": 0x3BE, "omicron": 0x3BF, "pi": 0x3C0, "rho": 0x3C1, "sigmaf": 0x3C2,
        "sigma": 0x3C3, "tau": 0x3C4, "upsilon": 0x3C5, "phi": 0x3C6, "chi": 0x3C7, "psi": 0x3C8,
        "omega": 0x3C9, "thetasym": 0x3D1, "upsih": 0x3D2, "piv": 0x3D6,
        // General punctuation.
        "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E,
        "rlm": 0x200F, "hyphen": 0x2010, "dash": 0x2010, "ndash": 0x2013, "mdash": 0x2014,
        "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D,
        "bdquo": 0x201E, "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026,
        "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033, "lsaquo": 0x2039, "rsaquo": 0x203A,
        "oline": 0x203E, "frasl": 0x2044, "euro": 0x20AC,
        // Letterlike symbols and arrows.
        "image": 0x2111, "weierp": 0x2118, "real": 0x211C, "trade": 0x2122, "TRADE": 0x2122,
        "alefsym": 0x2135, "larr": 0x2190, "uarr": 0x2191, "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194,
        "crarr": 0x21B5, "lArr": 0x21D0, "uArr": 0x21D1, "rArr": 0x21D2, "dArr": 0x21D3, "hArr": 0x21D4,
        // Mathematical operators.
        "forall": 0x2200, "part": 0x2202, "exist": 0x2203, "empty": 0x2205, "nabla": 0x2207,
        "isin": 0x2208, "notin": 0x2209, "ni": 0x220B, "prod": 0x220F, "sum": 0x2211, "minus": 0x2212,
        "lowast": 0x2217, "radic": 0x221A, "prop": 0x221D, "infin": 0x221E, "ang": 0x2220, "and": 0x2227,
        "or": 0x2228, "cap": 0x2229, "cup": 0x222A, "int": 0x222B, "there4": 0x2234, "sim": 0x223C,
        "cong": 0x2245, "asymp": 0x2248, "ne": 0x2260, "equiv": 0x2261, "le": 0x2264, "ge": 0x2265,
        "sub": 0x2282, "sup": 0x2283, "nsub": 0x2284, "sube": 0x2286, "supe": 0x2287, "oplus": 0x2295,
        "otimes": 0x2297, "perp": 0x22A5, "sdot": 0x22C5,
        // Technical, geometric and miscellaneous symbols.
        "lceil": 0x2308, "rceil": 0x2309, "lfloor": 0x230A, "rfloor": 0x230B, "lang": 0x27E8,
        "rang": 0x27E9, "loz": 0x25CA, "starf": 0x2605, "star": 0x2606, "spades": 0x2660, "clubs": 0x2663,
        "hearts": 0x2665, "diams": 0x2666, "check": 0x2713, "cross": 0x2717,
    ]

    static let namedEntities: [String: UInt32] = {
        var table = otherEntities
        for (offset, name) in latin1Names.enumerated() {
            table[name] = 0xA0 + UInt32(offset)
        }
        return table
    }()
}
