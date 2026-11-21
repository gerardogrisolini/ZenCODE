//
//  TerminalCodeBlockRenderer+LineHighlighting.swift
//  ZenCODE
//
//  Per-language line highlighters of the code block renderer: keyword
//  profiles, data formats, markup and CSS.
//

import Foundation
import ZenCODERuntime

extension TerminalCodeBlockRenderer {
    static func renderProfileLine(
        _ line: String,
        profile: SyntaxProfile,
        palette: TerminalMarkdownPalette
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if matchingPrefix(
                in: line,
                at: index,
                prefixes: profile.lineComments
            ) != nil {
                rendered += "\(palette.syntaxComment)\(line[index...])\(reset)"
                break
            }

            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(palette.syntaxComment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: profile.stringDelimiters,
                allowsSwiftRawStrings: profile.allowsSwiftRawStrings
            ) {
                rendered += "\(palette.syntaxString)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if profile.attributePrefixes.contains(line[index]) {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(palette.syntaxAttribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if profile.directivePrefixes.contains(line[index]),
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)].isLetter {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(palette.syntaxKeyword)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(palette.syntaxNumber)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if containsToken(token, in: profile.keywords) {
                    rendered += "\(palette.syntaxKeyword)\(token)\(reset)"
                } else if containsToken(token, in: profile.types) {
                    rendered += "\(palette.syntaxType)\(token)\(reset)"
                } else if containsToken(token, in: profile.constants) {
                    rendered += "\(palette.syntaxNumber)\(token)\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(palette.syntaxFunction)\(token)\(reset)"
                } else {
                    rendered += token
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    static func renderDataLine(
        _ line: String,
        language: String?,
        palette: TerminalMarkdownPalette,
        syntaxColors: DataSyntaxColors? = nil
    ) -> String {
        let propertyColor = syntaxColors?.property ?? palette.syntaxProperty
        let stringColor = syntaxColors?.string ?? palette.syntaxString
        let commentColor = syntaxColors?.comment ?? palette.syntaxComment
        let numberColor = syntaxColors?.number ?? palette.syntaxNumber
        let comments: [String] = {
            switch language {
            case "json":
                return []
            case "jsonc":
                return ["//"]
            default:
                return ["#"]
            }
        }()

        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if matchingPrefix(in: line, at: index, prefixes: comments) != nil {
                rendered += "\(commentColor)\(line[index...])\(reset)"
                break
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                let token = String(line[index..<stringEnd])
                if isObjectKey(in: line, after: stringEnd) {
                    rendered += "\(propertyColor)\(token)\(reset)"
                } else {
                    rendered += "\(stringColor)\(token)\(reset)"
                }
                index = stringEnd
                continue
            }

            if line[index].isNumber || line[index] == "-" {
                let end = consumeNumber(in: line, from: index)
                if end > index {
                    rendered += "\(numberColor)\(line[index..<end])\(reset)"
                    index = end
                    continue
                }
            }

            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if ["false", "null", "true"].contains(token.lowercased()) {
                    rendered += "\(numberColor)\(token)\(reset)"
                } else if isObjectKey(in: line, after: end) {
                    rendered += "\(propertyColor)\(token)\(reset)"
                } else {
                    rendered += token
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    static func renderMarkupLine(
        _ line: String,
        palette: TerminalMarkdownPalette
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if hasPrefix("<!--", in: line, at: index) {
                let end = endOfDelimitedSegment(
                    in: line,
                    from: index,
                    closing: "-->"
                )
                rendered += "\(palette.syntaxComment)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index] == "<" {
                rendered.append("<")
                index = line.index(after: index)

                if index < line.endIndex, line[index] == "/" {
                    rendered.append("/")
                    index = line.index(after: index)
                }

                let tagEnd = consumeIdentifier(in: line, from: index)
                if tagEnd > index {
                    rendered += "\(palette.syntaxKeyword)\(line[index..<tagEnd])\(reset)"
                    index = tagEnd
                    continue
                }
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(palette.syntaxString)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if isIdentifierStart(line[index]), isMarkupAttribute(in: line, after: index) {
                let end = consumeIdentifier(in: line, from: index)
                rendered += "\(palette.syntaxAttribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    static func renderCSSLine(
        _ line: String,
        palette: TerminalMarkdownPalette
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(palette.syntaxComment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(palette.syntaxString)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if line[index] == "@" {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(palette.syntaxAttribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index] == "#",
               let end = cssColorEnd(in: line, from: index) {
                rendered += "\(palette.syntaxNumber)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(palette.syntaxNumber)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if isIdentifierStart(line[index]) {
                let end = consumeCSSIdentifier(in: line, from: index)
                if isObjectKey(in: line, after: end) {
                    rendered += "\(palette.syntaxProperty)\(line[index..<end])\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(palette.syntaxFunction)\(line[index..<end])\(reset)"
                } else {
                    rendered += "\(palette.syntaxType)\(line[index..<end])\(reset)"
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }
}
