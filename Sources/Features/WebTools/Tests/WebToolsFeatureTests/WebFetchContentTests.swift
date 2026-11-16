import FeatureKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

/// In-memory fixtures for the web.fetch pipeline: no test here touches the network.
private enum FetchFixture {
    static let pageURL = URL(string: "https://example.com/docs/page.html")!

    static func input(
        format: String? = nil,
        offset: Int? = nil,
        includeLinks: Bool? = nil,
        mainContentOnly: Bool? = nil,
        selector: String? = nil,
        render: String? = nil,
        maxBytes: Int? = nil,
        timeoutSeconds: Int? = nil
    ) -> WebFetchTool.Input {
        WebFetchTool.Input(
            url: pageURL.absoluteString,
            maxBytes: maxBytes,
            timeoutSeconds: timeoutSeconds,
            format: format,
            offset: offset,
            includeLinks: includeLinks,
            mainContentOnly: mainContentOnly,
            selector: selector,
            render: render
        )
    }

    static func response(
        _ url: URL = pageURL,
        status: Int = 200,
        contentType: String?
    ) throws -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    static func document(
        _ body: String,
        contentType: String?,
        status: Int = 200,
        wasTruncated: Bool = false,
        options: WebFetchOptions = WebFetchOptions()
    ) throws -> WebFetchDocument {
        try document(Data(body.utf8), contentType: contentType, status: status, wasTruncated: wasTruncated, options: options)
    }

    static func document(
        _ data: Data,
        contentType: String?,
        status: Int = 200,
        wasTruncated: Bool = false,
        options: WebFetchOptions = WebFetchOptions()
    ) throws -> WebFetchDocument {
        try WebFetchContent.document(
            data: data,
            response: response(status: status, contentType: contentType),
            requestURL: pageURL,
            wasTruncated: wasTruncated,
            options: options
        )
    }

    static func content(of document: WebFetchDocument) -> String? {
        if case let .content(text, _) = document.body {
            return text
        }
        return nil
    }

    static func message(of document: WebFetchDocument) -> String? {
        if case let .message(text) = document.body {
            return text
        }
        return nil
    }

