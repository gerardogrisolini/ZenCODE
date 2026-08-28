//
//  TerminalTelegramInboundAttachments.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Selective, bounded ingress for Telegram documents and photos.
///
/// Telegram sends many media kinds; ZenCODE accepts exactly two — documents
/// and photos — and only with an allowlisted MIME type and a size inside the
/// download budget. Everything else is refused before any byte is requested
/// from the network. The refusal is visible to the operator (a short system
/// message) so a rejected file does not look like a lost message.
public struct TerminalTelegramInboundAttachment: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case document
        case photo
    }

    /// Telegram file identifier (opaque).
    public let fileID: String
    public let fileUniqueID: String?
    public let kind: Kind
    /// Server-declared MIME type (documents only).
    public let mimeType: String?
    public let fileSize: Int?
    public let fileName: String?
    public let messageID: Int

    public init(
        fileID: String,
        fileUniqueID: String?,
        kind: Kind,
        mimeType: String?,
        fileSize: Int?,
        fileName: String?,
        messageID: Int
    ) {
        self.fileID = fileID
        self.fileUniqueID = fileUniqueID
        self.kind = kind
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.fileName = fileName
        self.messageID = messageID
    }
}

/// Ingress gate: the single authority for which attachments may be received.
public enum TerminalTelegramInboundAttachmentGate {
    /// Documents: text-oriented working files the agent can be asked to read.
    public static let allowedDocumentMIMETypes: Set<String> = [
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
        "application/yaml",
        "text/yaml",
        "application/x-yaml",
        "application/pdf",
        "text/x-diff",
        "application/x-patch",
        "application/rtf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.oasis.opendocument.text",
    ]
    /// Images (photos are always JPEG on Telegram; documents may carry them).
    public static let allowedImageMIMETypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
    ]
    /// Bot API download budget for bots.
    public static let maximumDownloadBytes = 20 * 1_024 * 1_024
    /// Filename characters that never survive sanitization.
    static let forbiddenFilenameCharacters = Set("/\\:\0")

    /// Normalized MIME type or `nil` when the raw value is unusable.
    static func normalizedMIMEType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty,
              let slash = trimmed.firstIndex(of: "/"),
              slash != trimmed.startIndex,
              slash != trimmed.index(before: trimmed.endIndex) else {
            return nil
        }
        // Strip parameters the server may append.
        let cutoff = trimmed.firstIndex { $0 == ";" || $0.isWhitespace } ?? trimmed.endIndex
        return String(trimmed[..<cutoff])
    }

    /// Decides whether the attachment may be received. Returns a normalized
    /// snapshot on acceptance or a refusal reason the caller can show.
    public static func admit(
        _ attachment: TerminalTelegramInboundAttachment
    ) -> Result<TerminalTelegramInboundAttachment, Refusal> {
        // Opaque Telegram identifiers are bounded: an absurd file_id is not a
        // download attempt, it is hostile input.
        guard attachment.fileID.utf8.count <= 256,
              !attachment.fileID.isEmpty else {
            return .failure(.invalidIdentifier)
        }
        if let size = attachment.fileSize {
            guard size >= 0, size <= maximumDownloadBytes else {
                return .failure(.tooLarge(limit: maximumDownloadBytes))
            }
        }
        switch attachment.kind {
        case .document:
            let mime = normalizedMIMEType(attachment.mimeType)
            guard let mime, allowedDocumentMIMETypes.contains(mime) else {
                return .failure(.unsupportedMIMEType(
                    normalizedMIMEType(attachment.mimeType)
                ))
            }
        case .photo:
            // Photos have no MIME type on the wire; size was already checked.
            break
        }
        return .success(
            TerminalTelegramInboundAttachment(
                fileID: attachment.fileID,
                fileUniqueID: attachment.fileUniqueID,
                kind: attachment.kind,
                mimeType: normalizedMIMEType(attachment.mimeType),
                fileSize: attachment.fileSize,
                fileName: attachment.fileName.map(sanitizedFilename),
                messageID: attachment.messageID
            )
        )
    }

    /// A single safe path component, fit for a temporary file name.
    public static func sanitizedFilename(_ raw: String) -> String {
        // Reduce to the basename first, then drop separators and NULs so the
        // result can never re-introduce a directory structure. An empty or
        // whitespace-only raw value is handled before the basename: an empty
        // URL means "current directory", not "no name".
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return "attachment" }
        var candidate = URL(fileURLWithPath: trimmedRaw).lastPathComponent
        candidate = String(String.UnicodeScalarView(
            candidate.unicodeScalars.map { scalar in
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    return " "
                }
                return scalar
            }
        ))
        candidate = String.UnicodeScalarView(
            candidate.unicodeScalars.filter { scalar in
                !forbiddenFilenameCharacters.contains(Character(scalar))
            }
        ).description
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            candidate = "attachment"
        }
        if candidate.utf8.count > 128 {
            candidate = String(candidate.prefix(96))
        }
        return candidate
    }

    public enum Refusal: Equatable, Sendable, Error {
        case tooLarge(limit: Int)
        case unsupportedMIMEType(String?)
        case invalidIdentifier

        var operatorMessage: String {
            switch self {
            case let .tooLarge(limit):
                return "ZenCODE message: that file exceeds the \(limit / 1_024 / 1_024) MB Telegram download limit and was not received."
            case let .unsupportedMIMEType(mime):
                let shown = mime ?? "unknown type"
                return "ZenCODE message: \(shown) files are not accepted. Allowed: text, markdown, csv, json, yaml, pdf, rtf, word, odt and images."
            case .invalidIdentifier:
                return "ZenCODE message: that attachment could not be identified and was not received."
            }
        }
    }
}

