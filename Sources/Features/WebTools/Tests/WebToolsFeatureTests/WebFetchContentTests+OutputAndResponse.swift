//
//  WebFetchContentTests+OutputAndResponse.swift
//  ZenCODE
//
//  Slicing, output assembly and content-type suites of the web.fetch content
//  tests, plus the WebKit response-decision suite.
//

import FeatureKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

extension WebFetchContentTests {
    @Suite
    struct WebFetchSlicingTests {
        @Test
        func offsetsMoveBackToAScalarStartAndEndsNeverSplitOne() throws {
            let content = "aé✓b" // 1 + 2 + 3 + 1 bytes
            let inside = try WebFetchOutput.slice(content, offset: 2, maxBytes: 3)
            #expect(inside == WebContentSlice(text: "é", start: 1, end: 3, total: 7))
            let next = try WebFetchOutput.slice(content, offset: inside.end, maxBytes: 3)
            #expect(next == WebContentSlice(text: "✓", start: 3, end: 6, total: 7))
            #expect(try WebFetchOutput.slice(content, offset: 4, maxBytes: 10).start == 3)
            #expect(try !WebFetchOutput.slice(content, offset: 6, maxBytes: 10).isTruncated)
            #expect(try WebFetchOutput.slice("", offset: 0, maxBytes: 10) == WebContentSlice(text: "", start: 0, end: 0, total: 0))
        }

        @Test
        func continuationReassemblesTheContent() throws {
            let content = "Grüße, 世界! e\u{301} 👩‍💻 done. " + String(repeating: "ünïcødé ", count: 20)
            for maxBytes in 4...12 {
                var pieces: [String] = []
                var offset = 0
                while true {
                    let slice = try WebFetchOutput.slice(content, offset: offset, maxBytes: maxBytes)
                    #expect(slice.text.utf8.count <= maxBytes)
                    #expect(slice.start == offset, "a returned end must be a valid next offset")
                    pieces.append(slice.text)
                    guard slice.isTruncated else { break }
                    #expect(slice.end > offset)
                    offset = slice.end
                }
                #expect(pieces.joined() == content)
            }
        }

        @Test
        func offsetPastTheEndStatesTheTotalLength() {
            #expect(throws: WebFetchInputError.offsetOutOfRange(offset: 10, length: 10)) {
                try WebFetchOutput.slice("0123456789", offset: 10, maxBytes: 5)
            }
            let message = WebFetchInputError.offsetOutOfRange(offset: 50, length: 10).localizedDescription
            #expect(message.contains("total length is 10 bytes"))
            #expect(message.contains("offset 50"))
            #expect(WebFetchInputError.offsetOutOfRange(offset: 3, length: 0).localizedDescription.contains("total length 0 bytes"))
        }
    }
}

extension WebFetchContentTests {
    @Suite
    struct WebFetchOutputAssemblyTests {
        private func document(_ content: String, links: [WebExtractedLink] = []) -> WebFetchDocument {
            WebFetchDocument(
                url: "https://example.com/a",
                status: 200,
                title: "Title",
                engine: .urlSession,
                contentType: "text/html; charset=utf-8",
                scope: "main (article)",
                description: "Summary",
                body: .content(content, isComplete: true),
                links: links
            )
        }