    /// A minimal uncompressed PDF: one Helvetica text line per page and a
    /// byte-exact cross-reference table.
    static func pdf(pages: [String]) -> Data {
        let pageNumbers = pages.indices.map { 4 + $0 * 2 }
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\(pageNumbers.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pages.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        for (index, text) in pages.enumerated() {
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> "
                    + "/Contents \(pageNumbers[index] + 1) 0 R >>"
            )
            let stream = "BT /F1 24 Tf 72 700 Td (\(text)) Tj ET"
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            let digits = String(offset)
            pdf += String(repeating: "0", count: 10 - digits.count) + digits + " 00000 n \n"
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}

/// Namespace suite so `swift test --filter WebFetchContent` selects every
/// web.fetch option, assembly, dispatch and extraction test below.
@Suite
enum WebFetchContentTests {}

extension WebFetchContentTests {
    @Suite
    struct WebFetchOptionTests {
        @Test
        func defaultsAndClamps() throws {
            let defaults = try WebFetchOptions(FetchFixture.input())
            #expect(defaults == WebFetchOptions())
            #expect(defaults.maxBytes == 120_000)
            #expect(defaults.timeout == 20)
            #expect(defaults.format == .markdown)
            #expect(defaults.render == .auto)
            #expect(defaults.offset == 0)
            #expect(defaults.includeLinks && defaults.mainContentOnly)
            #expect(defaults.selector == nil)

            #expect(try WebFetchOptions(FetchFixture.input(maxBytes: 10)).maxBytes == 1_024)
            #expect(try WebFetchOptions(FetchFixture.input(maxBytes: 5_000_000)).maxBytes == 1_000_000)
            #expect(try WebFetchOptions(FetchFixture.input(maxBytes: 4_000)).maxBytes == 4_000)
            #expect(try WebFetchOptions(FetchFixture.input(timeoutSeconds: 0)).timeout == 1)
            #expect(try WebFetchOptions(FetchFixture.input(timeoutSeconds: 500)).timeout == 120)

            let custom = try WebFetchOptions(FetchFixture.input(
                offset: 300,
                includeLinks: false,
                mainContentOnly: false,
                selector: "  h1, h2  "
            ))
            #expect(custom.offset == 300)
            #expect(!custom.includeLinks && !custom.mainContentOnly)
            #expect(custom.selector == "h1, h2")
            #expect(try WebFetchOptions(FetchFixture.input(selector: "   ")).selector == nil)
        }

        @Test
        func enumsAreCaseInsensitiveAndValidated() throws {
            #expect(try WebFetchOptions(FetchFixture.input(format: "TEXT")).format == .text)
            #expect(try WebFetchOptions(FetchFixture.input(format: " Html ")).format == .html)
            #expect(try WebFetchOptions(FetchFixture.input(format: "")).format == .markdown)
            #expect(try WebFetchOptions(FetchFixture.input(render: "Rendered")).render == .rendered)
            #expect(try WebFetchOptions(FetchFixture.input(render: "RAW")).render == .raw)

            #expect(throws: WebFetchInputError.invalidOption(name: "format", value: "xml", allowed: ["markdown", "text", "html"])) {
                try WebFetchOptions(FetchFixture.input(format: "xml"))
            }
            #expect(throws: WebFetchInputError.invalidOption(name: "render", value: "Fast", allowed: ["auto", "raw", "rendered"])) {
                try WebFetchOptions(FetchFixture.input(render: "Fast"))
            }
            #expect(WebFetchInputError.invalidOption(name: "render", value: "Fast", allowed: ["auto", "raw", "rendered"])
                .localizedDescription == "Invalid render 'Fast'. Expected one of: auto, raw, rendered.")
            #expect(throws: WebFetchInputError.negativeOffset(-1)) {
                try WebFetchOptions(FetchFixture.input(offset: -1))
            }
        }

        @Test
        func scopeOptionsAreFlaggedAsIgnoredForHTML() throws {
            #expect(try WebFetchOptions(FetchFixture.input(format: "html", selector: "main")).ignoresScopeForHTML)
            #expect(try WebFetchOptions(FetchFixture.input(format: "html", mainContentOnly: false)).ignoresScopeForHTML)
            // `mainContentOnly: true` is what happens anyway: nothing is ignored.
            #expect(try !WebFetchOptions(FetchFixture.input(format: "html", mainContentOnly: true)).ignoresScopeForHTML)
            #expect(try !WebFetchOptions(FetchFixture.input(format: "html")).ignoresScopeForHTML)
            #expect(try !WebFetchOptions(FetchFixture.input(selector: "main")).ignoresScopeForHTML)
        }

        @Test
        func unsupportedSelectorsAreRejectedWhenTheOptionsAreBuilt() async throws {
            #expect(throws: WebContentError.invalidSelector("a:hover")) {
                try WebFetchOptions(FetchFixture.input(selector: " a:hover "))
            }
            #expect(throws: WebContentError.invalidSelector("div >")) {
                try WebFetchOptions(FetchFixture.input(format: "html", selector: "div >"))
            }
            #expect(try WebFetchOptions(FetchFixture.input(selector: "article .content, h1")).selector == "article .content, h1")

            // An IP literal needs no DNS lookup, so the selector error is the
            // first failure: nothing is requested.
            let input = WebFetchTool.Input(url: "https://93.184.216.34/", maxBytes: nil, timeoutSeconds: nil, selector: "a:hover")
            await #expect(throws: WebContentError.invalidSelector("a:hover")) {
                _ = try await WebFetchTool().run(
                    input,
                    context: FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: [:])
                )
            }
        }

        @Test
        func invalidOptionsFailBeforeAnyRequest() async {
            // An IP literal needs no DNS lookup, so the URL passes the policy
            // offline and the option error is the first failure.
            let input = WebFetchTool.Input(url: "https://93.184.216.34/", maxBytes: nil, timeoutSeconds: nil, format: "pdf")
            await #expect(throws: WebFetchInputError.self) {
                _ = try await WebFetchTool().run(
                    input,
                    context: FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: [:])
                )
            }
        }

        @Test
        func inputDecodesNewFields() throws {
            let json = #"{"url":"https://example.com","format":"text","offset":5,"includeLinks":false,"#
                + #""mainContentOnly":false,"selector":"h1","render":"raw","maxBytes":2048,"timeoutSeconds":5}"#
            let input = try JSONDecoder().decode(WebFetchTool.Input.self, from: Data(json.utf8))
            let options = try WebFetchOptions(input)
            #expect(options.format == .text && options.render == .raw)
            #expect(options.offset == 5 && options.maxBytes == 2_048 && options.timeout == 5)
            #expect(!options.includeLinks && !options.mainContentOnly && options.selector == "h1")
        }

        @Test
        func schemaDescribesEveryProperty() throws {
            let schema = try #require(
                JSONSerialization.jsonObject(with: Data(WebFetchTool.inputSchema.utf8)) as? [String: Any]
            )
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            #expect(Set(properties.keys) == [
                "url", "maxBytes", "timeoutSeconds", "format", "offset", "includeLinks", "mainContentOnly", "selector", "render",
            ])
            for (name, property) in properties {
                #expect((property["description"] as? String)?.isEmpty == false, "\(name) needs a description")
            }
            #expect(properties["format"]?["enum"] as? [String] == ["markdown", "text", "html"])
            #expect(properties["render"]?["enum"] as? [String] == ["auto", "raw", "rendered"])
            #expect(schema["required"] as? [String] == ["url"])
        }
    }
}

