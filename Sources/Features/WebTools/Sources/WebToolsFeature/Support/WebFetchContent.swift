//  Content-type aware extraction for web.fetch: one guarded request, then
//  HTML -> Markdown/text, JSON and text as is, PDF text (PDFKit), or a short
//  explanation for anything else.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(PDFKit)
import PDFKit
#endif
import ToolCore

enum WebFetchContentKind: String, Sendable, Equatable {
    case html
    case json
    case text
    case pdf
    case binary

    var label: String {
        switch self {
        case .html: "HTML"
        case .json: "JSON"
        case .text: "text"
        case .pdf: "PDF"
        case .binary: "binary"
        }
    }
}

enum WebFetchContent {
    static let maxPDFPages = 200
    /// Single-line JSON below this size is pretty-printed.
    static let jsonPrettyPrintLimit = 256 * 1024
    /// Converted text of an HTTP error page included in the error message.
    static let errorSnippetBytes = 2_048
    /// Start of an error body that is parsed to build that snippet.
    static let errorSnippetInputBytes = 64 * 1024
    static let textSniffBytes = 4_096
    static let binaryMessage = "This content type is not text; nothing was extracted."
    static let pdfUnavailableMessage = "PDF text extraction is not available on this platform; download the file with another tool."

    // MARK: Content types

    /// Lowercased MIME essence without parameters, or nil when absent/blank.
    static func normalizedMIMEType(_ header: String?) -> String? {
        guard let header else { return nil }
        let essence = header.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let value = essence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }

    /// Documents WebKit renders as web pages (rather than as a viewer or a
    /// raw XML tree): the only main-frame types the rendered path accepts.
    static func isHTMLDocumentMIMEType(_ mimeType: String?) -> Bool {
        guard let mime = normalizedMIMEType(mimeType) else { return false }
        return mime == "text/html" || mime == "application/xhtml+xml"
    }

    /// Kind implied by a declared (normalised) MIME type; nil when the type
    /// says nothing useful and the body has to be inspected.
    static func declaredKind(_ mime: String) -> WebFetchContentKind? {
        switch mime {
        case "text/html", "application/xhtml+xml":
            return .html
        case "application/json", "text/json":
            return .json
        case "application/pdf", "application/x-pdf":
            return .pdf
        case "application/xml", "application/javascript", "application/x-javascript", "application/ecmascript",
             "application/x-www-form-urlencoded":
            return .text
        case "application/octet-stream", "binary/octet-stream", "application/unknown":
            return nil
        default:
            if mime.hasSuffix("+json") {
                return .json
            }
            if mime.hasSuffix("+xml") || mime.hasPrefix("text/") {
                return .text
            }
            if ["image/", "audio/", "video/", "font/", "model/"].contains(where: mime.hasPrefix) {
                return .binary
            }
            return nil
        }
    }

    /// The header decides; a missing or generic (`application/octet-stream`)
    /// type is sniffed from the body, and any other undeclared type is text
    /// only when the body really is UTF-8 text.
    static func contentKind(mimeType: String?, data: Data) -> WebFetchContentKind {
        guard let mime = normalizedMIMEType(mimeType) else { return sniff(data) }
        if let kind = declaredKind(mime) {
            return kind
        }
        if mime == "application/octet-stream" || mime == "binary/octet-stream" || mime == "application/unknown" {
            return sniff(data)
        }
        return looksLikeText(data) ? .text : .binary
    }

    /// `%PDF-` is a PDF, a leading `<` (`<!doctype`, `<html`, ...) is HTML,
    /// valid UTF-8 is text, anything else is binary. A UTF-8 byte order mark
    /// and leading whitespace are skipped.
    static func sniff(_ data: Data) -> WebFetchContentKind {
        let head = Array(data.prefix(1_024))
        var index = 0
        if head.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        while index < head.count, [0x20, 0x09, 0x0A, 0x0D, 0x0C].contains(head[index]) {
            index += 1
        }
        let rest = head[index...]
        if rest.starts(with: Array("%PDF-".utf8)) {
            return .pdf
        }
        if rest.first == UInt8(ascii: "<") {
            return .html
        }
        return looksLikeText(data) ? .text : .binary
    }

