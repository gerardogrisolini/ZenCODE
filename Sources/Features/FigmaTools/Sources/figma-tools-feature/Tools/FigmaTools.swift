//
//  FigmaTools.swift
//  ZenCODE
//
//  Figma tools backed by the Figma cloud REST API. Tool names match the
//  Figma MCP server's so existing prompts keep working without the Figma
//  desktop app.
//

import FeatureKit
import Foundation
import ToolCore

// MARK: Shared input and helpers

struct FigmaNodeInput: Decodable, Sendable {
    let url: String?
    let fileKey: String?
    let file_key: String?
    let nodeId: String?
    let node_id: String?
    let depth: JSONValue?
    let scale: JSONValue?
    let format: String?

    func reference() throws -> FigmaReference {
        try FigmaReference.resolve(
            url: url,
            fileKey: firstNonBlank(fileKey, file_key),
            nodeID: firstNonBlank(nodeId, node_id)
        )
    }

    func depthValue() throws -> Int? {
        guard let depth, depth != .null else { return nil }
        guard let value = depth.intValue, (1 ... 100).contains(value) else {
            throw FigmaToolsError.invalidArgument(name: "depth", message: "must be an integer between 1 and 100.")
        }
        return value
    }

    func scaleValue() throws -> Double {
        guard let scale, scale != .null else { return 1 }
        guard let value = scale.doubleValue, value >= 0.01, value <= 4 else {
            throw FigmaToolsError.invalidArgument(name: "scale", message: "must be a number between 0.01 and 4.")
        }
        return value
    }

    func formatValue() throws -> String {
        switch format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank ?? "png" {
        case "png": return "png"
        case "jpg", "jpeg": return "jpg"
        default:
            throw FigmaToolsError.invalidArgument(name: "format", message: "must be png or jpg.")
        }
    }
}

enum FigmaToolSupport {
    static let referenceProperties: [SchemaProperty] = [
        .string("url", description: "Figma link, for example from Copy link to selection; its node-id selects the node."),
        .string("fileKey", description: "Figma file key (the id after /design/ or /file/ in the link)."),
        .string("file_key", description: "Alias of fileKey."),
        .string("nodeId", description: "Node id such as 1:2 (the link form 1-2 is accepted)."),
        .string("node_id", description: "Alias of nodeId.")
    ]
    static let depthProperty = SchemaProperty.number(
        "depth",
        description: "Optional number of child levels to traverse (1-100)."
    )
    static let targetKeyPaths = ["url", "nodeId", "node_id", "fileKey", "file_key"]

    static func nodeHeader(
        _ title: String,
        document: JSONValue,
        file: JSONValue,
        reference: FigmaReference
    ) -> [String] {
        let type = document["type"]?.stringValue ?? "NODE"
        let name = FigmaFormat.quoted(document["name"]?.stringValue ?? "", limit: 200)
        let id = document["id"]?.stringValue ?? reference.nodeID ?? ""
        var lines = ["\(title) for \(type) \(name) [\(id)] in file \(FigmaFormat.quoted(file["name"]?.stringValue ?? reference.fileKey, limit: 200))"]
        lines.append("Link: \(reference.webURL)")
        if let lastModified = file["lastModified"]?.stringValue {
            lines.append("Last modified: \(lastModified)")
        }
        return lines
    }

    static func truncationNote(_ budget: FigmaTextBudget) -> String? {
        guard budget.isExhausted || budget.omittedNodeCount > 0 else { return nil }
        let omitted = budget.omittedNodeCount > 0 ? " \(budget.omittedNodeCount) node(s) omitted." : ""
        return "[Output truncated at \(budget.limit) characters.\(omitted) Use a child nodeId or a smaller depth.]"
    }
}

// MARK: figma.get_design_context

struct FigmaGetDesignContextTool: FeatureTool {
    typealias Input = FigmaNodeInput