extension WebFetchContentTests {
    @Suite
    struct WebFetchDispatchTests {
        @Test
        func htmlIsConvertedWithTheToolOptions() throws {
            let body = String(repeating: "Story text lorem ipsum dolor sit amet. ", count: 10)
            let html = "<html><head><title>Docs page</title><meta name=description content='About it'></head><body>"
                + "<nav><a href='/home'>Home page</a></nav><article><h1>Heading</h1><p>\(body)</p>"
                + "<p><a href='other.html'>Other page</a> <a href='#top'>Back to top</a></p></article></body></html>"
            let document = try FetchFixture.document(html, contentType: "text/html; charset=utf-8")

            #expect(document.engine == .urlSession)
            #expect(document.status == 200)
            #expect(document.title == "Docs page")
            #expect(document.description == "About it")
            #expect(document.contentType == "text/html; charset=utf-8")
            #expect(document.scope == "main (article)")
            let content = try #require(FetchFixture.content(of: document))
            #expect(content.hasPrefix("# Heading\n\nStory text"))
            #expect(content.hasSuffix("[Other page](https://example.com/docs/other.html) Back to top"))
            #expect(!content.contains("Home page"))
            #expect(document.links == [WebExtractedLink(text: "Other page", url: "https://example.com/docs/other.html")])

            var plain = WebFetchOptions()
            plain.format = .text
            plain.includeLinks = false
            let text = try FetchFixture.document(html, contentType: "text/html", options: plain)
            #expect(FetchFixture.content(of: text)?.hasSuffix("Other page Back to top") == true)
            #expect(text.links.isEmpty)

            var selected = WebFetchOptions()
            selected.selector = "h1"
            let heading = try FetchFixture.document(html, contentType: "text/html", options: selected)
            #expect(heading.scope == "selector h1")
            #expect(FetchFixture.content(of: heading) == "# Heading")
            selected.selector = ".missing"
            #expect(throws: WebContentError.selectorMatchedNothing(".missing")) {
                try FetchFixture.document(html, contentType: "text/html", options: selected)
            }
        }

        @Test
        func htmlFormatReturnsTheDocumentAsReceived() throws {
            var options = WebFetchOptions()
            options.format = .html
            options.selector = "p"
            options.ignoresScopeForHTML = true
            let html = "<html><head><title>T</title></head><body><p>x</p></body></html>"
            let document = try FetchFixture.document(html, contentType: nil, options: options)
            #expect(FetchFixture.content(of: document) == html)
            #expect(document.title == "T")
            #expect(document.scope == "full page")
            #expect(document.contentType == "(not specified; sniffed as HTML)")
            #expect(document.notes == ["selector/mainContentOnly are ignored with format html"])
        }