    /// Valid UTF-8 without NUL bytes in the first ``textSniffBytes``; a
    /// character cut by that window is ignored.
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var bytes = Array(data.prefix(textSniffBytes))
        if data.count > bytes.count {
            bytes = trimmingIncompleteUTF8Tail(bytes)
        }
        guard !bytes.contains(0) else { return false }
        return String(validating: bytes, as: UTF8.self) != nil
    }

    static func trimmingIncompleteUTF8Tail(_ bytes: [UInt8]) -> [UInt8] {
        var index = bytes.count - 1
        var steps = 0
        while index >= 0, steps < 4, !bytes[index].isUTF8ScalarStart {
            index -= 1
            steps += 1
        }
        guard index >= 0 else { return bytes }
        let lead = bytes[index]
        let expected = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return bytes.count - index < expected ? Array(bytes[..<index]) : bytes
    }

    // MARK: Documents

    /// Builds the document for a raw response held in memory. Non-2xx
    /// statuses throw; a 4xx/5xx with a textual body includes the start of
    /// its converted text in the error.
    static func document(
        data: Data,
        response: HTTPURLResponse,
        requestURL: URL,
        wasTruncated: Bool,
        options: WebFetchOptions
    ) throws -> WebFetchDocument {
        let finalURL = response.url?.absoluteString ?? requestURL.absoluteString
        let header = response.value(forHTTPHeaderField: "Content-Type")
        let mime = normalizedMIMEType(header)
        let kind = contentKind(mimeType: mime, data: data)
        try validateStatus(response, kind: kind, data: data, pageURL: URL(string: finalURL))

        let base = WebFetchDocument(
            url: finalURL,
            status: response.statusCode,
            engine: .urlSession,
            contentType: contentTypeLabel(header: header, mime: mime, kind: kind),
            body: .content("", isComplete: true)
        )
        var document: WebFetchDocument
        switch kind {
        case .html:
            document = try htmlDocument(
                html: textBody(data, response: response),
                base: base,
                preferredTitle: nil,
                options: options
            )
        case .json:
            let text = textBody(data, response: response)
            document = base
            document.body = .content(prettyPrintedJSON(text) ?? text, isComplete: true)
        case .text:
            document = base
            document.body = .content(textBody(data, response: response), isComplete: true)
        case .pdf:
            document = pdfDocument(data: data, base: base, wasTruncated: wasTruncated, options: options)
        case .binary:
            document = base
            document.extraHeaders = [.init(name: "bytes", value: "\(data.count)")]
            document.body = .message(binaryMessage)
        }
        if kind != .html, options.selector != nil {
            document.notes.append("selector is ignored for \(kind.label) content")
        }
        if wasTruncated {
            document.notes.append("response body cut at \(data.count) bytes; content may be incomplete")
        }
        return document
    }

    /// Builds the document for HTML produced by the WebKit renderer. A 4xx/5xx
    /// status throws like the raw path does, with the start of the page's text.
    static func renderedDocument(
        html: String,
        finalURL: String,
        title: String,
        status: Int?,
        mimeType: String?,
        htmlWasCut: Bool,
        blockedSubframeCount: Int,
        options: WebFetchOptions
    ) throws -> WebFetchDocument {
        if let status, status >= 400 {
            throw httpFailure(
                status: status,
                snippet: errorSnippet(html, isHTML: true, pageURL: URL(string: finalURL))
            )
        }
        let mime = normalizedMIMEType(mimeType) ?? "text/html"
        let base = WebFetchDocument(
            url: finalURL,
            status: status,
            engine: .webKit,
            contentType: "\(mime) (rendered)",
            body: .content("", isComplete: true)
        )
        var document = try htmlDocument(html: html, base: base, preferredTitle: title, options: options)
        if htmlWasCut {
            document.notes.append("rendered HTML cut at \(html.utf16.count) characters; content may be incomplete")
        }
        if blockedSubframeCount > 0 {
            document.notes.append("\(blockedSubframeCount) embedded frame(s) pointing at non-public hosts were not loaded")
        }
        return document
    }

    /// HTML as is (`format: html`) or converted with the tool options.
    static func htmlDocument(
        html: String,
        base: WebFetchDocument,
        preferredTitle: String?,
        options: WebFetchOptions
    ) throws -> WebFetchDocument {
        var document = base
        let pageURL = URL(string: base.url)
        if options.format == .html {
            let metadata = WebMarkdownConverter.metadata(html: html, baseURL: pageURL)
            document.title = preferredTitle?.nilIfBlank ?? metadata.title
            document.scope = WebFetchDocument.scopeLabel(.fullPage)
            document.description = metadata.description
            document.body = .content(html, isComplete: true)
            if options.ignoresScopeForHTML {
                document.notes.append("selector/mainContentOnly are ignored with format html")
            }
            return document
        }
        let conversion = try WebMarkdownConverter.convert(html: html, options: options.markdownOptions(pageURL: pageURL))
        if html.utf8.count > WebHTMLParser.defaultMaxInputBytes {
            document.notes.append("HTML longer than 8 MiB; the remainder was ignored")
        }
        document.title = preferredTitle?.nilIfBlank ?? conversion.title
        document.scope = WebFetchDocument.scopeLabel(conversion.scope)
        document.description = conversion.description
        document.body = .content(conversion.content, isComplete: true)
        document.links = options.includeLinks ? conversion.links : []
        return document
    }

    /// The header value as received, plus what sniffing found when the
    /// header was missing or generic.
    static func contentTypeLabel(header: String?, mime: String?, kind: WebFetchContentKind) -> String {
        guard let header = header?.nilIfBlank, let mime else {
            return "(not specified; sniffed as \(kind.label))"
        }
        if declaredKind(mime) == nil {
            return "\(header) (sniffed as \(kind.label))"
        }
        return header
    }

    static func textBody(_ data: Data, response: HTTPURLResponse?) -> String {
        var text = WebToolsSupport.decodeBody(data, response: response)
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }

    // MARK: HTTP errors

    static func validateStatus(_ response: HTTPURLResponse, kind: WebFetchContentKind, data: Data, pageURL: URL?) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        if status >= 400, kind == .html || kind == .json || kind == .text {
            let snippet = errorSnippet(textBody(data, response: response), isHTML: kind == .html, pageURL: pageURL)
            if !snippet.isEmpty {
                throw httpFailure(status: status, snippet: snippet)
            }
        }
        try WebToolsSupport.validateHTTPResponse(response)
    }

    /// The error both fetch paths throw for a failed request; the response
    /// text is included when there is any.
    static func httpFailure(status: Int, snippet: String) -> WebToolsFeatureError {
        let message = "The web request failed with HTTP status \(status)."
        return .permissionDenied(snippet.isEmpty ? message : "\(message) Response text: \(snippet)")
    }

    /// First ``errorSnippetBytes`` of the body's text on one line; only the
    /// first ``errorSnippetInputBytes`` of the body are parsed.
    static func errorSnippet(_ body: String, isHTML: Bool, pageURL: URL?) -> String {
        var text = WebFetchTool.truncated(body, toBytes: errorSnippetInputBytes)
        if isHTML {
            var options = WebMarkdownOptions(baseURL: pageURL)
            options.includeLinks = false
            options.format = .text
            text = (try? WebMarkdownConverter.convert(html: body, options: options).content) ?? ""
        }
        let line = WebMarkdownRenderer.collapsedText(text)
        let cut = WebFetchTool.truncated(line, toBytes: errorSnippetBytes)
        return cut.utf8.count < line.utf8.count ? cut + "…" : cut
    }

    // MARK: JSON

    /// Re-indents single-line (minified) JSON below ``jsonPrettyPrintLimit``,
    /// preserving key order; returns nil for anything else (already
    /// formatted, too large, scalars, invalid).
    static func prettyPrintedJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.utf8.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              trimmed.utf8.count < jsonPrettyPrintLimit,
              !trimmed.contains(where: \.isNewline),
              (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil else {
            return nil
        }
        let bytes = Array(trimmed.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        var depth = 0
        var inString = false
        var escaped = false
        func newline() {
            output.append(0x0A)
            output.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if inString {
                output.append(byte)
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
                output.append(byte)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var next = index
                while next < bytes.count, WebMarkdownRenderer.isHTMLWhitespace(bytes[next]) {
                    next += 1
                }
                let closer = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                if next < bytes.count, bytes[next] == closer {
                    output.append(byte)
                    output.append(closer)
                    index = next + 1
                } else {
                    output.append(byte)
                    depth += 1
                    newline()
                }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth = max(0, depth - 1)
                newline()
                output.append(byte)
            case UInt8(ascii: ","):
                output.append(byte)
                newline()
            case UInt8(ascii: ":"):
                output.append(byte)
                output.append(0x20)
            case 0x20, 0x09, 0x0A, 0x0D:
                break
            default:
                output.append(byte)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: PDF

    static func pdfDocument(data: Data, base: WebFetchDocument, wasTruncated: Bool, options: WebFetchOptions) -> WebFetchDocument {
        var document = base
        document.extraHeaders = [.init(name: "bytes", value: "\(data.count)")]
        #if canImport(PDFKit)
        // Extraction stops once the requested window is covered, so a long
        // PDF read page by page is never extracted in full on every call.
        let budget = options.offset + options.maxBytes
        switch extractPDFText(data, budget: budget) {
        case .unreadable:
            document.body = .message(
                "The PDF could not be parsed" + (wasTruncated ? " (the download was cut)" : "") + "; nothing was extracted."
            )
        case .locked:
            document.body = .message("The PDF is encrypted; nothing was extracted.")
        case let .text(text, extractedPages, pageCount, title):
            document.title = title
            document.extraHeaders.append(.init(name: "pages", value: "\(extractedPages) of \(pageCount)"))
            if extractedPages < pageCount, extractedPages >= maxPDFPages {
                document.notes.append("text extracted from the first \(maxPDFPages) pages only")
            }
            document.body = .content(text, isComplete: extractedPages >= min(pageCount, maxPDFPages))
        }
        #else
        document.body = .message(pdfUnavailableMessage)
        #endif
        return document
    }

    #if canImport(PDFKit)
    enum PDFExtraction: Equatable {
        case unreadable
        case locked
        case text(String, extractedPages: Int, pageCount: Int, title: String?)
    }

    /// Text of the first pages (at most ``maxPDFPages``), stopping once more
    /// than `budget` bytes were extracted. Pages are joined with
    /// `--- page N ---` separators.
    static func extractPDFText(_ data: Data, budget: Int, maxPages: Int = maxPDFPages) -> PDFExtraction {
        guard let document = PDFDocument(data: data) else { return .unreadable }
        guard !document.isLocked else { return .locked }
        let pageCount = document.pageCount
        var text = ""
        var size = 0
        var extracted = 0
        for index in 0..<min(pageCount, maxPages) {
            guard size <= budget else { break }
            var pageText = document.page(at: index)?.string ?? ""
            while let last = pageText.last, last.isWhitespace {
                pageText.removeLast()
            }
            let piece = index == 0 ? pageText : "\n\n--- page \(index + 1) ---\n\n" + pageText
            text += piece
            size += piece.utf8.count
            extracted += 1
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfBlank
        return .text(text, extractedPages: extracted, pageCount: pageCount, title: title)
    }
    #endif
}

extension WebToolsSupport {
    /// The raw `web.fetch` path: exactly one request for the document,
    /// through the guarded session (every redirect hop is policy-checked and
    /// the redirect cap applies), never reading more than
    /// ``WebFetchOptions/downloadLimit`` bytes of body.
    static func rawFetchDocument(
        url: URL,
        options: WebFetchOptions,
        timeout: TimeInterval,
        policy: WebNetworkRequestPolicy
    ) async throws -> WebFetchDocument {
        try policy.validateRequestURL(url.absoluteString)

        let session = makeBoundedSession(policy: policy, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let result = try await loadBounded(
            makeRequest(url: url, timeout: timeout),
            session: session,
            maxBytes: WebFetchOptions.downloadLimit
        )
        return try WebFetchContent.document(
            data: result.data,
            response: result.response,
            requestURL: url,
            wasTruncated: result.wasTruncated,
            options: options
        )
    }
}
