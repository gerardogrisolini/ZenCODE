import Foundation

enum WebContentError: LocalizedError, Equatable, Sendable {
    case invalidSelector(String)
    case selectorMatchedNothing(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelector(let selector):
            "Invalid or unsupported CSS selector: \(selector). Supported: tag, *, #id, .class, [attr], "
                + "[attr=v], [attr^=v], [attr$=v], [attr*=v], [attr~=v], [attr|=v], descendant and '>' "
                + "combinators, comma-separated groups."
        case .selectorMatchedNothing(let selector):
            "CSS selector matched no elements: \(selector)"
        }
    }
}

enum WebContentFormat: String, Sendable {
    case markdown
    case text
}

struct WebExtractedLink: Sendable, Hashable {
    let text: String
    let url: String
}

struct WebMarkdownConversion: Sendable {
    enum Scope: Sendable, Equatable {
        /// The tag or role used, e.g. `"main"`, `"[role=main]"`, `"article"`.
        case mainContent(String)
        case fullPage
        case selector(String)
    }

    /// `<title>` collapsed, else the first `<h1>`, else "".
    let title: String
    /// Markdown or plain text, per ``WebMarkdownOptions/format``.
    let content: String
    let links: [WebExtractedLink]
    let scope: Scope
    /// `<meta name=description>` or `og:description`, collapsed.
    let description: String?
}

struct WebMarkdownOptions: Sendable {
    /// Resolves relative hrefs/srcs; a `<base href>` in the document overrides it.
    var baseURL: URL? = nil
    /// Address of the document itself. Links to it (ignoring the fragment),
    /// such as same-page anchors and cite notes, render as plain text and are
    /// left out of `links`. Defaults to `baseURL` when nil.
    var pageURL: URL? = nil
    /// Converts the main-content element only and strips navigation,
    /// sidebars, footers, menus and dialogs, also inside that element.
    var mainContentOnly: Bool = true
    /// When set (non-blank), `mainContentOnly` is ignored.
    var selector: String? = nil
    /// When false, `links` is empty and anchors render as plain text.
    var includeLinks: Bool = true
    var maxLinks: Int = 80
    var format: WebContentFormat = .markdown
}

/// Platform-independent HTML -> Markdown / plain-text conversion built on
/// ``WebHTMLParser``. Pure Foundation, linear time, iterative traversal.
enum WebMarkdownConverter {
    /// Minimum collapsed text length (UTF-8 bytes) for a main-content candidate.
    static let mainContentMinimumLength = 200
    /// Minimum share of the body's text for a main-content candidate.
    static let mainContentMinimumShare = 0.2

    static func convert(html: String, options: WebMarkdownOptions = .init()) throws -> WebMarkdownConversion {
        let document = WebHTMLParser.parse(html)
        let survey = WebDocumentSurvey(document: document)
        let baseURL = survey.documentBaseURL(fallback: options.baseURL)
        var renderer = WebMarkdownRenderer(
            format: options.format,
            includeLinks: options.includeLinks,
            maxLinks: options.maxLinks,
            baseURL: baseURL,
            pageURL: options.pageURL ?? options.baseURL
        )

        let scope: WebMarkdownConversion.Scope
        let selector = options.selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selector.isEmpty {
            let matches = try WebCSSSelector.select(selector, in: document)
            guard !matches.isEmpty else {
                throw WebContentError.selectorMatchedNothing(selector)
            }
            // The caller chose exact elements: nothing inside them is stripped.
            for match in matches {
                renderer.render(match, landmarks: .keep)
            }
            scope = .selector(selector)
        } else {
            let pageRoot = survey.body ?? document
            if options.mainContentOnly, let main = survey.mainContent(pageRoot: pageRoot) {
                renderer.render(main.node, landmarks: .insideMainContent)
                scope = .mainContent(main.name)
            } else {
                renderer.render(pageRoot, landmarks: options.mainContentOnly ? .fullPage : .keep)
                scope = .fullPage
            }
        }

        let metadata = survey.metadata()
        return WebMarkdownConversion(
            title: metadata.title,
            content: renderer.finish(),
            links: renderer.links,
            scope: scope,
            description: metadata.description
        )
    }

    /// Title and description only, without rendering; used when the HTML
    /// itself is returned.
    static func metadata(html: String) -> WebHTMLMetadata {
        WebDocumentSurvey(document: WebHTMLParser.parse(html)).metadata()
    }
}
