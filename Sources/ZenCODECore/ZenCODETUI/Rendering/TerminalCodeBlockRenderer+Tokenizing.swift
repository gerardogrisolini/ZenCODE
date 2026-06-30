//
//  TerminalCodeBlockRenderer+Tokenizing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation

extension TerminalCodeBlockRenderer {
    static func matchingPrefix(
        in line: String,
        at index: String.Index,
        prefixes: [String]
    ) -> String? {
        // Track the longest matching prefix directly instead of sorting the
        // prefix list on every call (this runs for each character of each line).
        var longestMatch: String?
        for prefix in prefixes where hasPrefix(prefix, in: line, at: index) {
            if longestMatch == nil || prefix.count > longestMatch!.count {
                longestMatch = prefix
            }
        }
        return longestMatch
    }
    
    static func hasPrefix(
        _ prefix: String,
        in line: String,
        at index: String.Index
    ) -> Bool {
        var cursor = index
        for character in prefix {
            guard cursor < line.endIndex, line[cursor] == character else {
                return false
            }
            cursor = line.index(after: cursor)
        }
        return true
    }
    
    static func blockCommentEnd(
        in line: String,
        at index: String.Index
    ) -> String.Index? {
        guard hasPrefix("/*", in: line, at: index) else {
            return nil
        }
        return endOfDelimitedSegment(in: line, from: index, closing: "*/")
    }
    
    static func endOfDelimitedSegment(
        in line: String,
        from start: String.Index,
        closing: String
    ) -> String.Index {
        var cursor = start
        while cursor < line.endIndex {
            if hasPrefix(closing, in: line, at: cursor) {
                var end = cursor
                for _ in closing {
                    end = line.index(after: end)
                }
                return end
            }
            cursor = line.index(after: cursor)
        }
        return line.endIndex
    }
    
    static func stringEnd(
        in line: String,
        at index: String.Index,
        delimiters: Set<Character>,
        allowsSwiftRawStrings: Bool
    ) -> String.Index? {
        var hashCount = 0
        var quoteIndex = index
        while allowsSwiftRawStrings,
              quoteIndex < line.endIndex,
              line[quoteIndex] == "#" {
            hashCount += 1
            quoteIndex = line.index(after: quoteIndex)
        }
        
        guard quoteIndex < line.endIndex,
              delimiters.contains(line[quoteIndex]) else {
            return nil
        }
        
        let delimiter = line[quoteIndex]
        var cursor = line.index(after: quoteIndex)
        while cursor < line.endIndex {
            if hashCount == 0,
               line[cursor] == "\\" {
                cursor = line.index(after: cursor)
                if cursor < line.endIndex {
                    cursor = line.index(after: cursor)
                }
                continue
            }
            
            if line[cursor] == delimiter,
               stringClosingHashesMatch(
                in: line,
                afterQuoteAt: cursor,
                hashCount: hashCount
               ) {
                var end = line.index(after: cursor)
                for _ in 0..<hashCount {
                    end = line.index(after: end)
                }
                return end
            }
            
            cursor = line.index(after: cursor)
        }
        
        return line.endIndex
    }
    
    static func stringClosingHashesMatch(
        in line: String,
        afterQuoteAt quoteIndex: String.Index,
        hashCount: Int
    ) -> Bool {
        var cursor = line.index(after: quoteIndex)
        for _ in 0..<hashCount {
            guard cursor < line.endIndex, line[cursor] == "#" else {
                return false
            }
            cursor = line.index(after: cursor)
        }
        return true
    }
    
    static func consumeNumber(
        in line: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        if cursor < line.endIndex, line[cursor] == "-" {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex,
              line[cursor].isNumber || line[cursor] == "." else {
            return start
        }
        while cursor < line.endIndex {
            let character = line[cursor]
            guard character.isNumber
                    || character.isLetter
                    || character == "."
                    || character == "_"
            else {
                break
            }
            cursor = line.index(after: cursor)
        }
        return cursor
    }
    
    static func consumeCSSIdentifier(
        in line: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < line.endIndex {
            let character = line[cursor]
            guard isIdentifierPart(character)
                    || character == "-"
            else {
                break
            }
            cursor = line.index(after: cursor)
        }
        return cursor
    }
    
    static func cssColorEnd(
        in line: String,
        from start: String.Index
    ) -> String.Index? {
        var cursor = line.index(after: start)
        var count = 0
        while cursor < line.endIndex,
              isHexDigit(line[cursor]),
              count < 8 {
            count += 1
            cursor = line.index(after: cursor)
        }
        return [3, 4, 6, 8].contains(count) ? cursor : nil
    }
    
    static func consumeIdentifier(
        in line: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < line.endIndex, isIdentifierPart(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return cursor
    }
    
    static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }
    
    static func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }
    
    static func isHexDigit(_ character: Character) -> Bool {
        switch character {
        case "a", "b", "c", "d", "e", "f",
            "A", "B", "C", "D", "E", "F":
            return true
        default:
            return character.isNumber
        }
    }
    
    static func containsToken(
        _ token: String,
        in tokens: Set<String>
    ) -> Bool {
        tokens.contains(token)
        || tokens.contains(token.lowercased())
        || tokens.contains(token.uppercased())
    }
    
    static func isObjectKey(
        in line: String,
        after end: String.Index
    ) -> Bool {
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && (line[cursor] == ":" || line[cursor] == "=")
    }
    
    static func isMarkupAttribute(
        in line: String,
        after start: String.Index
    ) -> Bool {
        let end = consumeIdentifier(in: line, from: start)
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && line[cursor] == "="
    }
    
    static func isFunctionCall(
        in line: String,
        after end: String.Index
    ) -> Bool {
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && line[cursor] == "("
    }
}
