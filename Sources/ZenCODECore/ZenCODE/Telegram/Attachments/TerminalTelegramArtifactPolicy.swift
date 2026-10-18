//
//  TerminalTelegramArtifactPolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One outbound artifact the operator explicitly selected on Telegram.
///
/// ZenCODE never uploads repository content, secrets or whole files by
/// default. An artifact exists only as the result of an explicit selection:
/// the operator asks for the session diff with `/diff` and then confirms with
/// one tap on the consent keyboard. `/diff` is the only producer of a
/// `TerminalTelegramArtifact`.
public struct TerminalTelegramArtifact: Sendable, Equatable {
    /// Where the bytes to upload live. Always a local file: uploads are
    /// streamed from disk, never from an in-memory repository copy.
    public let fileURL: URL
    /// Client-visible filename. Sanitized: no path components, no control
    /// characters, bounded length.
    public let filename: String
    /// Explicit MIME type; nil lets Telegram infer it from the extension.
    public let contentType: String?

    public init(fileURL: URL, filename: String, contentType: String? = nil) {
        self.fileURL = fileURL
        self.filename = filename
        self.contentType = contentType
    }
}

/// Fail-closed allowlist that decides what may leave the machine.
///
/// The policy answers two questions for every prospective upload:
/// 1. Is the source path inside a directory that may ever be exported?
/// 2. Is the file an allowed export kind (extension and size)?
/// Both must hold; anything else is refused with an explanatory error. The
/// policy has no "allow everything" mode and no directory escape: candidate
/// paths are normalized and prefix-checked against the allowlist, and the
/// denied secrets list is checked first so a rule ordering mistake can never
/// leak a credential file.
public struct TerminalTelegramArtifactPolicy: Sendable {
    /// Directories whose regular files may be exported, when individually
    /// selected. Repository working directories and dot-directories are never
    /// implicit members of this list: the caller must have resolved the exact
    /// file, and the file must match an allowed extension and size.
    public let allowedDirectories: [URL]
    /// Filename suffixes allowed for export. Defaults to session diffs only.
    public let allowedExtensions: Set<String>
    /// Hard per-file byte budget (also enforced by the multipart builder).
    public let maximumBytes: Int

    /// Names whose files are never exportable, wherever they live.
    static let deniedFilenames: Set<String> = [
        ".env", ".env.local", "credentials.json", "secrets.json", "secrets.yaml",
        "secrets.yml", "id_rsa", "id_ed25519", "id_ecdsa", ".netrc", ".npmrc",
        ".pypirc", "service-account.json", "telegram.json", "settings.json",
        ".git-credentials",
    ]
    /// Path fragments that mark a secret-bearing or VCS-internal tree.
    static let deniedPathFragments: Set<String> = [
        ".git", ".ssh", ".gnupg", ".aws", ".docker", "node_modules",
    ]

    public init(
        allowedDirectories: [URL],
        allowedExtensions: Set<String> = ["diff"],
        maximumBytes: Int = 45 * 1_024 * 1_024
    ) {
        self.allowedDirectories = allowedDirectories
        self.allowedExtensions = allowedExtensions
        self.maximumBytes = maximumBytes
    }