    static let name = "figma.get_design_context"
    static let description = "Figma: Returns the design context of a Figma node from the Figma cloud REST API (the Figma desktop app is not needed): the layer tree with auto-layout direction, gap, padding and alignment, sizing, fills, strokes, corner radii, effects, typography, text content, component instances with their properties, and the components and styles used. Use it to implement a design in code. Pass the link copied with Copy link to selection as url, or fileKey plus nodeId. Optional depth limits the traversed child levels; large trees are truncated."
    static let inputSchema = buildInputSchema(FigmaToolSupport.referenceProperties + [FigmaToolSupport.depthProperty])
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma design", action: "Inspect", kind: .inspect, targetKeyPaths: FigmaToolSupport.targetKeyPaths)
    }

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let reference = try input.reference()
        guard let nodeID = reference.nodeID else {
            throw FigmaToolsError.missingNodeID(tool: Self.name)
        }
        let depth = try input.depthValue()
        let (file, entry) = try await FigmaSession.run(environment: context.environment) { client in
            try await client.node(key: reference.fileKey, id: nodeID, depth: depth)
        }
        let document = entry["document"] ?? .null

        var budget = FigmaTextBudget()
        for line in FigmaToolSupport.nodeHeader("Figma design context", document: document, file: file, reference: reference) {
            budget.append(line)
        }
        budget.append("Units are px; x/y are relative to the parent, sizes are width x height; colors are #RRGGBB or #RRGGBBAA.")
        budget.append("")
        FigmaDesignContextRenderer.render(entry: entry, budget: &budget)
        var output = budget.text
        if let note = FigmaToolSupport.truncationNote(budget) {
            output += "\n\(note)"
        }
        return output
    }
}

// MARK: figma.get_metadata

struct FigmaGetMetadataTool: FeatureTool {
    typealias Input = FigmaNodeInput

    static let name = "figma.get_metadata"
    static let description = "Figma: Returns a compact XML outline of a Figma node, or of a whole file, from the Figma cloud REST API: layer ids, names, types, x/y relative to the parent, and sizes. Without a node id it lists the file's pages and their top-level frames (depth 2 unless depth is given). Use it to find node ids for figma.get_design_context and figma.get_screenshot. Pass a Figma link as url, or fileKey with an optional nodeId."
    static let inputSchema = buildInputSchema(FigmaToolSupport.referenceProperties + [FigmaToolSupport.depthProperty])
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma layers", action: "Inspect", kind: .inspect, targetKeyPaths: FigmaToolSupport.targetKeyPaths)
    }

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let reference = try input.reference()
        let depth = try input.depthValue()
        var budget = FigmaTextBudget()

        if let nodeID = reference.nodeID {
            let (file, entry) = try await FigmaSession.run(environment: context.environment) { client in
                try await client.node(key: reference.fileKey, id: nodeID, depth: depth)
            }
            let document = entry["document"] ?? .null
            for line in FigmaToolSupport.nodeHeader("Figma metadata", document: document, file: file, reference: reference) {
                budget.append(line)
            }
            budget.append("")
            FigmaMetadataRenderer.render(document, parentBox: nil, budget: &budget)
        } else {
            let levels = depth ?? 2
            let file = try await FigmaSession.run(environment: context.environment) { client in
                try await client.file(key: reference.fileKey, depth: levels)
            }
            let name = FigmaFormat.quoted(file["name"]?.stringValue ?? reference.fileKey, limit: 200)
            budget.append("Figma metadata for file \(name) (depth \(levels): pages\(levels > 1 ? " and their frames" : ""))")
            budget.append("Link: \(reference.webURL)")
            if let lastModified = file["lastModified"]?.stringValue {
                budget.append("Last modified: \(lastModified)")
            }
            budget.append("")
            for page in file["document"]?["children"]?.arrayValue ?? [] {
                FigmaMetadataRenderer.render(page, parentBox: nil, budget: &budget)
            }
        }

        var output = budget.text
        if let note = FigmaToolSupport.truncationNote(budget) {
            output += "\n\(note)"
        }
        return output
    }
}

// MARK: figma.get_screenshot

struct FigmaScreenshotOutput: Encodable, Sendable, FeatureInvocationAttachmentProviding {
    let summary: String
    let path: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let scale: Double
    let link: String

    var featureInvocationAttachments: [FeatureInvocationAttachment] {
        [
            FeatureInvocationAttachment(
                path: path,
                kind: .image,
                contentType: mimeType,
                originalFilename: URL(fileURLWithPath: path).lastPathComponent
            )
        ]
    }
}

struct FigmaGetScreenshotTool: FeatureTool {
    typealias Input = FigmaNodeInput

