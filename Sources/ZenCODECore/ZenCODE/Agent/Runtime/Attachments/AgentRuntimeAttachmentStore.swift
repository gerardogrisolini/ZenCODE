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

        switch sourceURL.pathExtension.lowercased() {
        case "apng", "avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp":
            return .image
        case "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm":
            return .video
        default:
            throw AgentRuntimeAttachmentStoreError.unsupportedFileType(sourceURL)
        }
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

    private static func fallbackMIMEType(forExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "apng":
            return "image/apng"
        case "avif":
            return "image/avif"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "jpeg", "jpg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "tif", "tiff":
            return "image/tiff"
        case "webp":
            return "image/webp"
        case "avi":
            return "video/x-msvideo"
        case "m4v":
            return "video/x-m4v"
        case "mkv":
            return "video/x-matroska"
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        case "mpeg", "mpg":
            return "video/mpeg"
        case "webm":
            return "video/webm"
        default:
            return nil
        }
    }

    private static func fallbackFilenameExtension(forContentType contentType: String) -> String {
        switch contentType.lowercased() {
        case "image/apng":
            return "apng"
        case "image/avif":
            return "avif"
        case "image/gif":
            return "gif"
        case "image/heic":
            return "heic"
        case "image/heif":
            return "heif"
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/tiff":
            return "tiff"
        case "image/webp":
            return "webp"
        case "video/mp4":
            return "mp4"
        case "video/quicktime":
            return "mov"
        case "video/webm":
            return "webm"
        default:
            return ""
        }
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