    /// Validates one candidate artifact. Throws a descriptive
    /// `TerminalTelegramControlError` on refusal; returns the normalized
    /// artifact on success.
    public func validated(_ artifact: TerminalTelegramArtifact) throws(TerminalTelegramControlError) -> TerminalTelegramArtifact {
        // 1. Path sanity, fail-closed: the URL must be a file URL whose
        //    standardized form is unchanged (no `..` traversal). Symlinks are
        //    judged in step 3, relative to the allowed directory.
        let path = artifact.fileURL.path
        guard artifact.fileURL.isFileURL,
              artifact.fileURL.standardizedFileURL.path == path,
              let realPath = Self.realPath(path) else {
            throw .artifactPathRejected
        }
        let values: URLResourceValues
        do {
            values = try URL(fileURLWithPath: realPath).resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
        } catch {
            throw TerminalTelegramControlError.artifactPathRejected
        }
        guard values.isRegularFile == true else {
            throw .artifactPathRejected
        }
        let resolved = artifact.fileURL

        // 2. Denied trees and names come first, before any allow rule.
        let components = resolved.pathComponents
        let realComponents = URL(fileURLWithPath: realPath).pathComponents
        for fragment in Self.deniedPathFragments
        where components.contains(fragment) || realComponents.contains(fragment) {
            throw .artifactPathRejected
        }
        let base = resolved.lastPathComponent
        if Self.deniedFilenames.contains(base) {
            throw .artifactPathRejected
        }
        if base.hasPrefix(".env") || base.hasSuffix(".pem") || base.hasSuffix(".key") {
            throw .artifactPathRejected
        }

        // 3. The file must live inside an allowed directory, compared on
        //    resolved real paths. Symlinks in ancestors of the allowed
        //    directory are fine; any symlink between the allowed directory and
        //    the file (or the file itself) is rejected.
        let isAllowed = allowedDirectories.contains { directory in
            Self.isContainedWithoutSymlinks(path: path, in: directory)
        }
        guard isAllowed else {
            throw .artifactPathRejected
        }

        // 4. Extension allowlist.
        let ext = resolved.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            throw .artifactPathRejected
        }

        // 5. Size budget, checked against the real on-disk size.
        let size = values.fileSize ?? 0
        guard size >= 0, size <= maximumBytes else {
            throw .fileTooLarge(limit: maximumBytes)
        }

        // 6. Filename is metadata that travels on the wire: sanitize it.
        let safeFilename = Self.sanitizedFilename(artifact.filename, fallback: base)
        return TerminalTelegramArtifact(
            fileURL: resolved,
            filename: safeFilename,
            contentType: artifact.contentType?.nilIfBlank.map { Self.sanitizedContentType($0) }
        )
    }

    /// `realpath(3)` of `path`, or nil when it cannot be resolved.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else {
            return true // fail closed
        }
        return type == .typeSymbolicLink
    }

    /// True when `path` (unresolved, standardized) lies inside `directory`
    /// by real path and no component below the directory is a symlink.
    private static func isContainedWithoutSymlinks(path: String, in directory: URL) -> Bool {
        guard let realDirectory = realPath(directory.path) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Shortest prefix of the candidate that resolves to the allowed directory.
        var prefix = ""
        for (index, part) in parts.enumerated() {
            prefix += "/" + part
            guard realPath(prefix) == realDirectory else { continue }
            let rest = parts[(index + 1)...]
            guard !rest.isEmpty else { return false }
            var current = prefix
            for component in rest {
                current += "/" + component
                if isSymbolicLink(current) { return false }
            }
            return true
        }
        return false
    }

    /// Normalizes a client-provided filename to a single safe path component.
    public static func sanitizedFilename(_ filename: String, fallback: String) -> String {
        var candidate = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip any directory structure the client tried to smuggle in.
        candidate = URL(fileURLWithPath: candidate).lastPathComponent
        // Drop control characters.
        candidate = String(String.UnicodeScalarView(
            candidate.unicodeScalars.map { scalar in
                if scalar.properties.isDefaultIgnorableCodePoint
                    || (scalar.value < 0x20) || scalar.value == 0x7f {
                    return " "
                }
                return scalar
            }
        ))
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            candidate = fallback
        }
        if candidate.utf8.count > 128 {
            candidate = String(candidate.prefix(96))
        }
        return candidate
    }

    /// Normalizes a MIME type to `type/subtype` with no parameters.
    static func sanitizedContentType(_ contentType: String) -> String {
        let trimmed = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip parameters the server may append before validating shape.
        let cutoff = trimmed.firstIndex { $0 == ";" || $0.isWhitespace } ?? trimmed.endIndex
        let base = trimmed[..<cutoff]
        guard let slash = base.firstIndex(of: "/"),
              slash != base.startIndex,
              slash != base.index(before: base.endIndex) else {
            return "application/octet-stream"
        }
        return String(base)
    }
}
