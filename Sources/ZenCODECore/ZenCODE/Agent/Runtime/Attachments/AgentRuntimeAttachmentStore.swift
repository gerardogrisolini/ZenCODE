//
//  AgentRuntimeAttachmentStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public struct AgentRuntimeImportedAttachment: Sendable {
    public let kind: AgentRuntimeAttachment.Kind
    public let contentType: String?
    public let originalFilename: String
    public let payload: Data
    public let fileURL: URL

    public var runtimeAttachment: AgentRuntimeAttachment {
        AgentRuntimeAttachment(
            kind: kind,
            fileURL: fileURL,
            data: payload,
            contentType: contentType,
            originalFilename: originalFilename
        )
    }
}

public enum AgentRuntimeAttachmentStoreError: LocalizedError {
    case unsupportedFileType(URL)
    case unreadableFile(URL)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(url):
            return "Unsupported attachment type: \(url.lastPathComponent)"
        case let .unreadableFile(url):
            return "Unable to read attachment data from \(url.lastPathComponent)."
        }
    }
}

public enum AgentRuntimeAttachmentStore {
    private struct FallbackContentType {
        let extensions: Set<String>
        let mimeType: String
        let kind: AgentRuntimeAttachment.Kind
        let preferredExtension: String?
    }

    private static let fallbackContentTypes = [
        FallbackContentType(extensions: ["apng"], mimeType: "image/apng", kind: .image, preferredExtension: "apng"),
        FallbackContentType(extensions: ["avif"], mimeType: "image/avif", kind: .image, preferredExtension: "avif"),
        FallbackContentType(extensions: ["gif"], mimeType: "image/gif", kind: .image, preferredExtension: "gif"),
        FallbackContentType(extensions: ["heic"], mimeType: "image/heic", kind: .image, preferredExtension: "heic"),
        FallbackContentType(extensions: ["heif"], mimeType: "image/heif", kind: .image, preferredExtension: "heif"),
        FallbackContentType(extensions: ["jpeg", "jpg"], mimeType: "image/jpeg", kind: .image, preferredExtension: "jpg"),
        FallbackContentType(extensions: ["png"], mimeType: "image/png", kind: .image, preferredExtension: "png"),
        FallbackContentType(extensions: ["tif", "tiff"], mimeType: "image/tiff", kind: .image, preferredExtension: "tiff"),
        FallbackContentType(extensions: ["webp"], mimeType: "image/webp", kind: .image, preferredExtension: "webp"),
        FallbackContentType(extensions: ["avi"], mimeType: "video/x-msvideo", kind: .video, preferredExtension: nil),
        FallbackContentType(extensions: ["m4v"], mimeType: "video/x-m4v", kind: .video, preferredExtension: nil),
        FallbackContentType(extensions: ["mkv"], mimeType: "video/x-matroska", kind: .video, preferredExtension: nil),
        FallbackContentType(extensions: ["mov"], mimeType: "video/quicktime", kind: .video, preferredExtension: "mov"),
        FallbackContentType(extensions: ["mp4"], mimeType: "video/mp4", kind: .video, preferredExtension: "mp4"),
        FallbackContentType(extensions: ["mpeg", "mpg"], mimeType: "video/mpeg", kind: .video, preferredExtension: nil),
        FallbackContentType(extensions: ["webm"], mimeType: "video/webm", kind: .video, preferredExtension: "webm"),
    ]

    public static func importRuntimeAttachments(
        from urls: [URL]
    ) throws -> [AgentRuntimeAttachment] {
        try importFiles(from: urls).map(\.runtimeAttachment)
    }

    public static func importFiles(
        from urls: [URL]
    ) throws -> [AgentRuntimeImportedAttachment] {
        var importedAttachments: [AgentRuntimeImportedAttachment] = []
        importedAttachments.reserveCapacity(urls.count)

        for url in urls {
            importedAttachments.append(try importFile(from: url))
        }

        return importedAttachments
    }