    static let name = "figma.get_screenshot"
    static let description = "Figma: Renders a Figma node to an image through the Figma cloud REST API and attaches it to the model's multimodal context (no Figma desktop app needed). Requires a node: pass a link with node-id as url, or fileKey plus nodeId. Optional scale (0.01-4, default 1) and format (png or jpg, default png)."
    static let inputSchema = buildInputSchema(FigmaToolSupport.referenceProperties + [
        .number("scale", description: "Render scale between 0.01 and 4 (default 1)."),
        .string("format", enumValues: ["png", "jpg"], description: "Image format (default png).")
    ])
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma screenshot", action: "Render", kind: .inspect, targetKeyPaths: FigmaToolSupport.targetKeyPaths)
    }

    /// Rendered images kept in the artifact directory; older ones are pruned.
    static let retainedArtifactCount = 40

    func run(_ input: Input, context: FeatureContext) async throws -> FigmaScreenshotOutput {
        let reference = try input.reference()
        guard let nodeID = reference.nodeID else {
            throw FigmaToolsError.missingNodeID(tool: Self.name)
        }
        let scale = try input.scaleValue()
        let format = try input.formatValue()

        let data = try await FigmaSession.run(environment: context.environment) { client in
            let renderURL = try await client.renderURL(key: reference.fileKey, id: nodeID, format: format, scale: scale)
            return try await client.downloadImage(from: renderURL)
        }
        let dimensions = try Self.validateImage(data, format: format)

        let directory = try FigmaStorage.artifactDirectoryURL(environment: context.environment)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safeNodeID = nodeID.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ";", with: "_")
        let fileURL = directory.appendingPathComponent(
            "figma-\(reference.fileKey)-\(safeNodeID)-\(timestamp)-\(UUID().uuidString.prefix(8)).\(format)"
        )
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        Self.pruneArtifacts(in: directory, keeping: Self.retainedArtifactCount)

        let size = dimensions.map { "\($0.width)x\($0.height) px" } ?? "\(data.count) bytes"
        return FigmaScreenshotOutput(
            summary: "Rendered Figma node \(nodeID) of file \(reference.fileKey) at scale \(FigmaFormat.number(scale)) (\(size)); the image is attached.",
            path: fileURL.path,
            mimeType: format == "png" ? "image/png" : "image/jpeg",
            width: dimensions?.width,
            height: dimensions?.height,
            scale: scale,
            link: reference.webURL
        )
    }

    /// Confirms the payload is the requested image type; returns PNG dimensions.
    static func validateImage(_ data: Data, format: String) throws -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(24))
        if format == "png" {
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard bytes.count == 24, bytes.starts(with: signature) else {
                throw FigmaToolsError.renderFailed("the downloaded file is not a PNG image.")
            }
            func bigEndian(_ offset: Int) -> Int {
                bytes[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            }
            return (bigEndian(16), bigEndian(20))
        }
        guard bytes.starts(with: [0xFF, 0xD8, 0xFF]) else {
            throw FigmaToolsError.renderFailed("the downloaded file is not a JPEG image.")
        }
        return nil
    }

    static func pruneArtifacts(in directory: URL, keeping limit: Int) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let artifacts = urls
            .filter { $0.lastPathComponent.hasPrefix("figma-") }
            .map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in artifacts.dropFirst(limit) {
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: figma.get_variable_defs

struct FigmaGetVariableDefsTool: FeatureTool {
    typealias Input = FigmaNodeInput

    static let name = "figma.get_variable_defs"
    static let description = "Figma: Lists the variables and styles used by a Figma node and its descendants (colors, typography, effects, spacing, radii) with their values, as a JSON object of name to value, from the Figma cloud REST API. Variable names come from the Figma Variables REST API, which requires an Enterprise plan and the file_variables:read token scope; otherwise variable ids are listed with the values applied in the design. Pass a link with node-id as url, or fileKey plus nodeId."
    static let inputSchema = buildInputSchema(FigmaToolSupport.referenceProperties)
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma variables", action: "Inspect", kind: .inspect, targetKeyPaths: FigmaToolSupport.targetKeyPaths)
    }

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        let reference = try input.reference()
        guard let nodeID = reference.nodeID else {
            throw FigmaToolsError.missingNodeID(tool: Self.name)
        }
        let (file, entry, client) = try await FigmaSession.run(environment: context.environment) { client in
            let (file, entry) = try await client.node(key: reference.fileKey, id: nodeID, depth: nil)
            return (file, entry, client)
        }
        let document = entry["document"] ?? .null

        var collector = FigmaVariableCollector()
        collector.collect(document)

        // Variable names are optional (Enterprise plan, file_variables:read):
        // a refusal here only adds a note and never triggers a new sign-in.
        var variablesResponse: JSONValue?
        var variablesNote: String?
        if !collector.variables.isEmpty {
            do {
                variablesResponse = try await client.localVariables(key: reference.fileKey)
            } catch {
                let detail: String
                if case let FigmaToolsError.authenticationFailed(message) = error {
                    detail = message
                } else {
                    detail = error.localizedDescription
                }
                variablesNote = "Variable names could not be loaded (\(detail)) The Figma Variables REST API requires an Enterprise plan and a login token with the file_variables:read scope; the values shown are those applied in the design."
            }
        }

        let resolved = collector.definitions(
            stylesMetadata: entry["styles"]?.objectValue ?? [:],
            variablesResponse: variablesResponse
        )
        var lines = FigmaToolSupport.nodeHeader("Figma variables and styles", document: document, file: file, reference: reference)
        lines.append("")
        if resolved.definitions.isEmpty {
            lines.append("No variables or styles are used by this node or its descendants.")
        } else {
            lines.append(JSONValue.object(resolved.definitions.mapValues(JSONValue.string)).prettyPrinted())
        }
        if let variablesNote {
            lines.append("")
            lines.append("Note: \(variablesNote)")
        } else if resolved.unresolvedVariableCount > 0 {
            lines.append("")
            lines.append("Note: \(resolved.unresolvedVariableCount) variable(s) were not returned by the Variables API; their values are those applied in the design.")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: figma.whoami

struct FigmaWhoAmITool: FeatureTool {
    struct Input: Decodable, Sendable {}

    static let name = "figma.whoami"
    static let description = "Figma: Returns the Figma account ZenCODE is signed in with and checks the connection to the Figma cloud API. Opens the Figma sign-in page in the browser when nobody is signed in."
    static let inputSchema = buildInputSchema([])
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma account", action: "Check", kind: .inspect, includesParameters: false)
    }

    func run(_: Input, context: FeatureContext) async throws -> String {
        let me = try await FigmaSession.run(environment: context.environment) { client in
            try await client.me()
        }
        var text = "Signed in to Figma as \(me["handle"]?.stringValue ?? "unknown user")"
        if let email = me["email"]?.stringValue?.nilIfBlank {
            text += " <\(email)>"
        }
        if let id = me["id"]?.flexibleStringValue {
            text += " (user id \(id))"
        }
        return text + "."
    }
}

// MARK: figma.login

struct FigmaLoginTool: FeatureTool {
    struct Input: Decodable, Sendable {}

    static let name = "figma.login"
    static let description = "Figma: Signs in to Figma. Opens the Figma sign-in page in the user's browser, verifies the account with Figma, and stores the login used by every figma tool; it waits up to 10 minutes for the user to finish. Use it to sign in or to switch account. The other figma tools open the sign-in page by themselves when nobody is signed in."
    static let inputSchema = buildInputSchema([])
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma account", action: "Sign in", kind: .manage, includesParameters: false)
    }

    func run(_: Input, context: FeatureContext) async throws -> String {
        let store = FigmaCredentialStore(environment: context.environment)
        let credential = try await FigmaLogin.signIn(reason: .manual, store: store)
        return "Signed in to Figma as \(credential.accountLabel)."
    }
}

// MARK: figma.logout

struct FigmaLogoutTool: FeatureTool {
    struct Input: Decodable, Sendable {}

    static let name = "figma.logout"
    static let description = "Figma: Signs out of Figma by deleting the stored Figma login. The next figma tool call opens the sign-in page again. The Figma token itself stays valid until it is revoked in Figma settings."
    static let inputSchema = buildInputSchema([])
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Figma account", action: "Sign out", kind: .manage, includesParameters: false)
    }

    func run(_: Input, context: FeatureContext) async throws -> String {
        let store = FigmaCredentialStore(environment: context.environment)
        let account = FigmaSession.storedLogin(environment: context.environment)?.accountLabel
        guard try store.remove() else {
            return "ZenCODE was not signed in to Figma."
        }
        if let account {
            return "Signed out of Figma (\(account)). Revoke the token in Figma settings if it should stop working."
        }
        return "Signed out of Figma. Revoke the token in Figma settings if it should stop working."
    }
}
