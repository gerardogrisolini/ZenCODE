//
//  TerminalCodeBlockRenderer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation

enum TerminalCodeBlockRenderer {
    static let reset = "\u{1B}[0m"
    static let keyword = "\u{1B}[38;5;141m"
    static let type = "\u{1B}[38;5;81m"
    static let string = "\u{1B}[38;5;114m"
    static let comment = "\u{1B}[38;5;244m"
    static let number = "\u{1B}[38;5;215m"
    static let attribute = "\u{1B}[38;5;214m"
    static let function = "\u{1B}[38;5;117m"
    static let property = "\u{1B}[38;5;109m"
    
    struct SyntaxProfile {
        var keywords: Set<String>
        var types: Set<String>
        var constants: Set<String>
        var lineComments: [String]
        var attributePrefixes: Set<Character>
        var directivePrefixes: Set<Character>
        var stringDelimiters: Set<Character>
        var allowsSwiftRawStrings: Bool
        
        static let generic = SyntaxProfile(
            keywords: [
                "and", "as", "async", "await", "break", "case", "catch", "class",
                "const", "continue", "def", "default", "do", "else", "enum",
                "except", "false", "for", "func", "function", "if", "import",
                "in", "let", "nil", "null", "return", "static", "struct",
                "switch", "throw", "true", "try", "var", "while", "yield"
            ],
            types: [],
            constants: ["false", "nil", "none", "null", "true"],
            lineComments: ["//", "#"],
            attributePrefixes: ["@"],
            directivePrefixes: [],
            stringDelimiters: ["\"", "'", "`"],
            allowsSwiftRawStrings: false
        )
    }
    
    static func renderBlock(_ code: String, language: String?) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { renderLine(String($0), language: language) }
            .joined(separator: "\n")
    }
    
    static func renderLine(_ line: String, language: String?) -> String {
        switch normalizedLanguage(language) {
        case "css":
            return renderCSSLine(line)
        case "html", "xml":
            return renderMarkupLine(line)
        case "json", "jsonc", "toml", "yaml":
            return renderDataLine(line, language: normalizedLanguage(language))
        default:
            return renderProfileLine(line, profile: profile(for: normalizedLanguage(language)))
        }
    }
    
    static func normalizedLanguage(_ language: String?) -> String? {
        guard let language = language?.lowercased() else {
            return nil
        }
        switch language {
        case "bash", "sh", "shell", "zsh":
            return "shell"
        case "c++", "cc", "cpp", "cxx":
            return "cpp"
        case "c#", "csharp":
            return "csharp"
        case "dockerfile":
            return "docker"
        case "htm", "xhtml":
            return "html"
        case "javascript", "js", "jsx", "mjs":
            return "javascript"
        case "kt", "kts":
            return "kotlin"
        case "md", "markdown":
            return "markdown"
        case "objective-c", "objc":
            return "objc"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "swift", "swiftui":
            return "swift"
        case "ts", "tsx":
            return "typescript"
        case "yml":
            return "yaml"
        default:
            return language
        }
    }
    
    static func renderProfileLine(
        _ line: String,
        profile: SyntaxProfile
    ) -> String {
        var rendered = ""
        var index = line.startIndex
        
        while index < line.endIndex {
            if matchingPrefix(
                in: line,
                at: index,
                prefixes: profile.lineComments
            ) != nil {
                rendered += "\(comment)\(line[index...])\(reset)"
                break
            }
            
            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(comment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }
            
            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: profile.stringDelimiters,
                allowsSwiftRawStrings: profile.allowsSwiftRawStrings
            ) {
                rendered += "\(string)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }
            
            if profile.attributePrefixes.contains(line[index]) {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(attribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            if profile.directivePrefixes.contains(line[index]),
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)].isLetter {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(keyword)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(number)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if containsToken(token, in: profile.keywords) {
                    rendered += "\(keyword)\(token)\(reset)"
                } else if containsToken(token, in: profile.types) {
                    rendered += "\(type)\(token)\(reset)"
                } else if containsToken(token, in: profile.constants) {
                    rendered += "\(number)\(token)\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(function)\(token)\(reset)"
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
    
    static func renderDataLine(_ line: String, language: String?) -> String {
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
                rendered += "\(comment)\(line[index...])\(reset)"
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
                    rendered += "\(property)\(token)\(reset)"
                } else {
                    rendered += "\(string)\(token)\(reset)"
                }
                index = stringEnd
                continue
            }
            
            if line[index].isNumber || line[index] == "-" {
                let end = consumeNumber(in: line, from: index)
                if end > index {
                    rendered += "\(number)\(line[index..<end])\(reset)"
                    index = end
                    continue
                }
            }
            
            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if ["false", "null", "true"].contains(token.lowercased()) {
                    rendered += "\(number)\(token)\(reset)"
                } else if isObjectKey(in: line, after: end) {
                    rendered += "\(property)\(token)\(reset)"
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
    
    static func renderMarkupLine(_ line: String) -> String {
        var rendered = ""
        var index = line.startIndex
        
        while index < line.endIndex {
            if hasPrefix("<!--", in: line, at: index) {
                let end = endOfDelimitedSegment(
                    in: line,
                    from: index,
                    closing: "-->"
                )
                rendered += "\(comment)\(line[index..<end])\(reset)"
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
                    rendered += "\(keyword)\(line[index..<tagEnd])\(reset)"
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
                rendered += "\(string)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }
            
            if isIdentifierStart(line[index]), isMarkupAttribute(in: line, after: index) {
                let end = consumeIdentifier(in: line, from: index)
                rendered += "\(attribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            rendered.append(line[index])
            index = line.index(after: index)
        }
        
        return rendered
    }
    
    static func renderCSSLine(_ line: String) -> String {
        var rendered = ""
        var index = line.startIndex
        
        while index < line.endIndex {
            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(comment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }
            
            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(string)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }
            
            if line[index] == "@" {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(attribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            if line[index] == "#",
               let end = cssColorEnd(in: line, from: index) {
                rendered += "\(number)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(number)\(line[index..<end])\(reset)"
                index = end
                continue
            }
            
            if isIdentifierStart(line[index]) {
                let end = consumeCSSIdentifier(in: line, from: index)
                if isObjectKey(in: line, after: end) {
                    rendered += "\(property)\(line[index..<end])\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(function)\(line[index..<end])\(reset)"
                } else {
                    rendered += "\(type)\(line[index..<end])\(reset)"
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
