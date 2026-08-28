//
//  TerminalTelegramMultipart.swift
//  ZenCODE
//

import Foundation
import Crypto
import ToolCore

/// Encoded multipart/form-data payload for one Bot API upload.
///
/// The payload is bounded: a builder refuses to produce a body larger than
/// `maximumBodyBytes`, so a document that does not fit the upload budget is
/// rejected before any bytes reach the wire (or memory). The file corpus is
/// still streamed to the transport in chunks when the caller uses
/// ``TerminalTelegramMultipartBodySource``, so the encoded form never needs a
/// second whole-file copy in memory while it is being written.
struct TerminalTelegramMultipartForm: Sendable, Equatable {
    enum Part: Sendable, Equatable {
        /// A JSON-encoded `String` field. The value is never re-encoded: it is
        /// already the exact text that belongs on the wire.
        case value(name: String, value: String)
        /// One attachment, read from disk.
        case file(name: String, filename: String, contentType: String, fileURL: URL, fileSize: Int)
    }

    /// Bot API upload budget. Telegram accepts files up to 50 MB for bots
    /// (`sendDocument`) and `multipart/form-data` requests up to ~150 MB
    /// overall; ZenCODE stays far below both so a hostile or accidental large
    /// selection fails locally with a clear error instead of a partial upload.
    static let maximumUploadFileBytes = 45 * 1_024 * 1_024
    /// Upper bound for the whole encoded form, including field parts and the
    /// framing overhead. Kept below the transport's own 16 MiB collected-body
    /// guarantee *for the response*, while the request side stays bounded by
    /// this explicit budget.
    static let maximumBodyBytes = 50 * 1_024 * 1_024
    /// Chunk size used when the corpus is streamed to the transport.
    static let streamingChunkBytes = 256 * 1_024

    let boundary: String
    let parts: [Part]

    /// Total encoded length, including the closing boundary. Computing it
    /// walks only metadata and the file sizes (never file contents), so the
    /// budget can be enforced before any byte is read.
    var totalBytes: Int {
        var total = 0
        for part in parts {
            switch part {
            case let .value(name, value):
                total += Self.headerLength(
                    boundary: boundary, name: name, filename: nil, contentType: nil
                ) + value.utf8.count + Self.crlfLength
            case let .file(name, filename, contentType, _, fileSize):
                total += Self.headerLength(
                    boundary: boundary,
                    name: name,
                    filename: filename,
                    contentType: contentType
                ) + fileSize + Self.crlfLength
            }
        }
        return total + closingBoundaryLength
    }

    var closingBoundaryLength: Int {
        ("--\(boundary)--").utf8.count + Self.crlfLength
    }

    static let crlfLength = 2

