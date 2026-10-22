import Foundation
import Testing
@testable import swift_tools_feature

private func outline(_ source: String, maxEntries: Int = 100) -> [String] {
    let lines = source.components(separatedBy: .newlines)
    return SwiftToolsSupport.swiftOutlineEntries(in: lines, maxEntries: maxEntries).entries
        .map { "\($0.line) \($0.depth) \($0.kind) \($0.name)" }
}

@Suite("SwiftTools outline")
struct SwiftOutlineTests {
    @Test func declarationsAreNestedAndQualified() {
        let source = """
        import Foundation

        // MARK: - Models

        public struct Point: Equatable {
            let x: Int
            var y: Int = 0

            init(x: Int) { self.x = x }

            mutating func move(by delta: Int) {
                let local = delta // not reported: nested in a function body
            }

            enum Kind {
                case origin
                case other(Int)
            }
        }

        extension Point {
            static func zero() -> Point { Point(x: 0) }
        }

        @MainActor final class Controller {
            class func make() -> Controller { Controller() }
            subscript(index: Int) -> Int { index }
        }

        protocol Shape {
            func area() -> Double
        }
        actor Counter {
            func increment() {}
        }
        """
        #expect(outline(source) == [
            "3 0 mark - Models",
            "5 0 struct Point",
            "6 1 let Point.x",
            "7 1 var Point.y",
            "9 1 init Point.init",
            "11 1 func Point.move",
            "15 1 enum Kind",
            "16 2 case origin",
            "17 2 case other",
            "21 0 extension Point",
            "22 1 func Point.zero",
            "25 0 class Controller",
            "26 1 func Controller.make",
            "27 1 subscript Controller.subscript",
            "30 0 protocol Shape",
            "31 1 func Shape.area",
            "33 0 actor Counter",
            "34 1 func Counter.increment",
        ])
    }

    @Test func singleLineBodiesReportOnlyTheFirstDeclaration() {
        // Known limitation of the line-based scanner: one entry per line.
        #expect(outline("protocol Shape { func area() -> Double }") == ["1 0 protocol Shape"])
    }

    @Test func commentsAndStringsDoNotProduceEntriesOrUnbalanceDepth() {
        let source = """
        /* block comment with struct Fake { */
        struct Real {
            /// doc comment: func notReal()
            let text = "struct NotAType { }" // trailing func alsoNotReal()
            let brace = "}"
            let escaped = "\\"}"
            func real() {}
        }
        /*
        func inLongComment() {}
        */
        func topLevel() {}
        """
        #expect(outline(source) == [
            "2 0 struct Real",
            "4 1 let Real.text",
            "5 1 let Real.brace",
            "6 1 let Real.escaped",
            "7 1 func Real.real",
            "12 0 func topLevel",
        ])
    }

    @Test func malformedSourcesNeverCrashAndDepthNeverGoesNegative() {
        let unbalanced = """
        }}}}
        struct After {
            func f() {
        }
        func stray() {}
        """
        #expect(outline(unbalanced) == [
            "2 0 struct After",
            "3 1 func After.f",
            "5 1 func After.stray",
        ])

        let fragments = """
        struct
        func
        class func
        enum {
        case
        let
        """
        #expect(outline(fragments).isEmpty)
        #expect(outline("").isEmpty)
        #expect(outline("/* never closed").isEmpty)
    }

    @Test func entriesAreCappedAndReportedAsTruncated() {
        let source = (1 ... 10).map { "func f\($0)() {}" }.joined(separator: "\n")
        let lines = source.components(separatedBy: .newlines)
        let result = SwiftToolsSupport.swiftOutlineEntries(in: lines, maxEntries: 3)
        #expect(result.entries.count == 3)
        #expect(result.truncated)
        let complete = SwiftToolsSupport.swiftOutlineEntries(in: lines, maxEntries: 10)
        #expect(complete.entries.count == 10)
        #expect(!complete.truncated)
    }

    @Test func renderedOutlineHandlesCRLFAndRejectsNonUTF8() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-outline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let crlf = root.appendingPathComponent("CRLF.swift")
        try Data("struct A {\r\n    func f() {}\r\n}\r\n".utf8).write(to: crlf)
        let lf = root.appendingPathComponent("LF.swift")
        try Data("struct A {\n    func f() {}\n}\n".utf8).write(to: lf)
        let rendered = try SwiftToolsSupport.renderSwiftOutline(fileURL: crlf, maxSymbols: nil)
        let renderedLF = try SwiftToolsSupport.renderSwiftOutline(fileURL: lf, maxSymbols: nil)
        // CRLF line endings must yield the same line numbers as LF.
        func body(_ rendered: String) -> [String] {
            rendered.components(separatedBy: "\n").filter { !$0.hasPrefix("File: ") && !$0.hasPrefix("read_hint: ") }
        }
        #expect(body(rendered) == body(renderedLF))
        #expect(body(rendered) == ["lines: 4", "symbols: 2", "outline:", "1\t0\tstruct\tA", "2\t1\tfunc\tA.f"])

        let empty = root.appendingPathComponent("Empty.swift")
        try Data().write(to: empty)
        let emptyRendered = try SwiftToolsSupport.renderSwiftOutline(fileURL: empty, maxSymbols: nil)
        #expect(emptyRendered.contains("lines: 0\n"))
        #expect(emptyRendered.hasSuffix("outline:\n<no Swift declarations found>"))

        let binary = root.appendingPathComponent("Binary.swift")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)
        #expect(throws: SwiftToolsFeatureError.self) {
            try SwiftToolsSupport.renderSwiftOutline(fileURL: binary, maxSymbols: nil)
        }
        #expect(throws: (any Error).self) {
            try SwiftToolsSupport.renderSwiftOutline(fileURL: root.appendingPathComponent("Missing.swift"), maxSymbols: nil)
        }
    }
}