        @Test
        func jsonIsReturnedAsTextAndMinifiedJSONIsReindented() throws {
            let minified = #"{"name":"swift","tags":["a","b,c"],"nested":{"empty":{},"list":[],"quote":"x\"}y"},"n":1.5e3,"ok":true}"#
            let document = try FetchFixture.document(minified, contentType: "application/json; charset=utf-8")
            #expect(document.scope == nil)
            #expect(document.title == nil)
            #expect(FetchFixture.content(of: document) == """
            {
              "name": "swift",
              "tags": [
                "a",
                "b,c"
              ],
              "nested": {
                "empty": {},
                "list": [],
                "quote": "x\\"}y"
              },
              "n": 1.5e3,
              "ok": true
            }
            """)

            let formatted = "{\n  \"a\": 1\n}\n"
            #expect(FetchFixture.content(of: try FetchFixture.document(formatted, contentType: "application/vnd.api+json")) == formatted)
            #expect(WebFetchContent.prettyPrintedJSON("{\"a\":") == nil)
            #expect(WebFetchContent.prettyPrintedJSON("42") == nil)
            let large = "[" + Array(repeating: "1", count: 140_000).joined(separator: ",") + "]"
            #expect(large.utf8.count > WebFetchContent.jsonPrettyPrintLimit)
            #expect(WebFetchContent.prettyPrintedJSON(large) == nil)
        }

        @Test
        func textIsDecodedAndReturnedAsIs() throws {
            let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" in ISO-8859-1
            let document = try FetchFixture.document(latin1, contentType: "text/plain; charset=ISO-8859-1")
            #expect(FetchFixture.content(of: document) == "café\n")
            #expect(document.scope == nil)

            let xml = "<?xml version=\"1.0\"?><feed><title>x</title></feed>"
            #expect(FetchFixture.content(of: try FetchFixture.document(xml, contentType: "application/atom+xml")) == xml)
            let bom = try FetchFixture.document("\u{FEFF}hello", contentType: "text/plain")
            #expect(FetchFixture.content(of: bom) == "hello")

            var options = WebFetchOptions()
            options.selector = "h1"
            let ignored = try FetchFixture.document("plain", contentType: "text/plain", options: options)
            #expect(ignored.notes == ["selector is ignored for text content"])
        }

        @Test
        func binaryContentIsNotExtracted() throws {
            let document = try FetchFixture.document(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), contentType: "image/png")
            #expect(FetchFixture.message(of: document) == WebFetchContent.binaryMessage)
            #expect(document.extraHeaders == [.init(name: "bytes", value: "6")])
            #expect(document.contentType == "image/png")

            let sniffed = try FetchFixture.document(Data([0x00, 0xFF, 0xFE]), contentType: "application/octet-stream")
            #expect(sniffed.contentType == "application/octet-stream (sniffed as binary)")
            #expect(FetchFixture.message(of: sniffed) == WebFetchContent.binaryMessage)
        }

        @Test
        func truncatedDownloadsAreFlagged() throws {
            let document = try FetchFixture.document("partial text", contentType: "text/plain", wasTruncated: true)
            #expect(document.notes == ["response body cut at 12 bytes; content may be incomplete"])
        }

        @Test
        func httpErrorsCarryTheStartOfTheirText() throws {
            func failure(_ body: Data, _ contentType: String, _ status: Int) -> String {
                let error = #expect(throws: (any Error).self) {
                    try FetchFixture.document(body, contentType: contentType, status: status)
                }
                return error?.localizedDescription ?? ""
            }
            let page = "<html><body><main><h1>Not Found</h1><p>The page\n you requested does not exist.</p></main></body></html>"
            let notFound = failure(Data(page.utf8), "text/html", 404)
            #expect(notFound.hasPrefix("The web request failed with HTTP status 404. Response text: "))
            #expect(notFound.contains("Not Found The page you requested does not exist."))
            #expect(!notFound.contains("\n"))

            #expect(failure(Data(#"{"error":"rate limited"}"#.utf8), "application/json", 503)
                .contains(#"status 503. Response text: {"error":"rate limited"}"#))

            let long = failure(Data(String(repeating: "word ", count: 2_000).utf8), "text/plain", 500)
            #expect(long.hasSuffix("…"))
            #expect(long.utf8.count < WebFetchContent.errorSnippetBytes + 200)

            #expect(failure(Data([0x00, 0x01]), "image/png", 404) == "The web request failed with HTTP status 404.")
            #expect(failure(Data("moved".utf8), "text/plain", 304) == "The web request failed with HTTP status 304.")
        }

        @Test
        func renderedDocumentsUseTheConverterAndReportTheirOrigin() throws {
            let html = "<html><head><title>DOM title</title></head><body><main><p>"
                + String(repeating: "Rendered body text. ", count: 15) + "<span hidden>secret</span></p></main></body></html>"
            let document = try WebFetchContent.renderedDocument(
                html: html,
                finalURL: "https://example.com/app",
                title: "Live title",
                status: 200,
                mimeType: "application/xhtml+xml",
                htmlWasCut: true,
                blockedSubframeCount: 2,
                options: WebFetchOptions()
            )
            #expect(document.engine == .webKit)
            #expect(document.status == 200)
            #expect(document.title == "Live title")
            #expect(document.contentType == "application/xhtml+xml (rendered)")
            #expect(document.scope == "main (main)")
            #expect(FetchFixture.content(of: document)?.contains("secret") == false)
            #expect(document.notes == [
                "rendered HTML cut at \(html.utf16.count) characters; content may be incomplete",
                "2 embedded frame(s) pointing at non-public hosts were not loaded",
            ])

            let fallbackTitle = try WebFetchContent.renderedDocument(
                html: html,
                finalURL: "https://example.com/app",
                title: " ",
                status: nil,
                mimeType: nil,
                htmlWasCut: false,
                blockedSubframeCount: 0,
                options: WebFetchOptions()
            )
            #expect(fallbackTitle.title == "DOM title")
            #expect(fallbackTitle.contentType == "text/html (rendered)")
            #expect(fallbackTitle.notes.isEmpty)
        }

        @Test
        func renderedErrorPagesFailLikeTheRawPath() throws {
            let page = "<html><body><main><h1>Not Found</h1><p>The page\n you requested does not exist.</p></main></body></html>"
            func failure(status: Int?, html: String = page) -> String? {
                do {
                    _ = try WebFetchContent.renderedDocument(
                        html: html,
                        finalURL: "https://example.com/missing",
                        title: "Not Found",
                        status: status,
                        mimeType: "text/html",
                        htmlWasCut: false,
                        blockedSubframeCount: 0,
                        options: WebFetchOptions()
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }

            // The same message the raw path produces for the same page.
            let raw = #expect(throws: (any Error).self) {
                try FetchFixture.document(page, contentType: "text/html", status: 404)
            }
            let rendered = failure(status: 404)
            #expect(rendered == raw?.localizedDescription)
            #expect(rendered?.hasPrefix("The web request failed with HTTP status 404. Response text: ") == true)
            #expect(rendered?.contains("Not Found The page you requested does not exist.") == true)
            #expect(rendered?.contains("\n") == false)

            #expect(failure(status: 503, html: "") == "The web request failed with HTTP status 503.")
            let long = failure(status: 500, html: "<p>" + String(repeating: "word ", count: 2_000) + "</p>")
            #expect(long?.hasSuffix("…") == true)
            #expect((long?.utf8.count ?? .max) < WebFetchContent.errorSnippetBytes + 200)

            // Anything below 400 (or an unknown status) is rendered as usual.
            #expect(failure(status: 399) == nil)
            #expect(failure(status: 200) == nil)
            #expect(failure(status: nil) == nil)
        }

        @Test
        func errorSnippetsOnlyParseTheStartOfTheBody() {
            let tail = String(repeating: "<p>filler</p>", count: 20_000)
            let page = "<p>visible start</p>" + tail + "<p>far end marker</p>"
            let snippet = WebFetchContent.errorSnippet(page, isHTML: true, pageURL: nil)
            #expect(snippet.hasPrefix("visible start filler"))
            #expect(!snippet.contains("far end marker"))
            #expect(snippet.hasSuffix("…"))

            // The cut never splits a multi-byte character.
            let accented = String(repeating: "é", count: WebFetchContent.errorSnippetInputBytes)
            let text = WebFetchContent.errorSnippet(accented, isHTML: false, pageURL: nil)
            #expect(text.hasSuffix("é…"))
            #expect(!text.contains("\u{FFFD}"))
        }

        @Test
        func htmlLongerThanTheParserLimitIsFlagged() throws {
            let oversize = "<html><body><p>" + String(repeating: "x", count: WebHTMLParser.defaultMaxInputBytes) + "</p></body></html>"
            let note = "HTML longer than 8 MiB; the remainder was ignored"
            #expect(oversize.utf8.count > WebHTMLParser.defaultMaxInputBytes)

            let rendered = try WebFetchContent.renderedDocument(
                html: oversize,
                finalURL: "https://example.com/big",
                title: "Big",
                status: 200,
                mimeType: "text/html",
                htmlWasCut: true,
                blockedSubframeCount: 0,
                options: WebFetchOptions()
            )
            // The renderer's own cut note is kept next to it.
            #expect(rendered.notes == [note, "rendered HTML cut at \(oversize.utf16.count) characters; content may be incomplete"])
            #expect(FetchFixture.content(of: rendered)?.hasPrefix("xxxxxxxx") == true)

            let small = try FetchFixture.document("<p>small</p>", contentType: "text/html")
            #expect(small.notes.isEmpty)

            // `format: html` returns the markup itself; nothing is dropped there.
            var htmlOptions = WebFetchOptions()
            htmlOptions.format = .html
            let verbatim = try FetchFixture.document(oversize, contentType: "text/html", options: htmlOptions)
            #expect(verbatim.notes.isEmpty)
        }
    }
}

extension WebFetchContentTests {
    @Suite
    struct WebFetchPDFTests {
        #if canImport(PDFKit)
        @Test
        func pdfTextIsExtracted() throws {
            let document = try FetchFixture.document(FetchFixture.pdf(pages: ["Hello ZenCODE"]), contentType: "application/pdf")
            let text = try #require(FetchFixture.content(of: document))
            #expect(text.contains("Hello ZenCODE"))
            #expect(document.extraHeaders.contains(.init(name: "pages", value: "1 of 1")))
            #expect(document.scope == nil)

            // Sniffed from a generic type as well.
            let sniffed = try FetchFixture.document(FetchFixture.pdf(pages: ["Hello ZenCODE"]), contentType: "application/octet-stream")
            #expect(FetchFixture.content(of: sniffed)?.contains("Hello ZenCODE") == true)
            #expect(sniffed.contentType == "application/octet-stream (sniffed as PDF)")
        }

        @Test
        func pagesAreSeparatedAndExtractionStopsAtTheBudget() throws {
            let pdf = FetchFixture.pdf(pages: ["First page", "Second page", "Third page"])
            let full = try FetchFixture.document(pdf, contentType: "application/pdf")
            let text = try #require(FetchFixture.content(of: full))
            #expect(text.contains("First page\n\n--- page 2 ---\n\nSecond page\n\n--- page 3 ---\n\nThird page"))
            guard case .content(_, let isComplete) = full.body else {
                Issue.record("expected content")
                return
            }
            #expect(isComplete)

            var budget = WebFetchOptions()
            budget.maxBytes = 3
            let partial = try FetchFixture.document(pdf, contentType: "application/pdf", options: budget)
            #expect(partial.extraHeaders.contains(.init(name: "pages", value: "1 of 3")))
            guard case .content(let partialText, let partialComplete) = partial.body else {
                Issue.record("expected content")
                return
            }
            #expect(!partialComplete)
            #expect(partialText.contains("First page") && !partialText.contains("Second"))
            #expect(try WebFetchOutput.render(partial, options: budget).contains("<truncated: at least"))
        }

        @Test
        func unreadablePDFsSayWhy() throws {
            let document = try FetchFixture.document("%PDF-1.4 garbage", contentType: "application/pdf", wasTruncated: true)
            #expect(FetchFixture.message(of: document) == "The PDF could not be parsed (the download was cut); nothing was extracted.")
        }
        #else
        @Test
        func pdfExtractionIsUnavailable() throws {
            let document = try FetchFixture.document(FetchFixture.pdf(pages: ["Hello ZenCODE"]), contentType: "application/pdf")
            #expect(FetchFixture.message(of: document) == WebFetchContent.pdfUnavailableMessage)
            #expect(document.extraHeaders.contains { $0.name == "bytes" })
        }
        #endif
    }
}
