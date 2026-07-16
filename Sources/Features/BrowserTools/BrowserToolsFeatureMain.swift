//
//  BrowserToolsFeatureMain.swift
//  BrowserTools
//
//  Created by Gerardo Grisolini on 03/06/26.
//
//  A browser-based web feature that uses a real Chrome/Chromium instance via
//  the Chrome DevTools Protocol. Provides the same capabilities as ds4_web:
//  Google search and page visit, both returning extracted markdown.
//

import FeatureKit
import Foundation
import ToolCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

private enum BrowserToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case browserError(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            "Missing required argument: \(argument)"
        case let .browserError(message):
            message
        }
    }
}

// MARK: - browser.google_search

/// Searches Google using a real Chrome browser and returns the visible results
/// as markdown. Mirrors `ds4_web_google_search`.
struct BrowserGoogleSearchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let query: String?
    }

    static let name = "browser.google_search"
    static let description = """
    Searches Google using a real Chrome browser and returns visible links \
    plus a text snapshot as markdown. A visible Chrome window is launched on \
    first use.
    """
    static let inputSchema = buildInputSchema(
        [.string("query")],
        required: ["query"]
    )

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let query = input.query?.nilIfBlank else {
            throw BrowserToolsFeatureError.missingArgument("query")
        }

        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let googleURL = components.url?.absoluteString else {
            throw BrowserToolsFeatureError.browserError("Unable to build Google search URL")
        }

        return try await BrowserToolsRunner.runInTab(url: googleURL) { session in
            try await session.clickGoogleConsentIfNeeded()
            return try await session.extractSearchResults()
        }
    }
}

// MARK: - browser.visit_page

/// Visits a page in a real Chrome browser, waits for dynamic content to load,
/// and returns the rendered content as markdown. Mirrors `ds4_web_visit_page`.
struct BrowserVisitPageTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let url: String?
    }

    static let name = "browser.visit_page"
    static let description = """
    Visits a page in a real Chrome browser, scrolls to load dynamic content, \
    and returns the rendered content as markdown. A visible Chrome window is \
    launched on first use.
    """
    static let inputSchema = buildInputSchema(
        [.string("url")],
        required: ["url"]
    )

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let rawURL = input.url?.nilIfBlank else {
            throw BrowserToolsFeatureError.missingArgument("url")
        }
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else {
            throw BrowserToolsFeatureError.browserError(
                "Invalid URL or unsupported scheme: \(rawURL). Only http and https are supported."
            )
        }

        return try await BrowserToolsRunner.runInTab(url: url.absoluteString) { session in
            try await session.clickGoogleConsentIfNeeded()
            try await session.scrollDynamicPage()
            return try await session.extractPageContent()
        }
    }
}

// MARK: - Shared browser runner

/// Coordinates the Chrome lifecycle and per-call tab management. Each tool
/// invocation opens a fresh background tab, runs the extraction closure, and
/// closes the tab when done — even on error or cancellation. The Chrome
/// instance itself persists across calls.
enum BrowserToolsRunner {
    /// Ensures Chrome is running, opens a tab, navigates to `url`, and invokes
    /// `body` with a connected CDP session.
    ///
    /// - Parameters:
    ///   - url: The URL to navigate to.
    ///   - body: Closure that receives the prepared CDP session and returns
    ///     extracted markdown.
    static func runInTab(
        url: String,
        body: (CDPSession) async throws -> String
    ) async throws -> String {
        let browser = ChromeBrowserManager()

        do {
            try await browser.ensureRunning()
            let tab = try await browser.createTab()

            do {
                let session = CDPSession(webSocketURL: tab.webSocketDebuggerURL)
                session.connect()
                defer { session.disconnect() }

                try await session.preparePage()
                try await session.navigate(to: url)

                let result = try await body(session)

                // Close the tab on the success path.
                await browser.closeTab(id: tab.id)
                return result
            } catch {
                // Guarantee tab cleanup on any error path, including
                // cancellation. Use an uncancellable task so cleanup survives
                // cooperative cancellation.
                let tabID = tab.id
                let browserRef = browser
                await Task { @Sendable in
                    await browserRef.closeTab(id: tabID)
                }.value
                throw error
            }
        } catch let error as CDPError {
            throw BrowserToolsFeatureError.browserError(error.localizedDescription)
        } catch let error as ChromeBrowserError {
            throw BrowserToolsFeatureError.browserError(error.localizedDescription)
        }
    }
}

// MARK: - Entry point

@main
struct BrowserToolsFeatureMain {
    static func main() async {
        await FeatureRunner.run([
            AnyFeatureTool(BrowserGoogleSearchTool()),
            AnyFeatureTool(BrowserVisitPageTool()),
        ])
    }
}
