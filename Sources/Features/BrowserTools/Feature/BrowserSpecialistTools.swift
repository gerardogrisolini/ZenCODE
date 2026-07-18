//
//  BrowserSpecialistTools.swift
//  BrowserToolsFeature
//
//  Carefully bounded specialist CDP capabilities: printable artifacts,
//  performance metrics, and a fail-closed download policy.
//

import FeatureKit
import Foundation

enum BrowserSpecialistError: LocalizedError, Equatable {
    case downloadPolicyUnavailable
    case unsupportedPDFFormat(String)

    var errorDescription: String? {
        switch self {
        case .downloadPolicyUnavailable:
            "Browser could not enforce its deny-download policy on this Chrome version, so the page was not opened."
        case let .unsupportedPDFFormat(format):
            "Unsupported PDF format '\(format)'. Use a4 or letter."
        }
    }
}

enum BrowserPDFFormat: String, Codable, Sendable {
    case a4
    case letter

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return .a4
        }
        guard let format = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserSpecialistError.unsupportedPDFFormat(rawValue)
        }
        return format
    }

    var paperSize: (widthInches: Double, heightInches: Double) {
        switch self {
        case .a4:
            (8.2677, 11.6929)
        case .letter:
            (8.5, 11)
        }
    }
}

struct BrowserPDFOutput: Codable, Sendable {
    let page: BrowserPage
    let artifact: BrowserArtifact
    let format: BrowserPDFFormat
    let landscape: Bool
    let note: String

    init(
        page: BrowserPage,
        artifact: BrowserArtifact,
        format: BrowserPDFFormat,
        landscape: Bool
    ) {
        self.page = page
        self.artifact = artifact
        self.format = format
        self.landscape = landscape
        self.note = "The PDF is stored as a Browser artifact and is not embedded in the model transcript."
    }
}

struct BrowserPerformanceMetric: Codable, Hashable, Sendable {
    let name: String
    let value: Double
}

struct BrowserPerformanceOutput: Codable, Sendable {
    let page: BrowserPage
    let metrics: [BrowserPerformanceMetric]
    let note: String

    init(page: BrowserPage, metrics: [BrowserPerformanceMetric]) {
        self.page = page
        self.metrics = metrics
        self.note = "Metrics are a point-in-time Chrome Performance-domain observation for this page target."
    }
}

enum BrowserDownloadPolicy {
    static let browserMethod = "Browser.setDownloadBehavior"
    static let pageFallbackMethod = "Page.setDownloadBehavior"

    static func apply(to session: CDPSession) async throws {
        if (try? await session.send(
            method: browserMethod,
            params: ["behavior": "deny"]
        )) != nil {
            return
        }
        if (try? await session.send(
            method: pageFallbackMethod,
            params: ["behavior": "deny"]
        )) != nil {
            return
        }
        throw BrowserSpecialistError.downloadPolicyUnavailable
    }
}

enum BrowserPerformanceSnapshot {
    static let includedMetricNames = [
        "Documents",
        "Frames",
        "JSEventListeners",
        "Nodes",
        "LayoutCount",
        "RecalcStyleCount",
        "LayoutDuration",
        "RecalcStyleDuration",
        "ScriptDuration",
        "TaskDuration",
        "JSHeapUsedSize",
        "JSHeapTotalSize",
    ]

    static func parse(_ response: [String: Any]) throws -> [BrowserPerformanceMetric] {
        guard let result = response["result"] as? [String: Any],
              let rawMetrics = result["metrics"] as? [[String: Any]]
        else {
            throw CDPError.invalidResponse("Performance.getMetrics did not return metrics")
        }
        let order = Dictionary(uniqueKeysWithValues: includedMetricNames.enumerated().map {
            ($0.element, $0.offset)
        })
        let metrics = rawMetrics.compactMap { raw -> BrowserPerformanceMetric? in
            guard let name = raw["name"] as? String,
                  includedMetricNames.contains(name),
                  let value = doubleValue(raw["value"])
            else {
                return nil
            }
            return BrowserPerformanceMetric(name: name, value: value)
        }
        return metrics.sorted {
            (order[$0.name] ?? .max) < (order[$1.name] ?? .max)
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

extension CDPSession {
    func printToPDF(format: BrowserPDFFormat, landscape: Bool) async throws -> Data {
        let size = format.paperSize
        let response = try await send(
            method: "Page.printToPDF",
            params: [
                "landscape": landscape,
                "displayHeaderFooter": false,
                "printBackground": true,
                "preferCSSPageSize": false,
                "paperWidth": size.widthInches,
                "paperHeight": size.heightInches,
            ]
        )
        guard let result = response["result"] as? [String: Any],
              let encoded = result["data"] as? String,
              let pdf = Data(base64Encoded: encoded),
              !pdf.isEmpty
        else {
            throw CDPError.invalidResponse("Page.printToPDF did not return PDF data")
        }
        return pdf
    }

    func performanceMetrics() async throws -> [BrowserPerformanceMetric] {
        _ = try await send(method: "Performance.enable")
        let response = try await send(method: "Performance.getMetrics")
        return try BrowserPerformanceSnapshot.parse(response)
    }
}

private enum BrowserSpecialistPageInput {
    static func resolve(
        pageID: String?,
        pageIDSnakeCase: String?,
        id: String?
    ) -> String? {
        pageID?.nilIfBlank ?? pageIDSnakeCase?.nilIfBlank ?? id?.nilIfBlank
    }
}

struct BrowserPDFTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let format: String?
        let landscape: Bool?

        var resolvedPageID: String? {
            BrowserSpecialistPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.print_pdf"
    static let description = "Prints a persistent Browser page to a PDF artifact with a controlled A4 or Letter layout. The PDF is not embedded in the model transcript."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("format", enumValues: ["a4", "letter"], description: "Paper format. Defaults to a4."),
            .boolean("landscape", description: "Use landscape orientation. Defaults to false."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserPDFOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        let format = try BrowserPDFFormat.resolve(input.format)
        let landscape = input.landscape ?? false
        let store = BrowserArtifactStore(environment: context.environment)

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            let pdf = try await session.printToPDF(format: format, landscape: landscape)
            let artifact = try store.storePDF(pdf, pageID: tab.id)
            let page = try await session.pageMetadata(pageID: tab.id)
            return BrowserPDFOutput(
                page: page,
                artifact: artifact,
                format: format,
                landscape: landscape
            )
        }
    }
}

struct BrowserPerformanceTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?

        var resolvedPageID: String? {
            BrowserSpecialistPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.performance"
    static let description = "Returns a selected, point-in-time set of Chrome Performance-domain metrics for a persistent Browser page."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
        ],
        required: ["pageId"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserPerformanceOutput {
        guard let pageID = input.resolvedPageID else {
            throw BrowserToolsFeatureError.missingArgument("pageId")
        }
        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            let metrics = try await session.performanceMetrics()
            let page = try await session.pageMetadata(pageID: tab.id)
            return BrowserPerformanceOutput(page: page, metrics: metrics)
        }
    }
}