    public static func importFile(from sourceURL: URL) throws -> AgentRuntimeImportedAttachment {
        #if os(macOS)
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        #endif

        let standardizedURL = sourceURL.standardizedFileURL
        let kind = try attachmentKind(for: standardizedURL)
        guard let payload = try? Data(contentsOf: standardizedURL) else {
            throw AgentRuntimeAttachmentStoreError.unreadableFile(standardizedURL)
        }

        let contentType = resolvedContentTypeIdentifier(for: standardizedURL)
        return AgentRuntimeImportedAttachment(
            kind: kind,
            contentType: contentType,
            originalFilename: standardizedURL.lastPathComponent,
            payload: payload,
            fileURL: standardizedURL
        )
    }

    public static func attachmentKind(
        for sourceURL: URL
    ) throws -> AgentRuntimeAttachment.Kind {
        #if canImport(UniformTypeIdentifiers)
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey])
        if let contentType = resourceValues?.contentType {
            if contentType.conforms(to: .image) {
                return .image
            }

            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return .video
            }
        }

        if let inferredType = UTType(filenameExtension: sourceURL.pathExtension.lowercased()) {
            if inferredType.conforms(to: .image) {
                return .image
            }

            if inferredType.conforms(to: .movie) || inferredType.conforms(to: .video) {
                return .video
            }
        }
        #endif

        guard let contentType = fallbackContentType(forExtension: sourceURL.pathExtension) else {
            throw AgentRuntimeAttachmentStoreError.unsupportedFileType(sourceURL)
        }
        return contentType.kind
    }

    public static func resolvedContentTypeIdentifier(for sourceURL: URL) -> String? {
        #if canImport(UniformTypeIdentifiers)
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey])
        if let identifier = resourceValues?.contentType?.identifier {
            return identifier
        }

        if let identifier = UTType(filenameExtension: sourceURL.pathExtension.lowercased())?.identifier {
            return identifier
        }
        #endif

        return fallbackMIMEType(forExtension: sourceURL.pathExtension)
    }

    public static func preferredFilenameExtension(
        originalFilename: String,
        contentType: String?
    ) -> String {
        let originalExtension = URL(fileURLWithPath: originalFilename).pathExtension
        if !originalExtension.isEmpty {
            return originalExtension
        }

        #if canImport(UniformTypeIdentifiers)
        if let contentType,
           let preferredExtension = UTType(contentType)?.preferredFilenameExtension {
            return preferredExtension
        }
        #endif

        guard let contentType else {
            return ""
        }
        return fallbackFilenameExtension(forContentType: contentType)
    }

    public static func byteCount(for attachment: AgentRuntimeAttachment) -> Int? {
        if let data = attachment.data {
            return data.count
        }

        guard let fileURL = attachment.fileURL else {
            return nil
        }
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize
    }

    private static func fallbackContentType(forExtension pathExtension: String) -> FallbackContentType? {
        fallbackContentTypes.first { $0.extensions.contains(pathExtension.lowercased()) }
    }

    private static func fallbackMIMEType(forExtension pathExtension: String) -> String? {
        fallbackContentType(forExtension: pathExtension)?.mimeType
    }

    private static func fallbackFilenameExtension(forContentType contentType: String) -> String {
        fallbackContentTypes.first {
            $0.mimeType == contentType.lowercased()
        }?.preferredExtension ?? ""
    }

}

public extension AgentRuntimeAttachment {
    init?(
        kindRawValue: String,
        fileURL: URL? = nil,
        data: Data? = nil,
        contentType: String? = nil,
        originalFilename: String
    ) {
        guard let kind = Kind(rawValue: kindRawValue) else {
            return nil
        }
        self.init(
            kind: kind,
            fileURL: fileURL,
            data: data,
            contentType: contentType,
            originalFilename: originalFilename
        )
    }
}
