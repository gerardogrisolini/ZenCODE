//
//  FeatureInvocationAttachment.swift
//  ZenCODE
//

import Foundation

/// A local media artifact produced by a feature invocation and intended for the
/// model's multimodal context. Paths cross only the local feature-process
/// boundary; the host reads and validates the file before contacting a provider.
public struct FeatureInvocationAttachment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case image
    }

    /// Absolute local path to the produced media file.
    public let path: String
    public let kind: Kind
    /// MIME type such as `image/png`.
    public let contentType: String?
    public let originalFilename: String?

    public init(
        path: String,
        kind: Kind,
        contentType: String? = nil,
        originalFilename: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.contentType = contentType
        self.originalFilename = originalFilename
    }
}

/// Adopt this protocol on a feature tool's output when the invocation creates
/// media that the model must receive as multimodal context.
public protocol FeatureInvocationAttachmentProviding: Sendable {
    var featureInvocationAttachments: [FeatureInvocationAttachment] { get }
}

/// Type-erased invocation output used by `FeatureRunner` to preserve the tool's
/// JSON output and any separately declared model-facing media attachments.
public struct AnyFeatureToolInvocationResult: Sendable {
    public let outputData: Data
    public let attachments: [FeatureInvocationAttachment]

    public init(
        outputData: Data,
        attachments: [FeatureInvocationAttachment] = []
    ) {
        self.outputData = outputData
        self.attachments = attachments
    }
}
