//
//  FigmaReference.swift
//  ZenCODE
//
//  Parses Figma links and explicit fileKey/nodeId arguments into the file
//  key and API node id used by the REST API.
//

import Foundation
import ToolCore

struct FigmaReference: Equatable, Sendable {
    let fileKey: String
    let nodeID: String?

    /// Combines a link with explicit arguments. Explicit `fileKey`/`nodeId`
    /// override the corresponding parts of the link. A `fileKey` that is
    /// itself a Figma link is accepted as a link.
    static func resolve(url: String?, fileKey: String?, nodeID: String?) throws -> FigmaReference {
        var linkFileKey: String?
        var linkNodeID: String?
        var explicitFileKey = fileKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank

        if let explicit = explicitFileKey, explicit.contains("/") {
            let parsed = try parse(link: explicit)
            linkFileKey = parsed.fileKey
            linkNodeID = parsed.nodeID
            explicitFileKey = nil
        }
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            let parsed = try parse(link: url)
            linkFileKey = parsed.fileKey
            linkNodeID = parsed.nodeID ?? linkNodeID
        }

        guard let resolvedFileKey = explicitFileKey ?? linkFileKey else {
            throw FigmaToolsError.missingFileReference
        }
        guard isValidFileKey(resolvedFileKey) else {
            throw FigmaToolsError.invalidReference("file key '\(resolvedFileKey)' must contain only letters and digits.")
        }

        let explicitNodeID = nodeID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let resolvedNodeID = try (explicitNodeID ?? linkNodeID).map(normalizeNodeID)
        return FigmaReference(fileKey: resolvedFileKey, nodeID: resolvedNodeID)
    }

    /// Accepts `figma.com/{design,file,proto,board,slides,deck,make,site}/<key>/...`
    /// links, including branch links (`.../<key>/branch/<branchKey>/...`,
    /// which resolve to the branch key) and links without a scheme.
    static func parse(link: String) throws -> (fileKey: String, nodeID: String?) {
        let text = link.contains("://") ? link : "https://\(link)"
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased(),
              host == "figma.com" || host.hasSuffix(".figma.com") else {
            throw FigmaToolsError.invalidReference("'\(link)' is not a figma.com link.")
        }

        let segments = components.path.split(separator: "/").map(String.init)
        let fileKinds: Set<String> = ["design", "file", "proto", "board", "slides", "deck", "make", "site", "buzz"]
        guard let kindIndex = segments.firstIndex(where: { fileKinds.contains($0.lowercased()) }),
              kindIndex + 1 < segments.count else {
            throw FigmaToolsError.invalidReference("'\(link)' does not contain a Figma file key.")
        }

        var fileKey = segments[kindIndex + 1]
        if kindIndex + 3 < segments.count, segments[kindIndex + 2].lowercased() == "branch" {
            fileKey = segments[kindIndex + 3]
        }
        guard isValidFileKey(fileKey) else {
            throw FigmaToolsError.invalidReference("'\(fileKey)' is not a valid Figma file key.")
        }

        let nodeValue = components.queryItems?
            .first(where: { $0.name.lowercased() == "node-id" || $0.name.lowercased() == "node_id" })?
            .value?
            .nilIfBlank
        return (fileKey, try nodeValue.map(normalizeNodeID))
    }

    /// Converts link-style ids (`12-34`, `I1-2;3-4`) to API ids (`12:34`,
    /// `I1:2;3:4`). Figma node ids never contain `-`, so the mapping is lossless.
    static func normalizeNodeID(_ raw: String) throws -> String {
        let decoded = (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = decoded.replacingOccurrences(of: "-", with: ":")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":;"))
        guard !normalized.isEmpty,
              normalized.count <= 256,
              normalized.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else {
            throw FigmaToolsError.invalidReference("node id '\(raw)' is not valid; use a value such as 1:2 or 1-2.")
        }
        return normalized
    }

    static func isValidFileKey(_ key: String) -> Bool {
        !key.isEmpty
            && key.count <= 128
            && key.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Canonical link back to the referenced file or node.
    var webURL: String {
        var link = "https://www.figma.com/design/\(fileKey)"
        if let nodeID {
            link += "?node-id=\(nodeID.replacingOccurrences(of: ":", with: "-"))"
        }
        return link
    }
}