/// Bounded receiver that materializes admitted attachments as private
/// temporaries and removes them deterministically.
public actor TerminalTelegramInboundAttachmentStore {
    /// At most this many received-but-unconsumed temporaries per chat. A
    /// burst of uploads cannot pin unbounded disk.
    public static let maximumStoredPerChat = 8
    /// At most this many concurrent downloads.
    public static let maximumConcurrentDownloads = 2

    struct StoredAttachment: Sendable {
        let url: URL
        let filename: String
        let mimeType: String
        let receivedAt: Date
    }

    private var stored: [Int64: [String: StoredAttachment]] = [:]
    private var activeDownloads = 0
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
    }

    /// Downloads an admitted attachment into a 0600 temporary under the
    /// system temporary directory. Failures clean the partial file, release
    /// the concurrency slot and throw; nothing is left behind.
    func receive(
        _ attachment: TerminalTelegramInboundAttachment,
        chatID: Int64,
        client: TerminalTelegramAPIClient,
        validateBeforeDownload: @Sendable () async throws -> Void = {}
    ) async throws -> StoredAttachment {
        guard activeDownloads < Self.maximumConcurrentDownloads else {
            throw TerminalTelegramControlError.attachmentStoreBusy
        }
        activeDownloads += 1
        defer { activeDownloads -= 1 }

        let downloaded = try await client.downloadFile(
            fileID: attachment.fileID,
            validateBeforeDownload: validateBeforeDownload
        )
        if downloaded.data.count > TerminalTelegramInboundAttachmentGate.maximumDownloadBytes {
            throw TerminalTelegramControlError.fileTooLarge(
                limit: TerminalTelegramInboundAttachmentGate.maximumDownloadBytes
            )
        }
        let filename = attachment.fileName
            ?? "telegram-\(attachment.kind.rawValue)-\(attachment.messageID)"
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-inbound", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let destination = directory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        let created = fileManager.createFile(
            atPath: destination.path,
            contents: downloaded.data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        )
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }
        let record = StoredAttachment(
            url: destination,
            filename: filename,
            mimeType: attachment.mimeType ?? "application/octet-stream",
            receivedAt: now()
        )
        // Re-read actor state after the suspension above. A snapshot captured
        // before download would overwrite records committed by a concurrent
        // receive while this actor was re-entrant.
        var chatAttachments = stored[chatID] ?? [:]
        if let replaced = chatAttachments[filename] {
            try? fileManager.removeItem(at: replaced.url)
        }
        chatAttachments[filename] = record
        if chatAttachments.count > Self.maximumStoredPerChat {
            let overflow = chatAttachments.count - Self.maximumStoredPerChat
            let oldest = chatAttachments
                .sorted { $0.value.receivedAt < $1.value.receivedAt }
                .prefix(overflow)
            for (key, removed) in oldest {
                try? fileManager.removeItem(at: removed.url)
                chatAttachments.removeValue(forKey: key)
            }
        }
        stored[chatID] = chatAttachments
        return record
    }

    /// Removes one stored attachment. Idempotent.
    func discard(filename: String, chatID: Int64) {
        guard var chatAttachments = stored[chatID],
              let record = chatAttachments.removeValue(forKey: filename) else {
            return
        }
        try? fileManager.removeItem(at: record.url)
        stored[chatID] = chatAttachments.isEmpty ? nil : chatAttachments
    }

    /// Deterministic teardown: removes every stored temporary for a chat
    /// (or every chat when `chatID` is nil) and returns how many files were
    /// deleted. Called on `stop()`, unbind and session teardown.
    @discardableResult
    func cleanup(chatID: Int64? = nil) -> Int {
        var removed = 0
        let targets = chatID.map { [$0] } ?? Array(stored.keys)
        for chat in targets {
            guard let chatAttachments = stored.removeValue(forKey: chat) else {
                continue
            }
            for (_, record) in chatAttachments {
                try? fileManager.removeItem(at: record.url)
                removed += 1
            }
        }
        return removed
    }

    /// Number of received-but-unconsumed temporaries for a chat.
    func storedCount(chatID: Int64) -> Int {
        stored[chatID]?.count ?? 0
    }

    func storedFilenames(chatID: Int64) -> [String] {
        Array((stored[chatID]?.keys ?? [:].keys)).sorted()
    }
}