        @Test
        func headerContentAndLinks() throws {
            let links = [
                WebExtractedLink(text: "Next [page]", url: "https://example.com/b"),
                WebExtractedLink(text: String(repeating: "x", count: 300), url: "https://example.com/c"),
            ]
            let output = try WebFetchOutput.render(document("Hello world", links: links), options: WebFetchOptions())
            #expect(output == """
            url: https://example.com/a
            status: 200
            title: Title
            engine: URLSession (raw fetch)
            content-type: text/html; charset=utf-8
            scope: main (article)
            length: 11
            description: Summary

            Hello world

            ## Links
            - [Next \\[page\\]](https://example.com/b)
            - [\(String(repeating: "x", count: 159))…](https://example.com/c)
            """)

            var withoutLinks = WebFetchOptions()
            withoutLinks.includeLinks = false
            #expect(!(try WebFetchOutput.render(document("Hello", links: links), options: withoutLinks)).contains("## Links"))
            var html = WebFetchOptions()
            html.format = .html
            #expect(!(try WebFetchOutput.render(document("<p>Hello</p>", links: links), options: html)).contains("## Links"))
        }

        @Test
        func truncationAddsARangeAndAContinuationHint() throws {
            let links = [WebExtractedLink(text: "Next", url: "https://example.com/b")]
            var options = WebFetchOptions()
            options.maxBytes = 4

            let first = try WebFetchOutput.render(document("0123456789", links: links), options: options)
            #expect(first.contains("length: 10\nrange: 0-4\ndescription: Summary\n\n0123\n\n"
                + "<truncated: 6 bytes omitted; call again with offset=4 to continue>\n\n## Links\n- [Next](https://example.com/b)"))

            options.offset = 4
            let second = try WebFetchOutput.render(document("0123456789", links: links), options: options)
            #expect(second.hasSuffix("length: 10\nrange: 4-8\ndescription: Summary\n\n4567\n\n"
                + "<truncated: 2 bytes omitted; call again with offset=8 to continue>"))

            options.offset = 8
            let last = try WebFetchOutput.render(document("0123456789", links: links), options: options)
            #expect(last.hasSuffix("range: 8-10\ndescription: Summary\n\n89"))

            options.offset = 10
            #expect(throws: WebFetchInputError.offsetOutOfRange(offset: 10, length: 10)) {
                try WebFetchOutput.render(document("0123456789"), options: options)
            }
        }

        @Test
        func notesComeFirstAndOptionalLinesAreOmitted() throws {
            let document = WebFetchDocument(
                url: "https://example.com/data.json",
                engine: .webKit,
                contentType: "text/html (rendered)",
                body: .content("", isComplete: true),
                notes: ["first note", "second note"]
            )
            #expect(try WebFetchOutput.render(document, options: WebFetchOptions()) == """
            note: first note
            note: second note
            url: https://example.com/data.json
            engine: WebKit (rendered, JavaScript executed)
            content-type: text/html (rendered)
            length: 0

            (no content)
            """)
        }

        @Test
        func messagesAndPartialContent() throws {
            let binary = WebFetchDocument(
                url: "https://example.com/i.png",
                status: 200,
                engine: .urlSession,
                contentType: "image/png",
                body: .message(WebFetchContent.binaryMessage),
                extraHeaders: [.init(name: "bytes", value: "42")]
            )
            #expect(try WebFetchOutput.render(binary, options: WebFetchOptions()) == """
            url: https://example.com/i.png
            status: 200
            engine: URLSession (raw fetch)
            content-type: image/png
            bytes: 42

            This content type is not text; nothing was extracted.
            """)

            let partial = WebFetchDocument(
                url: "https://example.com/a.pdf",
                engine: .urlSession,
                contentType: "application/pdf",
                body: .content("abcdefgh", isComplete: false),
                extraHeaders: [.init(name: "pages", value: "1 of 9")]
            )
            var options = WebFetchOptions()
            options.maxBytes = 5
            let output = try WebFetchOutput.render(partial, options: options)
            #expect(output.contains("pages: 1 of 9\nlength: 8 (partial: extraction stopped early)\nrange: 0-5"))
            #expect(output.hasSuffix("<truncated: at least 3 bytes omitted; call again with offset=5 to continue>"))
        }

        @Test
        func scopeLabels() {
            #expect(WebFetchDocument.scopeLabel(.mainContent("article")) == "main (article)")
            #expect(WebFetchDocument.scopeLabel(.mainContent("[role=main]")) == "main (role=main)")
            #expect(WebFetchDocument.scopeLabel(.fullPage) == "full page")
            #expect(WebFetchDocument.scopeLabel(.selector("h1, h2")) == "selector h1, h2")
        }
    }
}

extension WebFetchContentTests {
    @Suite
    struct WebFetchContentTypeTests {
        @Test
        func mimeTypesAreNormalized() {
            #expect(WebFetchContent.normalizedMIMEType("Text/HTML; charset=UTF-8") == "text/html")
            #expect(WebFetchContent.normalizedMIMEType("  application/json ") == "application/json")
            #expect(WebFetchContent.normalizedMIMEType("") == nil)
            #expect(WebFetchContent.normalizedMIMEType(" ; charset=utf-8") == nil)
            #expect(WebFetchContent.normalizedMIMEType(nil) == nil)

            #expect(WebFetchContent.isHTMLDocumentMIMEType("text/html; charset=utf-8"))
            #expect(WebFetchContent.isHTMLDocumentMIMEType("Application/XHTML+XML"))
            for other in ["application/xml", "text/xml", "application/json", "text/plain", "application/pdf", nil] {
                #expect(!WebFetchContent.isHTMLDocumentMIMEType(other), "\(other ?? "nil") is not an HTML document")
            }
        }

        @Test
        func declaredTypesMapToKinds() {
            let expectations: [(String, WebFetchContentKind?)] = [
                ("text/html", .html), ("application/xhtml+xml", .html),
                ("application/json", .json), ("application/ld+json", .json), ("application/problem+json", .json),
                ("application/pdf", .pdf),
                ("text/plain", .text), ("text/css", .text), ("text/xml", .text), ("application/xml", .text),
                ("application/rss+xml", .text), ("image/svg+xml", .text), ("application/javascript", .text),
                ("application/x-www-form-urlencoded", .text),
                ("image/png", .binary), ("video/mp4", .binary), ("font/woff2", .binary),
                ("application/octet-stream", nil), ("application/zip", nil),
            ]
            for (mime, kind) in expectations {
                #expect(WebFetchContent.declaredKind(mime) == kind, "\(mime)")
            }
        }

        @Test
        func missingOrGenericTypesAreSniffed() {
            func kind(_ header: String?, _ body: String) -> WebFetchContentKind {
                WebFetchContent.contentKind(mimeType: header, data: Data(body.utf8))
            }
            #expect(kind(nil, "<!DOCTYPE html><html></html>") == .html)
            #expect(kind(nil, "\u{FEFF}\n  <html><body>x</body></html>") == .html)
            #expect(kind(nil, "<p>fragment</p>") == .html)
            #expect(kind("application/octet-stream", "%PDF-1.7\n...") == .pdf)
            #expect(kind(nil, "just some text ✓") == .text)
            #expect(kind(nil, "") == .text)
            #expect(WebFetchContent.contentKind(mimeType: nil, data: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])) == .binary)
            // The header wins over the body when it is specific.
            #expect(kind("application/json; charset=utf-8", "<html>") == .json)
            // Undeclared types are text only when the body is UTF-8 text.
            #expect(kind("application/x-yaml", "key: value\n") == .text)
            #expect(WebFetchContent.contentKind(mimeType: "application/zip", data: Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])) == .binary)
        }

        @Test
        func textSniffingToleratesACharacterCutByTheWindow() {
            var bytes = Array(String(repeating: "a", count: WebFetchContent.textSniffBytes - 1).utf8)
            bytes += Array("é".utf8) + Array("tail".utf8) // "é" straddles the window
            #expect(WebFetchContent.looksLikeText(Data(bytes)))
            #expect(!WebFetchContent.looksLikeText(Data([0x61, 0xC3])))
            #expect(!WebFetchContent.looksLikeText(Data([0x61, 0x00, 0x62])))
            #expect(WebFetchContent.trimmingIncompleteUTF8Tail(Array("ab✓".utf8).dropLast()) == Array("ab".utf8))
            #expect(WebFetchContent.trimmingIncompleteUTF8Tail(Array("ab✓".utf8)) == Array("ab✓".utf8))
        }
    }
}

#if canImport(WebKit)
extension WebFetchContentTests {
    @Suite
    struct WebKitResponseDecisionTests {
        @Test
        func onlyHTMLMainDocumentsAreRendered() {
            #expect(WebKitPageRenderer.decideResponse(mimeType: "text/html", statusCode: 200, isMainFrame: true) == .allow)
            #expect(WebKitPageRenderer.decideResponse(mimeType: "Application/XHTML+XML", statusCode: 404, isMainFrame: true) == .allow)
            #expect(WebKitPageRenderer.decideResponse(mimeType: "application/json", statusCode: 200, isMainFrame: true)
                == .cancelMainFrame(.nonHTMLContent(mimeType: "application/json", statusCode: 200)))
            #expect(WebKitPageRenderer.decideResponse(mimeType: "text/xml", statusCode: 200, isMainFrame: true)
                == .cancelMainFrame(.nonHTMLContent(mimeType: "text/xml", statusCode: 200)))
            #expect(WebKitPageRenderer.decideResponse(mimeType: "application/xml", statusCode: 200, isMainFrame: true)
                == .cancelMainFrame(.nonHTMLContent(mimeType: "application/xml", statusCode: 200)))
            #expect(WebKitPageRenderer.decideResponse(mimeType: nil, statusCode: nil, isMainFrame: true)
                == .cancelMainFrame(.nonHTMLContent(mimeType: "unknown", statusCode: nil)))
            // An unknown status is left out of the message rather than shown as "HTTP 0".
            #expect(WebRenderError.nonHTMLContent(mimeType: "unknown", statusCode: nil).errorDescription
                == "The main document is unknown, not HTML; it was not rendered in WebKit.")
            #expect(WebRenderError.nonHTMLContent(mimeType: "application/json", statusCode: 200).errorDescription
                == "The main document is application/json (HTTP 200), not HTML; it was not rendered in WebKit.")
            // Subframes are not the extracted document and always load.
            #expect(WebKitPageRenderer.decideResponse(mimeType: "application/pdf", statusCode: 200, isMainFrame: false) == .allow)
        }

        @Test
        func settleProbeIsParsedAndJudged() {
            let complete = WebKitPageRenderer.parseSettleProbe("complete|1234")
            #expect(complete.readyState == "complete" && complete.textLength == 1_234)
            let interactive = WebKitPageRenderer.parseSettleProbe("interactive|0")
            #expect(interactive.readyState == "interactive" && interactive.textLength == 0)
            let garbage = WebKitPageRenderer.parseSettleProbe("garbage")
            #expect(garbage.readyState.isEmpty && garbage.textLength == 0)

            #expect(WebKitPageRenderer.isSettled(readyState: "complete", stableChecks: 1, elapsed: 0.5))
            #expect(!WebKitPageRenderer.isSettled(readyState: "complete", stableChecks: 1, elapsed: 0.4))
            #expect(!WebKitPageRenderer.isSettled(readyState: "interactive", stableChecks: 1, elapsed: 2))
            #expect(WebKitPageRenderer.isSettled(readyState: "interactive", stableChecks: 2, elapsed: 0.8))
            #expect(!WebKitPageRenderer.isSettled(readyState: "interactive", stableChecks: 2, elapsed: 0.6))
        }

        @Test
        func extractionScriptMarksHiddenElementsAndCapsTheHTML() {
            let script = WebKitPageRenderer.extractionJS
            #expect(script.contains("querySelectorAll('*')"))
            #expect(script.contains("style.display === 'none' || style.visibility === 'hidden'"))
            #expect(!script.contains("getBoundingClientRect"))
            #expect(script.contains("const LIMIT = \(WebKitPageRenderer.maxHTMLLength);"))
            #expect(script.contains("document.documentElement"))
        }
    }
}
#endif
