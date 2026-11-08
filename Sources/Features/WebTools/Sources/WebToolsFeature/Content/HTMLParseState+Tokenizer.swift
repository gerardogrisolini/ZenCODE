import Foundation

extension HTMLParseState {
    // MARK: Tokenizer

    func indexOf(_ byte: UInt8, from start: Int) -> Int? {
        var index = start
        let count = bytes.count
        while index < count {
            if bytes[index] == byte { return index }
            index += 1
        }
        return nil
    }

    func skipPast(_ byte: UInt8, from start: Int) -> Int {
        guard let index = indexOf(byte, from: start) else { return bytes.count }
        return index + 1
    }

    private func hasPrefix(_ prefix: StaticString, at index: Int) -> Bool {
        let length = prefix.utf8CodeUnitCount
        guard index + length <= bytes.count else { return false }
        return prefix.withUTF8Buffer { expected in
            for offset in 0..<length where bytes[index + offset] != expected[offset] {
                return false
            }
            return true
        }
    }

    /// Index of the first byte of `a b c` at or after `start`.
    private func indexOf(_ first: UInt8, _ second: UInt8, _ third: UInt8, from start: Int) -> Int? {
        var index = start
        let count = bytes.count
        while index + 2 < count {
            guard let candidate = indexOf(first, from: index), candidate + 2 < count else { return nil }
            if bytes[candidate + 1] == second, bytes[candidate + 2] == third {
                return candidate
            }
            index = candidate + 1
        }
        return nil
    }

    func slice(_ range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: bytes[range])
    }

    private func lowercasedString(_ range: Range<Int>) -> String {
        let source = slice(range)
        guard source.contains(where: Byte.isUpper) else {
            return String(decoding: source, as: UTF8.self)
        }
        return String(decoding: source.map { Byte.isUpper($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    }

    mutating func parseMarkupDeclaration(at index: Int) -> Int {
        let count = bytes.count
        if hasPrefix("<!--", at: index) {
            let bodyStart = index + 4
            // "<!-->" and "<!--->" are complete (empty) comments.
            if bodyStart < count, bytes[bodyStart] == Byte.greaterThan {
                appendNode(WebHTMLNode(kind: .comment))
                return bodyStart + 1
            }
            if bodyStart + 1 < count, bytes[bodyStart] == Byte.dash, bytes[bodyStart + 1] == Byte.greaterThan {
                appendNode(WebHTMLNode(kind: .comment))
                return bodyStart + 2
            }
            appendNode(WebHTMLNode(kind: .comment))
            guard let end = indexOf(Byte.dash, Byte.dash, Byte.greaterThan, from: bodyStart) else { return count }
            return end + 3
        }
        if hasPrefix("<![CDATA[", at: index) {
            let contentStart = index + 9
            let end = indexOf(Byte.rightBracket, Byte.rightBracket, Byte.greaterThan, from: contentStart) ?? count
            if end > contentStart {
                // Text nodes hold raw text that the converter entity-decodes,
                // so escape "&" to keep CDATA content literal.
                let raw = String(decoding: slice(contentStart..<end), as: UTF8.self)
                let text = raw.contains("&") ? raw.replacingOccurrences(of: "&", with: "&amp;") : raw
                appendNode(WebHTMLNode(kind: .text(text)))
            }
            return min(count, end + 3)
        }
        // Doctype or bogus comment.
        return skipPast(Byte.greaterThan, from: index + 2)
    }

    mutating func parseStartTag(at index: Int) -> Int {
        let count = bytes.count
        var cursor = index + 1
        let nameStart = cursor
        while cursor < count, !Byte.isTagNameEnd(bytes[cursor]) {
            cursor += 1
        }
        let name = lowercasedString(nameStart..<cursor)
        var attributes: [String: String] = [:]
        var selfClosing = false

        while true {
            while cursor < count, Byte.isWhitespace(bytes[cursor]) {
                cursor += 1
            }
            // EOF inside a tag: the tag is dropped, as browsers do.
            guard cursor < count else { return count }
            let byte = bytes[cursor]
            if byte == Byte.greaterThan {
                cursor += 1
                break
            }
            if byte == Byte.slash {
                if cursor + 1 < count, bytes[cursor + 1] == Byte.greaterThan {
                    selfClosing = true
                    cursor += 2
                    break
                }
                cursor += 1
                continue
            }

            let attributeStart = cursor
            cursor += 1
            while cursor < count {
                let current = bytes[cursor]
                if Byte.isTagNameEnd(current) || current == Byte.equals { break }
                cursor += 1
            }
            let attributeName = lowercasedString(attributeStart..<cursor)
            while cursor < count, Byte.isWhitespace(bytes[cursor]) {
                cursor += 1
            }

            var value = ""
            if cursor < count, bytes[cursor] == Byte.equals {
                cursor += 1
                while cursor < count, Byte.isWhitespace(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < count, bytes[cursor] == Byte.doubleQuote || bytes[cursor] == Byte.singleQuote {
                    let quote = bytes[cursor]
                    let valueStart = cursor + 1
                    guard let close = indexOf(quote, from: valueStart) else { return count }
                    value = WebHTMLEntities.decodedString(slice(valueStart..<close))
                    cursor = close + 1
                } else {
                    let valueStart = cursor
                    while cursor < count, !Byte.isWhitespace(bytes[cursor]), bytes[cursor] != Byte.greaterThan {
                        cursor += 1
                    }
                    value = WebHTMLEntities.decodedString(slice(valueStart..<cursor))
                }
            }
            // The first occurrence of a duplicated attribute wins.
            if attributes[attributeName] == nil {
                attributes[attributeName] = value
            }
        }

        return handleStartTag(name, attributes: attributes, selfClosing: selfClosing, contentStart: cursor)
    }

    mutating func parseEndTag(at index: Int) -> Int {
        let count = bytes.count
        var cursor = index + 2
        let nameStart = cursor
        while cursor < count, !Byte.isTagNameEnd(bytes[cursor]) {
            cursor += 1
        }
        let name = lowercasedString(nameStart..<cursor)
        let end = skipPast(Byte.greaterThan, from: cursor)
        handleEndTag(name)
        return end
    }

    /// Consumes raw text up to the matching end tag (case-insensitive) and
    /// closes the raw-text element.
    mutating func consumeRawText(of name: String, from start: Int) -> Int {
        let count = bytes.count
        let nameBytes = Array(name.utf8)
        var cursor = start
        while let lessThan = indexOf(Byte.lessThan, from: cursor) {
            let nameStart = lessThan + 2
            let nameEnd = nameStart + nameBytes.count
            if lessThan + 1 < count, bytes[lessThan + 1] == Byte.slash, nameEnd <= count,
               matchesLowercased(nameBytes, at: nameStart),
               nameEnd == count || Byte.isTagNameEnd(bytes[nameEnd]) {
                appendRawText(start..<lessThan)
                popTo(openNodes.count - 1)
                return skipPast(Byte.greaterThan, from: nameEnd)
            }
            cursor = lessThan + 1
        }
        appendRawText(start..<count)
        popTo(openNodes.count - 1)
        return count
    }

    private func matchesLowercased(_ name: [UInt8], at index: Int) -> Bool {
        for offset in 0..<name.count {
            let byte = bytes[index + offset]
            if (Byte.isUpper(byte) ? byte | 0x20 : byte) != name[offset] { return false }
        }
        return true
    }
}