    private static func headerLength(
        boundary: String,
        name: String,
        filename: String?,
        contentType: String?
    ) -> Int {
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(name)\""
        if let filename {
            header += "; filename=\"\(filename.escapingMultipartAttributeQuotes())\""
        }
        header += "\r\n"
        if let contentType {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "\r\n"
        return header.utf8.count
    }

    /// Builds a form for the given parts or throws when the encoded size
    /// would exceed the budget. Fails closed: no partial payload is produced.
    static func form(parts: [Part]) throws(TerminalTelegramControlError) -> TerminalTelegramMultipartForm {
        for part in parts {
            if case let .file(_, _, _, _, fileSize) = part,
               fileSize > maximumUploadFileBytes {
                throw .fileTooLarge(limit: maximumUploadFileBytes)
            }
        }
        let boundary = "zencode\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let form = TerminalTelegramMultipartForm(boundary: boundary, parts: parts)
        guard form.totalBytes <= maximumBodyBytes else {
            throw .payloadTooLarge(limit: maximumBodyBytes)
        }
        return form
    }

    var contentTypeHeader: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Materializes the complete form as one `Data`.
    ///
    /// Bounded: the builder already proved the total size fits the budget,
    /// and the file part is streamed from disk in chunks instead of being
    /// loaded through a whole-file `Data` API.
    func encode(expectedFileSHA256: String? = nil) throws -> Data {
        var data = Data()
        data.reserveCapacity(min(totalBytes, Self.maximumBodyBytes))
        for part in parts {
            switch part {
            case let .value(name, value):
                appendOpening(&data, name: name, filename: nil, contentType: nil)
                data.append(value.data(using: .utf8) ?? Data())
                data.append(Data("\r\n".utf8))
            case let .file(name, filename, contentType, fileURL, fileSize):
                appendOpening(&data, name: name, filename: filename, contentType: contentType)
                try appendFileContents(
                    &data, fileURL: fileURL, fileSize: fileSize,
                    expectedSHA256: expectedFileSHA256
                )
                data.append(Data("\r\n".utf8))
            }
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    private func appendOpening(
        _ data: inout Data,
        name: String,
        filename: String?,
        contentType: String?
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        var disposition = "Content-Disposition: form-data; name=\"\(name)\""
        if let filename {
            disposition += "; filename=\"\(filename.escapingMultipartAttributeQuotes())\""
        }
        data.append(Data("\(disposition)\r\n".utf8))
        if let contentType {
            data.append(Data("Content-Type: \(contentType)\r\n".utf8))
        }
        data.append(Data("\r\n".utf8))
    }

    /// Appends a file body in bounded chunks. The stream is closed on every
    /// exit path, including cancellation, so no descriptor is leaked.
    private func appendFileContents(
        _ data: inout Data,
        fileURL: URL,
        fileSize: Int,
        expectedSHA256: String?
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        var stream = TerminalTelegramBoundedFileReader(
            handle: handle,
            budgetBytes: fileSize,
            chunkBytes: Self.streamingChunkBytes
        )
        defer { stream.close() }
        var hasher = SHA256()
        while let chunk = try stream.readNext() {
            hasher.update(data: chunk)
            data.append(chunk)
        }
        if let expectedSHA256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256 else {
                throw TerminalTelegramControlError.artifactPathRejected
            }
        }
    }
}

extension String {
    /// Escapes `"` and `\` inside a quoted multipart attribute (RFC 7578
    /// §4.2/§5.1). Everything else stays literal: attribute values are
    /// already restricted by the artifact validator.
    func escapingMultipartAttributeQuotes() -> String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Reads a local file in bounded chunks under a hard byte budget.
///
/// The reader is fail-closed: more bytes than promised (or than the budget)
/// aborts with ``TerminalTelegramControlError/payloadTooLarge(limit:)`` and
/// closes the descriptor, so a file that grew between the size check and the
/// read can never inflate an upload. Deliberately non-`Sendable`: it owns the
/// open descriptor for the scope of one encode.
struct TerminalTelegramBoundedFileReader {
    private let handle: FileHandle
    private let budgetBytes: Int
    private let chunkBytes: Int
    private var consumed = 0
    private var finished = false

    init(handle: FileHandle, budgetBytes: Int, chunkBytes: Int) {
        self.handle = handle
        self.budgetBytes = max(0, budgetBytes)
        self.chunkBytes = max(1, chunkBytes)
    }

    /// Reads the next bounded chunk, or `nil` at end-of-budget/EOF.
    mutating func readNext() throws -> Data? {
        guard !finished else { return nil }
        let remaining = budgetBytes - consumed
        guard remaining > 0 else {
            // Only end the part when the file also ended: a file larger than
            // the promised size is a violation, not a quiet truncation.
            let extra = try handle.read(upToCount: 1)
            finished = true
            if let extra, !extra.isEmpty {
                throw TerminalTelegramControlError.payloadTooLarge(limit: budgetBytes)
            }
            return nil
        }
        let wanted = Swift.min(remaining, chunkBytes)
        guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else {
            finished = true
            // Fewer bytes than promised: the file changed underneath us.
            if consumed < budgetBytes {
                throw TerminalTelegramControlError.unexpectedResponse
            }
            return nil
        }
        consumed += chunk.count
        return chunk
    }

    func close() {
        try? handle.close()
    }
}
